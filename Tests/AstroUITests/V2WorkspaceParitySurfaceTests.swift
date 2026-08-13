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

    @Test("Results is a provenance table with safe file actions")
    func resultsWorkspaceActionsContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Results/ResultsView.swift"))
        #expect(workspace.contains("Table(snapshot.results, selection: $selectedResultID)"))
        #expect(workspace.contains("TableColumn(\"Result\""))
        #expect(workspace.contains("TableColumn(\"Created\""))
        #expect(workspace.contains("TableColumn(\"Software\""))
        #expect(workspace.contains("Open Result"))
        #expect(workspace.contains("Show in Finder"))
        #expect(workspace.contains("Copy Path"))
        #expect(workspace.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(workspace.contains("v2.results.table"))
    }

    @Test("Health, planning, and equipment use actionable work tables")
    func remainingWorkspaceTablesContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"))
        let planning = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningView.swift"))
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(health.contains("Table(filteredItems(snapshot), selection: $selectedFindingID)"))
        #expect(health.contains("TableColumn(\"Finding\""))
        #expect(health.contains("contextMenu(forSelectionType: String.self"))
        #expect(health.contains("v2.health.findings-table"))
        #expect(planning.contains("Table(store.filteredRecommendations, selection: $selectedTargetID)"))
        #expect(planning.contains("TableColumn(\"Target\""))
        #expect(planning.contains("Plan Selected"))
        #expect(planning.contains("contextMenu(forSelectionType: String.self"))
        #expect(settings.contains("Table(store.filters, selection: $selectedFilterID)"))
        #expect(settings.contains("Remove Selected"))
        #expect(settings.contains("v2.settings.filters-table"))
    }

    @Test("Health findings can be acknowledged, filtered, and show audit-run history")
    func healthAcknowledgementContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"))
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/LibraryHealthStore.swift"))
        #expect(health.contains("Mark as Acknowledged…"))
        #expect(health.contains("Revoke Acknowledgement"))
        #expect(health.contains("Show Acknowledged"))
        #expect(health.contains("v2.health.show-acknowledged"))
        #expect(health.contains("v2.health.audit-history"))
        #expect(store.contains("func acknowledge("))
        #expect(store.contains("func revokeAcknowledgement("))
        #expect(store.contains("func setShowAcknowledged("))
    }

    @Test("Calibration is a native master-inventory workspace with a gated link-preview")
    func calibrationWorkspaceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/CalibrationView.swift"))
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/CalibrationStore.swift"))
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        let route = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/AppRoute.swift"))
        #expect(workspace.contains("Table(coverageRows, selection: $selectedCoverageID)"))
        #expect(workspace.contains("Table(store.masters, selection: $selectedMasterID)"))
        #expect(workspace.contains("v2.calibration.coverage-table"))
        #expect(workspace.contains("v2.calibration.masters-table"))
        #expect(workspace.contains("v2.calibration.link-preview"))
        #expect(workspace.contains("Requires write access"))
        #expect(workspace.contains("Show in Finder"))
        #expect(workspace.contains("activateFileViewerSelecting"))
        #expect(store.contains("func preparePlan("))
        #expect(store.contains("func applyPlan("))
        #expect(health.contains("Calibration…"))
        #expect(shell.contains("case .calibration:"))
        #expect(shell.contains("CalibrationView("))
        #expect(route.contains("case calibration"))
    }

    @Test("Project goals and notes are editable rather than placeholders")
    func projectGoalAndNotesContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"))
        #expect(workspace.contains("Integration goal"))
        #expect(workspace.contains("Project notes"))
        #expect(workspace.contains("Save Project Details"))
        #expect(workspace.contains("saveAnnotation"))
        #expect(!workspace.contains("No project notes yet"))
    }

    @Test("Nights is a native navigable work table")
    func nightsWorkTableContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let nights = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(nights.contains("Table(store.visibleNights, selection:"))
        #expect(nights.contains("TableColumn(\"Night\""))
        #expect(nights.contains("TableColumn(\"Projects\""))
        #expect(nights.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(nights.contains("openNight"))
        #expect(shell.contains("openNight: { id in"))
    }

    @Test("Stable V2 does not present knowingly inert controls")
    func noInertProductionControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = [
            "Sources/AstroUI/Features/Review/ReviewWorkspace.swift",
            "Sources/AstroUI/Features/Library/CleanupPreviewView.swift",
            "Sources/AstroUI/Features/Library/HealthView.swift",
            "Sources/AstroUI/Features/Library/CalibrationView.swift",
            "Sources/AstroUI/Settings/V2SettingsView.swift",
        ]
        for relative in sources {
            let source = try String(contentsOf: root.appendingPathComponent(relative))
            #expect(!source.contains(".disabled(true)"), Comment(rawValue: relative))
            #expect(!source.contains("Button(\"Move to Archive\") {}"), Comment(rawValue: relative))
            #expect(!source.contains("Button(\"No Action Required\") {}"), Comment(rawValue: relative))
        }
    }
}
