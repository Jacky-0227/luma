import XCTest
import UIKit
@testable import Luma

final class DashboardPreviewTests: XCTestCase {
    func testSnapshotRequestUsesOnlyMatchingVideoChannelAndWebEndpoint() throws {
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local", channel: 3,
                                         ptzEnabled: false, controlPort: 8443, controlUseHTTPS: true, ptzChannel: 8)
        let request = try DashboardSnapshotRequest.make(for: camera)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://camera.local:8443/ISAPI/Streaming/channels/301/picture")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 3)
        let endpoint = try PTZEndpoint(configuration: camera, requireEnabled: false)
        XCTAssertTrue(endpoint.permitsCredentials(host: "camera.local", port: 8443, scheme: "https", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        XCTAssertFalse(endpoint.permitsCredentials(host: "other-camera.local", port: 8443, scheme: "https", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        var custom = camera
        custom.customPath = "/Streaming/Channels/701"
        XCTAssertThrowsError(try DashboardSnapshotRequest.make(for: custom))
    }

    func testOversizedAndNonSuccessHTTPResponsesAreRejectedBeforeReading() throws {
        let url = try XCTUnwrap(URL(string: "https://camera.local/ISAPI/Streaming/channels/101/picture"))
        for (status, length) in [(200, DashboardSnapshotRequest.maximumBytes + 1), (302, 0), (401, 0), (404, 0)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(length)]))
            XCTAssertThrowsError(try DashboardSnapshotRequest.validate(response))
        }
        let valid = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "100"]))
        XCTAssertNoThrow(try DashboardSnapshotRequest.validate(valid))
    }

    @MainActor
    func testJPEGDecodeIsDownsampledAndInvalidOrOversizedBodiesAreRejected() async throws {
        let loader = DashboardPreviewLoader()
        let decoded = await loader.decode(Self.jpeg(width: 1920, height: 1080))
        let image = try XCTUnwrap(decoded?.image)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 270)
        let invalid = await loader.decode(Data("<ResponseStatus/>".utf8))
        XCTAssertNil(invalid)
        var oversized = Data([0xff, 0xd8, 0xff])
        oversized.append(Data(repeating: 0, count: DashboardSnapshotRequest.maximumBytes))
        let rejected = await loader.decode(oversized)
        XCTAssertNil(rejected)
    }

    @MainActor
    func testGlobalQueueCoalescesDuplicatesAndSkipsCancelledQueuedRequests() async throws {
        let probe = PreviewFetchProbe(data: Self.jpeg())
        let service = DashboardPreviewService(fetch: { try await probe.fetch($0, password: $1) })
        let cameras = (1...4).map { CameraConfiguration(name: "Fixture \($0)", host: "camera.local", channel: $0) }
        let first = Task { @MainActor in await service.image(for: cameras[0], password: "test") }
        await probe.waitForRequests(1)
        let duplicate = Task { @MainActor in await service.image(for: cameras[0], password: "test") }
        let second = Task { @MainActor in await service.image(for: cameras[1], password: "test") }
        await probe.waitForRequests(2)
        var queuedStarted = false
        let cancelledQueued = Task { @MainActor in
            queuedStarted = true
            return await service.image(for: cameras[2], password: "test")
        }
        while !queuedStarted { await Task.yield() }
        var fourthStarted = false
        let fourth = Task { @MainActor in
            fourthStarted = true
            return await service.image(for: cameras[3], password: "test")
        }
        while !fourthStarted { await Task.yield() }
        cancelledQueued.cancel()
        probe.release(channel: 1)
        probe.release(channel: 2)
        await probe.waitForRequests(3)
        XCTAssertEqual(probe.channels, [1, 2, 4])
        XCTAssertLessThanOrEqual(probe.maximumActive, 2)
        probe.release(channel: 4)
        let results = await [first.value, duplicate.value, second.value, fourth.value]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        let cancelled = await cancelledQueued.value
        XCTAssertNil(cancelled)
    }

    @MainActor
    func testCancellingOneWaiterKeepsSharedFetchAndReopenAfterCancellationCanRestart() async throws {
        let probe = PreviewFetchProbe(data: Self.jpeg())
        let service = DashboardPreviewService(fetch: { try await probe.fetch($0, password: $1) })
        let camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let first = Task { @MainActor in await service.image(for: camera, password: "test") }
        await probe.waitForRequests(1)
        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await service.image(for: camera, password: "test")
        }
        while !secondStarted { await Task.yield() }
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        probe.release(channel: 1)
        let image = await second.value
        XCTAssertNotNil(image)
        XCTAssertEqual(probe.channels, [1])

        let nextCamera = CameraConfiguration(name: "Another fixture", host: "camera.local", channel: 2)
        let abandoned = Task { @MainActor in await service.image(for: nextCamera, password: "test") }
        await probe.waitForRequests(2)
        abandoned.cancel()
        let abandonedResult = await abandoned.value
        XCTAssertNil(abandonedResult)
        let reopened = Task { @MainActor in await service.image(for: nextCamera, password: "test") }
        await probe.waitForRequests(3)
        probe.release(channel: 2)
        let reopenedResult = await reopened.value
        XCTAssertNotNil(reopenedResult)
        XCTAssertEqual(probe.channels, [1, 2, 2])
    }

    @MainActor
    func testPreviewCacheExpiresAtSixtySecondsAndSeparatesCredentialsAndChannels() async throws {
        let data = Self.jpeg()
        var fetches = 0
        var date = Date(timeIntervalSince1970: 100)
        let service = DashboardPreviewService(fetch: { _, _ in fetches += 1; return data }, now: { date })
        var camera = CameraConfiguration(name: "Fixture", host: "camera.local")
        let originalKey = DashboardPreviewService.cacheKey(for: camera)
        _ = await service.image(for: camera, password: "first-test-password")
        date = date.addingTimeInterval(59)
        _ = await service.image(for: camera, password: "first-test-password")
        XCTAssertEqual(fetches, 1)
        date = date.addingTimeInterval(2)
        _ = await service.image(for: camera, password: "first-test-password")
        XCTAssertEqual(fetches, 2)
        _ = await service.image(for: camera, password: "changed-test-password")
        XCTAssertEqual(fetches, 3)
        camera.channel = 2
        XCTAssertNotEqual(DashboardPreviewService.cacheKey(for: camera), originalKey)
        _ = await service.image(for: camera, password: "changed-test-password")
        XCTAssertEqual(fetches, 4)
    }

    @MainActor
    func testPreviewCacheKeepsOnlySixtyFourEntriesAndPreCancelledCallDoesNotFetch() async throws {
        var fetches = 0
        let service = DashboardPreviewService(fetch: { _, _ in fetches += 1; return Data() })
        let firstCamera = CameraConfiguration(name: "First fixture", host: "camera.local")
        let cancelled = Task { @MainActor in await service.image(for: firstCamera, password: "test") }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertEqual(fetches, 0)
        var custom = firstCamera
        custom.customPath = "/another-input"
        let customImage = await service.image(for: custom, password: "test")
        XCTAssertNil(customImage)
        XCTAssertEqual(fetches, 0, "A custom RTSP path cannot safely use a default-channel snapshot.")
        _ = await service.image(for: firstCamera, password: "test")
        for channel in 2...65 {
            let camera = CameraConfiguration(name: "Fixture \(channel)", host: "camera.local", channel: channel)
            _ = await service.image(for: camera, password: "test")
        }
        XCTAssertEqual(fetches, 65)
        _ = await service.image(for: firstCamera, password: "test")
        XCTAssertEqual(fetches, 66, "The oldest cached failure must be evicted as well as images.")
    }

    @MainActor
    private static func jpeg(width: Int = 32, height: Int = 18) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format).jpegData(withCompressionQuality: 0.7) { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }
}

@MainActor
private final class PreviewFetchProbe {
    let data: Data
    private(set) var channels: [Int] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var blocked: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(data: Data) { self.data = data }

    func fetch(_ camera: CameraConfiguration, password: String) async throws -> Data {
        try Task.checkCancellation()
        channels.append(camera.channel)
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { blocked[camera.channel, default: []].append($0) }
        active -= 1
        try Task.checkCancellation()
        return data
    }

    func waitForRequests(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while channels.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(channels.count, count)
    }

    func release(channel: Int) {
        let continuations = blocked.removeValue(forKey: channel) ?? []
        continuations.forEach { $0.resume() }
    }
}
