import SwiftData
import UIKit

/// Display-size copies of developed JPEGs, read and decoded off the main actor.
///
/// A version's `imageData` is the full developed JPEG in external storage, 25.7 MB on the X-T50 at
/// full resolution (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md`). Reading it through
/// the main context would put that read on the main actor for every tile, so this actor reads it
/// through its own context, decodes straight to display size with ImageIO, and lets the bytes go.
@ModelActor
actor DevelopedImageLoader {
    /// The version's developed JPEG at no more than `maxLongEdge` pixels, or nil when the store holds
    /// no image for it: the version is gone, or was saved without its bytes. Callers keep showing
    /// the inline thumbnail on nil.
    func image(for versionID: UUID, maxLongEdge: CGFloat) -> UIImage? {
        if let cached = DevelopedImageCache.image(for: versionID, maxLongEdge: maxLongEdge) { return cached }
        var descriptor = FetchDescriptor<CookedVersion>(predicate: #Predicate { $0.uuid == versionID })
        descriptor.fetchLimit = 1
        guard let data = try? modelContext.fetch(descriptor).first?.imageData, !data.isEmpty,
              let image = ImageDownsampler.downsample(data, maxLongEdge: maxLongEdge) else { return nil }
        DevelopedImageCache.store(image, for: versionID, maxLongEdge: maxLongEdge)
        return image
    }

    /// The display copy `image(for:maxLongEdge:)` last made at this size, if it is still cached;
    /// cheap enough to call while rendering, so a revisited card can draw sharp at once.
    nonisolated static func cachedImage(for versionID: UUID, maxLongEdge: CGFloat) -> UIImage? {
        DevelopedImageCache.image(for: versionID, maxLongEdge: maxLongEdge)
    }

    /// The version's developed JPEG bytes as the camera returned them, EXIF included, or nil when
    /// the store holds none for it.
    func jpeg(for versionID: UUID) -> Data? {
        var descriptor = FetchDescriptor<CookedVersion>(predicate: #Predicate { $0.uuid == versionID })
        descriptor.fetchLimit = 1
        guard let data = try? modelContext.fetch(descriptor).first?.imageData, !data.isEmpty else { return nil }
        return data
    }
}

/// Decoded display copies, keyed by version and size. Versions are immutable once stored, so a
/// uuid-keyed cache never goes stale. Costed in bytes, and kept while the app is in the background
/// (`NSCache` empties then, and every return to Recent Results decoded every card again); a memory
/// warning empties it.
private enum DevelopedImageCache {
    private static let cache: CostBoundedCache<String, UIImage> = {
        let cache = CostBoundedCache<String, UIImage>(costLimit: 96 * 1024 * 1024)
        // The observer lives as long as the process, as the cache does; nothing removes it.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in cache.removeAll() }
        return cache
    }()

    static func image(for id: UUID, maxLongEdge: CGFloat) -> UIImage? {
        cache.value(for: key(id, maxLongEdge))
    }

    static func store(_ image: UIImage, for id: UUID, maxLongEdge: CGFloat) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.insert(image, for: key(id, maxLongEdge), cost: Int(pixels) * 4)
    }

    private static func key(_ id: UUID, _ maxLongEdge: CGFloat) -> String {
        "\(id.uuidString)-\(Int(maxLongEdge))"
    }
}
