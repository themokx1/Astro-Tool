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
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )
        let home = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Home/HomeView.swift"
            ),
            encoding: .utf8
        )
        let uiTest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "UITests/AstroToolUITests/AstroToolLaunchTests.swift"
            ),
            encoding: .utf8
        )

        #expect(home.contains("v2.detail.home"))
        for route in ["projects", "nights", "planning", "library", "insights"] {
            #expect(root.contains("v2.detail.\(route)"))
            #expect(uiTest.contains("v2.detail.\(route)"))
        }
        for title in [
            "Home",
            "No projects yet",
            "No observing nights yet",
            "No plan selected",
            "No library open",
            "No insights yet",
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

    @Test("Frame review exposes series, quality and inspector boundaries without Quick Look")
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
        #expect(!review.contains("QuickLook"))
        #expect(!review.contains("QLThumbnail"))
    }
}
