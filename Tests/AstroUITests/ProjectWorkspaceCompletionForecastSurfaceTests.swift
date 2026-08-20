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

    // MARK: - Expert ideation reserve #5 (Clear-Night Countdown to project completion)

    @Test("The pace sentence is immediately followed by the clear-night outlook row")
    func clearNightOutlookFollowsThePaceSentence() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains(
            "Text(\"At your current pace (~\\(paceHoursText) h/night) about ~\\(nightsText) more clear nights are needed to reach the goal.\")"
            + "\n                clearNightOutlookText(nightsNeeded: estimate.nightsNeeded)"
        ))
    }

    @Test("The clear-night outlook reads the real fetched horizon size and the shared threshold's own count, never a hardcoded 7")
    func clearNightOutlookFeedsRealCounts() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains("ClearNightOutlook.project("))
        #expect(source.contains("clearNightsInHorizon: ClearNightOutlook.clearNightCount(dailySummaries: dailySummaries)"))
        #expect(source.contains("horizonNights: dailySummaries.count"))
    }

    @Test("The soft weeks projection is never printed without its own 'if this rate holds' qualifier")
    func weeksProjectionAlwaysCarriesItsQualifier() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        // The ONLY place `paceWeeks`/`weeksText` is interpolated into a
        // sentence, that sentence must contain the qualifying language --
        // grepping for the one sentence that uses `weeksText` and asserting
        // it also contains "if this rate holds" pins that down structurally
        // rather than by convention alone.
        #expect(source.contains("if this rate holds, about \\(weeksText)"))
    }

    @Test("Both new clear-night sentences have a Hungarian translation")
    func clearNightSentencesAreTranslated() throws {
        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(translations.contains(
            "\"Of the next %@ days, %@ look clear — if this rate holds, about %@ more weeks to the goal.\" ="
        ))
        #expect(translations.contains("\"Of the next %@ days, %@ look clear.\" ="))
    }

    @Test("The dailySummariesProvider parameter follows the Optional + resolve-in-initializer async-default shape")
    func dailySummariesProviderUsesTheSafeAsyncDefaultShape() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        // Never a direct default (`= ClearNightOutlook.productionDailySummaries`
        // right on the parameter) -- see `AsyncContextSizeGateTests`'s own
        // header comment for why that shape corrupts the task allocator at
        // link time. Must be `Optional`, defaulted to `nil`, then resolved
        // inside the initializer's own body.
        #expect(source.contains("dailySummariesProvider: ClearNightDailySummariesProvider? = nil"))
        #expect(source.contains("self.dailySummariesProvider = dailySummariesProvider ?? ClearNightOutlook.productionDailySummaries"))
        #expect(!source.contains("dailySummariesProvider: ClearNightDailySummariesProvider = ClearNightOutlook.productionDailySummaries"))
    }

    @Test("The per-site weather fetch is keyed on rootURL and guards against a stale write after cancellation")
    func clearNightFetchIsGenerationGuarded() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains(".task(id: rootURL) { await loadClearNightOutlook() }"))
        #expect(source.contains("guard !Task.isCancelled else { return }"))
    }
}
