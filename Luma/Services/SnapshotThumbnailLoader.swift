import Foundation
import ImageIO

/// ImageIO produces an immutable CGImage. Only this immutable result crosses
/// executors; its source and mutable decode options stay on the loader actor.
struct SnapshotThumbnail: @unchecked Sendable {
    let image: CGImage
}

/// Serializes expensive file reads and decoding away from the UI executor.
/// Cancelled presentations skip queued work and never publish a stale image.
actor SnapshotThumbnailLoader {
    static let shared = SnapshotThumbnailLoader()

    func load(url: URL, maximumPixelSize: Int = 2048) -> SnapshotThumbnail? {
        guard !Task.isCancelled, url.isFileURL, maximumPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return SnapshotThumbnail(image: image)
    }
}
