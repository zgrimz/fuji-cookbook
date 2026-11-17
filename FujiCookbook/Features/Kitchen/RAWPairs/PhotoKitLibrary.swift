import Photos
import UIKit

/// `PhotoLibraryAccessing` over PhotoKit.
final class PhotoKitLibrary: PhotoLibraryAccessing {
    var access: PhotoAccess { PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }

    func requestAccess() async -> PhotoAccess {
        PhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func sharedRAWPhotos() async -> SharedRAWPhotos {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var shared = SharedRAWPhotos()
        assets.enumerateObjects { asset, _, _ in
            let photo = { (kind: SharedRAWPhoto.Kind) in
                SharedRAWPhoto(id: asset.localIdentifier, creationDate: asset.creationDate, kind: kind)
            }
            switch RAWResourceChoice.verdict(for: Self.resources(of: asset)) {
            case .pair: shared.photos.append(photo(.pair))
            case .rawOnly: shared.photos.append(photo(.rawOnly))
            case .noRAW: shared.withoutRAW += 1
            case .invalid: shared.invalid += 1
            }
        }
        return shared
    }

    func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        guard let asset = Self.asset(id) else { return nil }
        let options = PHImageRequestOptions()
        // One callback with the final image; opportunistic delivery calls back twice, which a
        // continuation can't take.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func copyRAF(of id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let asset = Self.asset(id) else { throw RAWCopyError.notVisible }
        let resources = PHAssetResource.assetResources(for: asset)
        let described = resources.map(Self.describe)
        let chosen: PhotoResource
        switch RAWResourceChoice.verdict(for: described) {
        case .pair(let raf), .rawOnly(let raf): chosen = raf
        case .noRAW: throw RAWCopyError.noRAW
        case .invalid: throw RAWCopyError.invalidOriginals
        }
        // `verdict` returns one of `described`, which maps `resources` one to one.
        guard let index = described.firstIndex(of: chosen) else { throw RAWCopyError.noRAW }

        // A directory per copy keeps the original name without two copies colliding.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.safeName(chosen.originalFileName))
        do {
            try await ResourceDownload.write(resources[index], to: file, progress: progress)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let relay = ChangeRelay { continuation.yield() }
            PHPhotoLibrary.shared().register(relay)
            continuation.onTermination = { _ in PHPhotoLibrary.shared().unregisterChangeObserver(relay) }
        }
    }

    func presentSelection(from controller: UIViewController, completion: @escaping ([String]) -> Void) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { identifiers in
            DispatchQueue.main.async { completion(identifiers) }
        }
    }

    private static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func resources(of asset: PHAsset) -> [PhotoResource] {
        PHAssetResource.assetResources(for: asset).map(describe)
    }

    private static func describe(_ resource: PHAssetResource) -> PhotoResource {
        let role: PhotoResource.Role = switch resource.type {
        case .photo: .photo
        case .alternatePhoto: .alternatePhoto
        default: .other
        }
        return PhotoResource(role: role, typeIdentifier: resource.uniformTypeIdentifier,
                             originalFileName: resource.originalFilename)
    }

    /// The name Photos recorded, reduced to its last component so it can't leave the directory.
    private static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." ? "Photo.RAF" : last
    }
}

/// Streams one resource into a file. `requestData` hands the bytes over in chunks, so a 198 MiB
/// GFX100S RAF never sits in memory whole, and its request ID lets cancelling the task stop the
/// transfer, which `writeData` can't.
///
/// The call ends exactly once, on whichever comes first: PhotoKit's completion, the task's
/// cancellation, or a failed write. Cancellation and a failed write don't wait for PhotoKit to
/// call back, which it may not do after `cancelDataRequest`; the file is closed when the call
/// ends, and chunks that arrive afterwards are dropped.
private enum ResourceDownload {
    static func write(_ resource: PHAssetResource, to file: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let request = RequestState(handle: try FileHandle(forWritingTo: file))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress(fraction) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard request.attach(continuation) else { return }
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                    request.write(chunk)
                } completionHandler: { error in
                    request.finish(error.map { .failure($0) } ?? .success(()))
                }
                request.start(id)
            }
        } onCancel: {
            request.stop(with: CancellationError())
        }
    }

    /// The request, the file it writes to and the one continuation, shared between PhotoKit's
    /// callbacks and the cancellation handler, which run on different threads.
    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var id: PHAssetResourceDataRequestID?
        private var continuation: CheckedContinuation<Void, Error>?
        /// Set when the call has ended or was stopped before it began.
        private var outcome: Result<Void, Error>?

        init(handle: FileHandle) {
            self.handle = handle
        }

        /// Holds the continuation, or resumes it at once if the call was stopped before it began.
        /// Returns whether the request should still be made.
        func attach(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
            let early = lock.withLock { () -> Result<Void, Error>? in
                if outcome == nil { self.continuation = continuation }
                return outcome
            }
            guard let early else { return true }
            continuation.resume(with: early)
            return false
        }

        func start(_ id: PHAssetResourceDataRequestID) {
            let stopped = lock.withLock { () -> Bool in
                self.id = id
                return outcome != nil
            }
            if stopped { PHAssetResourceManager.default().cancelDataRequest(id) }
        }

        /// Appends a chunk while the call is still running. A failed write stops the request, so a
        /// full disk doesn't keep downloading.
        func write(_ chunk: Data) {
            let failure = lock.withLock { () -> Error? in
                guard outcome == nil else { return nil }
                do {
                    try handle.write(contentsOf: chunk)
                    return nil
                } catch {
                    return error
                }
            }
            if let failure { stop(with: failure) }
        }

        func finish(_ result: Result<Void, Error>) {
            end(with: result)
        }

        /// Ends the call with `error` and cancels the request if it has started.
        func stop(with error: Error) {
            if let id = end(with: .failure(error)) {
                PHAssetResourceManager.default().cancelDataRequest(id)
            }
        }

        /// Records the outcome, closes the file and resumes the continuation, the first time only.
        /// Returns the request ID when this call was the one that ended it.
        @discardableResult
        private func end(with result: Result<Void, Error>) -> PHAssetResourceDataRequestID? {
            let ended = lock.withLock { () -> (CheckedContinuation<Void, Error>?, PHAssetResourceDataRequestID?)? in
                guard outcome == nil else { return nil }
                outcome = result
                try? handle.close()
                defer { continuation = nil }
                return (continuation, id)
            }
            guard let ended else { return nil }
            ended.0?.resume(with: result)
            return ended.1
        }
    }
}

private final class ChangeRelay: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
