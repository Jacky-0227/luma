import XCTest

final class WelcomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWelcomeAppearsOnceAndDailyPagesUseSectionTitles() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-welcome", "--ui-test-reset-welcome", "--ui-test-dark",
            "-AppleLanguages", "(en)", "-AppleLocale", "en"
        ]
        app.launch()
        defer { app.terminate() }

        let getStarted = app.buttons["welcome.continue"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        XCTAssertEqual(getStarted.label, "Get started")
        XCTAssertTrue(app.staticTexts["Home. Within sight."].exists)
        capture("en-welcome", app: app)
        getStarted.tap()

        verifyDailyPage("Cameras", app: app)
        XCTAssertFalse(getStarted.exists)
        XCTAssertTrue(app.buttons["camera.add.first"].waitForExistence(timeout: 5))
        capture("en-home-title", app: app)

        app.tabBars.buttons["Dashboard"].tap()
        verifyDailyPage("Dashboard", app: app)
        capture("en-dashboard-title", app: app)
        app.tabBars.buttons["Library"].tap()
        verifyDailyPage("Library", app: app)

        app.terminate()
        // Leave the welcome feature enabled on the second launch. Removing
        // only the reset flag proves persisted completion, not a test bypass.
        app.launchArguments.removeAll { $0 == "--ui-test-reset-welcome" }
        app.launch()
        verifyDailyPage("Cameras", app: app)
        XCTAssertFalse(getStarted.exists, "Completed onboarding must stay dismissed after a process restart.")
    }

    @MainActor
    private func verifyDailyPage(_ title: String, app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ready = app.navigationBars[title].waitForExistence(timeout: 5)
        if !ready { capture("welcome-unexpected-page", app: app) }
        XCTAssertTrue(ready, "Expected the \(title) section title.", file: file, line: line)
        for slogan in ["Home. Within sight.", "Every angle. Together."] {
            XCTAssertFalse(app.staticTexts[slogan].exists,
                           "Daily pages must show section names instead of the welcome slogan.", file: file, line: line)
        }
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy.txt"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
