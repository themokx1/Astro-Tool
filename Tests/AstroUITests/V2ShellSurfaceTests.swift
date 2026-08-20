import AstroUI
import Foundation
import Testing

@Suite("Native V2 shell")
struct V2ShellSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("V2 is the product default while explicit switches take precedence", arguments: [
        (arguments: ["AstroToolApp"], environment: [:], development: true, expected: true),
        (arguments: ["AstroToolApp"], environment: [:], development: false, expected: true),
        (arguments: ["AstroToolApp", "-UseV1UI"], environment: ["ASTROTOOL_V2_UI": "1"], development: true, expected: false),
        (arguments: ["AstroToolApp", "-UseV2UI"], environment: ["ASTROTOOL_V2_UI": "0"], development: false, expected: true),
        (arguments: ["AstroToolApp"], environment: ["ASTROTOOL_V2_UI": "false"], development: true, expected: false),
        (arguments: ["AstroToolApp"], environment: ["ASTROTOOL_V2_UI": "YES"], development: false, expected: true),
    ])
    func launchSelection(
        arguments: [String],
        environment: [String: String],
        development: Bool,
        expected: Bool
    ) {
        #expect(
            AppUILaunchSelection(
                arguments: arguments,
                environment: environment,
                isDevelopmentBuild: development
            ).usesV2 == expected
        )
    }

    // MARK: V2 UI/UX audit task 4 -- a launch argument that opens a section
    // directly, enabling runtime verification (e.g. of the Planning freeze)
    // without clicking through the sidebar by hand.

    @Test("-UITestInitialSection parses a valid section, rejects an unknown value, and is nil when absent -- a pure function, no running app required", arguments: [
        (arguments: ["AstroToolApp", "-UITestInitialSection", "planning"], expected: PrimarySection.planning as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "library"], expected: PrimarySection.library as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "home"], expected: PrimarySection.home as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "projects"], expected: PrimarySection.projects as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "nights"], expected: PrimarySection.nights as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "insights"], expected: PrimarySection.insights as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection", "bogus-section"], expected: nil as PrimarySection?),
        (arguments: ["AstroToolApp", "-UITestInitialSection"], expected: nil as PrimarySection?),
        (arguments: ["AstroToolApp"], expected: nil as PrimarySection?),
    ])
    func initialSectionLaunchArgumentParsing(arguments: [String], expected: PrimarySection?) {
        #expect(
            AppUILaunchSelection(
                arguments: arguments,
                environment: [:],
                isDevelopmentBuild: true
            ).initialSection == expected
        )
    }

    @Test("V2RootView opens with the requested initial section and an empty path when one was parsed")
    func v2RootViewWiresTheInitialSectionArgument() throws {
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"),
            encoding: .utf8
        )
        #expect(root.contains("initialSection: PrimarySection?"))
        #expect(root.contains("router.navigate(to: initialSection)"))
    }

    @Test("The app entry point passes its parsed initial section into V2RootView")
    func appEntryPointPassesTheInitialSectionArgument() throws {
        let appEntry = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroToolApp/AstroToolApp.swift"),
            encoding: .utf8
        )
        #expect(appEntry.contains("initialSection: launchSelection.initialSection"))
    }

    @Test("The shell uses native split-view, inspector, and window-scoped routing")
    func shellSurface() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift")
        let root = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(root.contains("NavigationSplitView"))
        #expect(root.contains(".inspector(isPresented:"))
        #expect(root.contains(".focusedSceneValue(\\.appRouter"))
        #expect(root.contains("minWidth: 820"))
        #expect(root.contains("minHeight: 600"))
        #expect(root.contains("@SceneStorage(\"v2.windowRestoration\")"))
        #expect(root.contains("@State private var router"))
        #expect(!root.contains(".onDisappear"))
        #expect(!root.contains(".preferredColorScheme"))
        #expect(!root.contains("AppState.shared"))
        #expect(!root.contains("NotificationCenter"))
        #expect(root.contains("ScanWorkflowMaterializer.materializeProductionLibrary"))
    }

    /// Owner feedback 2026-08-19 ("miért nem rendes liquid glass-os még
    /// mindig?"): the sidebar was pure system material sitting next to an
    /// opaque detail column that stopped dead at its own edge -- vibrancy
    /// needs content behind the glass to refract, and a hard edge is
    /// nothing. `backgroundExtensionEffect()` is the macOS 26 primitive
    /// that mirrors/blurs the detail column's edge into the region under
    /// the sidebar's glass. Pinned on the exact detail-column paint site so
    /// a future edit that drops the call regresses back to a flat sidebar
    /// without this test noticing the reason why.
    @Test("The detail column extends its backdrop under the sidebar's glass")
    func detailColumnExtendsBackdropUnderSidebarGlass() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift")
        let root = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let groundRange = root.range(of: ".background(AstroTokens.Color.ground)") else {
            Issue.record("the detail column's ground paint is gone -- see theDetailColumnPaintsTheOpaqueBackdrop")
            return
        }
        guard let extensionRange = root.range(of: ".backgroundExtensionEffect()", range: groundRange.upperBound..<root.endIndex) else {
            Issue.record("`.backgroundExtensionEffect()` not found after the detail column's `ground` paint")
            return
        }
        let between = root[groundRange.upperBound..<extensionRange.lowerBound]
        let onlyCommentsOrBlankBetween = between
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .allSatisfy { $0.isEmpty || $0.hasPrefix("//") }
        #expect(onlyCommentsOrBlankBetween, """
            `backgroundExtensionEffect()` must sit immediately after the \
            detail column's `ground` paint with nothing but comments in \
            between -- it extends exactly that backdrop under the \
            sidebar's glass, not some later, different layer:
            \(between)
            """)

        // The sidebar itself must stay pure system material: vibrancy dies
        // the moment anything opaque sits on or behind it, so the sidebar
        // type must carry no `.background(` of its own.
        guard let sidebarRange = root.range(of: "private struct V2Sidebar") else {
            Issue.record("V2Sidebar not found")
            return
        }
        guard let nextStructRange = root.range(of: "\nprivate struct ", range: sidebarRange.upperBound..<root.endIndex)
            ?? root.range(of: "\nstruct ", range: sidebarRange.upperBound..<root.endIndex) else {
            Issue.record("could not bound V2Sidebar's body")
            return
        }
        let sidebarBody = root[sidebarRange.upperBound..<nextStructRange.lowerBound]
        #expect(!sidebarBody.contains(".background("), """
            V2Sidebar must stay unpainted -- any `.background(` here would \
            sit behind the system glass and kill the refraction \
            `backgroundExtensionEffect()` on the detail column exists to feed.
            """)
    }

    @Test("Appearance tokens are adaptive and unavailable actions are honest")
    func adaptiveTokensAndHonestActions() throws {
        let tokens = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/DesignSystem/AstroTokens.swift"
            ),
            encoding: .utf8
        )
        let home = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Home/HomeView.swift"
            ),
            encoding: .utf8
        )
        let commands = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Views/Commands.swift"
            ),
            encoding: .utf8
        )
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )

        // Wave 2 Task 2: `ground`/`edge` no longer alias
        // `NSColor.windowBackgroundColor`/`.separatorColor` -- the rebuilt
        // `AstroTokens` palette (spec section 5.1) gives every color its own
        // literal dark/light hex pair through `NSColor(name:dynamicProvider:)`
        // instead, which is what actually makes each token adaptive now.
        #expect(tokens.contains("dynamicProvider"))
        #expect(tokens.contains("bestMatch(from: [.aqua, .darkAqua])"))
        #expect(home.contains("Choose Image Library…"))
        #expect(home.contains("read-only index"))
        #expect(!home.contains("Open Library"))
        // W6-D: "New Project…"/"New Night…" used to be the one permanently
        // `.disabled(true)` menu pair, with a "not built yet" tooltip --
        // `V2RootView` has carried real `.newProject`/`.newNight` router
        // presentations since Wave 4 (this same file's own toolbar "New
        // Project" button, `NewProjectView`/`NewSessionView`), so these two
        // are wired to `router?.present(...)` now instead of shipping a
        // permanently-dead menu entry. "Unavailable actions are honest"
        // now means neither of these fake-disables itself -- both either
        // work or don't exist.
        #expect(!root.contains("Available after library workflows arrive"))
        #expect(!commands.contains("Available after library workflows arrive"))
        #expect(!root.contains(".disabled(true)"))
        #expect(!commands.contains(".disabled(true)"))
        #expect(commands.contains("router?.present(.newProject)"))
        #expect(commands.contains("router?.present(.newNight)"))
    }

    @Test("Every stable section is represented once by the shared route model")
    func stableSections() {
        #expect(PrimarySection.allCases == [
            .home,
            .projects,
            .nights,
            .planning,
            .library,
            .insights,
        ])
    }

    @Test("Every sidebar route exposes a stable detail identifier and title")
    func stableDetailAutomationContract() throws {
        // Wave 4 Task 2: `V2RootView` no longer carries its own dead
        // `PrimarySection.detailAccessibilityIdentifier` helper (removed as
        // part of the two-column shell cleanup -- it was never actually
        // APPLIED to any view, only kept alive so this test's old
        // `root.contains(...)` grep would pass). Each feature view already
        // applies its own `v2.detail.*` identifier directly to itself; this
        // test now reads THOSE files instead of grepping the dead helper.
        let home = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Home/HomeView.swift"
            ),
            encoding: .utf8
        )
        let featureFiles: [(route: String, path: String)] = [
            ("projects", "Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            ("nights", "Sources/AstroUI/Features/Nights/NightsView.swift"),
            ("planning", "Sources/AstroUI/Features/Planning/PlanningView.swift"),
            // Task 10: `.library` now renders `ArchiveView`, the deleted
            // `LibraryView`'s replacement.
            ("library", "Sources/AstroUI/Features/Archive/ArchiveView.swift"),
            ("insights", "Sources/AstroUI/Features/Insights/InsightsView.swift"),
        ]
        let uiTest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "UITests/AstroToolUITests/AstroToolLaunchTests.swift"
            ),
            encoding: .utf8
        )

        #expect(home.contains("v2.detail.home"))
        for (route, path) in featureFiles {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("v2.detail.\(route)"))
            #expect(uiTest.contains("v2.detail.\(route)"))
        }
        for title in [
            "Home",
            "Projects",
            "Nights",
            "Planning",
            "Library",
            "Insights",
        ] {
            #expect(uiTest.contains("title: \"\(title)\""))
        }
    }

    @Test("Unavailable V2 creation commands preserve the native New Window command")
    func unavailableCreationCommandsPreserveNewWindow() throws {
        let commands = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Views/Commands.swift"
            ),
            encoding: .utf8
        )
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)

        #expect(v2Commands.contains("CommandGroup(after: .newItem)"))
        #expect(!v2Commands.contains("CommandGroup(replacing: .newItem)"))
        #expect(!v2Commands.contains(".keyboardShortcut(\"n\""))
    }

    @Test("Frame review exposes series, quality, inspector, and visual-review boundaries")
    func reviewWorkspaceContract() throws {
        let review = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Review/ReviewWorkspace.swift"
            ),
            encoding: .utf8
        )
        let inspector = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Inspector/SeriesInspector.swift"
            ),
            encoding: .utf8
        )

        for identifier in ["v2.review.workspace", "v2.review.series-list", "v2.review.quality"] {
            #expect(review.contains(identifier))
        }
        #expect(inspector.contains("v2.review.inspector"))
        #expect(review.contains("Review distribution"))
        #expect(review.contains("keyboardShortcut(\"a\""))
        #expect(review.contains("keyboardShortcut(\"r\""))
        #expect(review.contains("Source files are never moved here"))
        // R10-B1/Wave-3-Task-2: visual frame review (blink + thumbnails +
        // QuickLook) is now connected -- this workspace deliberately DOES
        // reference `QuickLookSpacebarMonitor`/`FrameThumbnailCell` below,
        // unlike the earlier "no visual review yet" contract this test used
        // to enforce.
        #expect(review.contains("v2.review.blink"))
        #expect(review.contains("QuickLookSpacebarMonitor("))
        #expect(review.contains("FrameThumbnailCell("))
    }

    @Test("Planning exposes setup, focal length, framing and integration boundaries")
    func planningWorkspaceContract() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Planning/PlanningView.swift"
            ),
            encoding: .utf8
        )
        for identifier in [
            "v2.planning.setup", "v2.planning.focal-length",
            "v2.planning.recommendations", "v2.planning.integration"
        ] {
            #expect(source.contains(identifier))
        }
    }

    @Test("The shell wires the operation backbone into its toolbar and overlay")
    func operationBackboneIsWiredIntoTheShell() throws {
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )

        #expect(root.contains("OperationStatusView"))
        #expect(root.contains("ToastOverlay"))
        #expect(root.contains("v2.toolbar.operations"))
        #expect(root.contains("v2.toast-layer"))
    }

    // Freeze diagnosis (build 20017, live-sampled): `ToastOverlay` is mounted
    // on the root view, and its `.task` used to run `while !Task.isCancelled`
    // forever, mutating `OperationHost` state once a second even with zero
    // toasts -- an unconditional 1 Hz invalidation of the entire shell. Pins
    // the fix so the forever-poll shape cannot regress: toast expiry must be
    // event-driven (scheduled only while toasts actually exist), not a
    // perpetual timer loop.
    @Test("ToastOverlay's expiry timer is event-driven, not a forever-poll")
    func toastOverlayHasNoUnconditionalPollingLoop() throws {
        let overlay = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Operations/ToastOverlay.swift"
            ),
            encoding: .utf8
        )

        #expect(!overlay.contains("while !Task.isCancelled"))
        #expect(!overlay.contains("while true"))
    }

    @Test("A global rescan (⌘R) is wired into the menu bar and the Archive workspace")
    func rescanIsWiredIntoCommandsAndArchiveView() throws {
        let commands = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Views/Commands.swift"
            ),
            encoding: .utf8
        )
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)
        #expect(v2Commands.contains("Rescan"))
        #expect(v2Commands.contains(".keyboardShortcut(\"r\""))

        // Task 10: the Rescan button survives as one of `ArchiveView`'s own
        // toolbar actions (`LibraryView`, and its `v2.library.rescan`
        // identifier, are gone).
        let archive = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Archive/ArchiveView.swift"
            ),
            encoding: .utf8
        )
        #expect(archive.contains("\"v2.archive.rescan\""))
    }

    @Test("Run Audit (⌥⌘A) is wired into the menu bar and Library Health's split button/verify sheet")
    func auditIsWiredIntoCommandsAndHealthView() throws {
        let commands = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Views/Commands.swift"
            ),
            encoding: .utf8
        )
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)
        #expect(v2Commands.contains("Run Audit"))
        #expect(v2Commands.contains(".keyboardShortcut(\"a\", modifiers: [.command, .option])"))
        #expect(v2Commands.contains("libraryAudit?(.full)"))
        #expect(v2Commands.contains("libraryAudit?(.fast)"))

        let focusedValues = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/FocusedAppValues.swift"
            ),
            encoding: .utf8
        )
        #expect(focusedValues.contains("var libraryAudit: LibraryAuditCommand?"))

        let rootView = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )
        #expect(rootView.contains("\\.libraryAudit"))

        let health = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Library/HealthView.swift"
            ),
            encoding: .utf8
        )
        #expect(health.contains("v2.health.run-audit"))
        #expect(health.contains("v2.health.verify"))
        #expect(health.contains("v2.health.verify.sample"))
        #expect(health.contains("v2.health.verify.fill-missing"))
        #expect(health.contains("v2.health.verify.confirm"))
        #expect(health.contains("primaryAction:"))

        let store = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Library/LibraryHealthStore.swift"
            ),
            encoding: .utf8
        )
        #expect(store.contains("func runAudit("))
        #expect(store.contains("func verifyIntegrity("))
    }

    @Test("The mutation confirmation route renders the real quarantine-apply sheet, not a placeholder")
    func mutationConfirmationIsWiredToTheRealSheet() throws {
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )

        #expect(root.contains("MutationConfirmationSheet("))
        #expect(root.contains("case .mutationConfirmation(let id) = presentation"))
        #expect(root.contains("pendingMutationPlan"))
    }

    @Test("The Libraries & Safety settings tab exposes an explicit write-operations toggle wired to LibraryAccessMode")
    func writeOperationsToggleIsWired() throws {
        let settings = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Settings/V2SettingsView.swift"
            ),
            encoding: .utf8
        )
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )

        #expect(settings.contains("Enable write operations"))
        #expect(settings.contains("v2.settings.enable-write-operations"))
        #expect(settings.contains("v2.library.enableWriteOperations"))
        #expect(root.contains("v2.library.enableWriteOperations"))
        #expect(root.contains("libraryAccessMode"))
    }

    @Test("Sensor Profiles exposes a real measure action, a history chart, and an honest footer")
    func sensorProfilesMeasureIsWiredIntoTheView() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Library/SensorProfilesView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("v2.sensor-profiles.measure"))
        #expect(source.contains("v2.sensor-profiles.measure-start"))
        #expect(source.contains("v2.sensor-profiles.measure-cancel"))
        #expect(source.contains("v2.sensor-profiles.history-chart"))
        #expect(source.contains("v2.sensor-profiles.missing-combos"))
        #expect(source.contains("Chart("))
        #expect(source.contains("OperationHost"))
        // The old "measurement acquisition is not enabled" / "classic
        // workflow or CLI" claims must be gone now that a real measure flow
        // exists -- this is the honest-empty-state half of the parity gate.
        #expect(!source.contains("classic workflow or CLI"))
        #expect(!source.contains("measurement acquisition is not enabled"))

        let store = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Library/SensorProfilesStore.swift"
            ),
            encoding: .utf8
        )
        #expect(store.contains("OperationHost"))
        #expect(store.contains("SensorMeasurementCommand"))
    }

    /// Task 7 (2026-08-17 owner-feedback wave 3) replaced this gate's own
    /// subject. It used to require `v2.results.lineage`, `v2.results.
    /// publishable`, "Input series" and "Source result" -- the vocabulary of
    /// the `results`/`lineage_edges` tables. **This gate was green for the
    /// entire life of a page that was structurally empty for every user**,
    /// because nothing in the product has ever written a row into either
    /// table: it pinned the shape of a screen with no data behind it. A
    /// gate that asserts a section EXISTS says nothing about whether that
    /// section can ever contain anything.
    ///
    /// The rule it holds now is the one that would have caught the original
    /// defect: this page must read a source the product actually writes.
    @Test("Results reads a data source the product actually writes, and says so honestly when there is none")
    func resultsWorkspaceContract() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Results/ResultsView.swift"
            ),
            encoding: .utf8
        )
        for identifier in ["v2.results.workspace", "v2.results.table", "v2.results.summary"] {
            #expect(source.contains(identifier))
        }
        // The store must go through the query that calls `StackDiscovery`,
        // never the dead lineage snapshot.
        #expect(source.contains("stackResults(target:"))
        #expect(!source.contains("snapshot(projectID:"),
                "the results/lineage_edges tables have no writer -- this page must not read them")
        // Honest empty state: it names what is missing (a finished stack),
        // not a table row that could never have existed.
        #expect(source.contains("No finished stacks yet"))
        // And it must not promise a provenance panel discovery cannot fill.
        #expect(!source.contains("Input series"))
        #expect(!source.contains("Source result"))
    }
}
