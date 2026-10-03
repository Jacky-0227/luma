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

    func testContinuousRequestAndMomentaryOnlyStopUseCorrectResourcesAndDeadlines() throws {
        let endpoint = try PTZEndpoint(configuration: CameraConfiguration(name: "PTZ", host: "camera.local", ptzEnabled: true))
        let move = PTZCommand(direction: .left, mode: .continuous)
        let request = try endpoint.request(for: move)
        XCTAssertEqual(request.url?.lastPathComponent, "continuous")
        XCTAssertFalse(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("Momentary"))
        XCTAssertEqual(request.timeoutInterval, 1.5)
        let settings = PTZRequestPolicy.sessionConfiguration(for: move)
        XCTAssertEqual(settings.timeoutIntervalForResource, 2)
        XCTAssertGreaterThanOrEqual(settings.httpMaximumConnectionsPerHost, 2)
        XCTAssertNotNil(settings.urlCredentialStorage)
        XCTAssertFalse(settings.urlCredentialStorage === URLCredentialStorage.shared)
        let stop = PTZCommand.stop(mode: .momentary)
        let stopRequest = try endpoint.request(for: stop)
        XCTAssertEqual(stopRequest.url?.lastPathComponent, "momentary")
        let xml = String(decoding: try XCTUnwrap(stopRequest.httpBody), as: UTF8.self)
        XCTAssertTrue(xml.contains("<pan>0</pan><tilt>0</tilt><zoom>0</zoom>"))
        XCTAssertTrue(xml.contains("<Momentary><duration>500</duration></Momentary>"))
        XCTAssertEqual(PTZRequestPolicy.sessionConfiguration(for: stop).timeoutIntervalForResource, 2)
    }

    func testLegacyCommandUsesDetectedPrefixAndVersionWithoutChangingCredentialsPolicy() throws {
        let camera = CameraConfiguration(name: "Legacy", host: "camera.local", ptzEnabled: true, ptzChannel: 7)
        let endpoint = try PTZEndpoint(configuration: camera, apiFamily: .legacy)
        let request = try endpoint.request(for: PTZCommand(direction: .left, mode: .continuous))
        XCTAssertEqual(request.url?.path, "/PTZCtrl/channels/7/continuous")
        let xml = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(xml.contains("version=\"1.0\""))
        XCTAssertTrue(xml.contains("http://www.hikvision.com/ver10/XMLSchema"))
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNoThrow(try PTZResponse.validate(statusCode: 200, body: Data("<ResponseStaus><statusCode>1</statusCode></ResponseStaus>".utf8)))
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
    func testReleaseBeforeMovementTaskStartsNeverSendsTheObsoleteMove() async throws {
        let transport = RecordingPTZTransport()
        let controller = PTZController(enabled: true, transport: transport)
        let token = try XCTUnwrap(controller.press(.left))
        // Deliberately do not suspend between touch-down and touch-up.
        controller.release(token: token)
        await transport.waitForCount(1)
        try await waitUntil { !controller.isStopping }
        XCTAssertFalse(transport.commands.isEmpty)
        XCTAssertTrue(transport.commands.allSatisfy(\.isStop), "A released, unsent movement must never reach the transport.")
        XCTAssertFalse(controller.isMoving)
    }

    @MainActor
    func testReleaseSendsStopBeforeMoveReplyAndLateSuccessOrFailureRequiresAnotherStop() async throws {
        for fails in [false, true] {
            let transport = RecordingPTZTransport(blockFirstMove: true, failFirstMove: fails)
            let controller = PTZController(enabled: true, transport: transport)
            let token = try XCTUnwrap(controller.press(.left))
            await transport.waitForCount(1)
            controller.release(token: token)
            await transport.waitForCount(2)
            XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop])
            XCTAssertFalse(controller.isMoving)
            XCTAssertTrue(controller.isStopping, "An early Stop ACK cannot cover an unresolved movement.")
            transport.releaseMove()
            await transport.waitForCount(3)
            try await waitUntil { !controller.isStopping }
            XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop, .stop])
        }
    }

    @MainActor
    func testStopDiscardsMovesThatHaveNotStarted() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport)
        controller.press(.left)
        await transport.waitForCount(1)
        controller.press(.right)
        controller.stop()
        await transport.waitForCount(2)
        transport.releaseMove()
        await transport.waitForCount(3)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop, .stop])
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

    @MainActor
    func testContinuousHoldSendsOneMoveThenScheduledStopWithoutRefreshPulses() async throws {
        let transport = RecordingPTZTransport()
        let controller = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities,
                                       holdLimit: .milliseconds(650))
        let started = ContinuousClock.now
        controller.press(.up)
        await transport.waitForCount(2)
        XCTAssertGreaterThanOrEqual(started.duration(to: ContinuousClock.now), .milliseconds(600))
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .up, mode: .continuous), .stop],
                       "Continuous movement must not be repeated using the momentary refresh timer.")
        XCTAssertFalse(controller.isMoving)
        XCTAssertFalse(controller.isStopping)
    }

    @MainActor
    func testHoldDeadlineSendsStopWhileMovementResponseIsStillUnacknowledged() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities,
                                       holdLimit: .milliseconds(20))
        controller.press(.left)
        await transport.waitForCount(1)
        await transport.waitForCount(2)
        XCTAssertTrue(controller.isStopping)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left, mode: .continuous), .stop])
        XCTAssertFalse(controller.isMoving)
        transport.releaseMove()
        await transport.waitForCount(3)
        try await waitUntil { !controller.isStopping }
        XCTAssertEqual(transport.commands.last, .stop, "Late movement completion must be covered by a second Stop.")
        XCTAssertFalse(controller.isStopping)
    }

    @MainActor
    func testMoveSettlingBeforeAnAlreadySentStopReplyStillRequiresAFreshStop() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true, blockFirstStop: true)
        let controller = PTZController(enabled: true, transport: transport)
        controller.press(.left)
        await transport.waitForCount(1)
        controller.stop()
        await transport.waitForCount(2)
        transport.releaseMove()
        try await waitUntil { transport.completedMoves == 1 }
        transport.releaseStop()
        await transport.waitForCount(3)
        try await waitUntil { !controller.isStopping }
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left), .stop, .stop])
    }

    @MainActor
    func testRapidDirectionChangesKeepOnlyLatestHeldIntentAndIgnoreOldTouchReleases() async throws {
        let transport = RecordingPTZTransport(blockFirstMove: true)
        let controller = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities)
        let left = try XCTUnwrap(controller.press(.left))
        await transport.waitForCount(1)
        let right = try XCTUnwrap(controller.press(.right))
        let up = try XCTUnwrap(controller.press(.up))
        controller.release(token: left)
        controller.release(token: right)
        await transport.waitForCount(2)
        XCTAssertTrue(controller.isMoving, "An old touch release cannot discard a newer held direction.")
        transport.releaseMove()
        await transport.waitForCount(4)
        XCTAssertEqual(transport.commands, [PTZCommand(direction: .left, mode: .continuous), .stop, .stop,
                                            PTZCommand(direction: .up, mode: .continuous)])
        controller.release(token: up)
        await transport.waitForCount(5)
        try await waitUntil { !controller.isStopping }
        XCTAssertFalse(controller.isMoving)
    }

    @MainActor
    func testFailedStopRetriesAreBoundedAndRequireExplicitConfirmedRetryBeforeMoving() async throws {
        let transport = RecordingPTZTransport(stopFailures: 3)
        let controller = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities,
                                       stopRetryDelay: .milliseconds(1))
        controller.press(.left)
        await transport.waitForCount(1)
        controller.stop()
        await transport.waitForCount(4)
        try await waitUntil { controller.isBlocked }
        XCTAssertEqual(transport.commands.filter(\.isStop).count, 3)
        XCTAssertTrue(controller.isStopping)
        XCTAssertNotNil(controller.errorMessage)
        controller.press(.right)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.commands.count, 4, "Unconfirmed Stop must neither restart movement nor retry forever.")
        controller.stop()
        await transport.waitForCount(5)
        try await waitUntil { !controller.isStopping }
        XCTAssertFalse(controller.isBlocked)
        XCTAssertFalse(controller.isStopping)
        XCTAssertNil(controller.errorMessage)
        controller.press(.right)
        await transport.waitForCount(6)
        XCTAssertEqual(transport.commands.last, PTZCommand(direction: .right, mode: .continuous))
        controller.stop()
        await transport.waitForCount(7)
    }

    @MainActor
    func testStopAcknowledgmentAfterRetriesClearsStoppingState() async throws {
        let transport = RecordingPTZTransport(stopFailures: 2)
        let controller = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities,
                                       stopRetryDelay: .milliseconds(1))
        controller.press(.up)
        await transport.waitForCount(1)
        controller.stop()
        await transport.waitForCount(4)
        XCTAssertFalse(controller.isStopping)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(transport.commands.filter(\.isStop).count, 3)
    }

    @MainActor
    func testSingleAndMixedAxisModesRejectUnsafeDiagonalsAndChoosePerAxisCommands() async throws {
        let transport = RecordingPTZTransport()
        let capabilities = PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: .momentary, zoomMode: nil)
        let controller = PTZController(enabled: true, transport: transport, capabilities: capabilities)
        XCTAssertTrue(controller.supports(.left))
        XCTAssertTrue(controller.supports(.up))
        XCTAssertFalse(controller.supports(.upLeft))
        XCTAssertFalse(controller.supports(.zoomIn))
        XCTAssertTrue(controller.usesContinuousControl)
        controller.press(.upLeft)
        XCTAssertTrue(transport.commands.isEmpty)
        controller.press(.left)
        await transport.waitForCount(1)
        XCTAssertEqual(transport.commands.last?.mode, .continuous)
        controller.stop()
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands.last, .stop, "Mixed devices with continuous support use its zero-axis stop.")
        controller.press(.up)
        await transport.waitForCount(3)
        XCTAssertEqual(transport.commands.last?.mode, .momentary)
        controller.stop()
        await transport.waitForCount(4)
        XCTAssertEqual(transport.commands.last, .stop)
        let panOnly = PTZController(enabled: true, transport: RecordingPTZTransport(),
                                    capabilities: PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: nil, zoomMode: nil))
        XCTAssertTrue(panOnly.supportsPanTilt)
        XCTAssertFalse(panOnly.supports(.up))
        XCTAssertFalse(panOnly.supports(.downRight))
    }

    @MainActor
    func testMomentaryOnlyDeviceUsesTimedZeroCommandToStop() async throws {
        let transport = RecordingPTZTransport()
        let capabilities = PTZCapabilities(channel: 1, panMode: .momentary, tiltMode: .momentary, zoomMode: nil,
                                           supportsContinuousStop: false)
        let controller = PTZController(enabled: true, transport: transport, capabilities: capabilities)
        controller.press(.left)
        await transport.waitForCount(1)
        controller.stop()
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands.last, .stop(mode: .momentary))
        XCTAssertFalse(controller.usesContinuousControl)
    }

    @MainActor
    func testDroppingPresentationDoesNotLoseContinuousStopDeadline() async throws {
        let transport = RecordingPTZTransport()
        var controller: PTZController? = PTZController(enabled: true, transport: transport, capabilities: Self.continuousCapabilities,
                                                     holdLimit: .milliseconds(40))
        weak var owner = controller
        controller?.press(.left)
        await transport.waitForCount(1)
        controller = nil
        await transport.waitForCount(2)
        XCTAssertEqual(transport.commands.last, .stop)
        try await waitUntil { owner == nil }
    }

    private static var continuousCapabilities: PTZCapabilities {
        PTZCapabilities(channel: 1, panMode: .continuous, tiltMode: .continuous, zoomMode: .continuous)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "PTZ state did not reach the expected value within three seconds.")
    }
}

@MainActor
private final class RecordingPTZTransport: PTZTransport {
    private(set) var commands: [PTZCommand] = []
    private(set) var completedMoves = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var blockedStop: CheckedContinuation<Void, Never>?
    private var waiters: [(id: UUID, count: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private let blockFirstMove: Bool
    private let failFirstMove: Bool
    private let blockFirstStop: Bool
    private var stopCount = 0
    private var stopFailures: Int

    init(blockFirstMove: Bool = false, failFirstMove: Bool = false, stopFailures: Int = 0, blockFirstStop: Bool = false) {
        self.blockFirstMove = blockFirstMove
        self.failFirstMove = failFirstMove
        self.stopFailures = stopFailures
        self.blockFirstStop = blockFirstStop
    }

    func send(_ command: PTZCommand) async throws {
        commands.append(command)
        let ordinal = commands.count
        if command.isStop { stopCount += 1 }
        if ordinal == 1, blockFirstMove {
            await withCheckedContinuation { continuation in
                blocked = continuation
                resumeWaiters()
            }
        } else if command.isStop, stopCount == 1, blockFirstStop {
            await withCheckedContinuation { continuation in
                blockedStop = continuation
                resumeWaiters()
            }
        } else { resumeWaiters() }
        if !command.isStop { completedMoves += 1 }
        if ordinal == 1, failFirstMove {
            throw NSError(domain: "private-password", code: 1)
        }
        if command.isStop, stopFailures > 0 {
            stopFailures -= 1
            throw NSError(domain: "private-stop-diagnostic", code: 1)
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

    func releaseStop() {
        blockedStop?.resume()
        blockedStop = nil
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.count <= commands.count }
        waiters.removeAll { $0.count <= commands.count }
        ready.forEach { $0.continuation.resume(returning: true) }
    }
}
