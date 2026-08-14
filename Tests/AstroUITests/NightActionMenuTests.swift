import Foundation
import Testing

/// Source-string surface checks, the same shape `V2WorkspaceParitySurfaceTests`
/// already uses throughout this suite: `NightActionMenu` is a SwiftUI view
/// with no host-independent way to drive a real context menu headlessly, so
/// this asserts every action is wired to a REAL handler (not a stub) by
/// reading the source directly, and that every row surface (`NightsView`,
/// the night workspace toolbar, the project workspace's Nights tab) actually
/// wires the shared menu in rather than reimplementing its own subset.
@Suite("V2 Night action menu")
struct NightActionMenuTests {
    private func read(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath))
    }

    @Test("Every listed action is bound to a real handler, not a disabled stub")
    func everyActionHasARealHandler() throws {
        let menu = try read("Sources/AstroUI/Features/Nights/NightActionMenu.swift")

        #expect(menu.contains("public struct NightActionMenu"))
        #expect(menu.contains("Button(\"Open Night\""))
        #expect(menu.contains("Button(\"Reveal in Finder\", systemImage: \"folder\", action: revealInFinder)"))
        #expect(menu.contains("Button(\"Night Report…\", systemImage: \"doc.richtext\", action: exportNightReport)"))
        #expect(menu.contains("Button(\"Edit Night Notes…\", systemImage: \"note.text\", action: editNotes)"))
        #expect(menu.contains("Button(\"Open Calibration…\", systemImage: \"camera.filters\", action: openCalibration)"))
        #expect(menu.contains("Button(\"Rate Frames\", systemImage: \"star.leadinghalf.filled\", action: rateFrames)"))
        #expect(menu.contains("Button(\"Open in Insights\""))
        #expect(menu.contains("openInsights(setupDescriptor)"))
        #expect(menu.contains("NSWorkspace.shared.activateFileViewerSelecting"))
        #expect(menu.contains("ExportService.production(rootURL: rootURL).nightReport"))
        #expect(menu.contains("FrameRatingCommand.production(rootURL: rootURL)"))
        #expect(menu.contains("command.run("))
        #expect(menu.contains("v2.nights.action-menu"))

        // No inert stubs anywhere in the menu.
        #expect(!menu.contains(".disabled(true)"))
        #expect(!menu.contains("action: {}"))
        #expect(!menu.contains("action: { }"))
    }

    @Test("Reveal in Finder resolves the night's own on-disk path with containment, never a bare join")
    func revealInFinderIsContainmentChecked() throws {
        let menu = try read("Sources/AstroUI/Features/Nights/NightActionMenu.swift")
        #expect(menu.contains("FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: \"sessions/\\(target)/\\(date)\")"))
    }

    @Test("The Nights table wires the shared action menu into every row's context menu")
    func nightsViewWiresSharedMenu() throws {
        let nights = try read("Sources/AstroUI/Features/Nights/NightsView.swift")
        #expect(nights.contains("NightActionMenu("))
        #expect(nights.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(nights.contains("NightNoteSheet("))
        #expect(nights.contains("openCalibration"))
        #expect(nights.contains("openInsights"))
    }

    @Test("The night workspace toolbar surfaces the shared action menu")
    func nightWorkspaceWiresSharedMenu() throws {
        let workspace = try read("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        #expect(workspace.contains("NightActionMenu("))
        #expect(workspace.contains("v2.night.workspace.actions"))
        #expect(workspace.contains("NightNoteSheet("))
    }

    @Test("The project workspace's Nights tab wires the shared action menu into every row's context menu")
    func projectWorkspaceNightsTabWiresSharedMenu() throws {
        let project = try read("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(project.contains("NightActionMenu("))
        #expect(project.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(project.contains("NightNoteSheet("))
    }

    @Test("Open in Insights presets AppRouter's pending setup filter before navigating")
    func openInsightsPresetsSetupFilter() throws {
        let router = try read("Sources/AstroUI/App/AppModel.swift")
        let root = try read("Sources/AstroUI/App/V2RootView.swift")
        #expect(router.contains("pendingInsightsSetupFilter"))
        #expect(router.contains("func navigateToInsights(presetSetupFilter"))
        #expect(root.contains("router.navigateToInsights(presetSetupFilter: setup)"))
        #expect(root.contains("initialSetupFilter: router.pendingInsightsSetupFilter"))
    }
}
