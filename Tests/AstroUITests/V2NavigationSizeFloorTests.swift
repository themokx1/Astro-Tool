import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) systemic pattern S10: `ReviewWorkspace`,
/// `ConversionWorkspace`, `ResultsView`, `SensorProfilesView`, and
/// `CleanupPreviewView` all carried a `minWidth`/`minHeight` sized for their
/// old life as window-covering sheets. Now that they are navigation
/// destinations pushed inside a split view, that floor forces the whole
/// window wider (or clips) whenever the shell is near its own minimum width
/// and the inspector/sidebar are also showing. Follows this repo's
/// established "surface" suite convention: literal source-text assertions
/// against the exact floors the audit measured, not a rendering test --
/// SwiftUI `.frame` proposals aren't independently introspectable outside a
/// hosted window.
@Suite("V2 navigation destinations don't reintroduce sheet-era size floors")
struct V2NavigationSizeFloorTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("ReviewWorkspace no longer forces its old 800x580 sheet floor")
    func reviewWorkspaceHasNoOuterFloor() throws {
        let source = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(!source.contains("minWidth: 800"))
        // The nested HSplitView's own three-pane minimums (205 + 340 + 220
        // = 765) reintroduced almost exactly the same floor one level down
        // -- reduced so a narrow detail column can still show all three
        // panes without forcing the window wider.
        #expect(!source.contains("minWidth: 205"))
        #expect(!source.contains("minWidth: 340"))
        #expect(!source.contains("minWidth: 220, idealWidth: 250"))
    }

    @Test("ConversionWorkspace no longer forces its old 820x600 sheet floor")
    func conversionWorkspaceHasNoOuterFloor() throws {
        let source = try contents("Sources/AstroUI/Features/Library/ConversionWorkspace.swift")
        #expect(!source.contains("minWidth: 820"))
    }

    @Test("ResultsView no longer forces its old 780x560 sheet floor")
    func resultsViewHasNoOuterFloor() throws {
        let source = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        #expect(!source.contains("minWidth: 780"))
        // The nested HSplitView's own two-pane minimums (440 + 430 = 870)
        // were an even bigger floor than the outer one they sat inside.
        #expect(!source.contains("minWidth: 440, idealWidth: 560"))
        #expect(!source.contains("resultDetail(snapshot).frame(minWidth: 430)"))
    }

    @Test("SensorProfilesView's own workspace route no longer forces its old 820x520 sheet floor")
    func sensorProfilesViewHasNoOuterFloor() throws {
        let source = try contents("Sources/AstroUI/Features/Library/SensorProfilesView.swift")
        #expect(!source.contains("minWidth: 820"))
        // `SensorMeasureConfirmSheet` is a genuine `.sheet(...)` (not a
        // pushed destination) and keeps its own 440x220 floor.
        #expect(source.contains("minWidth: 440, minHeight: 220"))
    }

    @Test("CleanupPreviewView no longer forces its old 760x540 sheet floor")
    func cleanupPreviewViewHasNoOuterFloor() throws {
        let source = try contents("Sources/AstroUI/Features/Library/CleanupPreviewView.swift")
        #expect(!source.contains("minWidth: 760"))
    }
}
