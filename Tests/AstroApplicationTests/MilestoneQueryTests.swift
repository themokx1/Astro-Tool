@testable import AstroApplication
import Foundation
import Testing

/// Pins `MilestoneQuery.evaluate`'s pure crossing rules -- expert ideation
/// spec #5 ("honest milestones"). Real integration-hour thresholds only,
/// fired exactly once per crossing, never retroactively on a fresh install.
struct MilestoneQueryTests {
    @Test("Fires exactly once when the total crosses a threshold (99.5h -> 100.2h)")
    func firesOnceOnCrossing() {
        let projectID = UUID()
        let previous = [projectID: 99.5 * 3600]
        let snapshot = projectSnapshot(id: projectID, integrationSeconds: 100.2 * 3600)

        let result = MilestoneQuery.evaluate(projects: [snapshot], previousTotals: previous)

        #expect(result.hits.count == 1)
        #expect(result.hits.first?.thresholdHours == 100)
        #expect(result.updatedTotals[projectID] == 100.2 * 3600)
    }

    @Test("Does not re-fire the same threshold on the very next snapshot at the same (or higher) total")
    func doesNotRefireOnNextSnapshot() {
        let projectID = UUID()
        // Simulate the ledger having already been updated by the first
        // `evaluate` call above -- the "previous" total is now 100.2h.
        let previous = [projectID: 100.2 * 3600]
        let snapshot = projectSnapshot(id: projectID, integrationSeconds: 100.2 * 3600)

        let result = MilestoneQuery.evaluate(projects: [snapshot], previousTotals: previous)

        #expect(result.hits.isEmpty)
    }

    @Test("A fresh install with an already-100h project seeds silently and fires nothing")
    func freshInstallSeedsWithoutFiring() {
        let projectID = UUID()
        // No entry in `previousTotals` at all -- this project has never
        // been observed by this ledger before.
        let snapshot = projectSnapshot(id: projectID, integrationSeconds: 150 * 3600)

        let result = MilestoneQuery.evaluate(projects: [snapshot], previousTotals: [:])

        #expect(result.hits.isEmpty)
        // The baseline is still recorded, so a FUTURE real crossing (past
        // 150h, e.g. the next threshold at 250h) can still fire later.
        #expect(result.updatedTotals[projectID] == 150.0 * 3600.0)
    }

    @Test("A total that stays flat between two observations never fires")
    func flatTotalNeverFires() {
        let projectID = UUID()
        let previous: [UUID: Double] = [projectID: 50 * 3600]
        let snapshot = projectSnapshot(id: projectID, integrationSeconds: 50 * 3600)

        let result = MilestoneQuery.evaluate(projects: [snapshot], previousTotals: previous)

        #expect(result.hits.isEmpty)
    }

    @Test("Jumping across several thresholds at once reports only the largest")
    func largestThresholdWinsOnAMultiCrossingJump() {
        let projectID = UUID()
        let previous: [UUID: Double] = [projectID: 8 * 3600]
        // A big backfilled scan jumps straight past 10/25/50/100 at once.
        let snapshot = projectSnapshot(id: projectID, integrationSeconds: 110 * 3600)

        let result = MilestoneQuery.evaluate(projects: [snapshot], previousTotals: previous)

        #expect(result.hits.count == 1)
        #expect(result.hits.first?.thresholdHours == 100)
    }

    @Test("Multiple projects crossing the same day are all reported, largest threshold first")
    func multipleProjectsSortedByThreshold() {
        let smallProjectID = UUID()
        let bigProjectID = UUID()
        let previous: [UUID: Double] = [smallProjectID: 9 * 3600, bigProjectID: 95 * 3600]
        let smallSnapshot = projectSnapshot(id: smallProjectID, catalogID: "M 42", integrationSeconds: 10.5 * 3600)
        let bigSnapshot = projectSnapshot(id: bigProjectID, catalogID: "NGC 7000", integrationSeconds: 101 * 3600)

        let result = MilestoneQuery.evaluate(projects: [smallSnapshot, bigSnapshot], previousTotals: previous)

        #expect(result.hits.map(\.thresholdHours) == [100, 10])
        #expect(result.hits.map(\.catalogID) == ["NGC 7000", "M 42"])
    }

    // MARK: - MilestoneLedger persistence

    @Test("The ledger round-trips totals through its JSON file")
    func ledgerRoundTripsTotals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilestoneLedgerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = MilestoneLedger(fileURL: directory.appendingPathComponent("milestones.json"))
        let projectA = UUID()
        let projectB = UUID()

        #expect(ledger.load().isEmpty)

        try ledger.save([projectA: 36_000, projectB: 900_000])
        let loaded = ledger.load()

        #expect(loaded[projectA] == 36_000)
        #expect(loaded[projectB] == 900_000)
    }

    @Test("A missing or corrupt ledger file reads back as empty, never a crash")
    func ledgerTreatsCorruptFileAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilestoneLedgerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("milestones.json")
        try Data("not json".utf8).write(to: fileURL)

        let ledger = MilestoneLedger(fileURL: fileURL)

        #expect(ledger.load().isEmpty)
    }

    // MARK: - Fixtures

    private func projectSnapshot(id: UUID, catalogID: String = "NGC 7000", integrationSeconds: Double) -> ProjectSnapshot {
        let project = ProjectRecord(id: id, catalogID: catalogID, displayName: catalogID, phase: .collecting)
        let seriesSnapshot = ProjectSeriesSnapshot(
            series: SeriesRecord(
                id: UUID(), projectID: id, nightID: UUID(), setupID: nil,
                setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .broadband,
                exposureSeconds: 300, filterName: nil, filterID: nil, gain: nil, offset: nil, binning: "1x1"
            ),
            totalFrames: 0, usableFrames: 0, excludedFrames: 0, undecidedFrames: 0,
            integrationSeconds: integrationSeconds
        )
        return ProjectSnapshot(
            project: project, canonicalFolderName: catalogID, series: [], nights: [],
            orphanedSeries: [seriesSnapshot],
            nextAction: ProjectNextAction(kind: .keepCollecting, title: "Keep collecting", explanation: "")
        )
    }
}
