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
        XCTAssertTrue(app.staticTexts["1"].exists)
        XCTAssertTrue(app.staticTexts["M31"].exists)
        app.tabBars.buttons["Sync"].tap()
        XCTAssertTrue(app.otherElements["mobile-sync-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import newer plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original photos stay on your Mac or external drive."].exists)
    }

    func testImportedFixtureSupportsAllFourTabsAndSafePhoneEdits() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "imported"]
        app.launch()

        XCTAssertTrue(app.otherElements["mobile-tonight-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobile-checklist-focus"].waitForExistence(timeout: 5))
        app.buttons["mobile-checklist-focus"].tap()
        XCTAssertEqual(app.buttons["mobile-checklist-focus"].value as? String, "Completed")
        app.buttons["mobile-note-edit"].tap()
        let editor = app.textViews["v5.mobile.note.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" On phone")
        app.buttons["v5.mobile.note.save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "On phone")).firstMatch.waitForExistence(timeout: 5))

        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.otherElements["mobile-projects-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Collecting"].exists)
        app.tabBars.buttons["Briefings"].tap()
        XCTAssertTrue(app.otherElements["mobile-briefings-surface"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Sync"].tap()
        XCTAssertTrue(app.otherElements["mobile-sync-surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Phone changes waiting"].exists)
        XCTAssertTrue(app.staticTexts["Ready to send back in the next step."].exists)
        XCTAssertTrue(app.staticTexts["mobile-queued-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mobile-queued-count"].label, "2")
        XCTAssertTrue(app.staticTexts["Original photos stay on your Mac or external drive."].exists)
    }

    func testImportedFixtureSupportsHungarianPlanJourney() {
        let app = XCUIApplication()
        app.launchArguments = ["--astrotool-mobile-ui-fixture", "imported", "-AppleLanguages", "(hu)", "-AppleLocale", "hu_HU"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Ma este"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Projektek"].tap()
        XCTAssertTrue(app.staticTexts["Gyűjtés"].waitForExistence(timeout: 5))
        app.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Szűretlen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Még nincs jegyzet"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Tervek"].tap()
        XCTAssertTrue(app.otherElements["mobile-briefings-surface"].waitForExistence(timeout: 5))
        app.cells.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["Dátum nincs megadva"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Átvitel"].tap()
        XCTAssertTrue(app.staticTexts["A Mac-terv mentve ezen az iPhone-on"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Az eredeti fotók a Macen vagy a külső meghajtón maradnak."].exists)
    }
}
