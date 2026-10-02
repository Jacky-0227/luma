import XCTest

final class DashboardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCreateEditReorderAndRemoveDashboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-dark", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        defer { app.terminate() }
        addCamera("Entry", host: "127.0.0.1", app: app)
        addCamera("Garden", host: "127.0.0.2", app: app)
        app.tabBars.buttons["Dashboard"].tap()
        XCTAssertTrue(app.buttons["dashboard.add"].waitForExistence(timeout: 5))
        app.buttons["dashboard.add"].tap()
        let name = app.textFields["dashboard.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Porch group")

        let entry = selection("Entry", app: app)
        reveal(entry, app: app)
        entry.tap()
        let garden = selection("Garden", app: app)
        reveal(garden, app: app)
        garden.tap()
        XCTAssertEqual(entry.value as? String, "Selected")
        XCTAssertEqual(garden.value as? String, "Selected")
        let gardenID = String(garden.identifier.dropFirst("dashboard.select.".count))
        let entryID = String(entry.identifier.dropFirst("dashboard.select.".count))
        let moveGardenUp = app.buttons["dashboard.move-up.\(gardenID)"]
        reveal(moveGardenUp, app: app, towardTop: true)
        XCTAssertTrue(moveGardenUp.isEnabled)
        moveGardenUp.tap()
        waitFor(NSPredicate(format: "enabled == false"), on: moveGardenUp)
        XCTAssertTrue(app.buttons["dashboard.move-up.\(entryID)"].isEnabled)
        let oneColumn = app.buttons["One column"]
        reveal(oneColumn, app: app, towardTop: true)
        oneColumn.tap()
        app.buttons["dashboard.save"].tap()

        let card = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "dashboard.card.", "Porch group"
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let dashboardID = String(card.identifier.dropFirst("dashboard.card.".count))
        capture("en-dashboard-groups")
        app.buttons["dashboard.menu.\(dashboardID)"].tap()
        app.buttons["Edit dashboard"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Porch group")
        XCTAssertTrue(app.buttons["One column"].isSelected)
        XCTAssertFalse(app.buttons["dashboard.move-up.\(gardenID)"].isEnabled)
        XCTAssertTrue(app.buttons["dashboard.move-up.\(entryID)"].isEnabled)
        capture("en-dashboard-editor")
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Porch group".count) + "Courtyard")
        app.buttons["dashboard.save"].tap()
        let renamed = app.descendants(matching: .any).matching(identifier: "dashboard.card.\(dashboardID)").firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertEqual(renamed.label, "Courtyard")

        app.buttons["dashboard.menu.\(dashboardID)"].tap()
        app.buttons["Remove dashboard"].tap()
        app.buttons["Remove"].tap()
        waitFor(NSPredicate(format: "exists == false"), on: renamed)
        app.tabBars.buttons["Cameras"].tap()
        XCTAssertTrue(app.buttons["camera.add"].waitForExistence(timeout: 5))
        let savedEntry = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "camera.card.", "Entry"
        )).firstMatch
        let savedGarden = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "camera.card.", "Garden"
        )).firstMatch
        reveal(savedEntry, app: app, towardTop: true)
        reveal(savedGarden, app: app)
    }

    @MainActor
    private func addCamera(_ title: String, host: String, app: XCUIApplication) {
        XCTAssertTrue(app.buttons["camera.add"].waitForExistence(timeout: 15))
        app.buttons["camera.add"].tap()
        let name = app.textFields["camera.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(title)
        let address = app.textFields["camera.host"]
        address.tap()
        address.typeText(host)
        app.buttons["camera.save"].tap()
        XCTAssertTrue(app.buttons["camera.add"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func selection(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "dashboard.select.", name)).firstMatch
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        app: XCUIApplication,
        towardTop: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // SwiftUI Form is backed by a collection view on iOS 26. Send the
        // gesture to its scroll surface so a downward swipe cannot dismiss
        // the editor sheet through its header or another app-level surface.
        let surfaces = [app.collectionViews.firstMatch, app.tables.firstMatch, app.scrollViews.firstMatch]
        let scrollSurface = surfaces.first(where: { $0.exists && $0.isHittable }) ?? app
        for _ in 0..<5 where !element.isHittable {
            if towardTop { scrollSurface.swipeDown() } else { scrollSurface.swipeUp() }
        }
        if !element.isHittable {
            capture("dashboard-missing-control")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "dashboard-missing-control-hierarchy.txt"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(element.isHittable, "Control is not reachable: \(element)", file: file, line: line)
    }

    @MainActor
    private func waitFor(_ predicate: NSPredicate, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
