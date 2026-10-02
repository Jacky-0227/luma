import XCTest
import UIKit
@testable import Luma

final class SnapshotThumbnailTests: XCTestCase {
    @MainActor
    func testLargeSnapshotIsDownsampledBeforePresentation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 1024), format: format).pngData { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4096, height: 1024))
        }
        try data.write(to: url)
        let decoded = await SnapshotThumbnailLoader.shared.load(url: url, maximumPixelSize: 512)
        let image = try XCTUnwrap(decoded?.image)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 128)
    }

    @MainActor
    func testCancelledAndInvalidSnapshotsDoNotProduceAnImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        let invalid = await SnapshotThumbnailLoader.shared.load(url: url)
        XCTAssertNil(invalid)

        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        try data.write(to: url)
        // This MainActor task cannot start before the cancellation below.
        let request = Task { @MainActor in await SnapshotThumbnailLoader.shared.load(url: url) }
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
    }
}
