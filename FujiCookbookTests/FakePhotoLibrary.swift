import UIKit
@testable import FujiCookbook

/// A photo library with no Photos behind it. Each id copies to a file, fails with an error, or
/// holds until its task is cancelled, as the test says; the access request can be held open too.
final class FakePhotoLibrary: PhotoLibraryAccessing {
    enum Outcome {
        case raf(String)
        case fails(Error)
        /// Never finishes on its own: waits for its task to be cancelled, then throws.
        case holdsUntilCancelled
    }

    var access: PhotoAccess
    var accessAfterRequest: PhotoAccess
    var shared = SharedRAWPhotos()
    var outcomes: [String: Outcome] = [:]
    /// What Apple's selection screen reports as newly selected.
    var newlySelected: [String] = []
    /// While true, `requestAccess()` waits for `releaseAccessRequest()`.
    var holdsAccessRequest = false

    /// Guards what the library's async methods write off the main thread and the test reads on it.
    private let lock = NSLock()
    private var _requests = 0
    private var _copied: [String] = []
    private var _written: [URL] = []
    private var changeContinuation: AsyncStream<Void>.Continuation?
    private var heldRequest: CheckedContinuation<Void, Never>?

    var requests: Int { lock.withLock { _requests } }
    var copied: [String] { lock.withLock { _copied } }
    /// The files the fake has written, so a test can check they were removed.
    var written: [URL] { lock.withLock { _written } }
    var isFollowingChanges: Bool { lock.withLock { changeContinuation != nil } }
    /// True once a held request is waiting; release it only then, or the release is lost.
    var isHoldingAccessRequest: Bool { lock.withLock { heldRequest != nil } }

    init(access: PhotoAccess = .limited, accessAfterRequest: PhotoAccess = .limited) {
        self.access = access
        self.accessAfterRequest = accessAfterRequest
    }

    func requestAccess() async -> PhotoAccess {
        lock.withLock { _requests += 1 }
        if holdsAccessRequest {
            await withCheckedContinuation { continuation in lock.withLock { heldRequest = continuation } }
        }
        access = accessAfterRequest
        return access
    }

    func releaseAccessRequest() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldRequest = nil }
            return heldRequest
        }
        held?.resume()
    }

    func sharedRAWPhotos() async -> SharedRAWPhotos { shared }

    func thumbnail(for id: String, side: CGFloat) async -> UIImage? { nil }

    func copyRAF(of id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock { _copied.append(id) }
        switch outcomes[id] ?? .fails(RAWCopyError.notVisible) {
        case .fails(let error):
            throw error
        case .holdsUntilCancelled:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .raf(let name):
            progress(1)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try RAFFixture.raf().write(to: file)
            lock.withLock { _written.append(file) }
            return file
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in lock.withLock { changeContinuation = continuation } }
    }

    func announceChange() {
        let continuation = lock.withLock { changeContinuation }
        continuation?.yield()
    }

    func presentSelection(from controller: UIViewController, completion: @escaping ([String]) -> Void) {
        completion(newlySelected)
    }
}
