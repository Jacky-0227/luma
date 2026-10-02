import XCTest
import UIKit
@testable import Luma

final class CaptureTests: XCTestCase {
    @MainActor
    func testSnapshotIsOnlyListedAfterValidatedSaveAndSurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let capture = try library.prepare(.snapshot)
        XCTAssertTrue(library.items.isEmpty)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try data.write(to: capture.snapshotURL)
        let item = try library.finish(capture, fileURL: capture.snapshotURL)
        XCTAssertEqual(library.items, [item])
        XCTAssertEqual(item.fileName, "\(capture.id.uuidString).png")
        XCTAssertNotNil(library.fileURL(for: item))
        let reloaded = MediaLibrary(rootDirectory: root)
        XCTAssertEqual(reloaded.items, [item])
        try reloaded.delete(item)
        XCTAssertTrue(MediaLibrary(rootDirectory: root).items.isEmpty)
    }

    @MainActor
    func testRejectsIncompleteFilesAndPathsOutsideCaptureDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let capture = try library.prepare(.recording)
        let empty = capture.directory.appendingPathComponent("empty.ts")
        try Data().write(to: empty)
        XCTAssertThrowsError(try library.finish(capture, fileURL: empty))
        let outside = root.appendingPathComponent("outside.ts")
        try Data([0x47, 1, 2, 3]).write(to: outside)
        XCTAssertThrowsError(try library.finish(capture, fileURL: outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(library.items.isEmpty)
    }

    @MainActor
    func testTwoRecordingArchivesPreserveTheSessionWorkspaceUntilDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let workspace = try library.prepare(.recording)
        var saved: [CapturedMedia] = []
        for number in 1...2 {
            let destination = try library.prepare(.recording)
            let source = workspace.directory.appendingPathComponent("sdk-recording.ts")
            // These bytes test archiving only. The integration test generates
            // actual H.264 and verifies both SDK recordings can be replayed.
            let bytes = Data([0x47, UInt8(number), 2, 3])
            try bytes.write(to: source)
            let staged = try library.stageRecording(fileURL: source, from: workspace, into: destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(library.items.count, number - 1)
            let item = try library.finish(destination, fileURL: staged)
            saved.append(item)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.fileURL(for: item))), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.directory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.directory.path))
        }
        XCTAssertEqual(Set(saved.map(\.id)).count, 2)
        XCTAssertEqual(MediaLibrary(rootDirectory: root).items.count, 2)
        library.discard(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
        XCTAssertTrue(saved.allSatisfy { library.fileURL(for: $0) != nil })
    }

    @MainActor
    func testRecordingStagingRejectsForeignPathsAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let workspace = try library.prepare(.recording)
        let destination = try library.prepare(.recording)
        let foreign = root.appendingPathComponent("outside.ts")
        let bytes = Data([0x47, 1, 2, 3])
        try bytes.write(to: foreign)
        XCTAssertThrowsError(try library.stageRecording(fileURL: foreign, from: workspace, into: destination))
        let link = workspace.directory.appendingPathComponent("link.ts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertThrowsError(try library.stageRecording(fileURL: link, from: workspace, into: destination))
        let empty = workspace.directory.appendingPathComponent("empty.ts")
        try Data().write(to: empty)
        XCTAssertThrowsError(try library.stageRecording(fileURL: empty, from: workspace, into: destination))
        XCTAssertThrowsError(try library.stageRecording(fileURL: foreign, from: destination, into: destination))
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        XCTAssertTrue(library.items.isEmpty)
    }

    @MainActor
    func testCorruptSnapshotIsNotReportedSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let capture = try library.prepare(.snapshot)
        try Data("not a PNG".utf8).write(to: capture.snapshotURL)
        XCTAssertThrowsError(try library.finish(capture, fileURL: capture.snapshotURL))
        XCTAssertTrue(library.items.isEmpty)
    }

    @MainActor
    func testIndexCannotExposeAFileOutsideLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = MediaLibrary(rootDirectory: root)
        let forged = CapturedMedia(id: UUID(), createdAt: Date(), kind: .recording, fileName: "../secret.ts")
        try JSONEncoder().encode([forged]).write(to: root.appendingPathComponent("index.json"))
        let library = MediaLibrary(rootDirectory: root)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertNil(library.fileURL(for: forged))
    }

    @MainActor
    func testCorruptIndexIsPreservedAndFurtherWritesAreBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MediaLibrary(rootDirectory: root)
        let pending = try library.prepare(.snapshot)
        let index = root.appendingPathComponent("index.json")
        let damaged = Data("{ damaged but potentially recoverable metadata".utf8)
        try damaged.write(to: index)
        library.reload()
        XCTAssertNotNil(library.errorMessage)
        XCTAssertThrowsError(try library.prepare(.recording))
        XCTAssertThrowsError(try library.finish(pending, fileURL: pending.snapshotURL))
        let reopened = MediaLibrary(rootDirectory: root)
        XCTAssertThrowsError(try reopened.prepare(.snapshot))
        XCTAssertEqual(try Data(contentsOf: index), damaged)
    }
}
