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
        let app = launch(language: "en")
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
        let ptzSwitch = app.switches["camera.ptz.enabled"]
        for _ in 0..<3 where !ptzSwitch.isHittable { app.swipeUp() }
        XCTAssertTrue(ptzSwitch.isHittable)
        captureInterface("debug-camera-ptz-before-toggle", app: app)
        // SwiftUI can expose the whole labeled Form row as the switch's
        // accessibility frame. Its center is not necessarily the native track.
        // Tap inside the trailing control, using the element's current frame.
        ptzSwitch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -20, dy: 0)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: ptzSwitch)
        let enabledResult = XCTWaiter.wait(for: [enabled], timeout: 5)
        if enabledResult != .completed {
            captureInterface("debug-camera-ptz-toggle-failed", app: app)
        }
        XCTAssertEqual(enabledResult, .completed, "PTZ must be enabled before saving the camera.")
        capture("en-04a-camera-ptz-enabled")
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
    private func waitForLabel(_ label: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func launch(language: String, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if dark { app.launchArguments.append("--ui-test-dark") }
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
