import XCTest

final class AstroToolLaunchTests: XCTestCase {
    private var fixtureContainer: URL!
    private var appSupportContainer: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let temporaryRoot = FileManager.default.temporaryDirectory
        let runID = UUID().uuidString
        fixtureContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Fixture-\(runID)",
            isDirectory: true
        )
        appSupportContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Support-\(runID)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureContainer,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: appSupportContainer,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        for url in [fixtureContainer, appSupportContainer].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    func testV2FixtureLaunchAndNavigationSmoke() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UseV2UI",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-UITestFixtureRoot", fixtureContainer.path,
            "-UITestAppSupport", appSupportContainer.path,
        ]
        app.launch()
        app.activate()

        let mainWindow = app.windows.firstMatch
        if !mainWindow.waitForExistence(timeout: 3) {
            let newWindow = app.menuItems["New Window"]
            XCTAssertTrue(
                newWindow.waitForExistence(timeout: 3),
                "A restored closed-window state must retain the native New Window command."
            )
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 10),
            "The V2 WindowGroup must open or recover a main window before UI queries begin."
        )

        let summary = element("v2.onboarding.summary", in: app)
        XCTAssertTrue(
            summary.waitForExistence(timeout: 20),
            "The injected read-only fixture should open directly to its scan summary."
        )
        XCTAssertFalse(
            app.dialogs.firstMatch.exists,
            "Fixture mode must never present the system folder picker."
        )

        let continueButton = element("v2.onboarding.continue", in: app)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.click()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5))

        let destinations = [
            (sidebar: "v2.sidebar.home", detail: "v2.detail.home", title: "Home"),
            (sidebar: "v2.sidebar.projects", detail: "v2.detail.projects", title: "No projects yet"),
            (sidebar: "v2.sidebar.nights", detail: "v2.detail.nights", title: "No observing nights yet"),
            (sidebar: "v2.sidebar.planning", detail: "v2.detail.planning", title: "No plan selected"),
            (sidebar: "v2.sidebar.library", detail: "v2.detail.library", title: "No library open"),
            (sidebar: "v2.sidebar.insights", detail: "v2.detail.insights", title: "No insights yet"),
        ]
        for expected in destinations {
            let destination = element(expected.sidebar, in: app)
            XCTAssertTrue(destination.waitForExistence(timeout: 5), "Missing \(expected.sidebar)")
            XCTAssertTrue(destination.isHittable, "Sidebar destination is not hittable: \(expected.sidebar)")
            destination.click()
            let detail = element(expected.detail, in: app)
            XCTAssertTrue(
                detail.waitForExistence(timeout: 5),
                "Sidebar click did not reveal \(expected.detail)"
            )
            XCTAssertEqual(
                detail.label,
                expected.title,
                "Unexpected detail title after clicking \(expected.sidebar)"
            )
        }

        element("v2.sidebar.home", in: app).click()
        XCTAssertTrue(element("v2.detail.home", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("v2.home.night-context", in: app).waitForExistence(timeout: 5))

        let inspectorToggle = element("v2.toolbar.inspector", in: app)
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(inspectorToggle.isHittable)
        inspectorToggle.click()
        XCTAssertTrue(element("v2.inspector", in: app).waitForExistence(timeout: 5))

        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
