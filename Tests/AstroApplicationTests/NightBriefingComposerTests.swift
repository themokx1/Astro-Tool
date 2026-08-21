import AstroApplication
import Foundation
import Testing

@Suite("Night briefing composition")
struct NightBriefingComposerTests {
    @Test("The beginner checklist has five ordered sections with explanations")
    func defaultChecklistHasFiveSections() {
        let sections = NightBriefingChecklistTemplate().sections(language: .hu)

        #expect(sections.map(\.id) == ["departure", "setup", "before-capture", "during-night", "shutdown"])
        #expect(sections.allSatisfy { !$0.items.isEmpty })
        #expect(sections.flatMap(\.items).allSatisfy { !($0.explanation ?? "").isEmpty })
    }

    @Test("A hidden built-in stays in the draft while custom items are retained")
    func compositionPreservesChecklistChoices() {
        var draft = fixtureDraft()
        var sections = NightBriefingChecklistTemplate().sections(language: .hu)
        sections[0].items[0].isVisible = false
        sections[0].items.append(.init(id: "custom-coffee", title: "Termosz", explanation: "A hosszú éjszakához.", isBuiltIn: false))
        draft.checklist = sections

        let document = NightBriefingComposer().compose(draft: draft, context: .init())

        #expect(document.draft.checklist[0].items[0].isVisible == false)
        #expect(document.draft.checklist[0].items.contains { $0.id == "custom-coffee" && !$0.isBuiltIn })
    }

    @Test("Manual capture values remain authoritative and integration is consistent")
    func manualCapturePlanWins() {
        var draft = fixtureDraft()
        draft.targets[0].capturePlan = .init(filterName: "L-eXtreme", exposureSeconds: 180, frameCount: 20, gain: 100)

        let document = NightBriefingComposer().compose(draft: draft, context: .init())

        #expect(document.draft.targets[0].capturePlan.filterName == "L-eXtreme")
        #expect(document.draft.targets[0].capturePlan.integrationSeconds == 3_600)
    }

    @Test("All six contingency categories are present without invented alternatives")
    func contingenciesUseKnownInputsOnly() {
        let document = NightBriefingComposer().compose(
            draft: fixtureDraft(),
            context: .init(calibrationGaps: ["flat"], poorQualityAction: "Fókusz ellenőrzése és tesztkép")
        )

        #expect(document.contingencies.map(\.id) == [
            "late-arrival", "short-night", "clouds", "primary-unavailable", "calibration", "quality",
        ])
        #expect(document.contingencies.first { $0.id == "primary-unavailable" }?.action.contains("M 31") == true)
        #expect(document.contingencies.first { $0.id == "calibration" }?.action.contains("flat") == true)
        #expect(document.contingencies.first { $0.id == "quality" }?.action == "Fókusz ellenőrzése és tesztkép")
    }

    @Test("No backup input yields an honest no-alternative message")
    func noBackupDoesNotInventOne() {
        var draft = fixtureDraft()
        draft.targets.removeAll { $0.role == .backup }

        let document = NightBriefingComposer().compose(draft: draft, context: .init())
        let action = document.contingencies.first { $0.id == "primary-unavailable" }?.action

        #expect(action == "Nincs megadott tartalék célpont; az ég és a felszerelés ellenőrzése után dönts.")
        #expect(!document.contingencies.map(\.action).joined().contains("M 31"))
    }

    private func fixtureDraft() -> NightBriefingDraft {
        let start = Date(timeIntervalSince1970: 1_786_738_400)
        return NightBriefingDraft(
            savedAt: start,
            nightDate: start,
            arrival: start,
            departure: start.addingTimeInterval(10_800),
            site: .init(id: "garden", name: "Kert"),
            setup: .init(id: "rig", name: "Kis setup"),
            weather: .known(.init(summary: "Derült", source: "Open-Meteo", updatedAt: start)),
            targets: [
                .init(name: "M 42", role: .primary, start: start, end: start.addingTimeInterval(3_600)),
                .init(name: "M 31", role: .backup, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(7_200)),
            ],
            language: .hu
        )
    }
}
