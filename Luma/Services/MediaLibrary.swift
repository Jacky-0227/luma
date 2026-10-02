import Foundation
import ImageIO
import Observation

enum CaptureKind: String, Codable, Hashable, Sendable {
    case snapshot
    case recording

    var title: String {
        self == .snapshot ? String(localized: "Snapshot") : String(localized: "Recording")
    }
}

struct CapturedMedia: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: CaptureKind
    let fileName: String
}

struct CaptureDestination: Sendable {
    let id: UUID
    let kind: CaptureKind
    let directory: URL
    var snapshotURL: URL { directory.appendingPathComponent("snapshot.png") }
}

enum MediaLibraryError: LocalizedError {
    case invalidCapture, unavailable, saveFailed, deleteFailed

    var errorDescription: String? {
        switch self {
        case .invalidCapture: String(localized: "No complete media file was produced. Please try again.")
        case .unavailable: String(localized: "The local media library is unavailable.")
        case .saveFailed: String(localized: "Unable to save this capture. Check the available storage on your iPhone.")
        case .deleteFailed: String(localized: "Unable to delete this item. Please try again.")
        }
    }
}

/// This directory is excluded from device backups. No camera names, network
/// addresses, credentials, URLs, or raw SDK filenames enter the saved index.
@MainActor
@Observable
final class MediaLibrary {
    static let shared = MediaLibrary()
    private(set) var items: [CapturedMedia] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let manager: FileManager
    @ObservationIgnored private var isReady = false
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        manager = fileManager
        root = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaMedia", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var excludedRoot = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedRoot.setResourceValues(values)
            try fileManager.createDirectory(at: root.appendingPathComponent("Staging"), withIntermediateDirectories: true)
            isReady = true
            reload()
        } catch {
            errorMessage = MediaLibraryError.unavailable.localizedDescription
        }
    }

    func prepare(_ kind: CaptureKind) throws -> CaptureDestination {
        guard isReady else { throw MediaLibraryError.unavailable }
        let id = UUID()
        let directory = root.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch { throw MediaLibraryError.saveFailed }
        return CaptureDestination(id: id, kind: kind, directory: directory)
    }

    /// VLC caches the first recording directory for a playback input. Keep
    /// that workspace alive and move each finalized recording into its own
    /// capture directory before committing it to the library.
    func stageRecording(fileURL: URL, from workspace: CaptureDestination,
                        into destination: CaptureDestination) throws -> URL {
        guard isReady, workspace.kind == .recording, destination.kind == .recording,
              workspace.id != destination.id, isOwned(workspace), isOwned(destination),
              Self.isDirectChild(fileURL, of: workspace.directory),
              Self.recordingExtensions.contains(fileURL.pathExtension.lowercased()),
              let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0
        else { throw MediaLibraryError.invalidCapture }

        let target = destination.directory.appendingPathComponent("recording.\(fileURL.pathExtension.lowercased())")
        guard Self.isDirectChild(target, of: destination.directory) else { throw MediaLibraryError.invalidCapture }
        do {
            try manager.moveItem(at: fileURL, to: target)
            return target
        } catch { throw MediaLibraryError.saveFailed }
    }

    /// Called only after the SDK's completion callback. Validate the actual
    /// file and contain the source in this capture's unique staging directory.
    @discardableResult
    func finish(_ destination: CaptureDestination, fileURL: URL) throws -> CapturedMedia {
        guard isReady, isOwned(destination),
              Self.isDirectChild(fileURL, of: destination.directory),
              let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0
        else { throw MediaLibraryError.invalidCapture }

        let fileExtension = fileURL.pathExtension.lowercased()
        if destination.kind == .snapshot {
            guard fileExtension == "png",
                  let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
            else { throw MediaLibraryError.invalidCapture }
        } else {
            guard Self.recordingExtensions.contains(fileExtension) else { throw MediaLibraryError.invalidCapture }
        }

        let item = CapturedMedia(id: destination.id, createdAt: Date(), kind: destination.kind,
                                 fileName: "\(destination.id.uuidString).\(fileExtension)")
        let finalURL = root.appendingPathComponent(item.fileName)
        do {
            try manager.moveItem(at: fileURL, to: finalURL)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: finalURL.path)
            let updated = [item] + items
            try persist(updated)
            items = updated
            errorMessage = nil
            discard(destination)
            return item
        } catch {
            // Keep a capture recoverable if saving metadata failed. It never
            // appears as "saved" unless both the file and atomic index succeed.
            if manager.fileExists(atPath: finalURL.path) {
                try? manager.moveItem(at: finalURL, to: fileURL)
            }
            throw MediaLibraryError.saveFailed
        }
    }

    func fileURL(for item: CapturedMedia) -> URL? {
        guard items.contains(item), Self.isSafeFileName(item.fileName, id: item.id) else { return nil }
        let url = root.appendingPathComponent(item.fileName)
        guard Self.isDirectChild(url, of: root), manager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func delete(_ item: CapturedMedia) throws {
        guard isReady, let url = fileURL(for: item) else { throw MediaLibraryError.deleteFailed }
        do {
            try manager.removeItem(at: url)
            items.removeAll { $0.id == item.id }
            try persist(items)
        } catch { throw MediaLibraryError.deleteFailed }
    }

    func discard(_ destination: CaptureDestination) {
        guard isOwned(destination) else { return }
        try? manager.removeItem(at: destination.directory)
    }

    func reload() {
        guard isReady else { return }
        guard manager.fileExists(atPath: indexURL.path) else { items = []; return }
        do {
            let decoded = try JSONDecoder().decode([CapturedMedia].self, from: Data(contentsOf: indexURL))
            var seen = Set<UUID>()
            items = decoded.filter { item in
                guard Self.isSafeFileName(item.fileName, id: item.id), seen.insert(item.id).inserted else { return false }
                let url = root.appendingPathComponent(item.fileName)
                return Self.isDirectChild(url, of: root) && manager.fileExists(atPath: url.path)
            }.sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            // Preserve a corrupt index for recovery. No subsequent capture or
            // deletion may replace it with a fresh (apparently empty) library.
            isReady = false
            errorMessage = MediaLibraryError.unavailable.localizedDescription
        }
    }

    private func isOwned(_ destination: CaptureDestination) -> Bool {
        let expected = root.appendingPathComponent("Staging").appendingPathComponent(destination.id.uuidString)
        return Self.isDirectChild(destination.directory, of: root.appendingPathComponent("Staging"))
            && Self.canonicalPath(expected) == Self.canonicalPath(destination.directory)
    }

    private func persist(_ values: [CapturedMedia]) throws {
        try JSONEncoder().encode(values).write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static let recordingExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "ts", "avi", "webm", "mpg", "mpeg", "ogg"]

    static func isSafeFileName(_ name: String, id: UUID) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == Substring(id.uuidString)
            && (parts[1] == "png" || recordingExtensions.contains(String(parts[1])))
    }

    static func isDirectChild(_ file: URL, of directory: URL) -> Bool {
        file.isFileURL && directory.isFileURL
            && canonicalPath(file.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent())
                == canonicalPath(directory)
    }

    private static func canonicalPath(_ url: URL) -> String {
        // Directory URLs may differ only in their trailing slash. Compare
        // resolved filesystem paths while retaining the symlink containment check.
        (url.standardizedFileURL.resolvingSymlinksInPath().path as NSString).standardizingPath
    }
}
