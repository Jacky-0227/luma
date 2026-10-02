import XCTest
@testable import Luma

final class LumaCoreTests: XCTestCase {
    func testHikvisionMainAndSubstreamPaths() throws {
        let camera = CameraConfiguration(name: "客厅", host: "192.0.2.60", channel: 12)
        XCTAssertEqual(try camera.streamURL(password: "", quality: .main).path, "/Streaming/Channels/1201")
        XCTAssertEqual(try camera.streamURL(password: "").path, "/Streaming/Channels/1202")
    }

    func testCredentialsRoundTripWithoutBecomingURLComponents() throws {
        let username = "用户@:#/%?"
        let password = "  p@:#/%?秘密  "
        let camera = CameraConfiguration(name: "玄关", host: "camera.local", username: username)
        let url = try camera.streamURL(password: password)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.user, username)
        XCTAssertEqual(components.password, password)
        XCTAssertEqual(components.host, "camera.local")
        XCTAssertEqual(components.path, "/Streaming/Channels/102")
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertFalse(camera.displayAddress.contains(username))
        XCTAssertFalse(camera.displayAddress.contains(password))
    }

    func testNormalizationAndIPv6() throws {
        let camera = CameraConfiguration(name: "  花园  ", host: " [2001:db8::1234] \n")
        let validated = try camera.validated()
        XCTAssertEqual(validated.name, "花园")
        XCTAssertEqual(validated.host, "2001:db8::1234")
        XCTAssertEqual(validated.displayAddress, "[2001:db8::1234]:554")
        XCTAssertTrue(try validated.streamURL(password: "p").absoluteString.contains("@[2001:db8::1234]:554/"))
        for host in ["::1", "::", "::ffff:192.0.2.2", "fe80:0:0:0:1:2:3:4"] {
            XCTAssertNoThrow(try CameraConfiguration(name: "测试", host: host).streamURL(password: ""))
        }
    }

    func testRejectsInjectedAndMalformedHosts() {
        for host in ["rtsp://camera.local", "user:secret@camera.local", "camera.local/stream", "camera.local:554", "camera.local?x=y", "camera.local#fragment", "camera.local\nother", "192.0.2.999", "2001:::1", "::1:", "1:2:3:4:5:6:7:8:9", "camera..local", "[camera.local]"] {
            XCTAssertThrowsError(try CameraConfiguration(name: "测试", host: host).validated(), host)
        }
    }

    func testPortChannelAndNameBounds() {
        for port in [0, -1, 65_536] {
            XCTAssertThrowsError(try CameraConfiguration(name: "测试", host: "camera.local", port: port).validated())
        }
        for channel in [0, -1, 1000, Int.max] {
            XCTAssertThrowsError(try CameraConfiguration(name: "测试", host: "camera.local", channel: channel).validated())
        }
        for port in [1, 554, 65_535] {
            XCTAssertNoThrow(try CameraConfiguration(name: "测试", host: "camera.local", port: port).validated())
        }
        XCTAssertThrowsError(try CameraConfiguration(name: " \n ", host: "camera.local").validated())
    }

    func testCustomPathRemainsPath() throws {
        let camera = CameraConfiguration(name: "测试", host: "camera.local", customPath: "/video/live stream%1")
        let url = try camera.streamURL(password: "password")
        XCTAssertEqual(url.path, "/video/live stream%1")
        for path in ["rtsp://camera.local/live", "//evil.local/live", "/user:secret@camera", "/live?token=secret", "/live#fragment", "/live\nstream"] {
            XCTAssertThrowsError(try CameraConfiguration(name: "测试", host: "camera.local", customPath: path).validated())
        }
    }

    func testCodableContainsNoCredentialFields() throws {
        let camera = CameraConfiguration(name: "书房", host: "192.0.2.8")
        let data = try JSONEncoder().encode(camera)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["password"])
        XCTAssertNil(object["streamURL"])
        XCTAssertEqual(try JSONDecoder().decode(CameraConfiguration.self, from: data), camera)
    }

    @MainActor
    func testStoreReloadAndCredentialSeparation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("cameras.json")
        let credentials = MemoryCredentials()
        let store = CameraStore(storageURL: storageURL, credentials: credentials)
        let camera = CameraConfiguration(name: "客厅", host: "192.0.2.20")
        let password = "NEVER-PERSIST-THIS@:#/%?"
        try store.save(camera, password: password)
        XCTAssertEqual(try store.password(for: camera), password)
        XCTAssertFalse(try String(contentsOf: storageURL, encoding: .utf8).contains(password))
        let reopened = CameraStore(storageURL: storageURL, credentials: credentials)
        XCTAssertEqual(reopened.cameras, [camera])
        try reopened.delete(camera)
        XCTAssertTrue(reopened.cameras.isEmpty)
        XCTAssertNil(try credentials.read(for: camera.id))
        XCTAssertTrue(CameraStore(storageURL: storageURL, credentials: credentials).cameras.isEmpty)
    }

    @MainActor
    func testFailedWriteRollsBackPasswordAndPreservesMemory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("cameras.json")
        let credentials = MemoryCredentials()
        let store = CameraStore(storageURL: storageURL, credentials: credentials)
        let camera = CameraConfiguration(name: "客厅", host: "192.0.2.20")
        try store.save(camera, password: "original")
        // Replacing the destination with a directory makes atomic file replacement fail.
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(camera, password: "replacement"))
        XCTAssertEqual(try store.password(for: camera), "original")
        XCTAssertEqual(store.cameras, [camera])
        XCTAssertThrowsError(try store.delete(camera))
        XCTAssertEqual(try store.password(for: camera), "original")
        XCTAssertEqual(store.cameras, [camera])
    }

    @MainActor
    func testCorruptFileIsNeverOverwritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("cameras.json")
        let original = Data("unreadable original content".utf8)
        try original.write(to: storageURL)
        let store = CameraStore(storageURL: storageURL, credentials: MemoryCredentials())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.save(CameraConfiguration(name: "测试", host: "camera.local"), password: "p"))
        XCTAssertEqual(try Data(contentsOf: storageURL), original)
    }

    @MainActor
    func testCredentialFailureDoesNotPublishOrPersistChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("cameras.json")
        let credentials = MemoryCredentials()
        let store = CameraStore(storageURL: storageURL, credentials: credentials)
        let camera = CameraConfiguration(name: "客厅", host: "192.0.2.20")
        try store.save(camera, password: "original")
        let originalData = try Data(contentsOf: storageURL)
        var changed = camera
        changed.name = "Changed"
        credentials.rejectWrites = true
        XCTAssertThrowsError(try store.save(changed, password: "replacement"))
        XCTAssertThrowsError(try store.delete(camera))
        XCTAssertEqual(store.cameras, [camera])
        XCTAssertEqual(try store.password(for: camera), "original")
        XCTAssertEqual(try Data(contentsOf: storageURL), originalData)
    }

    @MainActor
    func testFailedNewCameraWriteRemovesNewPassword() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("cameras.json")
        let credentials = MemoryCredentials()
        let store = CameraStore(storageURL: storageURL, credentials: credentials)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        let camera = CameraConfiguration(name: "客厅", host: "192.0.2.20")
        XCTAssertThrowsError(try store.save(camera, password: "secret"))
        XCTAssertTrue(store.cameras.isEmpty)
        XCTAssertNil(try credentials.read(for: camera.id))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumaTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class MemoryCredentials: CameraCredentialStorage {
    private var passwords: [UUID: String] = [:]
    var rejectWrites = false
    func read(for cameraID: UUID) throws -> String? { passwords[cameraID] }
    func set(_ password: String, for cameraID: UUID) throws {
        guard !rejectWrites else { throw CredentialError.invalidData }
        passwords[cameraID] = password
    }
    func remove(for cameraID: UUID) throws {
        guard !rejectWrites else { throw CredentialError.invalidData }
        passwords.removeValue(forKey: cameraID)
    }
}
