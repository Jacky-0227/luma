import XCTest

final class LumaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThreeLanguagesAndScreenshots() throws {
        let languages = [
            ("zh-Hant", "新增第一台攝影機", "設定"),
            ("zh-Hans", "添加第一台摄像头", "设置"),
            ("en", "Add your first camera", "Settings")
        ]
        for (language, addTitle, settingsTitle) in languages {
            let app = launch(language: language, dark: language != "en")
            XCTAssertTrue(app.buttons["camera.add.first"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["camera.add.first"].label, addTitle)
            capture("\(language)-01-home")
            app.buttons["camera.add"].tap()
            XCTAssertTrue(app.textFields["camera.name"].waitForExistence(timeout: 5))
            capture("\(language)-02-add-camera")
            app.buttons["camera.cancel"].tap()
            app.buttons["settings.open"].tap()
            XCTAssertTrue(app.navigationBars[settingsTitle].waitForExistence(timeout: 5))
            capture("\(language)-03-settings")
            if language == "en" {
                app.buttons["Done"].tap()
                app.tabBars.buttons["Dashboard"].tap()
                XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 5))
                capture("en-05-dashboard-empty")
                app.tabBars.buttons["Library"].tap()
                XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
                capture("en-06-library-empty")
            }
            app.terminate()
        }
    }

    @MainActor
    func testCameraValidationAndSave() throws {
        let app = launch(language: "en", automaticPTZ: true)
        XCTAssertTrue(app.buttons["camera.add"].waitForExistence(timeout: 15))
        app.buttons["camera.add"].tap()
        let save = app.buttons["camera.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        let name = app.textFields["camera.name"]
        name.tap()
        name.typeText("Entry camera")
        let address = app.textFields["camera.host"]
        address.tap()
        address.typeText("127.0.0.1")
        let automaticPTZ = app.descendants(matching: .any).matching(identifier: "camera.ptz.automatic").firstMatch
        for _ in 0..<3 where !automaticPTZ.isHittable { app.swipeUp() }
        XCTAssertTrue(automaticPTZ.exists)
        XCTAssertFalse(app.switches["camera.ptz.enabled"].exists)
        capture("en-04a-camera-ptz-automatic")
        save.tap()
        let savedCamera = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.card.")).firstMatch
        XCTAssertTrue(savedCamera.waitForExistence(timeout: 5))
        XCTAssertEqual(savedCamera.label, "Entry camera")
        XCTAssertFalse(app.buttons["camera.add.first"].exists)
        capture("en-04-saved-camera")
        // Loopback intentionally has no RTSP server. Exercise real VLC setup,
        // controls and teardown without touching a user's camera or credentials.
        savedCamera.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "player.status").firstMatch.waitForExistence(timeout: 10))
        app.buttons["player.mute"].tap()
        let fullscreen = app.buttons["player.fullscreen"]
        fullscreen.tap()
        waitForLabel("Exit full screen", on: fullscreen)
        let openPTZ = app.buttons["player.ptz"]
        XCTAssertTrue(openPTZ.waitForExistence(timeout: 5))
        openPTZ.tap()
        let stopMovement = app.buttons["ptz.stop"]
        XCTAssertTrue(stopMovement.waitForExistence(timeout: 5))
        XCTAssertTrue(stopMovement.isHittable)
        capture("en-07-ptz-controls")
        app.buttons["Done"].tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        fullscreen.tap()
        waitForLabel("Full screen", on: fullscreen)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(savedCamera.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testRepeatedNavigationWhileCameraIsConnecting() throws {
        let app = launch(language: "en")
        XCTAssertTrue(app.buttons["camera.add"].waitForExistence(timeout: 15))
        app.buttons["camera.add"].tap()
        let name = app.textFields["camera.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Navigation test")
        let address = app.textFields["camera.host"]
        address.tap()
        address.typeText("127.0.0.1")
        app.buttons["camera.save"].tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "camera.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        // Never wait for a failed connection or use a real camera. Repeatedly
        // leave an opening stream, then change tabs while it is being retired.
        // Record simulator interaction time for future comparisons. This metric
        // includes XCTest synchronization; it is not a device FPS benchmark.
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            card.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "player.status").firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            app.tabBars.buttons["Dashboard"].tap()
            XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Library"].tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Cameras"].tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    @MainActor
    private func waitForLabel(_ label: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func launch(language: String, dark: Bool = false, automaticPTZ: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if dark { app.launchArguments.append("--ui-test-dark") }
        if automaticPTZ { app.launchArguments.append("--ui-test-ptz") }
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureInterface(_ name: String, app: XCUIApplication) {
        capture(name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
