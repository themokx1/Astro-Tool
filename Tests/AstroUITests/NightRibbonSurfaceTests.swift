import Foundation
import Testing

/// Ideation #6 ("Éjszaka idővonala"): `NightRibbonModel`/`NightRibbonBuilder`
/// (`AstroApplication`) had zero UI consumers before this ticket -- this
/// repo has no rendering harness for a SwiftUI body (see
/// `W3T12SilentFailureSurfaceTests`'s own doc comment for why), so this pins
/// the wiring itself: `NightWorkspaceView` actually loads and mounts the
/// ribbon, `NightRibbonView` actually reads `NightRibbonModel`, and neither
/// side reaches for a status color or a raw `.animation`/`withAnimation`
/// call for its bands.
@Suite("Night ribbon mount")
struct NightRibbonSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("NightWorkspaceView loads a NightRibbonStore off the report's own SessionTimeline, and mounts NightRibbonView")
    func nightWorkspaceLoadsAndMountsTheRibbon() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")

        #expect(source.contains("@State private var ribbonStore = NightRibbonStore()"))
        // The ribbon must reuse the report's own already-loaded timeline,
        // never re-querying per-frame DATE-OBS data itself.
        #expect(source.contains("timeline: reportStore.result?.timeline"))
        #expect(source.contains("ReportSection(title: \"Night Ribbon\")"))
        #expect(source.contains("NightRibbonView(model: ribbon)"))
    }

    @Test("NightWorkspaceView's Night Ribbon section explains itself instead of rendering a bare header when there is nothing to show")
    func nightRibbonSectionHasEmptyAndLoadingStates() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        guard let range = source.range(of: "ReportSection(title: \"Night Ribbon\")") else {
            Issue.record("Night Ribbon section not found")
            return
        }
        let section = source[range.lowerBound...]
        #expect(section.contains("ribbonStore.isLoading"))
        #expect(section.contains(#"ReportEmptyNote(text: "No timestamped events for this night.")"#))
    }

    @Test("NightRibbonView paints its five event-kind bands with data-category tokens only, never a status token")
    func nightRibbonViewUsesOnlyDataCategoryColors() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightRibbonView.swift")

        for token in ["dataCalibration", "dataStack", "dataProcessed", "dataLight", "dataUnclassified"] {
            #expect(source.contains("AstroTokens.Color.\(token)"), "expected the \(token) data-category token to be used somewhere in the ribbon view")
        }
        #expect(!source.contains("AstroTokens.Color.ok"))
        #expect(!source.contains("AstroTokens.Color.attention"))
        #expect(!source.contains("AstroTokens.Color.critical"))
    }

    @Test("NightRibbonView never calls withAnimation/.animation directly, per AstroMotion's own gate")
    func nightRibbonViewDoesNotBypassAstroMotion() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightRibbonView.swift")
        #expect(!source.contains("withAnimation("))
        #expect(!source.contains(".animation("))
    }

    @Test("NightRibbonView's tracks are sized as GeometryReader-relative fractions, never a fixed pixel width that could force horizontal scrolling")
    func nightRibbonViewTracksAreProportional() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightRibbonView.swift")
        #expect(source.contains("GeometryReader"))
        #expect(source.contains("proxy.size.width * widthFraction"))
        #expect(!source.contains("ScrollView"))
    }
}
