import Foundation
import Testing

@Suite("V2 workspace parity")
struct V2WorkspaceParitySurfaceTests {
    @Test("Projects is a native selectable work table")
    func projectsTableContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"), encoding: .utf8)
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
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"), encoding: .utf8)
        let route = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/AppRoute.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        // Wave 4 Task 3: the "Project › …" eyebrow is gone (redundant with
        // the global BreadcrumbBar), and the tab enum itself moved to
        // `AppRoute.swift` as router-owned `ProjectWorkspaceTab` -- its
        // cases are what carry the "Overview"/"Nights"/"Series"/"Results"/
        // "Notes" labels now.
        #expect(!workspace.contains("Project ›"))
        #expect(route.contains("case overview = \"Overview\""))
        #expect(route.contains("case nights = \"Nights\""))
        #expect(route.contains("case series = \"Series\""))
        #expect(route.contains("case results = \"Results\""))
        #expect(route.contains("case notes = \"Notes\""))
        #expect(workspace.contains("Review Frames"))
        #expect(workspace.contains("v2.project.workspace"))
        #expect(shell.contains("case .project(let rawID)"))
    }

    @Test("Project night rows open a dedicated night workspace")
    func nightWorkspaceContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        // Wave 4 Task 3: the "Night › …" eyebrow is gone (redundant with the
        // global BreadcrumbBar).
        #expect(!workspace.contains("Night ›"))
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
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        // Wave 4 Task 3: the "Project › … › Series › …" eyebrow is gone
        // (redundant with the global BreadcrumbBar).
        #expect(!workspace.contains("Series ›"))
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
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"), encoding: .utf8)
        #expect(workspace.contains("Table(rows, selection: $selectedDecisionIDs, sortOrder: $sortOrder)"))
        #expect(workspace.contains("TableColumn(\"Frame\""))
        #expect(workspace.contains("TableColumn(\"Decision\""))
        #expect(workspace.contains("TableColumn(\"Library status\""))
        #expect(workspace.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(workspace.contains("apply(.accepted, decisionIDs:"))
        #expect(workspace.contains("apply(.undecided, decisionIDs:"))
        #expect(workspace.contains("apply(.rejected, decisionIDs:"))
    }

    @Test("Frame review shows measured quality columns and can run frame rating")
    func frameReviewQualityContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"), encoding: .utf8)
        #expect(workspace.contains("TableColumn(\"Score\", value: \\.scoreSortKey)"))
        #expect(workspace.contains("TableColumn(\"FWHM\", value: \\.fwhmSortKey)"))
        #expect(workspace.contains("TableColumn(\"Roundness\", value: \\.roundnessSortKey)"))
        #expect(workspace.contains("TableColumn(\"Background\", value: \\.backgroundSortKey)"))
        #expect(workspace.contains("TableColumn(\"Percentile\")"))
        #expect(workspace.contains("v2.review.quality-columns"))
        #expect(workspace.contains("v2.review.rate"))
        #expect(workspace.contains("Rate Frames…"))
        #expect(workspace.contains("Full Re-measure (Siril + native)"))
        #expect(workspace.contains("Native Only (no Siril)"))
        #expect(workspace.contains("rateSelectedSeries(mode:"))
        #expect(workspace.contains("v2.review.capture-group-filter"))
        #expect(workspace.contains("v2.review.session-filter"))
        #expect(workspace.contains("row.isOutlier"))
    }

    @Test("Frame review offers a visual blink sheet with thumbnails and QuickLook")
    func frameReviewVisualReviewContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"), encoding: .utf8)
        let results = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Results/ResultsView.swift"), encoding: .utf8)
        let blink = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/FrameBlinkReview.swift"), encoding: .utf8)
        let thumbnail = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/FrameThumbnailCell.swift"), encoding: .utf8)
        let quickLook = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Review/QuickLookSupport.swift"), encoding: .utf8)
        #expect(workspace.contains("v2.review.blink"))
        #expect(workspace.contains("Review Frames…"))
        #expect(workspace.contains("openBlinkReview"))
        #expect(workspace.contains("FrameBlinkReview("))
        #expect(workspace.contains("FrameThumbnailCell(rootURL:"))
        #expect(workspace.contains("QuickLookSpacebarMonitor("))
        #expect(workspace.contains("QuickLookPreviewController.shared.preview"))
        #expect(results.contains("FrameThumbnailCell(rootURL:"))
        #expect(results.contains("QuickLookSpacebarMonitor("))
        #expect(results.contains("QuickLookPreviewController.shared.preview"))
        #expect(results.contains("Quick Look"))
        #expect(blink.contains("public final class FrameBlinkReviewStore"))
        #expect(blink.contains("keyboardShortcut(\"a\""))
        #expect(blink.contains("keyboardShortcut(\"x\""))
        #expect(blink.contains("keyboardShortcut(\"u\""))
        #expect(blink.contains("keyboardShortcut(.leftArrow"))
        #expect(blink.contains("keyboardShortcut(.rightArrow"))
        #expect(thumbnail.contains("public struct FrameThumbnailCell"))
        #expect(thumbnail.contains("QLThumbnailGenerator"))
        #expect(quickLook.contains("QLPreviewPanel"))
    }

    @Test("Results is a provenance table with safe file actions")
    func resultsWorkspaceActionsContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Results/ResultsView.swift"), encoding: .utf8)
        // V2 UI/UX audit (2026-08-14) systemic pattern S7: sortable since
        // the v2/v2.1 follow-up -- reads from the store's own cached,
        // re-sorted `results` rather than the raw snapshot.
        #expect(workspace.contains("Table(store.results, selection: $selectedResultID, sortOrder: $sortOrder)"))
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
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"), encoding: .utf8)
        let planning = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningView.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"), encoding: .utf8)
        // V2 UI/UX audit (2026-08-14) systemic pattern S7: findings are now
        // sortable (v2/v2.1 follow-up) -- the table reads from a locally
        // cached, re-sorted `displayedItems` rather than filtering inline.
        #expect(health.contains("Table(displayedItems, selection: $selectedFindingID, sortOrder: $sortOrder)"))
        #expect(health.contains("TableColumn(\"Finding\""))
        #expect(health.contains("contextMenu(forSelectionType: String.self"))
        #expect(health.contains("v2.health.findings-table"))
        // Sortable since the planning-workbench work: the composite score and
        // each of its three components are their own clickable column.
        #expect(planning.contains("Table(store.filteredRecommendations, selection: $selectedTargetID, sortOrder: $sortOrder)"))
        #expect(planning.contains("TableColumn(\"Target\""))
        #expect(planning.contains("TableColumn(\"Score\", value: \\.planningScore)"))
        #expect(planning.contains("TableColumn(\"Photographable\", value: \\.photographableFactor)"))
        #expect(planning.contains("TableColumn(\"Frame fill\", value: \\.frameFillFactor)"))
        #expect(planning.contains("TableColumn(\"Moon\", value: \\.moonFactor)"))
        #expect(planning.contains("Plan Selected"))
        #expect(planning.contains("contextMenu(forSelectionType: String.self"))
        // V2 UI/UX audit (2026-08-14) systemic pattern S7: sortable since
        // the v2/v2.1 follow-up.
        #expect(settings.contains("Table(store.filters, selection: $selectedFilterID, sortOrder: $sortOrder)"))
        #expect(settings.contains("Remove Selected"))
        #expect(settings.contains("v2.settings.filters-table"))
    }

    @Test("Health findings can be acknowledged, filtered, and show audit-run history")
    func healthAcknowledgementContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/LibraryHealthStore.swift"), encoding: .utf8)
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
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/CalibrationView.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/CalibrationStore.swift"), encoding: .utf8)
        let health = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/HealthView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        let route = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/AppRoute.swift"), encoding: .utf8)
        // V2 UI/UX audit (2026-08-14) systemic pattern S7: both tables are
        // now sortable (v2/v2.1 follow-up).
        #expect(workspace.contains("Table(sortedCoverageRows, selection: $selectedCoverageID, sortOrder: $coverageSortOrder)"))
        #expect(workspace.contains("store.masters, selection: $selectedMasterID,"))
        #expect(workspace.contains("sortOrder: Binding(get: { store.mastersSortOrder }, set: { store.setMastersSortOrder($0) })"))
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

    @Test("Session conversion is editable, resolves ambiguities, and applies/undoes through the V1 engine")
    func conversionWorkspaceAppliesAndUndoesThroughEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Library/ConversionWorkspace.swift"), encoding: .utf8)
        let command = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/Library/SessionConversionCommand.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)

        // Editable proposal fields.
        #expect(workspace.contains("TextField(\"Group name\""))
        #expect(workspace.contains("Picker(\"Sensor\""))
        #expect(workspace.contains("Picker(\"Signal\""))
        #expect(workspace.contains("TextField(\"Filter\""))
        #expect(workspace.contains("v2.conversion.group-name"))
        #expect(workspace.contains("v2.conversion.group-sensor"))
        #expect(workspace.contains("v2.conversion.group-signal"))
        #expect(workspace.contains("v2.conversion.group-filter"))

        // Mandatory ambiguity-resolution step.
        #expect(workspace.contains("v2.conversion.ambiguity-step"))
        #expect(workspace.contains("case resolve"))
        #expect(workspace.contains("store.plan?.ambiguities.isEmpty ?? true"))

        // Apply/undo, gated on write access, with confirmation dialogs stating file counts.
        #expect(workspace.contains("v2.conversion.apply"))
        #expect(workspace.contains("v2.conversion.undo"))
        #expect(workspace.contains("Requires write access"))
        #expect(workspace.contains(".disabled(store.accessMode != .mutationEnabled || !plan.canApply)"))
        #expect(workspace.contains("confirmationDialog("))
        #expect(workspace.contains("summary.fileAssignmentCount"))
        #expect(workspace.contains("summary.moveCount"))
        #expect(workspace.contains("Show Receipt in Finder"))
        #expect(workspace.contains("FrameThumbnailCell.resolvedURL"))
        #expect(workspace.contains("activateFileViewerSelecting"))

        // No stale "preview only" wording remains now that apply/undo are real.
        #expect(!workspace.contains("Preview only"))

        // The command wraps the V1 engine directly -- no new mover invented.
        #expect(command.contains("SessionConversionExecutor.apply"))
        #expect(command.contains("SessionConversionExecutor.rollback"))
        #expect(command.contains("SessionConversionPlanner.plan"))
        #expect(command.contains("SessionConversionPlanner.resolving"))
        #expect(command.contains("LibraryMutationError.readOnly"))

        #expect(shell.contains("ConversionWorkspace("))
        #expect(shell.contains("accessMode: libraryAccessMode"))
    }

    @Test("Project goals and notes are editable rather than placeholders")
    func projectGoalAndNotesContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"), encoding: .utf8)
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
        let nights = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(nights.contains("Table(store.visibleNights, selection:"))
        #expect(nights.contains("TableColumn(\"Night\""))
        #expect(nights.contains("TableColumn(\"Projects\""))
        #expect(nights.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(nights.contains("openNight"))
        #expect(shell.contains("openNight: { id in"))
    }

    @Test("Every V1 export path has a V2 export menu reaching the same content engines")
    func exportMenusReachEveryWorkspace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/Exports/ExportService.swift"), encoding: .utf8)
        let menu = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Exports/ExportMenu.swift"), encoding: .utf8)
        let project = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift"), encoding: .utf8)
        let night = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"), encoding: .utf8)
        let home = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"), encoding: .utf8)
        let results = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Results/ResultsView.swift"), encoding: .utf8)

        #expect(service.contains("AcquisitionExport.render"))
        #expect(service.contains("TargetReport.render"))
        #expect(service.contains("NightReport.render"))
        #expect(service.contains("StackList.select"))
        #expect(service.contains("PlanExport.renderCSV"))
        #expect(service.contains("PlanExport.renderClipboardText"))
        #expect(service.contains("CalibShoppingList.markdown"))
        #expect(menu.contains("public struct ExportMenu"))
        #expect(menu.contains("ExportFileWriter"))

        #expect(project.contains("ExportMenu("))
        #expect(project.contains("v2.project.export"))
        #expect(night.contains("ExportMenu("))
        #expect(night.contains("v2.nights.export"))
        #expect(home.contains("ExportMenu("))
        #expect(home.contains("v2.home.plan-export"))
        #expect(results.contains("ExportMenu("))
        #expect(results.contains("v2.results.export"))
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
            "Sources/AstroUI/Features/Nights/NightActionMenu.swift",
            "Sources/AstroUI/Features/Nights/NightsView.swift",
            "Sources/AstroUI/Features/Nights/NightWorkspaceView.swift",
        ]
        for relative in sources {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(!source.contains(".disabled(true)"), Comment(rawValue: relative))
            #expect(!source.contains("Button(\"Move to Archive\") {}"), Comment(rawValue: relative))
            #expect(!source.contains("Button(\"No Action Required\") {}"), Comment(rawValue: relative))
        }
    }
}

@Suite("Projects table carries its own facts")
struct ProjectsTableSelfSufficiencyTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // The owner's report: "when I click a target its detail appears in a
    // little strip at the bottom, that's very bad UX — if it isn't in the
    // list, put it in the list." Selecting a row must not be the only way to
    // learn a project's numbers, and comparing projects must not require
    // clicking them one at a time.
    @Test("Selecting a project does not open a cramped bottom detail strip")
    func noBottomDetailStrip() throws {
        let view = try source("Sources/AstroUI/Features/Projects/ProjectsView.swift")
        #expect(!view.contains("detailFooter"))
        #expect(!view.contains("ProjectAcquisitionDetail("))
    }

    @Test("Everything worth comparing is a column, including goal progress")
    func comparableFactsAreColumns() throws {
        let view = try source("Sources/AstroUI/Features/Projects/ProjectsView.swift")
        for column in ["Project", "Phase", "Nights", "Series", "Integration", "Frames", "Latest", "Goal", "Next"] {
            #expect(view.contains("TableColumn(\"\(column)\""), "missing the \(column) column")
        }
        // The advice is explainable in place rather than in a second panel.
        #expect(view.contains("help(row.nextActionExplanation)"))
    }

    @Test("The project advice is written in the app's own language")
    func nextActionIsEnglish() throws {
        let query = try source("Sources/AstroApplication/Features/Projects/ProjectsQuery.swift")
        #expect(query.contains("Keep collecting"))
        #expect(query.contains("Plan the first night"))
        // The Hungarian strings this column used to render on an English UI.
        #expect(!query.contains("Folytasd"))
        #expect(!query.contains("Készíts"))
    }
}
