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
        name.typeText("Porch group\n")
        waitFor(NSPredicate(format: "exists == false"), on: app.keyboards.firstMatch)

        let pageSize = app.segmentedControls["dashboard.pageSize"]
        XCTAssertTrue(pageSize.waitForExistence(timeout: 5))
        pageSize.buttons["16"].tap()
        XCTAssertTrue(pageSize.buttons["16"].isSelected)
        let columns = app.steppers["dashboard.columns"]
        XCTAssertEqual(columns.value as? String, "4")
        pageSize.buttons["Custom"].tap()
        let customPageSize = app.steppers["dashboard.customPageSize"]
        XCTAssertTrue(customPageSize.waitForExistence(timeout: 5))
        XCTAssertEqual(customPageSize.value as? String, "16")
        customPageSize.buttons["Increment"].tap()
        XCTAssertEqual(customPageSize.value as? String, "17")
        columns.buttons["Decrement"].tap()
        XCTAssertEqual(columns.value as? String, "3")

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
        XCTAssertTrue(pageSize.buttons["Custom"].isSelected)
        XCTAssertEqual(customPageSize.value as? String, "17")
        XCTAssertEqual(columns.value as? String, "3")
        capture("en-dashboard-layout")
        reveal(app.buttons["dashboard.move-up.\(entryID)"], app: app)
        XCTAssertFalse(app.buttons["dashboard.move-up.\(gardenID)"].isEnabled)
        XCTAssertTrue(app.buttons["dashboard.move-up.\(entryID)"].isEnabled)
        capture("en-dashboard-editor")
        reveal(name, app: app, towardTop: true)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Porch group".count) + "Courtyard\n")
        waitFor(NSPredicate(format: "exists == false"), on: app.keyboards.firstMatch)
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
            // UIKit keeps the Form's full-screen accessibility frame while
            // the keyboard covers its lower part. Default swipeUp therefore
            // starts on keyboard keys, not on the Form. Clip both endpoints
            // to the currently visible content, including the prediction bar.
            var visible = scrollSurface.frame.intersection(app.frame)
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter(\.isHittable).map { $0.frame.maxY }.max() ?? visible.minY
            let top = max(visible.minY, navigationBottom) + 16
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY - 50) - visible.minY)
            }
            let bottom = visible.maxY - 16
            guard bottom - top > 80 else { break }
            let upper = top + (bottom - top) * 0.2
            let lower = bottom - (bottom - top) * 0.2
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX, dy: (towardTop ? upper : lower) - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX, dy: (towardTop ? lower : upper) - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
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
