import XCTest
@testable import Luma

final class DashboardStoreTests: XCTestCase {
    @MainActor
    func testDefaultBoardIsSeededOnceAndDeletedBoardsStayDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dashboards.json")
        let store = DashboardStore(storageURL: url)
        let initial = try XCTUnwrap(store.dashboards.first)
        XCTAssertTrue(initial.includesAllCameras)
        try store.delete(initial)
        XCTAssertTrue(DashboardStore(storageURL: url).dashboards.isEmpty)
    }

    @MainActor
    func testEditsMembershipAndBoardOrderSurviveReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dashboards.json")
        let store = DashboardStore(storageURL: url)
        let first = CameraConfiguration(name: "First", host: "camera.local")
        let second = CameraConfiguration(name: "Second", host: "camera.local", channel: 2)
        var group = DashboardConfiguration(name: "  Indoors  ", cameraIDs: [second.id, first.id], columns: 1)
        try store.save(group)
        XCTAssertEqual(store.dashboards[1].name, "Indoors")
        group.name = "Entrance"
        try store.save(group)
        try store.move(from: IndexSet(integer: 1), to: 0)
        let reloaded = DashboardStore(storageURL: url)
        XCTAssertEqual(reloaded.dashboards.first?.name, "Entrance")
        XCTAssertEqual(reloaded.dashboards.first?.columns, 1)
        XCTAssertEqual(reloaded.dashboards.first?.cameras(from: [first, second]).map(\.id), [second.id, first.id])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("camera.local"))
        XCTAssertFalse(json.contains("admin"))
    }

    func testDeletedCameraIsIgnoredAndAllBoardAppendsNewCamerasInOrder() {
        let a = CameraConfiguration(name: "A", host: "camera.local")
        let b = CameraConfiguration(name: "B", host: "camera.local")
        let deleted = UUID()
        let custom = DashboardConfiguration(name: "Custom", cameraIDs: [b.id, deleted])
        XCTAssertEqual(custom.cameras(from: [a, b]).map(\.id), [b.id])
        var all = custom
        all.includesAllCameras = true
        XCTAssertEqual(all.cameras(from: [a, b]).map(\.id), [b.id, a.id])
    }

    @MainActor
    func testUnreadableFileIsPreservedAndCannotBeOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dashboards.json")
        let damaged = Data("broken JSON".utf8)
        try damaged.write(to: url)
        let store = DashboardStore(storageURL: url)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.save(DashboardConfiguration(name: "New")))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    @MainActor
    func testFailedSaveDoesNotMutateVisibleBoards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dashboards.json")
        let store = DashboardStore(storageURL: url)
        let before = store.dashboards
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(DashboardConfiguration(name: "New")))
        XCTAssertEqual(store.dashboards, before)
    }

    func testValidationRejectsAmbiguousMembershipAndInvalidLayout() {
        let id = UUID()
        XCTAssertThrowsError(try DashboardConfiguration(name: " ").validated())
        XCTAssertThrowsError(try DashboardConfiguration(name: String(repeating: "x", count: 41)).validated())
        XCTAssertThrowsError(try DashboardConfiguration(name: "Group", cameraIDs: [id, id]).validated())
        XCTAssertThrowsError(try DashboardConfiguration(name: "Group", columns: 3).validated())
    }
}
