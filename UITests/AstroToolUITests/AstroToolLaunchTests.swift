import XCTest

/// Full click-through smoke test of the V2 shell against an injected
/// read-only fixture library. Every `waitForExistence` doubles as a
/// responsiveness assertion: a frozen main thread stops answering
/// accessibility queries, so a UI hang fails the test instead of hanging it.
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
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 10),
            "The V2 WindowGroup must open a main window before UI queries begin."
        )

        completeOnboarding(app)
        walkAllSections(app)
        exercisePlanning(app)
        exerciseLibraryChildren(app)
        exerciseProjectWorkspace(app)
        exerciseInspector(app)

        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Flows

    @MainActor
    private func completeOnboarding(_ app: XCUIApplication) {
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
    }

    @MainActor
    private func walkAllSections(_ app: XCUIApplication) {
        let destinations = [
            (sidebar: "v2.sidebar.home", detail: "v2.detail.home"),
            (sidebar: "v2.sidebar.projects", detail: "v2.detail.projects"),
            (sidebar: "v2.sidebar.nights", detail: "v2.detail.nights"),
            (sidebar: "v2.sidebar.planning", detail: "v2.detail.planning"),
            (sidebar: "v2.sidebar.library", detail: "v2.detail.library"),
            (sidebar: "v2.sidebar.insights", detail: "v2.detail.insights"),
        ]
        for expected in destinations {
            let destination = element(expected.sidebar, in: app)
            XCTAssertTrue(destination.waitForExistence(timeout: 5), "Missing \(expected.sidebar)")
            XCTAssertTrue(destination.isHittable, "Sidebar destination is not hittable: \(expected.sidebar)")
            destination.click()
            XCTAssertTrue(
                element(expected.detail, in: app).waitForExistence(timeout: 8),
                "Sidebar click did not reveal \(expected.detail)"
            )
        }
    }

    /// Planning froze twice in the wild (builds 20013-20016): first from
    /// heavy recomputation on the render path, then from same-value binding
    /// writes closing an @Observable invalidation loop. This flow re-enters
    /// Planning repeatedly and drags the zoom slider - if any of those loops
    /// regress, the accessibility queries below time out and fail the test.
    @MainActor
    private func exercisePlanning(_ app: XCUIApplication) {
        for _ in 0..<3 {
            element("v2.sidebar.planning", in: app).click()
            XCTAssertTrue(
                element("v2.planning.setup", in: app).waitForExistence(timeout: 8),
                "Planning setup picker did not appear - Planning likely froze"
            )
            element("v2.sidebar.home", in: app).click()
            XCTAssertTrue(element("v2.detail.home", in: app).waitForExistence(timeout: 8))
        }

        element("v2.sidebar.planning", in: app).click()
        XCTAssertTrue(element("v2.planning.recommendations", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("v2.planning.integration", in: app).waitForExistence(timeout: 5))

        let focalControl = element("v2.planning.focal-length", in: app)
        if focalControl.waitForExistence(timeout: 3) {
            let slider = focalControl.sliders.firstMatch.exists
                ? focalControl.sliders.firstMatch
                : app.sliders.firstMatch
            if slider.exists {
                slider.adjust(toNormalizedSliderPosition: 0.8)
                slider.adjust(toNormalizedSliderPosition: 0.2)
            }
        }
        XCTAssertTrue(
            element("v2.planning.recommendations", in: app).waitForExistence(timeout: 8),
            "Planning stopped responding after slider interaction"
        )
    }

    @MainActor
    private func exerciseLibraryChildren(_ app: XCUIApplication) {
        let health = element("v2.sidebar.library.health", in: app)
        if !health.exists {
            element("v2.sidebar.library", in: app).click()
        }
        XCTAssertTrue(health.waitForExistence(timeout: 5), "Library must expose a Health child row")
        health.click()
        XCTAssertTrue(element("v2.detail.library.health", in: app).waitForExistence(timeout: 8))

        let calibration = element("v2.sidebar.library.calibration", in: app)
        XCTAssertTrue(calibration.waitForExistence(timeout: 5))
        calibration.click()
        XCTAssertTrue(element("v2.detail.library.calibration", in: app).waitForExistence(timeout: 8))
    }

    @MainActor
    private func exerciseProjectWorkspace(_ app: XCUIApplication) {
        element("v2.sidebar.projects", in: app).click()
        XCTAssertTrue(element("v2.detail.projects", in: app).waitForExistence(timeout: 8))

        let table = app.tables.firstMatch
        guard table.waitForExistence(timeout: 5) else {
            XCTFail("Projects table not found")
            return
        }
        let firstRow = table.tableRows.element(boundBy: 0)
        guard firstRow.waitForExistence(timeout: 5) else {
            XCTFail("The fixture library must list at least one project")
            return
        }
        firstRow.doubleClick()

        let workspace = element("v2.project.workspace", in: app)
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 10),
            "Double-clicking a project row must push the project workspace"
        )

        // Walk the router-backed tabs; a stuck tab switch fails the wait.
        for tab in ["Nights", "Series", "Results", "Notes", "Overview"] {
            let segment = app.radioButtons[tab].exists
                ? app.radioButtons[tab]
                : app.buttons[tab]
            if segment.exists, segment.isHittable {
                segment.click()
                XCTAssertTrue(
                    workspace.waitForExistence(timeout: 5),
                    "Project workspace vanished while switching to the \(tab) tab"
                )
            }
        }

        // Native Back must return to the projects list.
        let breadcrumb = element("v2.breadcrumb", in: app)
        if breadcrumb.exists, breadcrumb.buttons.firstMatch.isHittable {
            breadcrumb.buttons.firstMatch.click()
        } else {
            app.typeKey("[", modifierFlags: .command)
        }
        XCTAssertTrue(
            element("v2.detail.projects", in: app).waitForExistence(timeout: 8),
            "Back navigation did not return to the projects list"
        )
    }

    @MainActor
    private func exerciseInspector(_ app: XCUIApplication) {
        let inspectorToggle = element("v2.toolbar.inspector", in: app)
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(inspectorToggle.isHittable)
        inspectorToggle.click()
        XCTAssertTrue(element("v2.inspector", in: app).waitForExistence(timeout: 5))
        inspectorToggle.click()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
