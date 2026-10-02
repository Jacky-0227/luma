import XCTest
@testable import Luma

final class ConfigurationBackupTests: XCTestCase {
    @MainActor
    func testExportOmitsPasswordsAndImportPreservesExistingCameras() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = BackupTestCredentials()
        let source = CameraStore(storageURL: folder.appendingPathComponent("source.json"), credentials: credentials)
        let first = CameraConfiguration(name: "First", host: "192.0.2.1", ptzEnabled: true)
        let second = CameraConfiguration(name: "Second", host: "192.0.2.2")
        try source.save(first, password: "do-not-export-this-password")
        try source.save(second, password: "another-secret-password")
        let data = try source.exportConfiguration()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("do-not-export-this-password"))
        XCTAssertFalse(text.contains("another-secret-password"))
        XCTAssertFalse(text.contains("\"password\""))

        let importedCredentials = BackupTestCredentials()
        let destination = CameraStore(storageURL: folder.appendingPathComponent("destination.json"), credentials: importedCredentials)
        var existing = first
        existing.name = "Keep local name"
        try destination.save(existing, password: "keep-local-password")
        XCTAssertEqual(try destination.importConfiguration(data), 1)
        XCTAssertEqual(destination.cameras, [existing, second])
        XCTAssertEqual(try destination.password(for: existing), "keep-local-password")
        XCTAssertThrowsError(try destination.password(for: second))
        XCTAssertEqual(try destination.importConfiguration(data), 0)
        let reopened = CameraStore(storageURL: folder.appendingPathComponent("destination.json"), credentials: importedCredentials)
        XCTAssertEqual(reopened.cameras, [existing, second])
    }

    func testImportRejectsForeignVersionsDuplicateIDsAndOversizedFiles() throws {
        let camera = CameraConfiguration(name: "Test", host: "192.0.2.1")
        let duplicate = try JSONEncoder().encode(ConfigurationBackup(cameras: [camera, camera]))
        XCTAssertThrowsError(try ConfigurationBackup.decode(duplicate))
        XCTAssertThrowsError(try ConfigurationBackup.decode(Data(repeating: 0, count: 2_000_001)))
        let data = try JSONEncoder().encode(ConfigurationBackup(cameras: [camera]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        XCTAssertThrowsError(try ConfigurationBackup.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try ConfigurationBackup.decode(Data("{}".utf8)))
    }

    @MainActor
    func testImportedCameraCannotInheritAnOrphanedPassword() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = BackupTestCredentials()
        let store = CameraStore(storageURL: folder.appendingPathComponent("cameras.json"), credentials: credentials)
        let incoming = CameraConfiguration(name: "Imported endpoint", host: "192.0.2.99")
        try credentials.set("password-from-an-older-device", for: incoming.id)
        let backup = try JSONEncoder().encode(ConfigurationBackup(cameras: [incoming]))

        XCTAssertEqual(try store.importConfiguration(backup), 1)
        XCTAssertEqual(store.cameras, [incoming])
        XCTAssertThrowsError(try store.password(for: incoming))
        XCTAssertNil(try credentials.read(for: incoming.id))
        XCTAssertEqual(try store.importConfiguration(backup), 0)

        // Supplying a new password after import restores the normal edit path.
        try store.save(incoming, password: "new-device-password")
        XCTAssertEqual(try store.password(for: incoming), "new-device-password")
        XCTAssertEqual(try store.importConfiguration(backup), 0)
        XCTAssertEqual(try store.password(for: incoming), "new-device-password")
    }

    @MainActor
    func testFailedImportWriteRestoresAllOrphanedPasswords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = BackupTestCredentials()
        let location = folder.appendingPathComponent("cameras.json")
        let store = CameraStore(storageURL: location, credentials: credentials)
        let existing = CameraConfiguration(name: "Existing", host: "192.0.2.1")
        try store.save(existing, password: "existing-secret")
        let first = CameraConfiguration(name: "First", host: "192.0.2.2")
        let second = CameraConfiguration(name: "Second", host: "192.0.2.3")
        try credentials.set("first-orphan", for: first.id)
        try credentials.set("second-orphan", for: second.id)
        let backup = try JSONEncoder().encode(ConfigurationBackup(cameras: [first, second]))

        // A directory cannot be atomically replaced by the JSON file.
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.importConfiguration(backup))
        XCTAssertEqual(store.cameras, [existing])
        XCTAssertEqual(try store.password(for: existing), "existing-secret")
        XCTAssertEqual(try credentials.read(for: first.id), "first-orphan")
        XCTAssertEqual(try credentials.read(for: second.id), "second-orphan")
    }

    @MainActor
    func testCredentialRemovalFailureRollsBackEarlierRemovalsAndKeepsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = BackupTestCredentials()
        let location = folder.appendingPathComponent("cameras.json")
        let store = CameraStore(storageURL: location, credentials: credentials)
        let existing = CameraConfiguration(name: "Existing", host: "192.0.2.1")
        try store.save(existing, password: "existing-secret")
        let originalData = try Data(contentsOf: location)
        let first = CameraConfiguration(name: "First", host: "192.0.2.2")
        let second = CameraConfiguration(name: "Second", host: "192.0.2.3")
        try credentials.set("first-orphan", for: first.id)
        try credentials.set("second-orphan", for: second.id)
        credentials.rejectRemovalFor = second.id

        XCTAssertThrowsError(try store.importConfiguration(JSONEncoder().encode(ConfigurationBackup(cameras: [first, second]))))
        XCTAssertEqual(store.cameras, [existing])
        XCTAssertEqual(try Data(contentsOf: location), originalData)
        XCTAssertEqual(try credentials.read(for: first.id), "first-orphan")
        XCTAssertEqual(try credentials.read(for: second.id), "second-orphan")
        XCTAssertEqual(try store.password(for: existing), "existing-secret")
    }

    @MainActor
    func testRollbackFailureStillRestoresOtherPasswordsAndBlocksLaterWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = BackupTestCredentials()
        let location = folder.appendingPathComponent("cameras.json")
        let store = CameraStore(storageURL: location, credentials: credentials)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let first = CameraConfiguration(name: "First", host: "192.0.2.2")
        let second = CameraConfiguration(name: "Second", host: "192.0.2.3")
        try credentials.set("first-orphan", for: first.id)
        try credentials.set("second-orphan", for: second.id)
        credentials.rejectSetFor = second.id

        XCTAssertThrowsError(try store.importConfiguration(JSONEncoder().encode(ConfigurationBackup(cameras: [first, second]))))
        XCTAssertEqual(try credentials.read(for: first.id), "first-orphan", "An earlier failed restoration must not skip the remaining passwords.")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.cameras.isEmpty)
        credentials.rejectSetFor = nil
        XCTAssertThrowsError(try store.save(first, password: "new-password"))
    }
}

private final class BackupTestCredentials: CameraCredentialStorage {
    private var values: [UUID: String] = [:]
    var rejectRemovalFor: UUID?
    var rejectSetFor: UUID?
    func read(for cameraID: UUID) throws -> String? { values[cameraID] }
    func set(_ password: String, for cameraID: UUID) throws {
        guard rejectSetFor != cameraID else { throw CredentialError.invalidData }
        values[cameraID] = password
    }
    func remove(for cameraID: UUID) throws {
        guard rejectRemovalFor != cameraID else { throw CredentialError.invalidData }
        values[cameraID] = nil
    }
}
