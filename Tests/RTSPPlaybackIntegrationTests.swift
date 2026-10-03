import UIKit
import XCTest
@testable import Luma

/// These tests exercise the shipped VLC RTSP client over real TCP sockets.
/// XCTest keeps them serial with the existing hosted VLC tests because UIKit's
/// key window and the process-wide VLC event configuration are shared resources.
final class RTSPPlaybackIntegrationTests: XCTestCase {
    private let fixturePassword = "test@p:a/ss?#%+&= space"

    @MainActor
    func testDigestWithReservedPasswordCharactersDecodesRealRTSPFrames() async throws {
        let fixture = RTSPLoopbackFixture(password: fixturePassword, video: try await RTSPH264Pattern.make())
        defer { attachTimeline(fixture, name: "rtsp-digest-phases") }
        try await fixture.start()
        defer { fixture.stop() }
        let host = try VideoHost()
        defer { host.close() }
        let camera = try configuration(for: fixture)
        let startupBegan = ProcessInfo.processInfo.systemUptime
        let session = VLCPlaybackSession(url: try camera.streamURL(password: fixturePassword), useTCP: true)
        let probe = PlaybackProbe()
        let library = MediaLibrary.shared
        let previousItems = Set(library.items.map(\.id))
        defer { for item in library.items where !previousItems.contains(item.id) { try? library.delete(item) } }
        session.onEvent = { event in
            if case .firstFrame = event {
                if !probe.videoStarted { fixture.mark("first decoded frame received") }
                probe.videoStarted = true
            }
            if case .failed = event { probe.failed = true; fixture.mark("playback failed") }
        }
        session.onCaptureEvent = { event in
            if case .saved(.snapshot) = event { probe.snapshotSaved = true; fixture.mark("snapshot saved") }
            if case .failed = event { fixture.mark("snapshot failure callback") }
        }
        do {
            fixture.mark("playback start requested")
            session.start(on: host.surface, muted: true, aspectFill: false)
            try await eventually("VLC did not decode video from the authenticated RTSP socket.", seconds: 20) {
                session.pollVideoProgress()
                return probe.videoStarted
            }
            let startupSeconds = ProcessInfo.processInfo.systemUptime - startupBegan
            let timing = XCTAttachment(string: String(format: "Authenticated loopback RTSP first video: %.3f seconds", startupSeconds))
            timing.name = "rtsp-first-video-timing"
            timing.lifetime = .keepAlways
            add(timing)
            XCTAssertLessThan(startupSeconds, 5, "A local RTSP stream must not spend 10 seconds probing the receiving interface.")
            session.captureSnapshot()
            try await eventually("The real RTSP video did not produce a decoded frame snapshot.", seconds: 10) { probe.snapshotSaved }
            let item = try XCTUnwrap(library.items.first { !previousItems.contains($0.id) && $0.kind == .snapshot })
            let snapshotURL = try XCTUnwrap(library.fileURL(for: item))
            let snapshot = try XCTUnwrap(UIImage(contentsOfFile: snapshotURL.path))
            XCTAssertGreaterThan(snapshot.size.width, 0)
            XCTAssertGreaterThan(snapshot.size.height, 0)
            XCTAssertGreaterThan(fixture.authenticatedRequests, 0, "The server must independently verify the Digest response.")
            XCTAssertEqual(fixture.rejectedCredentials, 0)
            XCTAssertEqual(fixture.playRequests, 1)
            XCTAssertGreaterThan(fixture.sentVideoPackets, 0)
            XCTAssertFalse(probe.failed)
            try await retire(session, fixture: fixture)
        } catch {
            recordFailure(error, fixture: fixture)
            fixture.stop()
            session.retire()
            throw error
        }
    }

    @MainActor
    func testWrongDigestPasswordIsRejectedWithoutStartingVideo() async throws {
        let fixture = RTSPLoopbackFixture(password: fixturePassword)
        defer { attachTimeline(fixture, name: "rtsp-wrong-password-phases") }
        try await fixture.start()
        defer { fixture.stop() }
        let host = try VideoHost()
        defer { host.close() }
        let camera = try configuration(for: fixture)
        let session = VLCPlaybackSession(url: try camera.streamURL(password: "incorrect-test-password"), useTCP: true)
        let probe = PlaybackProbe()
        session.onEvent = { event in
            switch event {
            case .videoPlaying, .firstFrame: probe.videoStarted = true
            case .failed, .ended: probe.failed = true
            default: break
            }
        }
        do {
            session.start(on: host.surface, muted: true, aspectFill: false)
            try await eventually("The RTSP client never attempted Digest authentication.", seconds: 10) {
                fixture.rejectedCredentials > 0
            }
            try await eventually("A rejected RTSP handshake did not report a failure.", seconds: 8) { probe.failed }
            XCTAssertEqual(fixture.authenticatedRequests, 0)
            XCTAssertEqual(fixture.playRequests, 0)
            XCTAssertFalse(probe.videoStarted)
            try await retire(session, fixture: fixture)
        } catch {
            recordFailure(error, fixture: fixture)
            fixture.stop()
            session.retire()
            throw error
        }
    }

    @MainActor
    func testSlowRTSPSetupExceedingOldWatchdogStillReachesPlaying() async throws {
        let fixture = RTSPLoopbackFixture(password: fixturePassword, behavior: .delayedSetup(seconds: 22),
                                          video: try await RTSPH264Pattern.make())
        defer { attachTimeline(fixture, name: "rtsp-delayed-setup-phases") }
        try await fixture.start()
        defer { fixture.stop() }
        let host = try VideoHost()
        defer { host.close() }
        let player = CameraPlayer(configuration: try configuration(for: fixture), password: fixturePassword)
        do {
            player.attach(to: host.surface)
            fixture.mark("CameraPlayer play requested")
            player.play()
            try await eventually("The client never reached RTSP SETUP.", seconds: 15) { fixture.setupRequests > 0 }
            try await eventually("A 22-second RTSP setup was cancelled instead of reaching real video.", seconds: 35) {
                player.state == .playing
            }
            fixture.mark("CameraPlayer reached playing")
            XCTAssertEqual(fixture.connectionCount, 1, "A slow but valid handshake must not trigger a replacement connection.")
            XCTAssertEqual(fixture.playRequests, 1)
            XCTAssertEqual(fixture.teardownRequests, 0, "The startup watchdog must not tear down before the first frame.")
            XCTAssertGreaterThan(fixture.sentVideoPackets, 0)
            try await stop(player, fixture: fixture)
        } catch {
            recordFailure(error, fixture: fixture)
            fixture.stop()
            player.stop()
            throw error
        }
    }

    @MainActor
    func testRapidControlsAndCancellationOfStalledRTSPKeepMainActorResponsive() async throws {
        let fixture = RTSPLoopbackFixture(password: fixturePassword, behavior: .stalledHandshake)
        defer { attachTimeline(fixture, name: "rtsp-cancellation-phases") }
        try await fixture.start()
        defer { fixture.stop() }
        let host = try VideoHost()
        defer { host.close() }
        let player = CameraPlayer(configuration: try configuration(for: fixture), password: fixturePassword)
        let pulse = MainActorPulse()
        pulse.start()
        defer { pulse.stop() }
        do {
            try await eventually("Main actor heartbeat did not start.", seconds: 2) { pulse.ticks >= 3 }
            player.attach(to: host.surface)
            player.play()
            try await eventually("No real RTSP request reached the stalled server.", seconds: 10) { fixture.requestCount > 0 }
            for index in 0..<12 {
                player.retry()
                player.setQuality(index.isMultiple(of: 2) ? .main : .sub)
                player.setMuted(index.isMultiple(of: 2))
                player.stop()
                player.play()
                try await Task.sleep(for: .milliseconds(20))
            }
            let started = ProcessInfo.processInfo.systemUptime
            player.stop()
            let synchronousStopTime = ProcessInfo.processInfo.systemUptime - started
            fixture.mark(String(format: "synchronous stop returned in %.3fs", synchronousStopTime))
            XCTAssertEqual(player.state, .idle)
            try await stop(player, fixture: fixture)
            fixture.mark(String(format: "main actor heartbeat maximum gap %.3fs; ticks %d", pulse.maximumGap, pulse.ticks))
            XCTAssertLessThan(synchronousStopTime, 0.75, "Stopping an unresponsive camera must not block the UI thread.")
            XCTAssertLessThan(pulse.maximumGap, 0.75, "Rapid controls or SDK teardown blocked the main actor heartbeat.")
            XCTAssertGreaterThan(pulse.ticks, 6)
            XCTAssertEqual(player.state, .idle)
        } catch {
            recordFailure(error, fixture: fixture)
            fixture.stop()
            player.stop()
            throw error
        }
    }

    @MainActor
    private func attachTimeline(_ fixture: RTSPLoopbackFixture, name: String) {
        let attachment = XCTAttachment(string: fixture.diagnostics)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func recordFailure(_ error: Error, fixture: RTSPLoopbackFixture) {
        let message = "RTSP integration failure: \(error.localizedDescription)"
        fixture.mark(message)
        XCTFail(message)
    }

    @MainActor
    private func configuration(for fixture: RTSPLoopbackFixture) throws -> CameraConfiguration {
        CameraConfiguration(name: "Synthetic RTSP fixture", host: "127.0.0.1",
                            port: Int(try XCTUnwrap(fixture.port)), username: "viewer", useTCP: true)
    }

    @MainActor
    private func eventually(_ message: String, seconds: Double, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RTSPFixtureError.failed(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func retire(_ session: VLCPlaybackSession, fixture: RTSPLoopbackFixture) async throws {
        let completion = PlaybackProbe()
        fixture.mark("native retirement requested")
        session.retire { completion.retired = true }
        do {
            try await eventually("VLC did not complete real RTSP teardown within 6 seconds.", seconds: 6) { completion.retired }
            fixture.mark("native retirement completed")
        } catch {
            // Close only after the deadline, so fixture shutdown cannot make an
            // ineffective client cancellation falsely pass the assertion.
            fixture.stop()
            try? await eventually("Cleanup", seconds: 3) { completion.retired }
            throw error
        }
    }

    @MainActor
    private func stop(_ player: CameraPlayer, fixture: RTSPLoopbackFixture) async throws {
        let completion = PlaybackProbe()
        fixture.mark("CameraPlayer stopAndWait requested")
        Task { @MainActor in await player.stopAndWait(); completion.retired = true }
        do {
            try await eventually("CameraPlayer did not complete cancellation of a real RTSP connection within 6 seconds.", seconds: 6) { completion.retired }
            fixture.mark("CameraPlayer stopAndWait completed")
        } catch {
            fixture.stop()
            try? await eventually("Cleanup", seconds: 3) { completion.retired }
            throw error
        }
    }
}

@MainActor
private final class PlaybackProbe {
    var videoStarted = false
    var snapshotSaved = false
    var failed = false
    var retired = false
}

@MainActor
private final class MainActorPulse {
    var maximumGap: TimeInterval = 0
    var ticks = 0
    private var task: Task<Void, Never>?
    func start() {
        task = Task { @MainActor [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.maximumGap = max(self.maximumGap, now - previous)
                self.ticks += 1
                previous = now
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

@MainActor
private final class VideoHost {
    let window: UIWindow
    let surface: UIView
    private weak var previousWindow: UIWindow?
    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        surface = UIView(frame: controller.view.bounds)
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.backgroundColor = .black
        controller.view.addSubview(surface)
        surface.layoutIfNeeded()
        XCTAssertGreaterThan(surface.bounds.width, 0)
        XCTAssertGreaterThan(surface.bounds.height, 0)
    }
    func close() { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
}
