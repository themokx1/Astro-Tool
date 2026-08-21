import AstroApplication
import Foundation
import Testing

@Suite("Offline night briefing HTML")
struct NightBriefingHTMLRendererTests {
    @Test("Hungarian render contains mandatory field-ready sections")
    func rendersHungarianMandatorySections() {
        let html = NightBriefingHTMLRenderer().render(document(language: .hu))

        #expect(html.contains("Éjszakai briefing"))
        #expect(html.contains("Este röviden"))
        #expect(html.contains("Idővonal"))
        #expect(html.contains("Checklist"))
        #expect(html.contains("B terv"))
        #expect(html.contains("Terepi jegyzetek"))
        #expect(html.contains("M 42"))
    }

    @Test("English render uses English field language")
    func rendersEnglishSections() {
        let html = NightBriefingHTMLRenderer().render(document(language: .en))

        #expect(html.contains("Night briefing"))
        #expect(html.contains("Tonight at a glance"))
        #expect(html.contains("Timeline"))
        #expect(html.contains("Field notes"))
    }

    @Test("User content is escaped and the document has no external dependencies")
    func escapesAndRemainsOffline() {
        var fixture = document(language: .hu)
        fixture = NightBriefingDocument(
            draft: withNotes(fixture.draft, "<script src='https://bad.example'>alert(1)</script> & jegyzet"),
            readiness: fixture.readiness,
            issues: fixture.issues,
            contingencies: fixture.contingencies
        )

        let html = NightBriefingHTMLRenderer().render(fixture)
        let lowered = html.lowercased()

        #expect(html.contains("&lt;script src=&#39;https&#58;//bad.example&#39;&gt;"))
        #expect(!lowered.contains("<script"))
        #expect(!lowered.contains("http:"))
        #expect(!lowered.contains("https:"))
        #expect(!lowered.contains("file:"))
        #expect(!lowered.contains("@import"))
    }

    @Test("A4 print styling is deterministic, readable, and page-aware")
    func printContractIsStable() {
        let renderer = NightBriefingHTMLRenderer()
        let first = renderer.render(document(language: .hu))
        let second = renderer.render(document(language: .hu))

        #expect(first == second)
        #expect(first.contains("@page { size: A4 portrait"))
        #expect(first.contains("font-size: 11pt"))
        #expect(first.contains("page-break-before"))
        #expect(first.contains("<svg"))
    }

    private func document(language: BriefingDocumentLanguage) -> NightBriefingDocument {
        let start = Date(timeIntervalSince1970: 1_786_738_400)
        var draft = NightBriefingDraft(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            savedAt: start,
            nightDate: start,
            arrival: start,
            departure: start.addingTimeInterval(7_200),
            site: .init(id: "garden", name: language == .hu ? "Kert" : "Garden"),
            setup: .init(id: "rig", name: "RedCat 51 + ASI 2600MC"),
            weather: .missing(reason: language == .hu ? "Nincs időjárási adat" : "No weather data"),
            targets: [.init(name: "M 42", role: .primary, start: start, end: start.addingTimeInterval(3_600))],
            notes: "",
            language: language
        )
        draft.checklist = NightBriefingChecklistTemplate().sections(language: language)
        return NightBriefingComposer().compose(draft: draft, context: .init())
    }

    private func withNotes(_ draft: NightBriefingDraft, _ notes: String) -> NightBriefingDraft {
        var copy = draft
        copy.notes = notes
        return copy
    }
}
