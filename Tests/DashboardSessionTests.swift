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
