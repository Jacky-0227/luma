import XCTest
@testable import Luma

final class DashboardLayoutTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 700)

    func testFewerCamerasThanColumnsUseFewerColumnsAndFillWidth() {
        let layout = WallLayout(count: 2, preferredColumns: 3, size: phone, spacing: 4, gutter: 8)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.contentWidth, phone.width - 16, accuracy: 0.5)
        XCTAssertEqual(layout.cell.width / layout.cell.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.initiallyHiddenStart, 2)
    }

    func testPortraitSixteenFitsWithoutScrolling() {
        let layout = WallLayout(count: 16, preferredColumns: 4, size: phone, spacing: 4, gutter: 8)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.contentWidth, phone.width - 16, accuracy: 0.5)
    }

    func testLandscapeWallShrinksToFitHeight() {
        let landscape = CGSize(width: 874, height: 360)
        let layout = WallLayout(count: 4, preferredColumns: 2, size: landscape, spacing: 4, gutter: 8)
        XCTAssertTrue(layout.fits)
        let rows: CGFloat = 2
        XCTAssertLessThanOrEqual(rows * layout.cell.height + 4, landscape.height - 16 + 0.5)
        XCTAssertEqual(layout.cell.width / layout.cell.height, 16.0 / 9.0, accuracy: 0.01)
    }

    func testLargeWallScrollsAndStartsOnlyTheFirstScreen() {
        let layout = WallLayout(count: 64, preferredColumns: 2, size: phone, spacing: 4, gutter: 8)
        XCTAssertFalse(layout.fits)
        XCTAssertGreaterThan(layout.initiallyHiddenStart, 0)
        XCTAssertLessThan(layout.initiallyHiddenStart, 64)
        XCTAssertEqual(layout.initiallyHiddenStart % layout.columns, 0)
    }

    func testDashboardOrderSkipsDuplicatesAndMissingCameras() {
        let a = CameraConfiguration(name: "A", host: "192.0.2.1")
        let b = CameraConfiguration(name: "B", host: "192.0.2.2")
        let c = CameraConfiguration(name: "C", host: "192.0.2.3")
        let dashboard = DashboardConfiguration(name: "Mixed", cameraIDs: [b.id, UUID(), b.id, a.id], includesAllCameras: true)
        XCTAssertEqual(dashboard.cameras(from: [a, b, c]).map(\.name), ["B", "A", "C"])
    }

    @MainActor
    func testPlainHTTPWarningOnlyForDottedNonLocalNames() {
        for host in ["192.0.2.64", "fe80::1", "[fe80::1]", "camera", "camera.local", "Camera.Local."] {
            XCTAssertFalse(CameraEditorView.httpNeedsLocalName(host), host)
        }
        for host in ["cam.lan", "nvr.home.arpa", "camera.example.com"] {
            XCTAssertTrue(CameraEditorView.httpNeedsLocalName(host), host)
        }
    }
}
