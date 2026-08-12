@testable import AstroApplication
import Foundation
import Testing

struct NightRibbonModelTests {
    @Test("Ribbon orders real events and describes the observing window accessibly")
    func ordersEventsAndBuildsSummary() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-08-08T20:00:00Z"))
        let later = NightRibbonEvent(id: UUID(), start: start.addingTimeInterval(3600), end: start.addingTimeInterval(5400), kind: .capture, label: "IC 1396 · 300 s")
        let first = NightRibbonEvent(id: UUID(), start: start, end: start.addingTimeInterval(1800), kind: .capture, label: "IC 1396 · 30 s")

        let ribbon = try NightRibbonModel(events: [later, first])

        #expect(ribbon.events.map(\.id) == [first.id, later.id])
        #expect(ribbon.durationSeconds == 5400)
        #expect(ribbon.accessibilitySummary.contains("2 events"))
        #expect(ribbon.accessibilitySummary.contains("1 hour 30 minutes"))
    }

    @Test("Ribbon rejects impossible event intervals")
    func rejectsInvalidIntervals() {
        let now = Date()
        #expect(throws: NightRibbonError.invalidInterval) {
            try NightRibbonModel(events: [
                NightRibbonEvent(id: UUID(), start: now, end: now.addingTimeInterval(-1), kind: .gap, label: "Gap")
            ])
        }
    }
}
