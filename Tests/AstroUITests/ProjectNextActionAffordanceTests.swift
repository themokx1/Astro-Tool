import AstroApplication
import Testing

@testable import AstroUI

/// W4-4 item 3 (owner review): "Következő lépés ... looks like a button but
/// is dead" -- `ProjectNextActionAffordance` is the pure mapping behind
/// `ProjectWorkspaceView.nextActionAffordance`
/// (`Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift`) from
/// every `ProjectNextActionKind` to a real destination, or honestly to no
/// button at all. These tests pin that mapping directly, without rendering
/// a view.
@Suite("Project workspace next-action routing (W4-4 item 3)")
struct ProjectNextActionAffordanceTests {
    @Test("Collecting-phase kinds open the New Session sheet", arguments: [
        ProjectNextActionKind.planFirstNight,
        .startCollecting,
        .keepCollecting,
        // W7-F item 2 (2026-08-18 expert audit): the mosaic-balance case
        // routes to the same New Session sheet, prefilled for this project
        // -- that flow is where the owner actually captures the missing
        // panel integration.
        .balanceMosaicPanels(worstPanelLabel: "B", deficitHours: 2.1),
    ])
    func collectingKindsStartSession(kind: ProjectNextActionKind) {
        #expect(ProjectNextActionAffordance(kind) == .startSession)
    }

    @Test("Keep-processing opens Results -- its own explanation names stacks and lineage")
    func keepProcessingOpensResults() {
        #expect(ProjectNextActionAffordance(.keepProcessing) == .viewResults)
    }

    @Test("Write-final-report scrolls to the in-app report, not a dead push (W5-1: the export menu it used to open is gone)")
    func writeFinalReportOffersReport() {
        #expect(ProjectNextActionAffordance(.writeFinalReport) == .viewReport)
    }

    @Test("Archived has no sensible destination -- plain text, no button")
    func archivedHasNoDestination() {
        #expect(ProjectNextActionAffordance(.archived) == .none)
    }

    @Test("Every ProjectNextActionKind case maps to exactly one affordance -- no case silently falls through to a stale default")
    func everyCaseIsHandled() {
        // W7-F item 2: `.balanceMosaicPanels` added to this pin -- the
        // exhaustive switch inside `ProjectNextActionAffordance.init`
        // already forced this file to acknowledge the new case at compile
        // time; this test additionally pins WHICH affordance it resolves to
        // (startSession, alongside the other still-collecting kinds).
        let allKinds: [ProjectNextActionKind] = [
            .planFirstNight, .startCollecting, .keepCollecting, .keepProcessing, .writeFinalReport, .archived,
            .balanceMosaicPanels(worstPanelLabel: "B", deficitHours: 2.1),
        ]
        let affordances = allKinds.map(ProjectNextActionAffordance.init)
        #expect(affordances.filter { $0 == .startSession }.count == 4)
        #expect(affordances.filter { $0 == .viewResults }.count == 1)
        #expect(affordances.filter { $0 == .viewReport }.count == 1)
        #expect(affordances.filter { $0 == .none }.count == 1)
    }
}

/// W7-F item 2 (2026-08-18 expert audit, workflow #5): `ProjectNextActionResolution
/// .resolve` is the pure gate behind `ProjectWorkspaceView.effectiveNextAction`
/// -- takes the already-derived `mosaicBalanceNextAction: ProjectNextAction?`
/// rather than a whole `ProjectReportQuery.Result`, so these tests exercise
/// it with plain values instead of a full report fixture.
@Suite("Project workspace next-action mosaic-balance override (W7-F item 2)")
struct ProjectNextActionResolutionTests {
    private static let collectingBase = ProjectNextAction(
        kind: .keepCollecting, title: "Keep collecting", explanation: "Add the missing series on the next good night."
    )
    private static let archivedBase = ProjectNextAction(
        kind: .archived, title: "Project archived", explanation: "Nothing to do."
    )
    private static let mosaicOverride = ProjectNextAction(
        kind: .balanceMosaicPanels(worstPanelLabel: "B", deficitHours: 2.1),
        title: "Balance the panels: B panel +2.1 h",
        explanation: "B panel has the biggest integration gap in this mosaic -- capture more of it next."
    )

    @Test("No mosaic override (report not loaded yet, or no dominant gap) keeps the phase-based action")
    func noOverrideKeepsBase() {
        let resolved = ProjectNextActionResolution.resolve(base: Self.collectingBase, mosaicBalanceNextAction: nil)
        #expect(resolved == Self.collectingBase)
    }

    @Test("A dominant gap overrides a still-collecting phase's own action")
    func dominantGapOverridesCollectingBase() {
        let resolved = ProjectNextActionResolution.resolve(base: Self.collectingBase, mosaicBalanceNextAction: Self.mosaicOverride)
        #expect(resolved == Self.mosaicOverride)
    }

    @Test("Archived is exempt -- a dominant gap never re-litigates an owner's own archival decision")
    func archivedIsNeverOverridden() {
        let resolved = ProjectNextActionResolution.resolve(base: Self.archivedBase, mosaicBalanceNextAction: Self.mosaicOverride)
        #expect(resolved == Self.archivedBase)
    }
}
