import Foundation
import Testing

/// Expert ideation reserve #5 ("Clear-Night Countdown to project
/// completion"): pins the "Continue where it matters" card's own extra
/// caption line (`HomeView.featuredClearNightCaption`) -- follows this
/// repo's established "surface" suite convention
/// (`ProjectWorkspaceCompletionForecastSurfaceTests`, `V2PolishSurfaceTests`):
/// a literal source-text assertion, not a rendered-view-hierarchy check,
/// since `HomeView` needs a live `HomeStore` snapshot to render at all.
/// `HomeStoreTests` separately pins that `featuredCompletionForecast`/
/// `nightCloud.clearNightsInHorizon` are actually resolved onto the
/// snapshot this view reads.
@Suite("Home's featured clear-night caption wiring (expert ideation reserve #5)")
struct HomeViewClearNightCaptionSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The caption only renders once both the completion forecast AND the clear-night count exist")
    func captionRequiresBothInputs() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("guard let estimate = store.snapshot.featuredCompletionForecast,"))
        #expect(source.contains("let clearNights = store.snapshot.nightCloud?.clearNightsInHorizon"))
        #expect(source.contains("else { return nil }"))
    }

    @Test("The caption is only shown for a still-collecting featured project, never a placeholder")
    func captionIsWiredIntoTheCollectingBranch() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("if let caption = featuredClearNightCaption {"))
    }

    @Test("The caption never states the soft weeks extrapolation the Overview row's own sentence carries")
    func captionNeverExtrapolates() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        // `paceWeeks`/`ClearNightProjection` is the ONLY vehicle for the
        // soft "if this rate holds" extrapolation (`ClearNightOutlook`'s own
        // doc comment) -- the caption must never reference either, since a
        // one-line dashboard caption has no room for the qualifying
        // language that projection needs to stay honest.
        #expect(!source.contains("paceWeeks"))
        #expect(!source.contains("ClearNightProjection"))
    }

    @Test("The caption sentence's own %@ placeholders have a Hungarian translation")
    func captionSentenceIsTranslated() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("Text(\"~\\(nightsText) clear nights to the goal · \\(chancesText) chances this week\")"))

        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(translations.contains("\"~%@ clear nights to the goal · %@ chances this week\" ="))
    }
}
