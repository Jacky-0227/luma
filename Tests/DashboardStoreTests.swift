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
        var group = DashboardConfiguration(name: "  Indoors  ", cameraIDs: [second.id, first.id], columns: 1, pageSize: 16)
        try store.save(group)
        XCTAssertEqual(store.dashboards[1].name, "Indoors")
        group.name = "Entrance"
        try store.save(group)
        try store.move(from: IndexSet(integer: 1), to: 0)
        let reloaded = DashboardStore(storageURL: url)
        XCTAssertEqual(reloaded.dashboards.first?.name, "Entrance")
        XCTAssertEqual(reloaded.dashboards.first?.columns, 1)
        XCTAssertEqual(reloaded.dashboards.first?.pageSize, 16)
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
        for columns in [0, 9] {
            XCTAssertThrowsError(try DashboardConfiguration(name: "Group", columns: columns).validated())
        }
        for pageSize in [0, 65, Int.max] {
            XCTAssertThrowsError(try DashboardConfiguration(name: "Group", pageSize: pageSize).validated())
        }
    }

    func testOldDashboardJSONDefaultsToFourWhilePreservingExistingColumnLayout() throws {
        for columns in [1, 2] {
            let original = DashboardConfiguration(name: "Existing", cameraIDs: [UUID()], columns: columns, includesAllCameras: true)
            let encoded = try JSONEncoder().encode(original)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json.removeValue(forKey: "pageSize")
            let oldData = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(DashboardConfiguration.self, from: oldData).validated()
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.pageSize, 4)
            XCTAssertEqual(decoded.columns, columns)
            XCTAssertEqual(try JSONDecoder().decode(DashboardConfiguration.self, from: JSONEncoder().encode(decoded)), original)
        }
    }

    func testPresetAndCustomPageSizesSupportOneThroughEightColumns() throws {
        for pageSize in [1, 4, 7, 8, 16, 64] {
            for columns in 1...8 {
                let board = DashboardConfiguration(name: "Layout", columns: columns, pageSize: pageSize)
                XCTAssertEqual(try board.validated(), board)
                XCTAssertEqual(try JSONDecoder().decode(DashboardConfiguration.self, from: JSONEncoder().encode(board)), board)
            }
        }
    }

    func testPaginationPreservesMembershipOrderAndHandlesDeletedCamerasAndPartialPage() {
        let available = (1...19).map { CameraConfiguration(name: "Camera \($0)", host: "camera.local", channel: $0) }
        var board = DashboardConfiguration(name: "Pages", cameraIDs: available.reversed().map(\.id), columns: 4, pageSize: 8)
        XCTAssertEqual(board.pageCount(from: available), 3)
        XCTAssertEqual(board.cameras(onPage: 0, from: available).map(\.id), Array(available.reversed().prefix(8)).map(\.id))
        XCTAssertEqual(board.cameras(onPage: 1, from: available).count, 8)
        XCTAssertEqual(board.cameras(onPage: 2, from: available).map(\.id), Array(available.prefix(3).reversed()).map(\.id))
        XCTAssertTrue(board.cameras(onPage: 3, from: available).isEmpty)
        XCTAssertTrue(board.cameras(onPage: -1, from: available).isEmpty)
        XCTAssertTrue(board.cameras(onPage: Int.max, from: available).isEmpty)
        let remaining = Array(available.dropFirst(3))
        XCTAssertEqual(board.pageCount(from: remaining), 2)
        XCTAssertTrue(board.cameras(onPage: 2, from: remaining).isEmpty)
        board.pageSize = 7
        XCTAssertEqual(board.cameras(onPage: 2, from: available).count, 5)
        board.pageSize = 64
        XCTAssertEqual(board.pageCount(from: available), 1)
        XCTAssertEqual(board.cameras(onPage: 0, from: available).count, 19)
        XCTAssertEqual(board.pageCount(from: []), 0)
        board.pageSize = 0
        XCTAssertEqual(board.pageCount(from: available), 0)
        XCTAssertTrue(board.cameras(onPage: 0, from: available).isEmpty)
    }

    @MainActor
    func testInvalidStoredPageSizeBlocksWritesWithoutDiscardingOriginalFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dashboards.json")
        let invalid = try JSONEncoder().encode([DashboardConfiguration(name: "Invalid", pageSize: 65)])
        try invalid.write(to: url)
        let store = DashboardStore(storageURL: url)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.save(DashboardConfiguration(name: "Replacement")))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
}
