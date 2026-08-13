import Foundation
import Testing

@Suite("V2 workspace parity")
struct V2WorkspaceParitySurfaceTests {
    @Test("Projects is a native selectable work table")
    func projectsTableContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"))
        #expect(source.contains("Table("))
        #expect(source.contains("selection:"))
        #expect(source.contains("TableColumn(\"Integration\""))
        #expect(source.contains("contextMenu"))
        #expect(source.contains("onTapGesture(count: 2)"))
    }

    @Test("A project opens as a dedicated acquisition workspace")
    func projectWorkspaceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(workspace.contains("Project ›"))
        #expect(workspace.contains("Overview"))
        #expect(workspace.contains("Nights"))
        #expect(workspace.contains("Series"))
        #expect(workspace.contains("Results"))
        #expect(workspace.contains("Notes"))
        #expect(workspace.contains("Review Frames"))
        #expect(workspace.contains("v2.project.workspace"))
        #expect(shell.contains("case .project(let rawID)"))
    }

    @Test("Project night rows open a dedicated night workspace")
    func nightWorkspaceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"))
        let project = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(workspace.contains("Night ›"))
        #expect(workspace.contains("Table("))
        #expect(workspace.contains("Review Frames"))
        #expect(workspace.contains("v2.night.workspace"))
        #expect(project.contains("openNight"))
        #expect(shell.contains("case .night(let rawID)"))
    }

    @Test("Series rows open a metadata-rich series workspace")
    func seriesWorkspaceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(workspace.contains("Series ›"))
        #expect(workspace.contains("Passband"))
        #expect(workspace.contains("Gain / offset"))
        #expect(workspace.contains("Review Frames"))
        #expect(workspace.contains("v2.series.workspace"))
        #expect(shell.contains("case .projectSeries(let rawID)"))
    }

    @Test("Frame review is a multi-selection work table with shared actions")
    func frameReviewTableContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"))
        #expect(workspace.contains("Table(selected.decisions, selection: $selectedDecisionIDs)"))
        #expect(workspace.contains("TableColumn(\"Frame\""))
        #expect(workspace.contains("TableColumn(\"Decision\""))
        #expect(workspace.contains("TableColumn(\"Library status\""))
        #expect(workspace.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(workspace.contains("apply(.accepted, decisionIDs:"))
        #expect(workspace.contains("apply(.undecided, decisionIDs:"))
        #expect(workspace.contains("apply(.rejected, decisionIDs:"))
        #expect(workspace.contains("Archive preview"))
    }
}
