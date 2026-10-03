import XCTest
@testable import Luma

final class DashboardSessionTests: XCTestCase {
    @MainActor
    func testRepeatedVisibilityKeepsPlayersButExplicitReconnectReplacesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = DashboardCredentials()
        let store = CameraStore(storageURL: root.appendingPathComponent("cameras.json"), credentials: credentials)
        let camera = CameraConfiguration(name: "Local test", host: "127.0.0.1")
        try store.save(camera, password: "test-only")
        let dashboard = DashboardSession()
        // No drawable is attached: exercise ownership without opening a socket.
        dashboard.show([camera], store: store, active: true)
        await waitForTransition(dashboard)
        let original = try XCTUnwrap(dashboard.cameras.first?.player)
        let initialReads = credentials.readCount

        for _ in 0..<20 { dashboard.show([camera], store: store, active: true) }
        XCTAssertFalse(dashboard.isTransitioning)
        XCTAssertTrue(dashboard.cameras.first?.player === original)
        XCTAssertEqual(credentials.readCount, initialReads)

        dashboard.show([camera], store: store, active: true, forceRestart: true)
        await waitForTransition(dashboard)
        XCTAssertFalse(dashboard.cameras.first?.player === original)
        XCTAssertEqual(credentials.readCount, initialReads + 1)

        await dashboard.suspendAndWait()
        XCTAssertTrue(dashboard.cameras.isEmpty)
        dashboard.show([camera], store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.count, 1)
        await dashboard.suspendAndWait()
    }

    @MainActor
    func testSixteenCameraPageCreatesEveryPlayerAndSwitchStopsAllPreviousPlayers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = DashboardCredentials()
        let store = CameraStore(storageURL: root.appendingPathComponent("cameras.json"), credentials: credentials)
        let cameras = try makeCameras(count: 24, store: store)
        let dashboard = DashboardSession()
        defer { dashboard.suspend(); try? FileManager.default.removeItem(at: root) }
        // Deliberately do not attach drawables: ownership is exercised without
        // starting RTSP sockets or relying on physical cameras in a unit test.
        dashboard.show(Array(cameras.prefix(16)), store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.map(\.id), Array(cameras.prefix(16)).map(\.id))
        let retiring = dashboard.cameras.compactMap(\.player)
        XCTAssertEqual(retiring.count, 16)
        XCTAssertTrue(retiring.allSatisfy { $0.isMuted && $0.quality == .sub && !$0.aspectFill })
        XCTAssertTrue(retiring.allSatisfy { $0.state == .connecting })
        let reads = credentials.readCount
        for _ in 0..<10 { dashboard.show(Array(cameras.prefix(16)), store: store, active: true) }
        XCTAssertEqual(credentials.readCount, reads)
        XCTAssertFalse(dashboard.isTransitioning)

        dashboard.show(Array(cameras.suffix(8)), store: store, active: true)
        XCTAssertTrue(retiring.allSatisfy { $0.state == .idle }, "Every old player stops synchronously on page change.")
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.map(\.id), Array(cameras.suffix(8)).map(\.id))
        XCTAssertEqual(credentials.readCount, reads + 8)
        let final = dashboard.cameras.compactMap(\.player)
        await dashboard.suspendAndWait()
        XCTAssertTrue(dashboard.cameras.isEmpty)
        XCTAssertTrue(final.allSatisfy { $0.state == .idle })
    }

    @MainActor
    func testRapidPageChangeAndDepartureNeverStartSupersededPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = DashboardCredentials()
        let store = CameraStore(storageURL: root.appendingPathComponent("cameras.json"), credentials: credentials)
        let cameras = try makeCameras(count: 24, store: store)
        let dashboard = DashboardSession()
        defer { dashboard.suspend(); try? FileManager.default.removeItem(at: root) }
        let initialReads = credentials.readCount
        dashboard.show(Array(cameras.prefix(8)), store: store, active: true)
        dashboard.show(Array(cameras.dropFirst(8).prefix(8)), store: store, active: true)
        dashboard.show(Array(cameras.suffix(8)), store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.map(\.id), Array(cameras.suffix(8)).map(\.id))
        XCTAssertEqual(credentials.readCount, initialReads + 8, "Superseded pages must not load credentials or construct players.")
        let retiring = dashboard.cameras.compactMap(\.player)
        let reads = credentials.readCount
        dashboard.show(Array(cameras.prefix(16)), store: store, active: true)
        dashboard.suspend()
        await waitForTransition(dashboard)
        XCTAssertTrue(dashboard.cameras.isEmpty)
        XCTAssertEqual(credentials.readCount, reads)
        XCTAssertTrue(retiring.allSatisfy { $0.state == .idle })
    }

    @MainActor
    func testPageLimitAcceptsSixtyFourButRejectsOversizeAndDuplicatePagesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = DashboardCredentials()
        let store = CameraStore(storageURL: root.appendingPathComponent("cameras.json"), credentials: credentials)
        let cameras = try makeCameras(count: 65, store: store)
        let dashboard = DashboardSession()
        defer { dashboard.suspend(); try? FileManager.default.removeItem(at: root) }
        dashboard.show(Array(cameras.prefix(64)), store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.count, 64)
        let retiring = dashboard.cameras.compactMap(\.player)
        let reads = credentials.readCount
        dashboard.show(cameras, store: store, active: true)
        XCTAssertTrue(retiring.allSatisfy { $0.state == .idle })
        await waitForTransition(dashboard)
        XCTAssertTrue(dashboard.cameras.isEmpty, "Invalid pages must not be silently truncated.")
        XCTAssertEqual(credentials.readCount, reads)
        dashboard.show([cameras[0], cameras[0]], store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertTrue(dashboard.cameras.isEmpty)
        XCTAssertEqual(credentials.readCount, reads)
        dashboard.show(Array(cameras.prefix(7)), store: store, active: true)
        await waitForTransition(dashboard)
        XCTAssertEqual(dashboard.cameras.count, 7)
        await dashboard.suspendAndWait()
    }

    @MainActor
    private func makeCameras(count: Int, store: CameraStore) throws -> [CameraConfiguration] {
        try (1...count).map { channel in
            let camera = CameraConfiguration(name: "Local test \(channel)", host: "127.0.0.1", channel: channel)
            try store.save(camera, password: "test-only")
            return camera
        }
    }

    @MainActor
    private func waitForTransition(_ dashboard: DashboardSession) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while dashboard.isTransitioning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(dashboard.isTransitioning, "Dashboard transition did not finish.")
    }
}

private final class DashboardCredentials: CameraCredentialStorage {
    private var values: [UUID: String] = [:]
    private(set) var readCount = 0
    func read(for cameraID: UUID) throws -> String? {
        readCount += 1
        return values[cameraID]
    }
    func set(_ password: String, for cameraID: UUID) throws { values[cameraID] = password }
    func remove(for cameraID: UUID) throws { values.removeValue(forKey: cameraID) }
}
