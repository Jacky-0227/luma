import Foundation
import Observation

/// Small, UI-owned configuration store. Every mutation finishes synchronously on MainActor.
@MainActor
@Observable
final class CameraStore {
    private(set) var cameras: [CameraConfiguration] = []
    var errorMessage: String?

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let credentials: any CameraCredentialStorage
    @ObservationIgnored private var writesBlocked = false

    convenience init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(storageURL: applicationSupport.appendingPathComponent("Luma", isDirectory: true)
            .appendingPathComponent("cameras.json"), credentials: KeychainService())
    }

    /// Dependency injection also allows persistence failure and rollback to be tested.
    init(storageURL: URL, credentials: any CameraCredentialStorage) {
        self.storageURL = storageURL
        self.credentials = credentials
        load()
    }

    func save(_ camera: CameraConfiguration, password: String) throws {
        try requireWritable()
        let validated = try camera.validated()
        let previousPassword = try credentials.read(for: validated.id)
        var updated = cameras
        if let index = updated.firstIndex(where: { $0.id == validated.id }) {
            updated[index] = validated
        } else {
            updated.append(validated)
        }
        let data = try encoded(updated)
        try credentials.set(password, for: validated.id)
        do {
            try persist(data)
        } catch {
            try restorePassword(previousPassword, for: validated.id)
            throw CameraStoreError.cannotSave
        }
        cameras = updated
        errorMessage = nil
    }

    func delete(_ camera: CameraConfiguration) throws {
        try requireWritable()
        guard cameras.contains(where: { $0.id == camera.id }) else { return }
        let previousPassword = try credentials.read(for: camera.id)
        let updated = cameras.filter { $0.id != camera.id }
        let data = try encoded(updated)
        try credentials.remove(for: camera.id)
        do {
            try persist(data)
        } catch {
            try restorePassword(previousPassword, for: camera.id)
            throw CameraStoreError.cannotSave
        }
        cameras = updated
        errorMessage = nil
    }

    func password(for camera: CameraConfiguration) throws -> String {
        guard let password = try credentials.read(for: camera.id) else { throw CredentialError.missingPassword }
        return password
    }

    func exportConfiguration() throws -> Data {
        try requireWritable()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ConfigurationBackup(cameras: cameras))
    }

    /// Import metadata only, preserving existing IDs and their Keychain entries.
    /// Newly imported cameras require the user to enter their passwords locally.
    @discardableResult
    func importConfiguration(_ data: Data) throws -> Int {
        try requireWritable()
        let incoming = try ConfigurationBackup.decode(data)
        let existingIDs = Set(cameras.map(\.id))
        let additions = incoming.filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return 0 }
        let updated = cameras + additions
        let updatedData = try encoded(updated)
        // Imported UUIDs are external metadata, not authority to reuse a secret.
        // Keychain can outlive the metadata file, for example after reinstalling.
        // Read every old value before changing anything, so a failed read cannot
        // leave a partially cleared set of credentials.
        let orphaned = try additions.compactMap { camera -> (id: UUID, password: String)? in
            guard let password = try credentials.read(for: camera.id) else { return nil }
            return (camera.id, password)
        }
        var removed: [(id: UUID, password: String)] = []
        do {
            for item in orphaned {
                try credentials.remove(for: item.id)
                removed.append(item)
            }
            try persist(updatedData)
        } catch {
            // Attempt every restoration even if one fails. Preserve the original
            // metadata and stop further writes when rollback is incomplete.
            var rollbackFailed = false
            for item in removed.reversed() {
                do { try credentials.set(item.password, for: item.id) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                writesBlocked = true
                errorMessage = CameraStoreError.rollbackFailed.localizedDescription
                throw CameraStoreError.rollbackFailed
            }
            throw CameraStoreError.cannotSave
        }
        cameras = updated
        errorMessage = nil
        return additions.count
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let stored = try JSONDecoder().decode([CameraConfiguration].self, from: Data(contentsOf: storageURL))
            let validated = try stored.map { try $0.validated() }
            guard Set(validated.map(\.id)).count == validated.count else { throw CameraStoreError.cannotLoad }
            cameras = validated
        } catch {
            // Keep the original file untouched; an empty UI must never overwrite unreadable data.
            writesBlocked = true
            errorMessage = CameraStoreError.cannotLoad.localizedDescription
        }
    }

    private func requireWritable() throws {
        guard !writesBlocked else { throw CameraStoreError.writesBlocked }
    }

    private func encoded(_ cameras: [CameraConfiguration]) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(cameras)
        } catch {
            throw CameraStoreError.cannotSave
        }
    }

    private func persist(_ data: Data) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Metadata remains local to the device as well as the Keychain password.
        var privateDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(values)
        try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
    }

    private func restorePassword(_ password: String?, for cameraID: UUID) throws {
        do {
            if let password {
                try credentials.set(password, for: cameraID)
            } else {
                try credentials.remove(for: cameraID)
            }
        } catch {
            writesBlocked = true
            errorMessage = CameraStoreError.rollbackFailed.localizedDescription
            throw CameraStoreError.rollbackFailed
        }
    }
}

enum CameraStoreError: LocalizedError {
    case cannotLoad, cannotSave, writesBlocked, rollbackFailed

    var errorDescription: String? {
        switch self {
        case .cannotLoad: String(localized: "Camera settings could not be read. The original file is preserved and changes are paused. Unlock your iPhone and reopen Luma. If this continues, preserve the app data.")
        case .cannotSave: String(localized: "Camera settings could not be saved. The original settings and password were restored. Check available storage and try again.")
        case .writesBlocked: String(localized: "Camera settings cannot be safely changed right now. Reopen Luma. If this continues, preserve the app data.")
        case .rollbackFailed: String(localized: "Saving failed and the password could not be restored. Changes are paused. Unlock your iPhone, reopen Luma, and check this camera's password.")
        }
    }
}
