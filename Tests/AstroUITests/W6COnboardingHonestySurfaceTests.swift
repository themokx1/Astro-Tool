import Foundation
import Testing

/// Wave W6-A (static audit, rc.5), section C: `HomeView`'s night-context
/// rail renders unconditionally, above the "is a library even open" branch
/// -- its old "site not configured" copy named Settings ▸ Location even
/// with NO library open, though that panel is locked until one is
/// (`LocationSettingsView`'s own "no library" branch); a second render of
/// the same state, right below it, separately claimed the site was ALWAYS
/// derived automatically -- two contradictory stories shown at once. These
/// pin the state-dependent copy that replaced both, plus the Settings-side
/// placeholder that named a library it could not help the reader open.
@Suite("W6-A onboarding honesty (state-dependent copy)")
struct W6COnboardingHonestySurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("NightContextRail knows whether a library is open, not just whether a site resolved")
    func railReceivesHasLibrary() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("let hasLibrary: Bool"), "the rail must distinguish \"no library\" from \"library open, no site\"")
        #expect(source.contains("hasLibrary: store.snapshot.libraryName != nil"), "HomeView must pass the same signal its own no-library branch uses")
    }

    @Test("With no library open, the rail never names the locked Settings ▸ Location panel")
    func noLibraryStateNamesNoSettingsPanel() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(
            source.contains("Open a library — the site will resolve automatically from the FITS files"),
            "the no-library caption must point at opening a library, not at a locked Settings panel"
        )
        #expect(
            source.contains("Open a library first. Once one is open, AstroTool resolves the observing site automatically from your FITS files' own site coordinates."),
            "the no-library paragraph must agree with the caption, not separately re-claim full automation with no mention of needing a library first"
        )
    }

    @Test("With a library open but no site, the rail keeps the Settings pointer and gives it a real action")
    func libraryOpenNoSiteKeepsPointerWithAction() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("Text(\"Site not set — add it in Settings ▸ Location\")"), "the existing Settings pointer stays for this state")
        #expect(
            source.contains("No observing site is resolved for this library yet, so tonight's dusk-to-dawn window can't be shown here. Set your coordinates in Settings ▸ Location, or scan FITS files that carry site coordinates."),
            "the paragraph must agree with the caption -- both paths (manual Settings, auto-derived FITS) named together, not one claiming exclusivity"
        )
        #expect(source.contains(#"Button("Open Settings…") { openSettings() }"#), "the pointer must have a real action, not just text")
    }

    @Test("The two 'not configured' states no longer contradict each other on manual-vs-automatic site resolution")
    func noContradictoryAutomationClaim() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(
            !source.contains("AstroTool derives it automatically from your FITS files' own site coordinates once they're indexed."),
            "the old unconditional \"always automatic\" claim, shown alongside a manual Settings pointer, must be gone"
        )
    }

    @Test("Settings' own no-library placeholder names the button the reader actually has, since it cannot open one itself")
    func settingsNoLibraryPlaceholderNamesHomeButton() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(
            source.contains("Open a library first, using Choose Image Library… on Home."),
            "Settings' Location panel cannot reach V2RootView's own choose-library sheet (separate Settings { } scene) -- it must name Home's real button instead of a dead one"
        )
    }
}
