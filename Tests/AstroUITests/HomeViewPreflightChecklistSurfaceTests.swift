import Foundation
import Testing

/// Pre-flight Checklist (ideation #1, "Indulás előtti lista", usefulness
/// 5/5): pins `HomeView`'s own card wiring -- follows this repo's
/// established "surface" suite convention
/// (`HomeViewClearNightCaptionSurfaceTests`, `V2PolishSurfaceTests`): a
/// literal source-text assertion, not a rendered-view-hierarchy check,
/// since `HomeView` needs a live `HomeStore` snapshot to render at all.
/// `HomeStoreTests`/`PreflightChecklistTests` separately pin the actual
/// ✓/✗/n-a logic this card only ever renders, never recomputes.
@Suite("Home's pre-flight checklist card wiring (ideation #1)")
struct HomeViewPreflightChecklistSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The card sits at the very top of libraryOverview -- directly under the night-context rail, and only when a library is open")
    func cardIsWiredAtTheTopOfLibraryOverview() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        // `libraryOverview` itself only renders once `store.snapshot
        // .libraryName != nil` (see `body`'s own if/else) -- placing the
        // card as `libraryOverview`'s very first child view means it
        // inherits that same "no library, no card" honesty for free, with
        // no separate guard of its own, right under the night-context rail
        // `body` renders immediately above `libraryOverview`.
        #expect(source.contains(
            "    private var libraryOverview: some View {\n"
                + "        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {\n"
                + "            preflightChecklistCard"
        ))
    }

    @Test("The card reads HomeStore's own preflightChecklist, never recomputing the four facts itself")
    func cardReadsTheStoreComputedChecklist() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("let checklist = store.preflightChecklist"))
        #expect(source.contains("checklist.displayOrder"))
    }

    @Test("An all-clear checklist collapses to the one-line ritual sentence")
    func allClearCollapsesToOneLine() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("if checklist.allClear, !isExpanded {"))
        #expect(source.contains("Text(\"Ready to head out tonight ✓\")"))

        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(translations.contains("\"Ready to head out tonight ✓\" = \"Indulásra kész ma estére ✓\";"))
    }

    @Test("Any red line expands the card by default, ahead of a manual override")
    func redLineExpandsByDefault() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("preflightExpandedOverride ?? !checklist.allClear"))
    }

    @Test("Every item text branch has its own hu.lproj translation")
    func itemTextsAreAllTranslated() throws {
        let translations = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        for key in [
            "\"Darks and flats are current\"",
            "\"%lld calibration items still need attention\"",
            "\"Sky looks clear tonight\"",
            "\"Sky looks cloudy tonight\"",
            "\"No sky forecast available\"",
            "\"Moon interferes tonight (%@)\"",
            "\"Moon won't interfere tonight\"",
            "\"No tonight recommendation yet\"",
            "\"%@ clears 30° at %@\"",
            "\"Pre-flight checklist\"",
        ] {
            #expect(translations.contains(key + " ="), "Missing hu.lproj translation for \(key)")
        }
    }

    @Test("The accessibility identifiers a UI test would target are present")
    func accessibilityIdentifiersArePresent() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("\"v2.home.preflight-checklist\""))
        #expect(source.contains("\"v2.home.preflight-checklist-toggle\""))
    }
}
