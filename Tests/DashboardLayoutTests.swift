import XCTest
@testable import Luma

final class DashboardLayoutTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 700)
    private let landscape = CGSize(width: 874, height: 300)

    func testTwoCamerasOnAPortraitPhoneStackAtFullWidth() {
        let layout = WallLayout(count: 2, maxColumns: 8, size: phone, spacing: 4, gutter: 8)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.contentWidth, phone.width - 16, accuracy: 0.5)
        XCTAssertEqual(layout.cell.width / layout.cell.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.initiallyHiddenStart, 2)
    }

    func testFourCamerasFollowTheScreenOrientation() {
        let portrait = WallLayout(count: 4, maxColumns: 8, size: phone, spacing: 4, gutter: 8)
        XCTAssertEqual(portrait.columns, 1)
        XCTAssertTrue(portrait.fits)
        assertFits(portrait, rows: 4, in: phone)
        let wide = WallLayout(count: 4, maxColumns: 8, size: landscape, spacing: 4, gutter: 8)
        XCTAssertEqual(wide.columns, 2)
        XCTAssertTrue(wide.fits)
        assertFits(wide, rows: 2, in: landscape)
        XCTAssertEqual(wide.cell.width / wide.cell.height, 16.0 / 9.0, accuracy: 0.01)
    }

    func testPortraitSixteenFitsWithoutScrolling() {
        let layout = WallLayout(count: 16, maxColumns: 8, size: phone, spacing: 4, gutter: 8)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertGreaterThanOrEqual(layout.cell.width, WallLayout.minimumTileWidth)
        assertFits(layout, rows: 8, in: phone)
    }

    func testChosenColumnsGiveNearlyTheLargestTiles() {
        for size in [phone, landscape, CGSize(width: 1024, height: 700)] {
            for count in 1...16 {
                let chosen = WallLayout(count: count, maxColumns: 8, size: size, spacing: 4, gutter: 8)
                guard chosen.fits else { continue }
                for columns in 1...min(8, count) {
                    let rows = (count + columns - 1) / columns
                    let byWidth = (size.width - 16 - CGFloat(columns - 1) * 4) / CGFloat(columns)
                    let byHeight = (size.height - 16 - CGFloat(rows - 1) * 4) / CGFloat(rows) * 16 / 9
                    XCTAssertGreaterThanOrEqual(chosen.cell.width * WallLayout.columnPreference + 0.5,
                                                min(byWidth, byHeight), "\(count) cameras in \(size)")
                }
            }
        }
    }

    func testNineCamerasInLandscapeKeepASquareGrid() {
        let layout = WallLayout(count: 9, maxColumns: 8, size: landscape, spacing: 4, gutter: 8)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertTrue(layout.fits)
    }

    func testAccessibilitySizesUseOneColumn() {
        let layout = WallLayout(count: 4, maxColumns: 1, size: landscape, spacing: 4, gutter: 8)
        XCTAssertEqual(layout.columns, 1)
    }

    func testLargeWallScrollsAndStartsOnlyTheFirstScreen() {
        let layout = WallLayout(count: 64, maxColumns: 8, size: phone, spacing: 4, gutter: 8)
        XCTAssertFalse(layout.fits)
        XCTAssertGreaterThan(layout.initiallyHiddenStart, 0)
        XCTAssertLessThan(layout.initiallyHiddenStart, 64)
        XCTAssertEqual(layout.initiallyHiddenStart % layout.columns, 0)
        XCTAssertGreaterThanOrEqual(layout.cell.width, WallLayout.minimumTileWidth)
    }

    func testCoverUsesTheSquarestGrid() {
        XCTAssertEqual(DashboardConfiguration.coverColumns(forPageSize: 1), 1)
        XCTAssertEqual(DashboardConfiguration.coverColumns(forPageSize: 4), 2)
        XCTAssertEqual(DashboardConfiguration.coverColumns(forPageSize: 9), 3)
        XCTAssertEqual(DashboardConfiguration.coverColumns(forPageSize: 17), 5)
        XCTAssertEqual(DashboardConfiguration.coverColumns(forPageSize: 64), 8)
    }

    private func assertFits(_ layout: WallLayout, rows: Int, in size: CGSize,
                            file: StaticString = #filePath, line: UInt = #line) {
        let height = CGFloat(rows) * layout.cell.height + CGFloat(rows - 1) * 4
        XCTAssertLessThanOrEqual(height, size.height - 16 + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.contentWidth, size.width - 16 + 0.5, file: file, line: line)
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
