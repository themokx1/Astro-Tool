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

@Test("mobile labels use the production project, readiness, and target values")
func productionDomainValuesHaveHumanLabels() {
    #expect(MobileProjectPhaseLabel.label(for: "planned") == "Planned")
    #expect(MobileProjectPhaseLabel.label(for: "collecting") == "Collecting")
    #expect(MobileProjectPhaseLabel.label(for: "processing") == "Processing")
    #expect(MobileProjectPhaseLabel.label(for: "complete") == "Complete")
    #expect(MobileProjectPhaseLabel.label(for: "archived") == "Archived")
    #expect(MobileBriefingReadinessLabel.label(for: "attention") == "Needs attention")
    #expect(MobileBriefingReadinessLabel.label(for: "incomplete") == "Incomplete")
    #expect(MobileBriefingTargetRoleLabel.label(for: "primary") == "Primary target")
    #expect(MobileBriefingTargetRoleLabel.label(for: "backup") == "Backup target")
}

@Test("briefing selection labels tonight, upcoming, past, and undated plans deterministically")
func briefingSelectionIsHonestAndStable() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let past = MobileBriefing(id: UUID(), revision: 1, savedAt: now.addingTimeInterval(-100), nightDate: now.addingTimeInterval(-86_400), readiness: "ready", targets: [], checklist: [], noteID: "past")
    let future = MobileBriefing(id: UUID(), revision: 1, savedAt: now.addingTimeInterval(-50), nightDate: now.addingTimeInterval(86_400), readiness: "ready", targets: [], checklist: [], noteID: "future")
    let undated = MobileBriefing(id: UUID(), revision: 1, savedAt: now, nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: "undated")
    #expect(MobileBriefingSelection.select(briefings: [future, past], now: now, calendar: calendar)?.kind == .upcoming)
    #expect(MobileBriefingSelection.select(briefings: [past], now: now, calendar: calendar)?.kind == .past)
    #expect(MobileBriefingSelection.select(briefings: [undated], now: now, calendar: calendar)?.kind == .saved)
}

@Test("night timezone resolves by its local date instead of first-night order")
func briefingTimezoneUsesMatchingNight() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let matching = MobileNight(id: UUID(), localDate: "2023-11-14", timeZoneID: "Europe/Budapest")
    let unrelated = MobileNight(id: UUID(), localDate: "2026-08-23", timeZoneID: "America/Los_Angeles")
    #expect(MobileBriefingSelection.timeZone(for: date, nights: [unrelated, matching])?.identifier == "Europe/Budapest")
}

@Test("mobile editing surfaces contain only the two safe store mutation routes")
func mobileMutationSurfaceContract() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let surfaceFiles = [
        "Sources/AstroToolMobile/TonightMobileView.swift",
        "Sources/AstroToolMobile/ProjectsMobileView.swift",
        "Sources/AstroToolMobile/BriefingsMobileView.swift",
        "Sources/AstroToolMobile/SyncMobileView.swift"
    ]
    let source = try surfaceFiles
        .map { try String(contentsOf: repository.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")
        .lowercased()
    let visibleText = try surfaceFiles
        .map { try String(contentsOf: repository.appendingPathComponent($0), encoding: .utf8) }
        .map(visibleTextLiterals)
        .joined(separator: "\n")
        .lowercased()
    let noteAction = #"Button(String(localized: "Update note"))"#
    #expect(source.components(separatedBy: noteAction.lowercased()).count - 1 == 2)

    let english = try String(
        contentsOf: repository.appendingPathComponent("Sources/AstroToolMobile/Resources/en.lproj/Localizable.strings"),
        encoding: .utf8
    )
    let hungarian = try String(
        contentsOf: repository.appendingPathComponent("Sources/AstroToolMobile/Resources/hu.lproj/Localizable.strings"),
        encoding: .utf8
    )
    #expect(english.contains(#""Update note" = "Update note";"#))
    #expect(hungarian.contains(#""Update note" = "Jegyzet módosítása";"#))
    #expect(!english.contains(#""Edit" = "#))
    #expect(!hungarian.contains(#""Edit" = "#))

    for forbidden in [
        "finder", "file path", "path", "crud", "file management", "file-management",
        "delete", "move", "rename", "original file", "original-file", "manifest",
        "payload", "schema", "fits", "sync transport", "transport"
    ] {
        #expect(!source.contains(forbidden), "The mobile surface must not expose \(forbidden).")
    }
    #expect(source.components(separatedBy: "try await store.togglechecklistitem").count - 1 == 2)
    #expect(source.components(separatedBy: "try await store.editnote").count - 1 == 2)
    #expect(!source.contains("store.remove"))
    #expect(!source.contains("store.copy"))
    for forbidden in ["copy", "edit"] {
        #expect(
            visibleText.range(of: "\\b\\(forbidden)\\b", options: .regularExpression) == nil,
            "The mobile surface must not offer a visible \(forbidden) action."
        )
    }
}

@Test("every briefing row uses its UUID-backed semantic identifier")
func briefingRowsUseUniqueSemanticIdentifiers() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repository.appendingPathComponent("Sources/AstroToolMobile/BriefingsMobileView.swift"),
        encoding: .utf8
    )

    #expect(source.contains("mobile-briefing-\\(briefing.id.uuidString)"))
    #expect(!source.contains("mobile-briefing-undated"))
}

private func visibleTextLiterals(in source: String) -> String {
    let expression = try! NSRegularExpression(
        pattern: #"(?:Text|Button|Label|LabeledContent|ContentUnavailableView|navigationTitle|alert)\(\s*(?:String\(localized:\s*)?\"([^\"]+)\""#
    )
    let range = NSRange(source.startIndex..., in: source)
    return expression.matches(in: source, range: range).compactMap { match in
        guard let literalRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[literalRange])
    }.joined(separator: "\n")
}
