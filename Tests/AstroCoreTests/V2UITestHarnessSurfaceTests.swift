import Foundation
import Testing

@Suite("V2 UI-test harness surface")
struct V2UITestHarnessSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Fixture launch mode rejects every path outside resolved temporary storage")
    func UIHarnessRejectsRealLibraries() throws {
        let source = try read("Sources/AstroUI/PreviewSupport/V2PreviewFixtures.swift")
        let app = try read("Sources/AstroToolApp/AstroToolApp.swift")

        #expect(source.contains("-UITestFixtureRoot"))
        #expect(source.contains("-UITestAppSupport"))
        #expect(source.contains("refuseRealLibrary"))
        #expect(source.contains("resolvingSymlinksInPath"))
        #expect(source.contains("/private/tmp"))
        #expect(source.contains("/private/var/folders"))
        #expect(source.contains("AstroTool-V2-UI-"))
        #expect(source.contains("/Volumes/images"))
        #expect(source.contains("Astro"))
        #expect(source.contains("applicationSupport"))
        #expect(source.contains("caches"))
        #expect(app.contains("@State private var appState: AppState?"))
        #expect(app.contains("launchSelection.usesV2 ? nil : AppState()"))
        #expect(app.contains("WindowGroup"))
    }

    @Test("XCUITest launches only the deterministic fixture contract")
    func UIHarnessUsesDeterministicFixture() throws {
        let source = try read("UITests/AstroToolUITests/AstroToolLaunchTests.swift")

        #expect(source.contains("-UseV2UI"))
        #expect(source.contains("-UITestFixtureRoot"))
        #expect(source.contains("-UITestAppSupport"))
        #expect(source.contains("FileManager.default.temporaryDirectory"))
        #expect(source.contains("AstroTool-V2-UI-Fixture-"))
        #expect(source.contains("AstroTool-V2-UI-Support-"))
        #expect(!source.contains("launchEnvironment[\"TMPDIR\"]"))
        #expect(source.contains("app.activate()"))
        #expect(source.contains("let mainWindow = app.windows.firstMatch"))
        #expect(source.contains("mainWindow.waitForExistence"))
        #expect(source.contains("app.menuItems[\"New Window\"]"))
        #expect(source.contains("app.typeKey(\"n\", modifierFlags: .command)"))
        #expect(source.contains("-ApplePersistenceIgnoreState"))
        #expect(source.contains("-NSQuitAlwaysKeepsWindows"))
        #expect(source.contains("v2.sidebar.home"))
        #expect(source.contains("v2.sidebar.projects"))
        #expect(source.contains("v2.sidebar.nights"))
        #expect(source.contains("v2.sidebar.planning"))
        #expect(source.contains("v2.sidebar.library"))
        #expect(source.contains("v2.sidebar.insights"))
        #expect(source.contains("v2.home.night-context"))
        #expect(source.contains("v2.onboarding.summary"))
        #expect(source.contains("v2.toolbar.inspector"))
    }

    @Test("Generated project and CI include the macOS UI smoke")
    func generatedProjectAndCIIncludeUISmoke() throws {
        let project = try read("project.yml")
        let package = try read("Package.swift")
        let ci = try read(".github/workflows/ci.yml")

        #expect(package.contains(".library(name: \"AstroApplication\", targets: [\"AstroApplication\"])"))
        #expect(package.contains(".library(name: \"AstroUI\", targets: [\"AstroUI\"])"))
        #expect(project.contains("AstroToolUITests"))
        #expect(project.contains("com.astrotool.app"))
        #expect(project.contains("com.astrotool.app.UITests"))
        #expect(project.contains("CODE_SIGN_IDENTITY: \"-\""))
        #expect(project.contains("CODE_SIGNING_REQUIRED: NO"))
        #expect(ci.contains("xcodegen generate"))
        #expect(ci.contains("AstroToolUITests/AstroToolLaunchTests"))
        #expect(ci.contains("swift test --no-parallel"))
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
