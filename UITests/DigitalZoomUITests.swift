import XCTest

final class DigitalZoomUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFullscreenPinchPanResetKeepsRealVideoConnected() async throws {
        let fixture = RTSPLoopbackFixture(password: "luma-ui-fixture", video: try await RTSPH264Pattern.make())
        try await fixture.start()
        defer {
            fixture.stop()
            let timeline = XCTAttachment(string: fixture.diagnostics)
            timeline.name = "digital-zoom-rtsp-phases"
            timeline.lifetime = .keepAlways
            add(timeline)
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-stream", "--ui-test-dark",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launchEnvironment["LUMA_UI_RTSP_PORT"] = String(try XCTUnwrap(fixture.port))
        app.launch()
        defer { app.terminate() }
        let camera = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.card.")).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        let status = app.descendants(matching: .any).matching(identifier: "player.status").firstMatch
        try await waitUntil { status.exists && status.label.contains("Live") && fixture.sentVideoPackets > 0 }
        let initialConnections = fixture.connectionCount
        let initialPlays = fixture.playRequests
        let fullscreen = app.buttons["player.fullscreen"]
        fullscreen.tap()
        try await waitUntil { fullscreen.label == "Exit full screen" }
        let video = app.descendants(matching: .any).matching(identifier: "player.video").firstMatch
        XCTAssertTrue(video.exists)
        XCTAssertEqual(video.value as? String, "1.0×")
        video.pinch(withScale: 2.5, velocity: 1)
        try await waitUntil { (video.value as? String) != "1.0×" }
        let zoomedValue = video.value as? String
        let center = video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        XCTAssertEqual(video.value as? String, zoomedValue)
        capture("en-fullscreen-digital-zoom-synthetic")
        app.buttons["player.zoom.reset"].tap()
        try await waitUntil { video.value as? String == "1.0×" }
        capture("en-fullscreen-digital-zoom-reset-synthetic")
        video.pinch(withScale: 2, velocity: 1)
        try await waitUntil { video.value as? String != "1.0×" }
        fullscreen.tap()
        try await waitUntil { fullscreen.label == "Full screen" }
        XCTAssertEqual(video.value as? String, "1.0×")
        XCTAssertFalse(app.buttons["player.zoom.reset"].exists)
        XCTAssertEqual(fixture.connectionCount, initialConnections, "Display gestures must not reopen RTSP.")
        XCTAssertEqual(fixture.playRequests, initialPlays)
        XCTAssertTrue(status.label.contains("Live"))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
