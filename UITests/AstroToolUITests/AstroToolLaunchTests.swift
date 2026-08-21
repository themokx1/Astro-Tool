import XCTest

/// Full click-through smoke test of the V2 shell against an injected
/// read-only fixture library.
///
/// Every navigation step runs against a wall-clock **responsiveness budget**.
/// That is deliberate: the freezes reported from real use (builds 20013-20017)
/// were never crashes, they were the main thread failing to finish a layout
/// pass, and a plain `waitForExistence` hides that behind a generous timeout.
/// A measured budget turns "the UI feels frozen" into a hard gate — the
/// Planning regression, for instance, showed up here as a *73 second* sidebar
/// click while Home, Projects and Nights each took about two seconds.
final class AstroToolLaunchTests: XCTestCase {
    /// Entering a section must complete well inside this. Generous enough for
    /// a cold query layer on a loaded machine, far below the multi-minute
    /// stalls the layout regressions produced.
    private static let navigationBudget: TimeInterval = 12

    private var fixtureContainer: URL!
    private var appSupportContainer: URL!
    private var briefingExportURL: URL!

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
        try FileManager.default.createDirectory(at: fixtureContainer, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: appSupportContainer, withIntermediateDirectories: false)
        briefingExportURL = appSupportContainer.appendingPathComponent("night-briefing.pdf")
    }

    override func tearDownWithError() throws {
        for url in [fixtureContainer, appSupportContainer].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Tests

    @MainActor
    func testV2ShellNavigationIsResponsive() throws {
        let app = launchFixtureApp()
        completeOnboarding(app)

        let sections = [
            (sidebar: "v2.sidebar.home", detail: "v2.detail.home", title: "Home"),
            (sidebar: "v2.sidebar.projects", detail: "v2.detail.projects", title: "Projects"),
            (sidebar: "v2.sidebar.nights", detail: "v2.detail.nights", title: "Nights"),
            (sidebar: "v2.sidebar.planning", detail: "v2.detail.planning", title: "Planning"),
            (sidebar: "v2.sidebar.library", detail: "v2.detail.library", title: "Library"),
            (sidebar: "v2.sidebar.insights", detail: "v2.detail.insights", title: "Insights"),
        ]
        for section in sections {
            let detail = enterSection(section.sidebar, revealing: section.detail, in: app)
            XCTAssertEqual(
                detail.label, section.title,
                "Unexpected detail title after clicking \(section.sidebar)"
            )
        }

        // The Home rail is the app's first impression; keep it pinned.
        enterSection("v2.sidebar.home", revealing: "v2.detail.home", in: app)
        XCTAssertTrue(element("v2.home.night-context", in: app).waitForExistence(timeout: 8))

        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Planning is the page that froze in real use: its recommendation table
    /// holds the whole 217-target catalog. Re-entering it repeatedly and
    /// dragging the zoom slider is the regression net for that whole class of
    /// layout/invalidation defect.
    @MainActor
    func testPlanningStaysResponsiveUnderRepeatedEntryAndSliderDrag() throws {
        let app = launchFixtureApp()
        completeOnboarding(app)

        for _ in 0..<3 {
            enterSection("v2.sidebar.planning", revealing: "v2.detail.planning", in: app)
            XCTAssertTrue(
                element("v2.planning.setup", in: app).waitForExistence(timeout: 8),
                "Planning setup picker never appeared"
            )
            XCTAssertTrue(
                element("v2.planning.recommendations", in: app).waitForExistence(timeout: 8),
                "Planning recommendation table never appeared"
            )
            enterSection("v2.sidebar.home", revealing: "v2.detail.home", in: app)
        }

        enterSection("v2.sidebar.planning", revealing: "v2.detail.planning", in: app)
        let slider = app.sliders.firstMatch
        if slider.waitForExistence(timeout: 5) {
            let start = Date()
            slider.adjust(toNormalizedSliderPosition: 0.8)
            slider.adjust(toNormalizedSliderPosition: 0.2)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, Self.navigationBudget,
                "Dragging the focal-length slider blocked the UI for \(String(format: "%.1f", elapsed))s"
            )
        }
        XCTAssertTrue(
            element("v2.planning.recommendations", in: app).waitForExistence(timeout: 8),
            "Planning stopped responding after slider interaction"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testLibraryChildrenAndProjectWorkspaceDrillDown() throws {
        let app = launchFixtureApp()
        completeOnboarding(app)

        // Task 10: Health's own findings table is superseded by the Archive
        // page's task cards, which now render for `.library` itself (see
        // `enterSection` above), so Health no longer has its own sidebar
        // child row to click through here. Calibration still does.
        enterSection("v2.sidebar.library", revealing: "v2.detail.library", in: app)

        let calibration = element("v2.sidebar.library.calibration", in: app)
        XCTAssertTrue(calibration.waitForExistence(timeout: 5))
        calibration.click()
        XCTAssertTrue(element("v2.detail.library.calibration", in: app).waitForExistence(timeout: 10))

        enterSection("v2.sidebar.projects", revealing: "v2.detail.projects", in: app)
        // macOS 26 vends SwiftUI `Table` as an AX *outline* (verified from a
        // runner snapshot: the project list renders as Outline/OutlineRow
        // while `app.tables` matches nothing). The sidebar is also an
        // outline, but it is the only one labeled "Sidebar" -- so the first
        // non-sidebar outline IS the page table, on either vending.
        let projectTable = app.tables.firstMatch.exists
            ? app.tables.firstMatch
            : app.outlines.matching(NSPredicate(format: "label != 'Sidebar'")).firstMatch
        let firstRow = projectTable.descendants(matching: .outlineRow).firstMatch.exists
            ? projectTable.descendants(matching: .outlineRow).element(boundBy: 0)
            : projectTable.tableRows.element(boundBy: 0)
        guard firstRow.waitForExistence(timeout: 8) else {
            XCTFail("The fixture library must list at least one project row")
            return
        }
        let workspace = element("v2.project.workspace", in: app)
        // A hosted runner under load can split the two clicks past the
        // double-click interval, leaving the row merely selected -- retry
        // the GESTURE (not the assertion) a couple of times before failing,
        // and measure the budget from the attempt that actually landed.
        var pushStart = Date()
        // The row is WIDER than the window on a small display (the fixture
        // table's columns overflow horizontally), so a row-center double
        // click can land outside the safely-hittable region. Aim at real
        // cell content first, then fall back to the row itself and to an
        // explicit near-left coordinate.
        for attempt in 0..<3 {
            pushStart = Date()
            switch attempt {
            case 0:
                let text = firstRow.staticTexts.firstMatch
                (text.exists ? text : firstRow).doubleClick()
            case 1:
                firstRow.doubleClick()
            default:
                firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).doubleClick()
            }
            if workspace.waitForExistence(timeout: 4) { break }
            if attempt == 2 {
                XCTFail("Double-clicking a project row must push the project workspace")
                return
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(pushStart), Self.navigationBudget,
            "Pushing the project workspace exceeded the responsiveness budget"
        )

        for tab in ["Nights", "Series", "Results", "Notes", "Overview"] {
            let segment = app.radioButtons[tab].exists ? app.radioButtons[tab] : app.buttons[tab]
            guard segment.exists, segment.isHittable else { continue }
            let tabStart = Date()
            segment.click()
            XCTAssertTrue(
                workspace.waitForExistence(timeout: 8),
                "Project workspace vanished while switching to the \(tab) tab"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(tabStart), Self.navigationBudget,
                "Switching to the \(tab) tab exceeded the responsiveness budget"
            )
        }

        let breadcrumb = element("v2.breadcrumb", in: app)
        if breadcrumb.exists, breadcrumb.buttons.firstMatch.isHittable {
            breadcrumb.buttons.firstMatch.click()
        } else {
            app.typeKey("[", modifierFlags: .command)
        }
        XCTAssertTrue(
            element("v2.detail.projects", in: app).waitForExistence(timeout: 10),
            "Back navigation did not return to the projects list"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testInspectorTogglesWithoutStalling() throws {
        let app = launchFixtureApp()
        completeOnboarding(app)

        let toggle = element("v2.toolbar.inspector", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertTrue(toggle.isHittable)
        toggle.click()
        XCTAssertTrue(element("v2.inspector", in: app).waitForExistence(timeout: 8))
        toggle.click()
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testNightBriefingCanBePreparedSavedAndExportedForTheField() throws {
        let app = launchFixtureApp()
        completeOnboarding(app)

        enterSection("v2.sidebar.home", revealing: "v2.detail.home", in: app)
        let openBriefing = element("v2.home.open-briefing", in: app)
        XCTAssertTrue(
            openBriefing.waitForExistence(timeout: 20),
            "The briefing action must appear after the fixture library finishes opening."
        )
        XCTAssertTrue(openBriefing.isHittable, "The briefing action must be ready to click.")
        openBriefing.click()
        XCTAssertTrue(element("v2.briefing.start.today", in: app).waitForExistence(timeout: 8))
        element("v2.briefing.start.today", in: app).click()
        XCTAssertTrue(element("v2.briefing.step.1", in: app).waitForExistence(timeout: 8))

        element("v2.briefing.save-revision", in: app).click()
        element("v2.briefing.next", in: app).click()
        XCTAssertTrue(element("v2.briefing.add-target", in: app).waitForExistence(timeout: 8))
        element("v2.briefing.add-target", in: app).click()

        for step in 3...5 {
            element("v2.briefing.next", in: app).click()
            XCTAssertTrue(element("v2.briefing.step.\(step)", in: app).waitForExistence(timeout: 8))
        }
        let export = element("v2.briefing.export.pdf-png", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 20))
        export.click()

        let pdfExists = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.briefingExportURL.path) },
            object: nil
        )
        wait(for: [pdfExists], timeout: 30)
        let pages = briefingExportURL.deletingPathExtension().appendingPathExtension("pages")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pages.appendingPathComponent("page-1.png").path))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "V4 Night Briefing export"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: - Helpers

    @MainActor
    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-UseV2UI",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "-UITestFixtureRoot", fixtureContainer.path,
            "-UITestAppSupport", appSupportContainer.path,
            "-UITestBriefingExportPath", briefingExportURL.path,
        ]
        app.launch()
        app.activate()

        let mainWindow = app.windows.firstMatch
        if !mainWindow.waitForExistence(timeout: 3) {
            // A restored closed-window state must still expose the native
            // New Window command, otherwise the app is unrecoverable.
            let newWindow = app.menuItems["New Window"]
            XCTAssertTrue(
                newWindow.waitForExistence(timeout: 5),
                "A restored closed-window state must retain the native New Window command."
            )
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(
            mainWindow.waitForExistence(timeout: 15),
            "The V2 WindowGroup must open a main window before UI queries begin."
        )
        return app
    }

    @MainActor
    private func completeOnboarding(_ app: XCUIApplication) {
        let summary = element("v2.onboarding.summary", in: app)
        XCTAssertTrue(
            summary.waitForExistence(timeout: 25),
            "The injected read-only fixture should open directly to its scan summary."
        )
        XCTAssertFalse(
            app.dialogs.firstMatch.exists,
            "Fixture mode must never present the system folder picker."
        )
        let continueButton = element("v2.onboarding.continue", in: app)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        continueButton.click()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 8))
    }

    /// Clicks a sidebar row and asserts both that its detail appears and that
    /// the whole transition stayed inside the responsiveness budget.
    @MainActor
    @discardableResult
    private func enterSection(
        _ sidebarIdentifier: String,
        revealing detailIdentifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let destination = element(sidebarIdentifier, in: app)
        XCTAssertTrue(
            destination.waitForExistence(timeout: 8),
            "Missing \(sidebarIdentifier)", file: file, line: line
        )
        XCTAssertTrue(
            destination.isHittable,
            "Sidebar destination is not hittable: \(sidebarIdentifier)", file: file, line: line
        )

        let started = Date()
        destination.click()
        let detail = element(detailIdentifier, in: app)
        let appeared = detail.waitForExistence(timeout: Self.navigationBudget)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(
            appeared,
            "Clicking \(sidebarIdentifier) did not reveal \(detailIdentifier) within "
                + "\(String(format: "%.0f", Self.navigationBudget))s — the UI is stalled, not merely slow",
            file: file, line: line
        )
        XCTAssertLessThan(
            elapsed, Self.navigationBudget,
            "Entering \(sidebarIdentifier) took \(String(format: "%.1f", elapsed))s",
            file: file, line: line
        )
        return detail
    }

    /// Typed queries first: an untyped `descendants(matching: .any)` walks the
    /// entire accessibility tree, and on a page with a large table that query
    /// alone can time out. Role-filtered queries are far cheaper, so the
    /// untyped scan stays a last resort.
    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let typed: [XCUIElementQuery] = [
            window.buttons, window.staticTexts, window.groups,
            window.tables, window.outlines, window.sliders,
            window.popUpButtons, window.textFields, window.checkBoxes,
            window.radioButtons, window.scrollViews, window.splitGroups,
        ]
        for query in typed {
            let candidate = query[identifier]
            if candidate.exists { return candidate }
        }
        return window.descendants(matching: .any)[identifier]
    }
}
