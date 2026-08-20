import Foundation
import Testing

/// W4-4 item 2 (owner review): "The project page duplicates itself into the
/// inspector" -- `.project`'s hero metric cards (Integráció / Képkockák /
/// Legutóbbi éjszaka) used to reappear as rows in the inspector's own
/// "Előrehaladás" ("Progress") section, and `.projectSeries`'s own Usable/
/// Integration hero cards used to reappear as `SeriesSummaryPanel`'s
/// "Frames" section. One fact, one home: the inspector keeps identity
/// (`ProjectInspectorPanel`'s "Project" section) and quick actions, and
/// `SeriesSummaryPanel` keeps Capture/Setup, but neither duplicates a hero
/// metric card as a second row. Follows this repo's established "surface"
/// suite convention (`V2PolishSurfaceTests`): literal source-text
/// assertions scoped to each panel's own declaration body (brace-matched),
/// so a coincidentally-identical section title on an unrelated panel in the
/// same file (`NightInspectorPanel` also has its own "Frames" section, out
/// of this item's scope) can never produce a false pass or a false fail.
@Suite("Inspector duplication with project/series pages (W4-4 item 2)")
struct InspectorProjectDuplicationSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private enum ScanError: Error { case declarationNotFound(String) }

    /// Extracts one `struct <name>`'s source text, from its own opening
    /// `{` through its matching closing `}` (brace-depth counting -- good
    /// enough for well-formed Swift, and the same class of literal scan
    /// this repo's other "surface" suites already rely on instead of a
    /// real parser).
    private func declarationBody(named name: String, in source: String) throws -> String {
        guard let declRange = source.range(of: "struct \(name)") else {
            throw ScanError.declarationNotFound(name)
        }
        guard let openBrace = source[declRange.upperBound...].firstIndex(of: "{") else {
            throw ScanError.declarationNotFound(name)
        }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            }
            index = source.index(after: index)
        }
        throw ScanError.declarationNotFound(name)
    }

    @Test("ProjectInspectorPanel no longer has a Progress section duplicating the page's own hero metric cards")
    func projectPanelHasNoProgressSection() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        let body = try declarationBody(named: "ProjectInspectorPanel", in: source)
        #expect(!body.contains("Section(\"Progress\")"))
    }

    @Test("ProjectInspectorPanel keeps its identity section and Quick actions")
    func projectPanelKeepsIdentityAndQuickActions() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        let body = try declarationBody(named: "ProjectInspectorPanel", in: source)
        #expect(body.contains("Section(\"Project\")"))
        #expect(body.contains("Catalog ID"))
        #expect(body.contains("Section(\"Quick actions\")"))
    }

    @Test("SeriesSummaryPanel no longer has a Frames section duplicating the series page's own hero metric cards")
    func seriesSummaryPanelHasNoFramesSection() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        let body = try declarationBody(named: "SeriesSummaryPanel", in: source)
        #expect(!body.contains("Section(\"Frames\")"))
    }

    @Test("SeriesSummaryPanel keeps its Capture and Setup sections")
    func seriesSummaryPanelKeepsCaptureAndSetup() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        let body = try declarationBody(named: "SeriesSummaryPanel", in: source)
        #expect(body.contains("Section(\"Capture\")"))
        #expect(body.contains("Section(\"Setup\")"))
    }

    /// `NightInspectorPanel` is explicitly out of this item's scope (the
    /// owner named `.project`/`.projectSeries` only) -- this pins that its
    /// own, unrelated "Frames" section survives untouched, so a future
    /// change here does not accidentally widen this item's fix onto a panel
    /// nobody asked to change.
    @Test("NightInspectorPanel's own Frames section is untouched -- out of this item's scope")
    func nightPanelKeepsItsOwnFramesSection() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        let body = try declarationBody(named: "NightInspectorPanel", in: source)
        #expect(body.contains("Section(\"Frames\")"))
    }
}
