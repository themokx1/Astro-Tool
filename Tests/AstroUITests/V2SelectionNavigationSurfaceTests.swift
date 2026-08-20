import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14), systemic pattern S3: single-click table-row
/// selection was wired to navigate, and two of the four sites ALSO declared
/// a double-click `primaryAction:` that navigates -- so a double-click
/// pushed the same route twice (the user had to press Back twice), and it
/// was impossible to select a row without immediately leaving the page
/// (breaking the context menu and arrow-key traversal). The fix convention
/// established across all four sites: selection only updates selection
/// state; `primaryAction:` (double-click) navigates. Follows this repo's
/// "surface" suite convention -- literal source-text assertions, since this
/// is a wiring contract, not a layout contract.
@Suite("V2 selection selects, double-click navigates")
struct V2SelectionNavigationSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("NightsView's observed-nights table selects on click; only primaryAction (double-click) opens the night")
    func nightsSelectionDoesNotAlsoNavigate() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightsView.swift")
        #expect(
            !source.contains(".onChange(of: store.selectedNightID)"),
            "selecting a night must not ALSO navigate -- primaryAction already opens it on double-click"
        )
        #expect(source.contains("primaryAction"), "double-click must still navigate")
    }

    @Test("ProjectsView's project selection Binding only selects; only primaryAction (double-click) opens the project")
    func projectsSelectionBindingDoesNotAlsoNavigate() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectsView.swift")
        guard let setterStart = source.range(of: "private var projectSelection") else {
            Issue.record("projectSelection binding not found")
            return
        }
        let setterBody = String(source[setterStart.lowerBound...].prefix(400))
        #expect(
            !setterBody.contains("openProject(project)"),
            "the selection Binding's setter must not navigate -- primaryAction already opens it on double-click"
        )
        #expect(source.contains("primaryAction"), "double-click must still navigate")
    }

    @Test("ProjectWorkspaceView's night and series tables select on click; double-click navigates through primaryAction, not selection onChange")
    func projectWorkspaceTablesDoNotNavigateOnSelectionChange() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(
            !source.contains(".onChange(of: selection) { _, id in if let id { openNight(id) } }"),
            "ProjectNightsSummary must navigate through primaryAction, not a selection onChange"
        )
        #expect(
            !source.contains(".onChange(of: selection) { _, id in if let id { openSeries(id) } }"),
            "ProjectSeriesSummary must navigate through primaryAction, not a selection onChange"
        )
        // Both nested tables should now offer a double-click primaryAction
        // -- `contextMenu(forSelectionType:...)` is the vehicle for it
        // elsewhere in this codebase (NightsView, ProjectsView, HealthView).
        let occurrences = source.components(separatedBy: "primaryAction").count - 1
        #expect(occurrences >= 2, "both the nights and series tables need their own primaryAction for double-click navigation")
    }
}
