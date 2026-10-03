import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An opaque, single-use capture destination issued by one thumbnail store.
struct CameraThumbnailCapture: Sendable, Equatable {
    let fileURL: URL
    fileprivate let id: UUID
    fileprivate let storeID: UUID
    fileprivate let cameraID: UUID
    fileprivate let sourceKey: String
    fileprivate let generation: UInt64
}

/// Local static previews only. The catalog is supplied by CameraStore; capture
/// callbacks cannot register deleted cameras or change their source identity.
actor CameraThumbnailStore {
    nonisolated static let didChange = Notification.Name("LumaCameraThumbnailDidChange")
    typealias Encoder = @Sendable (URL) async -> Data?
    private struct Record: Codable {
        let version: Int
        let cameraID: UUID
        let sourceKey: String
        let jpeg: Data
    }

    private let directory: URL
    private let storeID = UUID()
    private let encode: Encoder
    private var catalog: [UUID: String]
    private var catalogRevision: UInt64 = 0
    private var generations: [UUID: UInt64] = [:]
    private var latest: [UUID: UUID] = [:]
    private var pending: [UUID: CameraThumbnailCapture] = [:]
    private var didScavengePending = false

    init(directory: URL, cameras: [CameraConfiguration] = [],
         encoder: @escaping Encoder = { await CameraThumbnailEncoder.encode($0) }) {
        self.directory = directory.standardizedFileURL
        catalog = Self.catalog(for: cameras)
        encode = encoder
    }

    /// Neither a username nor a password is part of the stored identity. Names,
    /// PTZ settings and transport selection do not change the video source.
    nonisolated static func key(for camera: CameraConfiguration) -> String {
        let components = [camera.id.uuidString,
                          camera.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                          String(camera.port), String(camera.channel), camera.customPath,
                          camera.defaultQuality.rawValue]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func imageData(for camera: CameraConfiguration) -> Data? {
        guard !Task.isCancelled, catalog[camera.id] == Self.key(for: camera) else { return nil }
        let file = recordURL(camera.id)
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1_048_576,
              let data = try? Data(contentsOf: file), data.count <= 1_048_576,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.cameraID == camera.id,
              record.sourceKey == catalog[camera.id],
              CameraThumbnailEncoder.isValidJPEG(record.jpeg) else { return nil }
        return record.jpeg
    }

    func prepareCapture(for camera: CameraConfiguration) -> CameraThumbnailCapture? {
        let key = Self.key(for: camera)
        guard !Task.isCancelled, catalog[camera.id] == key else { return nil }
        do {
            try prepareDirectory(directory)
            scavengeOldPending()
            let captureID = UUID()
            let captureDirectory = pendingDirectory(captureID)
            try prepareDirectory(captureDirectory)
            let capture = CameraThumbnailCapture(fileURL: captureDirectory.appendingPathComponent("snapshot.png"),
                id: captureID, storeID: storeID, cameraID: camera.id, sourceKey: key,
                generation: generations[camera.id, default: 0])
            if let oldID = latest[camera.id], let old = pending[oldID] { discard(old) }
            latest[camera.id] = captureID
            pending[captureID] = capture
            return capture
        } catch { return nil }
    }

    func save(_ capture: CameraThumbnailCapture) async {
        guard isCurrent(capture), !Task.isCancelled else { discard(capture); return }
        // Compression suspends this actor so a deletion, edit or newer capture
        // can revoke this ticket while ImageIO is working away from the UI.
        let jpeg = await encode(capture.fileURL)
        defer { discard(capture) }
        guard !Task.isCancelled, isCurrent(capture), let jpeg,
              CameraThumbnailEncoder.isValidJPEG(jpeg) else { return }
        do {
            let record = Record(version: 1, cameraID: capture.cameraID, sourceKey: capture.sourceKey, jpeg: jpeg)
            let data = try JSONEncoder().encode(record)
            guard data.count <= 1_048_576 else { return }
            // Image and fingerprint are one atomic record, never two files that
            // could refer to different sources after an interrupted update.
            try data.write(to: recordURL(capture.cameraID), options: [.atomic, .completeFileProtection])
            notify(capture.cameraID)
        } catch {
            // Keep the previous successful preview when a capture cannot save.
        }
    }

    /// Each capture owns its directory. Removing it also prevents VLC's late
    /// fopen from recreating a discarded snapshot after a timeout or teardown.
    func discard(_ capture: CameraThumbnailCapture) {
        guard capture.storeID == storeID else { return }
        pending[capture.id] = nil
        if latest[capture.cameraID] == capture.id { latest[capture.cameraID] = nil }
        try? FileManager.default.removeItem(at: pendingDirectory(capture.id))
    }

    /// Monotonic snapshots avoid out-of-order tasks restoring an earlier catalog.
    /// Initialization does not prune: an unreadable camera file must not erase
    /// previews. CameraStore calls this only after a successful metadata write.
    func prune(existing cameras: [CameraConfiguration], revision: UInt64) {
        guard revision > catalogRevision else { return }
        let updated = Self.catalog(for: cameras)
        let changed = Set(catalog.keys).union(updated.keys).filter { catalog[$0] != updated[$0] }
        catalogRevision = revision
        catalog = updated
        for id in changed {
            generations[id, default: 0] &+= 1
            if let captureID = latest[id], let capture = pending[captureID] { discard(capture) }
            try? FileManager.default.removeItem(at: recordURL(id))
            notify(id)
        }
        // Only our UUID-named record files are eligible for orphan cleanup.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), catalog[id] == nil else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func isCurrent(_ capture: CameraThumbnailCapture) -> Bool {
        capture.storeID == storeID && pending[capture.id] == capture
            && latest[capture.cameraID] == capture.id
            && catalog[capture.cameraID] == capture.sourceKey
            && generations[capture.cameraID, default: 0] == capture.generation
    }

    private func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func pendingDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("Pending", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func scavengeOldPending() {
        guard !didScavengePending else { return }
        didScavengePending = true
        let parent = directory.appendingPathComponent("Pending", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: Array(keys)) else { return }
        // A crash can leave a full-sized PNG. Keep recent captures, including
        // ones owned by another live store, and never touch arbitrary entries.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            guard let id = UUID(uuidString: file.lastPathComponent), pending[id] == nil,
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func notify(_ id: UUID) {
        NotificationCenter.default.post(name: Self.didChange, object: id)
    }

    private nonisolated static func catalog(for cameras: [CameraConfiguration]) -> [UUID: String] {
        var values: [UUID: String] = [:]
        for camera in cameras { values[camera.id] = key(for: camera) }
        return values
    }
}

enum CameraThumbnailEncoder {
    static let maximumJPEGBytes = 524_288

    static func encode(_ file: URL) async -> Data? {
        // A detached worker is deliberate: compression must not hold the store
        // actor while its catalog changes, and no UI object crosses this boundary.
        let worker = Task.detached(priority: .utility) { makeJPEG(file) }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }

    static func isValidJPEG(_ data: Data) -> Bool {
        guard data.count > 3, data.count <= maximumJPEGBytes, data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let dimensions = dimensions(source), dimensions.width <= 640, dimensions.height <= 640 else { return false }
        return true
    }

    private static func makeJPEG(_ file: URL) -> Data? {
        guard !Task.isCancelled,
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 33_554_432,
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = dimensions(source), size.width <= 16_384, size.height <= 16_384,
              size.width * size.height <= 64_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 640,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), !Task.isCancelled else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Re-encode pixels only: source EXIF, GPS and other metadata are omitted.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
        let result = output as Data
        return isValidJPEG(result) ? result : nil
    }

    private static func dimensions(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
