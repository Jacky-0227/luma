import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Luma

final class CameraThumbnailStoreTests: XCTestCase {
    @MainActor
    func testJPEGIsProportionalPersistentPrivateAndReplacedOnNextCapture() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Synthetic", host: "camera.local", username: "synthetic-user")
        let store = CameraThumbnailStore(directory: directory, cameras: [camera])
        let firstValue = await store.prepareCapture(for: camera)
        let first = try XCTUnwrap(firstValue)
        try image(width: 1920, height: 1080, red: true).write(to: first.fileURL)
        await store.save(first)
        let dataValue = await store.imageData(for: camera)
        let data = try XCTUnwrap(dataValue)
        XCTAssertTrue(data.starts(with: [0xff, 0xd8, 0xff]))
        let landscape = try dimensions(data)
        XCTAssertEqual(landscape.width, 640)
        XCTAssertEqual(landscape.height, 360)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.deletingLastPathComponent().path))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let recordURL = directory.appendingPathComponent(camera.id.uuidString + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        let record = try String(contentsOf: recordURL, encoding: .utf8)
        XCTAssertFalse(record.contains("camera.local"))
        XCTAssertFalse(record.contains("synthetic-user"))
        XCTAssertFalse(record.contains("Synthetic"))
        let reloaded = CameraThumbnailStore(directory: directory, cameras: [camera])
        let restored = await reloaded.imageData(for: camera)
        XCTAssertEqual(restored, data)

        let nextValue = await store.prepareCapture(for: camera)
        let next = try XCTUnwrap(nextValue)
        try image(width: 1080, height: 1920, red: false).write(to: next.fileURL)
        await store.save(next)
        let replacementValue = await store.imageData(for: camera)
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertNotEqual(replacement, data)
        let portrait = try dimensions(replacement)
        XCTAssertEqual(portrait.width, 360)
        XCTAssertEqual(portrait.height, 640)
    }

    @MainActor
    func testFingerprintTracksOnlyVideoSourceAndRejectsUnknownCamera() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let store = CameraThumbnailStore(directory: directory, cameras: [camera])
        var renamed = camera
        renamed.name = "Another name"
        renamed.username = "another-user"
        renamed.controlPort = 8080
        XCTAssertEqual(CameraThumbnailStore.key(for: renamed), CameraThumbnailStore.key(for: camera))
        var different = camera
        different.host = "other-camera.local"
        XCTAssertNotEqual(CameraThumbnailStore.key(for: different), CameraThumbnailStore.key(for: camera))
        let wrongSource = await store.prepareCapture(for: different)
        XCTAssertNil(wrongSource)
        different = camera
        different.customPath = "/different-stream"
        XCTAssertNotEqual(CameraThumbnailStore.key(for: different), CameraThumbnailStore.key(for: camera))
        let unknown = await store.prepareCapture(for: CameraConfiguration(name: "Unknown", host: "camera.local"))
        XCTAssertNil(unknown)
    }

    @MainActor
    func testDeletedCameraCannotBeResurrectedBySuspendedCompressionOrOlderCatalog() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let gate = ThumbnailEncodeGate(value: try image(width: 320, height: 180, red: true, jpeg: true))
        let store = CameraThumbnailStore(directory: directory, cameras: [camera], encoder: { await gate.encode($0) })
        let captureValue = await store.prepareCapture(for: camera)
        let capture = try XCTUnwrap(captureValue)
        let saving = Task { await store.save(capture) }
        defer { saving.cancel(); Task { await gate.release() } }
        try await gate.waitUntilBlocked()
        await store.prune(existing: [], revision: 2)
        await store.prune(existing: [camera], revision: 1)
        await gate.release()
        await saving.value
        let result = await store.imageData(for: camera)
        XCTAssertNil(result)
        let refused = await store.prepareCapture(for: camera)
        XCTAssertNil(refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(camera.id.uuidString + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.fileURL.deletingLastPathComponent().path))
    }

    @MainActor
    func testSourceEditWhileEncodingInvalidatesOldTicketAndOldDiskIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        var edited = camera
        edited.channel = 2
        let jpeg = try image(width: 320, height: 180, red: false, jpeg: true)
        let gate = ThumbnailEncodeGate(value: jpeg)
        let store = CameraThumbnailStore(directory: directory, cameras: [camera], encoder: { await gate.encode($0) })
        let captureValue = await store.prepareCapture(for: camera)
        let capture = try XCTUnwrap(captureValue)
        let saving = Task { await store.save(capture) }
        defer { saving.cancel(); Task { await gate.release() } }
        try await gate.waitUntilBlocked()
        await store.prune(existing: [edited], revision: 1)
        await gate.release()
        await saving.value
        let stale = await store.imageData(for: camera)
        let changed = await store.imageData(for: edited)
        XCTAssertNil(stale)
        XCTAssertNil(changed)
        let oldCapture = await store.prepareCapture(for: camera)
        XCTAssertNil(oldCapture)
        let nextValue = await store.prepareCapture(for: edited)
        let next = try XCTUnwrap(nextValue)
        await store.save(next)
        let current = await store.imageData(for: edited)
        XCTAssertEqual(current, jpeg)
    }

    @MainActor
    func testNewestIssuedTicketWinsEvenWhenOlderEncodingFinishesLast() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let oldJPEG = try image(width: 320, height: 180, red: true, jpeg: true)
        let newJPEG = try image(width: 320, height: 180, red: false, jpeg: true)
        let gate = ThumbnailEncodeGate(value: oldJPEG, laterValue: newJPEG)
        let store = CameraThumbnailStore(directory: directory, cameras: [camera], encoder: { await gate.encode($0) })
        let firstValue = await store.prepareCapture(for: camera)
        let first = try XCTUnwrap(firstValue)
        let saving = Task { await store.save(first) }
        defer { saving.cancel(); Task { await gate.release() } }
        try await gate.waitUntilBlocked()
        let secondValue = await store.prepareCapture(for: camera)
        let second = try XCTUnwrap(secondValue)
        await store.save(second)
        await gate.release()
        await saving.value
        let result = await store.imageData(for: camera)
        XCTAssertEqual(result, newJPEG)
        await store.discard(first)
        let retained = await store.imageData(for: camera)
        XCTAssertEqual(retained, newJPEG)
    }

    @MainActor
    func testInvalidCapturePreservesPreviousImageAndDiscardIsScopedAndIdempotent() async throws {
        let directory = temporaryDirectory()
        let otherDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: otherDirectory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let store = CameraThumbnailStore(directory: directory, cameras: [camera])
        let firstValue = await store.prepareCapture(for: camera)
        let first = try XCTUnwrap(firstValue)
        try image(width: 320, height: 180, red: true).write(to: first.fileURL)
        await store.save(first)
        let previous = await store.imageData(for: camera)
        XCTAssertNotNil(previous)
        let failedValue = await store.prepareCapture(for: camera)
        let failed = try XCTUnwrap(failedValue)
        try Data("not an image".utf8).write(to: failed.fileURL)
        await store.save(failed)
        let retained = await store.imageData(for: camera)
        XCTAssertEqual(retained, previous)
        let other = CameraThumbnailStore(directory: otherDirectory, cameras: [camera])
        let foreignValue = await other.prepareCapture(for: camera)
        let foreign = try XCTUnwrap(foreignValue)
        await store.discard(foreign)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.fileURL.deletingLastPathComponent().path))
        await other.discard(foreign)
        await other.discard(foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.fileURL.deletingLastPathComponent().path))
        XCTAssertThrowsError(try Data([1]).write(to: foreign.fileURL), "A late writer cannot recreate a discarded capture directory.")
        XCTAssertFalse(CameraThumbnailEncoder.isValidJPEG(Data(repeating: 0xff, count: CameraThumbnailEncoder.maximumJPEGBytes + 1)))
    }

    @MainActor
    func testCatalogChangeRemovesPersistedImageAndRestartDoesNotTrustOldSource() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let store = CameraThumbnailStore(directory: directory, cameras: [camera])
        let captureValue = await store.prepareCapture(for: camera)
        let capture = try XCTUnwrap(captureValue)
        try image(width: 320, height: 180, red: true).write(to: capture.fileURL)
        await store.save(capture)
        var changed = camera
        changed.port = 8554
        let reloaded = CameraThumbnailStore(directory: directory, cameras: [changed])
        let rejected = await reloaded.imageData(for: changed)
        XCTAssertNil(rejected)
        await store.prune(existing: [], revision: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(camera.id.uuidString + ".json").path))
    }

    @MainActor
    func testFirstCaptureScavengesOnlyOldUUIDPendingDirectories() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let store = CameraThumbnailStore(directory: directory, cameras: [camera])
        let savedValue = await store.prepareCapture(for: camera)
        let saved = try XCTUnwrap(savedValue)
        try image(width: 320, height: 180, red: true).write(to: saved.fileURL)
        await store.save(saved)
        let previous = await store.imageData(for: camera)
        let pending = directory.appendingPathComponent("Pending", isDirectory: true)
        let orphan = pending.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recent = pending.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = pending.appendingPathComponent("unrelated", isDirectory: true)
        for folder in [orphan, recent, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("snapshot.png"))
        }
        for folder in [orphan, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
                                                  ofItemAtPath: folder.path)
        }
        let reloaded = CameraThumbnailStore(directory: directory, cameras: [camera])
        let nextValue = await reloaded.prepareCapture(for: camera)
        let next = try XCTUnwrap(nextValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let retained = await reloaded.imageData(for: camera)
        XCTAssertEqual(retained, previous)
        await reloaded.discard(next)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LumaThumbnailTests-" + UUID().uuidString)
    }

    private func image(width: Int, height: Int, red: Bool, jpeg: Bool = false) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }
}

private actor ThumbnailEncodeGate {
    let value: Data
    let laterValue: Data?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var started = false
    private var released = false

    init(value: Data, laterValue: Data? = nil) { self.value = value; self.laterValue = laterValue }

    func encode(_ file: URL) async -> Data? {
        if started, let laterValue { return laterValue }
        if released { return value }
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while continuation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard continuation != nil else { throw GateFailure.didNotStart }
    }

    func release() {
        released = true
        continuation?.resume(returning: value)
        continuation = nil
    }

    private enum GateFailure: Error { case didNotStart }
}
