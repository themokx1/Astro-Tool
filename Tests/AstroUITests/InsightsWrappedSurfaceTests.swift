import Foundation
import Testing

/// Expert ideation reserve #9 ("Év-összegző Wrapped"): literal source-text
/// assertions over `InsightsView.swift`, same "surface" suite convention
/// `V2PolishSurfaceTests`/`TrendsDashboardSurfaceTests` already establish for
/// wiring/visibility contracts that don't need a rendered view tree.
@Suite("Insights Year Wrapped surface")
struct InsightsWrappedSurfaceTests {
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

    /// The card's own guard: `selectedYear != nil` gates it directly, in the
    /// SAME `if` as the `insight.yearWrapped` unwrap, rather than the two
    /// conditions living in separate, independently-toggleable `if`s where a
    /// future edit could satisfy one without the other. This is the one
    /// piece `InsightsQueryTests`'s own application-layer tests cannot pin
    /// on their own: `yearWrapped` already comes back `nil` on "Minden év"
    /// today, but nothing at that layer stops a future change from building
    /// it unconditionally -- this is the view's own belt alongside that
    /// braces.
    @Test("The year card's own guard checks selectedYear != nil, not only insight.yearWrapped")
    func cardGuardsOnSelectedYearNotOnlyOnWrappedData() throws {
        let text = try source()
        #expect(text.contains("if selectedYear != nil, let wrapped = insight.yearWrapped"))
    }

    /// The guard and the card call must be the SAME statement -- otherwise a
    /// refactor could hoist `yearWrappedCard` out from under the guard while
    /// leaving the `if selectedYear != nil` line looking untouched.
    @Test("yearWrappedCard is called from inside the selectedYear guard, not from a separate unconditional site")
    func cardIsOnlyCalledFromInsideItsOwnGuard() throws {
        let text = try source()
        let guardLine = "if selectedYear != nil, let wrapped = insight.yearWrapped {"
        guard let guardRange = text.range(of: guardLine) else {
            Issue.record("expected guard line not found verbatim")
            return
        }
        let afterGuard = text[guardRange.upperBound...].prefix(200)
        #expect(afterGuard.contains("yearWrappedCard(wrapped)"))

        // And there is exactly one INVOCATION of the card function overall
        // (its own `private func yearWrappedCard(` declaration is the other
        // occurrence of the substring) -- it is never invoked a second time
        // from somewhere unguarded.
        let callSiteCount = text.components(separatedBy: "yearWrappedCard(wrapped)").count - 1
        #expect(callSiteCount == 1)
    }

    /// The card's own helper functions exist and stay wired to
    /// `AstroCore.YearWrapped`'s real fields -- a light check that this
    /// isn't a stub that always renders placeholder text.
    @Test("The year card reads real YearWrapped fields, not placeholder literals")
    func cardReadsRealYearWrappedFields() throws {
        let text = try source()
        #expect(text.contains("wrapped.mostShotTarget"))
        #expect(text.contains("wrapped.totalUsableFrameCount"))
        #expect(text.contains("wrapped.biggestMonth"))
        #expect(text.contains("wrapped.firstLights"))
        #expect(text.contains("wrapped.bestFWHMNight"))
    }

    /// Sparse-data honesty: the best-FWHM tile is only appended to the grid
    /// when `bestFWHMNight` unwraps -- it must never render a fabricated
    /// "best" over zero measurements.
    @Test("The best-FWHM tile drops entirely, rather than showing a placeholder, when unmeasured")
    func bestFWHMTileDropsWhenAbsent() throws {
        let text = try source()
        #expect(text.contains("if let best = wrapped.bestFWHMNight {"))
    }

    /// The card uses the shared raised/recessed vocabulary (no ad hoc
    /// corner radius, no new fill color) -- `astroRaisedSurface` for the
    /// card itself, `astroRecessedSurface` for its stat tiles, and the
    /// shared `astroDataHero`/`astroDisplay` type roles for its headline
    /// numbers and judgment sentence.
    @Test("The year card uses the shared design-system surfaces and type roles, not new ones")
    func cardUsesSharedDesignVocabulary() throws {
        let text = try source()

        // Sliced to exactly this function's own body (up to the next
        // function's declaration) -- a bare suffix-of-file `contains` check
        // would trivially pass because SOME other function later in this
        // same file also uses these modifiers, which would not actually
        // prove `yearWrappedCard` itself does.
        // The marker must be the DECLARATION, not the call site --
        // `yearWrappedCard` itself calls `yearWrappedHeadline(wrapped)`
        // inline, and a bare "yearWrappedHeadline" marker would match that
        // call first, truncating the slice before the very
        // `.astroDisplay()`/`.astroRaisedSurface()` lines this test exists
        // to check.
        let cardBody = try function(named: "yearWrappedCard", upTo: "private func yearWrappedHeadline(", in: text)
        #expect(cardBody.contains(".astroRaisedSurface()"))
        #expect(cardBody.contains(".astroDisplay()"))

        let tileBody = try function(named: "yearWrappedTile", upTo: "private func metrics(", in: text)
        #expect(tileBody.contains(".astroRecessedSurface()"))
        #expect(tileBody.contains(".astroDataHero()"))
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
