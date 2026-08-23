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
    }
}
