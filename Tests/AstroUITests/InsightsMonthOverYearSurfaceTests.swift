import Foundation
import Testing

/// Ideation #3 ("Ez a hónap tavalyhoz képest", "This month vs last year"):
/// literal source-text assertions over `InsightsView.swift`, same "surface"
/// suite convention `InsightsWrappedSurfaceTests` already establishes for
/// wiring/visibility contracts that don't need a rendered view tree.
@Suite("Insights month-over-year surface")
struct InsightsMonthOverYearSurfaceTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Insights/InsightsView.swift"),
            encoding: .utf8
        )
    }

    /// Judgment call (this card, unlike Year Wrapped, is not scoped to a
    /// past year the owner picked -- it is always "the real current
    /// month"): visible on "Minden év" (`selectedYear == nil`) AND when the
    /// Period picker happens to be on the current calendar year
    /// (`selectedYear == insight.currentYear`). Browsing an older year
    /// (say 2024) would show a "this month" comparison unrelated to what's
    /// on screen, so the card drops there even though `InsightsQuery`
    /// always computes the underlying data regardless of scope.
    @Test("The card's own guard checks selectedYear against currentYear, not the raw yearWrapped scoping rule")
    func cardGuardChecksCurrentYear() throws {
        let text = try source()
        #expect(text.contains("if selectedYear == nil || selectedYear == insight.currentYear {"))
    }

    /// The guard and the card call must be the SAME statement -- same
    /// "hoisting a refactor can't quietly drop the guard" concern
    /// `InsightsWrappedSurfaceTests.cardIsOnlyCalledFromInsideItsOwnGuard`
    /// already documents for the Year Wrapped card.
    @Test("monthOverYearCard is called from inside its own currentYear guard, not from a separate unconditional site")
    func cardIsOnlyCalledFromInsideItsOwnGuard() throws {
        let text = try source()
        let guardLine = "if selectedYear == nil || selectedYear == insight.currentYear {"
        guard let guardRange = text.range(of: guardLine) else {
            Issue.record("expected guard line not found verbatim")
            return
        }
        let afterGuard = text[guardRange.upperBound...].prefix(200)
        #expect(afterGuard.contains("monthOverYearCard(insight.yearOverYearComparison, currentMonth: insight.currentMonth)"))

        let callSiteCount = text.components(separatedBy: "monthOverYearCard(insight.yearOverYearComparison, currentMonth: insight.currentMonth)").count - 1
        #expect(callSiteCount == 1)
    }

    /// The card takes the comparison as an OPTIONAL -- it must still render
    /// (with an honest empty state) even when there is no prior-year data,
    /// unlike Year Wrapped which drops entirely when its data is `nil`.
    @Test("The card function accepts an optional comparison, not an unwrapped one")
    func cardTakesOptionalComparison() throws {
        let text = try source()
        #expect(text.contains("private func monthOverYearCard(_ comparison: YearOverYearComparison?, currentMonth: Int) -> some View {"))
    }

    /// Sparse-data honesty carried through: the FWHM tile is only appended
    /// when `bestFWHM` unwraps, same posture Year Wrapped's own best-FWHM
    /// tile already takes.
    @Test("The best-FWHM tile drops entirely, rather than showing a placeholder, when unmeasured")
    func fwhmTileDropsWhenAbsent() throws {
        let text = try source()
        #expect(text.contains("if let fwhm = comparison.bestFWHM {"))
    }

    /// The card reuses the EXACT same tile helper Year Wrapped already
    /// uses (`yearWrappedTile`) rather than a near-duplicate second one --
    /// same raised/recessed surface vocabulary, no new corner radius or
    /// fill color invented for this card.
    @Test("The card reuses yearWrappedTile rather than declaring a near-duplicate tile helper")
    func cardReusesSharedTileHelper() throws {
        let text = try source()
        let cardBody = try function(named: "monthOverYearCard", upTo: "private func monthOverYearHeadline(", in: text)
        #expect(cardBody.contains("yearWrappedTile("))
        #expect(cardBody.contains(".astroRaisedSurface()"))
        #expect(!text.contains("private func monthOverYearTile("), "must not declare a second near-duplicate tile helper")
    }

    /// The empty state (no prior-year data for this month yet) still
    /// renders something -- never just an empty VStack -- and carries its
    /// own accessibility identifier so a UI test could assert on it.
    @Test("The empty state renders its own identified text rather than nothing at all")
    func emptyStateRendersIdentifiedText() throws {
        let text = try source()
        #expect(text.contains("v2.insights.month-over-year-empty"))
    }

    /// Every month 1...12 has its own literal (not %@-interpolated) empty-
    /// state sentence -- judgment call: Hungarian month names take
    /// different, vowel-harmony-dependent grammatical suffixes ("augusztusban"
    /// vs "szeptemberben"), so a single %@-templated sentence with an
    /// English month name plugged in could never translate correctly for
    /// every month. Twelve fully-formed per-month sentences sidestep that
    /// entirely, same posture `moonPhaseBandLabel`'s own per-case switch
    /// already takes for band-specific text.
    @Test("The empty-state text switches over all 12 months as literal per-case sentences")
    func emptyStateCoversAllTwelveMonths() throws {
        let text = try source()
        // Months 1...11 as explicit `case N:` arms; 12 as the exhaustive
        // `default:` (a `switch` over a plain, unbounded `Int` cannot be
        // exhaustive on literal cases alone) -- both arms must still carry
        // their own fully-formed, non-%@-templated sentence, never a shared
        // fallback string.
        for month in 1...11 {
            #expect(text.contains("case \(month):"), "missing empty-state case for month \(month)")
        }
        #expect(text.contains("default: return \"No prior-year data yet for December"))
    }

    private func function(named name: String, upTo nextMarker: String, in text: String) throws -> Substring {
        guard let start = text.range(of: "private func \(name)(") else {
            Issue.record("\(name) function not found")
            return ""
        }
        guard let end = text.range(of: nextMarker, range: start.upperBound..<text.endIndex) else {
            Issue.record("\(nextMarker) not found after \(name)")
            return text[start.lowerBound...]
        }
        return text[start.lowerBound..<end.lowerBound]
    }
}
