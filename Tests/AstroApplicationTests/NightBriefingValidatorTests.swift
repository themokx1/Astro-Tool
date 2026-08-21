import AstroApplication
import Foundation
import Testing

@Suite("Night briefing readiness")
struct NightBriefingValidatorTests {
    private let start = Date(timeIntervalSince1970: 1_786_738_400)

    @Test("A complete draft is ready and exportable")
    func completeDraftIsReady() {
        let report = NightBriefingValidator().validate(completeDraft())

        #expect(report.readiness == .ready)
        #expect(!report.blocksExport)
        #expect(report.issues.isEmpty)
    }

    @Test("A missing night date blocks an impossible export")
    func missingDateBlocksExport() {
        var draft = completeDraft()
        draft.nightDate = nil

        let report = NightBriefingValidator().validate(draft)

        #expect(report.readiness == .incomplete)
        #expect(report.blocksExport)
        #expect(report.issues.contains { $0.code == .missingDate && $0.blocksExport })
    }

    @Test("A target ending before it starts blocks export")
    func invalidTargetWindowBlocksExport() {
        var draft = completeDraft()
        draft.targets[0].end = draft.targets[0].start

        let report = NightBriefingValidator().validate(draft)

        #expect(report.blocksExport)
        #expect(report.issues.contains { $0.code == .invalidTargetWindow })
    }

    @Test("Missing context stays exportable but is honestly incomplete")
    func missingContextDoesNotBlock() {
        var draft = completeDraft()
        draft.site = nil
        draft.setup = nil
        draft.weather = .missing(reason: "Nincs időjárási adat")

        let report = NightBriefingValidator().validate(draft)

        #expect(report.readiness == .incomplete)
        #expect(!report.blocksExport)
        #expect(report.issues.map(\.code).contains(.missingSite))
        #expect(report.issues.map(\.code).contains(.missingSetup))
        #expect(report.issues.map(\.code).contains(.missingWeather))
    }

    @Test("Overlapping target blocks ask for attention without blocking")
    func overlapNeedsAttention() {
        var draft = completeDraft()
        draft.targets.append(
            BriefingTargetBlock(
                name: "M 31",
                role: .backup,
                start: start.addingTimeInterval(1_800),
                end: start.addingTimeInterval(5_400)
            )
        )

        let report = NightBriefingValidator().validate(draft)

        #expect(report.readiness == .attention)
        #expect(!report.blocksExport)
        #expect(report.issues.contains { $0.code == .overlappingTargets })
    }

    @Test("A plan with backups only explains the missing primary target")
    func missingPrimaryIsIncompleteButExportable() {
        var draft = completeDraft()
        draft.targets[0].role = .backup

        let report = NightBriefingValidator().validate(draft)

        #expect(report.readiness == .incomplete)
        #expect(!report.blocksExport)
        #expect(report.issues.contains { $0.code == .missingPrimaryTarget })
    }

    private func completeDraft() -> NightBriefingDraft {
        NightBriefingDraft(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            revision: 0,
            savedAt: start,
            nightDate: start,
            arrival: start,
            departure: start.addingTimeInterval(10_800),
            site: BriefingSiteSummary(id: "garden", name: "Kert"),
            setup: BriefingSetupSummary(id: "rig-1", name: "Kis setup"),
            weather: .known(BriefingWeatherSummary(summary: "Derült", source: "Open-Meteo", updatedAt: start)),
            targets: [
                BriefingTargetBlock(
                    name: "M 42",
                    role: .primary,
                    start: start,
                    end: start.addingTimeInterval(3_600)
                )
            ],
            language: .hu
        )
    }
}
