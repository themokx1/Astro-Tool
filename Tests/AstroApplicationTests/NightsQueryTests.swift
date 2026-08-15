@testable import AstroApplication
import Foundation
import Testing

struct NightsQueryTests {
    @Test("One civil night aggregates projects and capture series")
    func aggregatesProjectsAndSeries() async throws {
        let metadata = try MetadataStore.temporary()
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let ic1396 = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let m42 = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .collecting)
        let series = [makeSeries(project: ic1396.id, night: night.id, exposure: 30), makeSeries(project: m42.id, night: night.id, exposure: 120)]
        try await metadata.save(MetadataWriteBatch(projects: [ic1396, m42], nights: [night], series: series))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series[0].id, relativePath: "a.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: series[0].id, relativePath: "b.fit", verdict: .rejected, logicallyExcluded: true),
            FrameDecisionRecord(id: UUID(), seriesID: series[1].id, relativePath: "c.fit", verdict: .undecided, logicallyExcluded: false),
        ]))

        let rows = try await NightsQuery(metadata: metadata).nights()

        #expect(rows.count == 1)
        #expect(rows[0].projects.map(\.catalogID) == ["IC 1396", "M 42"])
        #expect(rows[0].series.map(\.exposureSeconds) == [30, 120])
        #expect(rows[0].totalFrames == 3)
        #expect(rows[0].usableFrames == 2)
        #expect(rows[0].undecidedFrames == 1)
        #expect(rows[0].integrationSeconds == 150)
    }

    // V2 product/UX audit (2026-08-15) section 2.3, CRITICAL: `undecidedFrames`
    // is the field `NightRow.triageState` (AstroUI) keys "needs review" off
    // of -- these three cases pin its counting rule at the query layer,
    // independent of the UI-level triage state derived from it.

    @Test("A night where every frame has a verdict has zero undecided frames, even with rejections")
    func fullyDecidedNightHasNoUndecidedFrames() async throws {
        let metadata = try MetadataStore.temporary()
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "b.fit", verdict: .rejected, logicallyExcluded: true),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "c.fit", verdict: .rejected, logicallyExcluded: true),
        ]))

        let rows = try await NightsQuery(metadata: metadata).nights()

        #expect(rows[0].undecidedFrames == 0)
        #expect(rows[0].usableFrames == 1)
    }

    @Test("A freshly scanned night has every frame undecided")
    func freshlyScannedNightIsFullyUndecided() async throws {
        let metadata = try MetadataStore.temporary()
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .undecided, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "b.fit", verdict: .undecided, logicallyExcluded: false),
        ]))

        let rows = try await NightsQuery(metadata: metadata).nights()

        #expect(rows[0].undecidedFrames == 2)
        #expect(rows[0].usableFrames == 2)
    }

    @Test("A night where every frame was rejected has zero usable and zero undecided frames")
    func fullyRejectedNightHasNoUsableOrUndecidedFrames() async throws {
        let metadata = try MetadataStore.temporary()
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .rejected, logicallyExcluded: true),
        ]))

        let rows = try await NightsQuery(metadata: metadata).nights()

        #expect(rows[0].usableFrames == 0)
        #expect(rows[0].undecidedFrames == 0)
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "Test", sensorMode: .osc, passband: .broadband,
            exposureSeconds: exposure, filterName: nil, filterID: nil, gain: nil,
            offset: nil, binning: "1x1")
    }
}
