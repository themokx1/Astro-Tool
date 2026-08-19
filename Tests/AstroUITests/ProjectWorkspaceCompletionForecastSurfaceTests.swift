import Foundation
import Testing

/// Expert ideation spec #2 ("még ~3 tiszta éjszaka a célig"). Follows this
/// repo's established "surface" suite convention
/// (`ProjectWorkspaceLayoutSurfaceTests`, `V2PolishSurfaceTests`): a literal
/// source-text assertion pinning the Overview tab's completion-forecast row
/// actually wires through `CompletionForecast.nightsNeeded` and the
/// `recentSessionIntegrationSeconds` field it needs, and that the
/// insufficient-data honesty-rail sentence is the exact string translated in
/// `hu.lproj/Localizable.strings` -- not a rendered-view-hierarchy check,
/// since `ProjectWorkspaceView` needs a live `ProjectReportQuery.Result` to
/// render at all.
@Suite("Project workspace completion-forecast wiring (expert ideation spec #2)")
struct ProjectWorkspaceCompletionForecastSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The Overview tab's Planning section calls the completion-forecast row right next to the goal-progress row")
    func plumbedNextToGoalProgress() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains("goalProgressText(report: report, goalSeconds: goalSeconds)"))
        #expect(source.contains("completionForecastText(report: report)"))
    }

    @Test("completionForecastText feeds the report's own remaining/recent-session data into the pure forecast engine")
    func forecastReadsRealReportFields() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains("CompletionForecast.nightsNeeded("))
        #expect(source.contains("remainingSeconds: remaining"))
        #expect(source.contains("recentSessionSeconds: report.recentSessionIntegrationSeconds"))
    }

    @Test("The insufficient-data honesty-rail sentence is the exact string translated in hu.lproj")
    func insufficientDataStringIsTranslated() throws {
        let viewSource = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        let sentence = "Not enough data yet to estimate the pace."
        #expect(viewSource.contains("Text(\"\(sentence)\")"))

        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(translations.contains("\"\(sentence)\" ="))
    }

    @Test("The forecast sentence's own %@ placeholders have a Hungarian translation")
    func forecastSentenceIsTranslated() throws {
        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(translations.contains(
            "\"At your current pace (~%@ h/night) about ~%@ more clear nights are needed to reach the goal.\" ="
        ))
    }
}
