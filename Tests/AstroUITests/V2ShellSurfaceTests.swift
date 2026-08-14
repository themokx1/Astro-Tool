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

        #expect(tokens.contains("NSColor.windowBackgroundColor"))
        #expect(tokens.contains("NSColor.separatorColor"))
        #expect(home.contains("Choose Image Library…"))
        #expect(home.contains("read-only index"))
        #expect(!home.contains("Open Library"))
        #expect(!root.contains("Available after library workflows arrive"))
        #expect(commands.contains("Available after library workflows arrive"))
        #expect(!root.contains(".disabled(true)"))
        #expect(commands.contains(".disabled(true)"))
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
            ("library", "Sources/AstroUI/Features/Library/LibraryView.swift"),
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
        #expect(review.contains("v2.review.archive-preview"))
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

    @Test("A global rescan (⌘R) is wired into the menu bar and the Library workspace")
    func rescanIsWiredIntoCommandsAndLibraryView() throws {
        let commands = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Views/Commands.swift"
            ),
            encoding: .utf8
        )
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)
        #expect(v2Commands.contains("Rescan"))
        #expect(v2Commands.contains(".keyboardShortcut(\"r\""))

        let library = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Library/LibraryView.swift"
            ),
            encoding: .utf8
        )
        #expect(library.contains("v2.library.rescan"))
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

    @Test("Results expose lineage, publish readiness and an honest empty state")
    func resultsWorkspaceContract() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Results/ResultsView.swift"
            ),
            encoding: .utf8
        )
        for identifier in ["v2.results.workspace", "v2.results.lineage", "v2.results.publishable"] {
            #expect(source.contains(identifier))
        }
        #expect(source.contains("No results recorded"))
        #expect(source.contains("Input series"))
        #expect(source.contains("Source result"))
    }
}
