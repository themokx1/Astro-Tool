import Foundation
import Testing
@testable import AstroToolMobile
@testable import AstroMobileDomain

@Test("stale snapshot classification uses the explicit 24 hour threshold")
func staleSnapshotClassificationIsDeterministic() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    #expect(MobileSnapshotFreshness.classification(snapshotDate: now.addingTimeInterval(-86_399), now: now) == .fresh)
    #expect(MobileSnapshotFreshness.classification(snapshotDate: now.addingTimeInterval(-86_400), now: now) == .stale)
    #expect(MobileSnapshotFreshness.classification(snapshotDate: now.addingTimeInterval(60), now: now) == .fresh)
}

@Test("effective checklist state folds queued completion changes")
func effectiveChecklistStateUsesLatestQueuedValue() {
    let briefingID = UUID()
    let changes: [MobileChange] = [
        .checklistCompletion(ChecklistCompletionChange(changeID: UUID(), deviceID: UUID(), briefingID: briefingID, itemID: "focus", baseRevision: 1, isCompleted: true, createdAt: Date(timeIntervalSince1970: 1))),
        .checklistCompletion(ChecklistCompletionChange(changeID: UUID(), deviceID: UUID(), briefingID: briefingID, itemID: "focus", baseRevision: 1, isCompleted: false, createdAt: Date(timeIntervalSince1970: 2)))
    ]

    #expect(MobileEffectiveState.checklistValue(briefingID: briefingID, itemID: "focus", snapshotValue: true, changes: changes) == false)
}

@Test("effective note state preserves the immutable snapshot while showing a queued revision")
func effectiveNoteStateUsesLatestQueuedValue() {
    let changes: [MobileChange] = [
        .noteRevision(NoteRevisionChange(changeID: UUID(), deviceID: UUID(), noteID: "briefing-note", ownerID: "briefing", baseRevision: 1, text: "A clear night", createdAt: Date(timeIntervalSince1970: 1))),
        .noteRevision(NoteRevisionChange(changeID: UUID(), deviceID: UUID(), noteID: "briefing-note", ownerID: "briefing", baseRevision: 1, text: "A clear night after midnight", createdAt: Date(timeIntervalSince1970: 2)))
    ]

    #expect(MobileEffectiveState.noteText(noteID: "briefing-note", snapshotText: "Mac note", changes: changes) == "A clear night after midnight")
    #expect(MobileEffectiveState.noteText(noteID: "other-note", snapshotText: "Mac note", changes: changes) == "Mac note")
}

@Test("project progress is defensive for missing, zero, nonfinite, and over-goal values")
func projectProgressNeverProducesInvalidUIValues() {
    #expect(MobileProjectProgress.fraction(integrationSeconds: 1_800, goalHours: 1) == 0.5)
    #expect(MobileProjectProgress.fraction(integrationSeconds: 7_200, goalHours: 1) == 1)
    #expect(MobileProjectProgress.fraction(integrationSeconds: -1, goalHours: 1) == 0)
    #expect(MobileProjectProgress.fraction(integrationSeconds: .infinity, goalHours: 1) == nil)
    #expect(MobileProjectProgress.fraction(integrationSeconds: 1, goalHours: 0) == nil)
    #expect(MobileProjectProgress.fraction(integrationSeconds: 1, goalHours: nil) == nil)
}

@Test("mobile surface language names only the two permitted phone edits")
func mobileSurfaceSafetyContract() {
    #expect(MobileSurfaceSafety.permittedMutationMethods == ["toggleChecklistItem", "editNote"])
    #expect(MobileSurfaceSafety.forbiddenTerms.contains("Finder"))
    #expect(MobileSurfaceSafety.forbiddenTerms.contains("path"))
    #expect(MobileSurfaceSafety.forbiddenTerms.contains("delete"))
}
