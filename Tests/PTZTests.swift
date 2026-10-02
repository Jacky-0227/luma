import XCTest
@testable import Luma

final class PTZTests: XCTestCase {
    func testLegacyCameraDecodesWithPTZDisabled() throws {
        let camera = CameraConfiguration(name: "Legacy", host: "192.0.2.8")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
        for key in ["ptzEnabled", "controlPort", "controlUseHTTPS", "ptzChannel"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(CameraConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.ptzEnabled)
        XCTAssertEqual(decoded.controlPort, 80)
        XCTAssertFalse(decoded.controlUseHTTPS)
        XCTAssertEqual(decoded.ptzChannel, 1)
    }

    func testControlSettingsValidateIndependentlyOfStream() {
        XCTAssertThrowsError(try CameraConfiguration(name: "PTZ", host: "camera.local", controlPort: 0).validated())
        XCTAssertThrowsError(try CameraConfiguration(name: "PTZ", host: "camera.local", ptzChannel: 1000).validated())
        XCTAssertNoThrow(try CameraConfiguration(name: "PTZ", host: "camera.local", channel: 9, ptzEnabled: true, controlPort: 443, controlUseHTTPS: true, ptzChannel: 2).validated())
    }

    func testPTZRequestUsesSeparateChannelAndNeverEmbedsCredentials() throws {
        let camera = CameraConfiguration(name: "PTZ", host: "[2001:db8::4]", port: 554, username: "private-user", channel: 8,
                                         ptzEnabled: true, controlPort: 8443, controlUseHTTPS: true, ptzChannel: 2)
        let endpoint = try PTZEndpoint(configuration: camera)
        let request = try endpoint.request(for: PTZCommand(direction: .upRight))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/ISAPI/PTZCtrl/channels/2/momentary")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "PUT")
        let xml = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(xml.contains("<pan>30</pan><tilt>30</tilt><zoom>0</zoom>"))
        XCTAssertTrue(xml.contains("<Momentary><duration>500</duration></Momentary>"))
        XCTAssertFalse(xml.contains(camera.username))
        let stop = try endpoint.request(for: .stop)
        XCTAssertEqual(stop.url?.path, "/ISAPI/PTZCtrl/channels/2/continuous")
        XCTAssertFalse(String(decoding: try XCTUnwrap(stop.httpBody), as: UTF8.self).contains("Momentary"))
    }

    func testSpeedBoundsAndDirections() {
        let clamped = PTZCommand(pan: Int.max, tilt: Int.min, zoom: 400)
        XCTAssertEqual(clamped.pan, 100)
        XCTAssertEqual(clamped.tilt, -100)
        XCTAssertEqual(clamped.zoom, 100)
        XCTAssertEqual(PTZCommand(direction: .left).pan, -30)
        XCTAssertEqual(PTZCommand(direction: .down).tilt, -30)
        XCTAssertEqual(PTZCommand(direction: .zoomIn).zoom, 30)
        XCTAssertEqual(PTZCommand(direction: .zoomOut).zoom, -30)
        XCTAssertTrue(PTZCommand.stop.isStop)
    }

    func testAuthenticationIsBoundToEndpointAndSecureMethod() throws {
        let http = try PTZEndpoint(configuration: CameraConfiguration(name: "PTZ", host: "camera.local", ptzEnabled: true))
        XCTAssertTrue(http.permitsCredentials(host: "CAMERA.local", port: 80, scheme: "http", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        XCTAssertFalse(http.permitsCredentials(host: "camera.local", port: 80, scheme: "http", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false))
        XCTAssertFalse(http.permitsCredentials(host: "other.local", port: 80, scheme: "http", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        XCTAssertFalse(http.permitsCredentials(host: "camera.local", port: 81, scheme: "http", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        XCTAssertFalse(http.permitsCredentials(host: "camera.local", port: 80, scheme: "https", method: NSURLAuthenticationMethodHTTPDigest, isProxy: false))
        XCTAssertFalse(http.permitsCredentials(host: "camera.local", port: 80, scheme: "http", method: NSURLAuthenticationMethodHTTPDigest, isProxy: true))
        let https = try PTZEndpoint(configuration: CameraConfiguration(name: "PTZ", host: "camera.local", ptzEnabled: true, controlPort: 443, controlUseHTTPS: true))
        XCTAssertTrue(https.permitsCredentials(host: "camera.local", port: 443, scheme: "https", method: NSURLAuthenticationMethodHTTPBasic, isProxy: false))
    }

    func testDeviceStatusMustConfirmSuccess() throws {
        let ok = Data("<ResponseStatus xmlns=\"http://www.isapi.org/ver20/XMLSchema\"><statusCode>1</statusCode></ResponseStatus>".utf8)
        XCTAssertNoThrow(try PTZResponse.validate(statusCode: 200, body: ok))
        let rejected = Data("<ResponseStatus><statusCode>4</statusCode><statusString>private device diagnostic</statusString></ResponseStatus>".utf8)
        XCTAssertThrowsError(try PTZResponse.validate(statusCode: 200, body: rejected)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private device diagnostic"))
        }
        XCTAssertThrowsError(try PTZResponse.validate(statusCode: 302, body: ok))
        XCTAssertThrowsError(try PTZResponse.validate(statusCode: 401, body: ok))
        XCTAssertThrowsError(try PTZResponse.validate(statusCode: 404, body: ok))
        XCTAssertThrowsError(try PTZResponse.validate(statusCode: 200, body: Data("<html>Login</html>".utf8)))
    }

    @MainActor
    func testReleaseWaitsForInflightMoveThenSendsStop() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport)
        controller.press(.left)
        await transport.waitForCount(1)
        controller.stop()
        XCTAssertFalse(controller.isMoving)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left)])
        transport.releaseMove()
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop])
    }

    @MainActor
    func testStopDiscardsMovesThatHaveNotStarted() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport)
        controller.press(.left)
        await transport.waitForCount(1)
        controller.press(.right)
        controller.stop()
        transport.releaseMove()
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop])
    }

    @MainActor
    func testHoldAutomaticallyStopsAndNudgeDoesNotRepeat() async throws {
        let heldTransport = RecordingPTZTransport()
        let held = PTZController(enabled: true, transport: heldTransport, holdLimit: .milliseconds(20))
        held.press(.up)
        await heldTransport.waitForCount(2)
        XCTAssertEqual(heldTransport.commands, [PTZCommand(direction: .up), .stop])
        XCTAssertFalse(held.isMoving)

        let nudgedTransport = RecordingPTZTransport()
        let nudged = PTZController(enabled: true, transport: nudgedTransport)
        nudged.nudge(.zoomIn)
        await nudgedTransport.waitForCount(2)
        XCTAssertEqual(nudgedTransport.commands, [PTZCommand(direction: .zoomIn), .stop])
        XCTAssertFalse(nudged.isMoving)
    }

    @MainActor
    func testFailureStillAttemptsStopWithoutExposingRawErrors() async throws {
        let transport = RecordingPTZTransport(failFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport)
        controller.press(.down)
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .down), .stop])
        XCTAssertFalse(controller.isMoving)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.errorMessage?.contains("private-password") ?? true)
    }
}

@MainActor
private final class RecordingPTZTransport: PTZTransport {
    private(set) var commands: [PTZCommand] = []
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [(id: UUID, count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private let blockFirstMove: Bool
    private let failFirstMove: Bool

    init(blockFirstMove: Bool = false, failFirstMove: Bool = false) {
        self.blockFirstMove = blockFirstMove
        self.failFirstMove = failFirstMove
    }

    func send(_ command: PTZCommand) async throws {
        commands.append(command)
        if commands.count == 1, blockFirstMove {
            await withCheckedContinuation { continuation in
                blocked = continuation
                resumeWaiters()
            }
        } else { resumeWaiters() }
        if commands.count == 1, failFirstMove {
            throw NSError(domain: "private-password", code: 1)
        }
    }

    func waitForCount(_ count: Int) async {
        if commands.count >= count { return }
        let id = UUID()
        let reached = await withCheckedContinuation { continuation in
            waiters.append((id, count, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                let waiter = self.waiters.remove(at: index)
                waiter.continuation.resume(returning: false)
            }
        }
        XCTAssertTrue(reached, "PTZ command queue did not reach the expected state within 3 seconds.")
    }

    func releaseMove() {
        blocked?.resume()
        blocked = nil
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.count <= commands.count }
        waiters.removeAll { $0.count <= commands.count }
        ready.forEach { $0.continuation.resume(returning: true) }
    }
}
