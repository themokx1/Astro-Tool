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
    ])
    func collectingKindsStartSession(kind: ProjectNextActionKind) {
        #expect(ProjectNextActionAffordance(kind) == .startSession)
    }

    @Test("Keep-processing opens Results -- its own explanation names stacks and lineage")
    func keepProcessingOpensResults() {
        #expect(ProjectNextActionAffordance(.keepProcessing) == .viewResults)
    }

    @Test("Write-final-report offers the export menu, not a dead push")
    func writeFinalReportOffersExport() {
        #expect(ProjectNextActionAffordance(.writeFinalReport) == .exportSummary)
    }

    @Test("Archived has no sensible destination -- plain text, no button")
    func archivedHasNoDestination() {
        #expect(ProjectNextActionAffordance(.archived) == .none)
    }

    @Test("Every ProjectNextActionKind case maps to exactly one affordance -- no case silently falls through to a stale default")
    func everyCaseIsHandled() {
        let allKinds: [ProjectNextActionKind] = [
            .planFirstNight, .startCollecting, .keepCollecting, .keepProcessing, .writeFinalReport, .archived,
        ]
        let affordances = allKinds.map(ProjectNextActionAffordance.init)
        #expect(affordances.filter { $0 == .startSession }.count == 3)
        #expect(affordances.filter { $0 == .viewResults }.count == 1)
        #expect(affordances.filter { $0 == .exportSummary }.count == 1)
        #expect(affordances.filter { $0 == .none }.count == 1)
    }
}
