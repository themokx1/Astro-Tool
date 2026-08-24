import XCTest

final class AstroToolMobileLaunchTests: XCTestCase {
    func testEmptyStateExplainsAirDropAndPhotoSafety() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "empty"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No AstroTool library on this iPhone yet."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original photos stay on your Mac or external drive."].exists)
    }

    func testEmptyStateIsLocalizedInHungarian() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "empty", "-AppleLanguages", "(hu)", "-AppleLocale", "hu_HU"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Még nincs AstroTool-könyvtár ezen az iPhone-on."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Az eredeti fotók a Macen vagy a külső meghajtón maradnak."].exists)
    }

    func testExistingLibraryFixtureLoadsAnAuthoritativeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "imported"]
        app.launch()

        XCTAssertTrue(app.otherElements["mobile-imported-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["M31"].exists)
        app.tabBars.buttons["Sync"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile-sync-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Projects, 1"].waitForExistence(timeout: 5))
        let syncList = app.collectionViews["mobile-sync-surface"]
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Original photos stay on your Mac or external drive."], in: syncList))
        XCTAssertTrue(scrollUntilVisible(app.buttons["Import newer plan"], in: syncList))
    }

    func testImportedFixtureSupportsAllFourTabsAndSafePhoneEdits() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "imported"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["mobile-tonight-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobile-checklist-focus"].waitForExistence(timeout: 5))
        app.buttons["mobile-checklist-focus"].tap()
        let completed = NSPredicate(format: "value == %@", "Completed")
        let completionExpectation = XCTNSPredicateExpectation(predicate: completed, object: app.buttons["mobile-checklist-focus"])
        XCTAssertEqual(XCTWaiter.wait(for: [completionExpectation], timeout: 5), .completed)
        app.buttons["mobile-note-edit"].tap()
        let editor = app.textViews["v5.mobile.note.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" On phone")
        app.buttons["v5.mobile.note.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "On phone")).firstMatch.waitForExistence(timeout: 5))

        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile-projects-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Collecting"].exists)
        app.tabBars.buttons["Briefings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile-briefings-surface"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sync"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile-sync-surface"].waitForExistence(timeout: 5))
        let syncList = app.collectionViews["mobile-sync-surface"]
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Phone changes waiting"], in: syncList))
        XCTAssertTrue(app.staticTexts["Ready to send back in the next step."].exists)
        let queuedCount = app.staticTexts["mobile-queued-count"]
        XCTAssertTrue(queuedCount.exists)
        XCTAssertEqual(queuedCount.label, "Phone changes waiting, 2")
        XCTAssertTrue(app.staticTexts["Original photos stay on your Mac or external drive."].exists)
    }

    func testImportedFixtureSupportsHungarianPlanJourney() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "imported", "-AppleLanguages", "(hu)", "-AppleLocale", "hu_HU"]
        app.launch()

        XCTAssertTrue(app.staticTexts["A ma esti terv"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Projektek"].tap()
        XCTAssertTrue(app.staticTexts["Gyűjtés"].waitForExistence(timeout: 5))
        // Cell 0 is the sort-mode segmented control and cell 1 is the
        // "Projektek" section header; the project row itself is cell 2.
        app.cells.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["Szűretlen"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Még nincs jegyzet"], in: app.collectionViews.firstMatch))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Tervek"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile-briefings-surface"].waitForExistence(timeout: 5))
        let undatedBriefing = app.descendants(matching: .any)["mobile-briefing-00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(undatedBriefing.waitForExistence(timeout: 5))
        undatedBriefing.tap()
        // "Planned" (title) and "Date not set" (value) are combined by
        // LabeledContent into a single accessibility element.
        XCTAssertTrue(app.staticTexts["Tervezve, Dátum nincs megadva"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Átvitel"].tap()
        XCTAssertTrue(app.staticTexts["A Mac-terv mentve ezen az iPhone-on"].waitForExistence(timeout: 5))
        let syncList = app.collectionViews["mobile-sync-surface"]
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Az eredeti fotók a Macen vagy a külső meghajtón maradnak."], in: syncList))
    }

    /// Off-screen `List`/`CollectionView` rows are virtualized by UIKit and
    /// do not exist in the accessibility tree until scrolled into view, so a
    /// plain `waitForExistence` never finds them. Nudge the given container
    /// up until the element materializes (or give up after `maxSwipes`).
    @discardableResult
    private func scrollUntilVisible(_ element: XCUIElement, in container: XCUIElement, maxSwipes: Int = 8) -> Bool {
        var attempts = 0
        while !element.exists && attempts < maxSwipes {
            container.swipeUp()
            attempts += 1
        }
        return element.waitForExistence(timeout: 2)
    }
}
