import XCTest

final class DashboardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testVideoWallFillsTheScreenWithProportionalNamedTiles() throws {
        for count in [4, 8, 16] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-test-wall", "--ui-test-dark",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en"]
            app.launchEnvironment["LUMA_UI_DASHBOARD_COUNT"] = String(count)
            app.launch()
            app.tabBars.buttons["Dashboard"].tap()
            let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard.card.")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 8))
            card.tap()
            let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard.camera."))
            waitFor(NSPredicate(format: "count == %d", count), on: tiles)
            let frames = tiles.allElementsBoundByIndex.map(\.frame)
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 100)
                XCTAssertEqual(frame.width / frame.height, 16.0 / 9.0, accuracy: 0.04)
                // Every camera on the page is on screen without scrolling.
                XCTAssertTrue(app.frame.contains(frame), "\(frame) is off screen")
            }
            // The old wall left a small grid floating in black space. Tiles
            // now take the largest size that fits (about half the screen).
            let tileArea = frames.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertGreaterThan(tileArea, app.frame.width * app.frame.height * 0.35)
            // Phone tiles are wide enough for names. Status words are never overlaid.
            XCTAssertTrue(app.staticTexts["View 01"].exists)
            XCTAssertFalse(app.staticTexts["Live · Muted"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.isHittable)
            capture("en-dashboard-wall-\(count)-offline-layout")
            if count == 4 {
                // Landscape rearranges the same page into a grid.
                XCUIDevice.shared.orientation = .landscapeLeft
                defer { XCUIDevice.shared.orientation = .portrait }
                let rotated = Date().addingTimeInterval(5)
                while app.frame.width < app.frame.height, Date() < rotated { usleep(100_000) }
                XCTAssertGreaterThan(app.frame.width, app.frame.height)
                // Let the rotation animation and the relayout finish.
                sleep(1)
                let landscapeFrames = tiles.allElementsBoundByIndex.map(\.frame)
                XCTAssertEqual(Set(landscapeFrames.map { Int($0.minY) }).count, 2, "Four cameras form two rows in landscape")
                for frame in landscapeFrames {
                    XCTAssertEqual(frame.width / frame.height, 16.0 / 9.0, accuracy: 0.04)
                    XCTAssertTrue(app.frame.contains(frame), "\(frame) is off screen")
                }
                capture("en-dashboard-wall-4-landscape")
            }
            app.terminate()
        }
    }

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
        // Columns follow the screen; there is no separate column setting.
        XCTAssertFalse(app.steppers["dashboard.columns"].exists)
        pageSize.buttons["Custom"].tap()
        let customPageSize = app.steppers["dashboard.customPageSize"]
        XCTAssertTrue(customPageSize.waitForExistence(timeout: 5))
        XCTAssertEqual(customPageSize.value as? String, "16")
        customPageSize.buttons["dashboard.customPageSize-Increment"].tap()
        XCTAssertEqual(customPageSize.value as? String, "17")

        let entry = selection("Entry", app: app)
        reveal(entry, app: app)
        entry.tap()
        let garden = selection("Garden", app: app)
        reveal(garden, app: app)
        garden.tap()
        // Each selection adds an order row above the list, which can push the
        // tapped row out of the lazy Form; scroll back to it before reading.
        reveal(garden, app: app)
        XCTAssertEqual(garden.value as? String, "Selected")
        let gardenID = String(garden.identifier.dropFirst("dashboard.select.".count))
        reveal(entry, app: app, towardTop: true)
        XCTAssertEqual(entry.value as? String, "Selected")
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

        renamed.tap()
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard.camera."))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(tiles.count, 2)
        for tile in tiles.allElementsBoundByIndex {
            XCTAssertGreaterThan(tile.frame.width, 50)
            XCTAssertEqual(tile.frame.width / tile.frame.height, 16.0 / 9.0, accuracy: 0.04)
        }
        XCTAssertTrue(app.staticTexts["Entry"].exists)
        XCTAssertTrue(app.staticTexts["Garden"].exists)
        XCTAssertFalse(app.staticTexts["Live · Muted"].exists)
        XCTAssertFalse(app.staticTexts["Fluent streams, sound off. Every view keeps its original proportions."].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        capture("en-dashboard-video-wall")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))

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
    private func waitFor(_ predicate: NSPredicate, on element: Any) {
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
