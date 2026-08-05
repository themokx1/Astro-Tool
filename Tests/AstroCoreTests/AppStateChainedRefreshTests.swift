import Foundation
import Testing
@testable import AstroCore
@testable import AstroToolApp

/// Regression tests for the `beginOperation` chain-cancellation race: two
/// public `loadX(); loadY()` calls made back-to-back synchronously cancel
/// each other's Tasks, so only the LAST load ever landed (see the
/// refresh-core comment in `AppState`). These tests exercise the combined
/// operations that replaced every such chain (`runPlateSolve`'s inline
/// refresh shares the exact same `refreshStatsCore`/`refreshPlanCore`
/// path) and assert that EVERY chained result lands, not just the last
/// one's.
///
/// All state mutation happens on the main actor (AppState is `@MainActor`);
/// the tests poll `isBusy`, which `endOperation` flips back exactly once
/// the whole combined operation -- not just its first stage -- finished.

/// Fresh sqlite-backed `Database` under a temp dir (AppState's detached
/// workers hop threads, so a file-backed DB matches production better than
/// `:memory:`), plus an `AppState` already pointed at it.
@MainActor
private struct AppStateFixture {
    let dbDir: URL
    let db: Database
    let state: AppState

    static func make() throws -> AppStateFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-appstate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        let state = AppState()
        state.db = db
        state.rootStatus = .ok
        return AppStateFixture(dbDir: dbDir, db: db, state: state)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Inserts one rated session light (`files` + `fits_meta` + `ratings`)
    /// -- enough for StatsQueries/Planner/SessionQuality to each return a
    /// non-empty result. Same synthetic-row conventions as
    /// `SessionQualityTests` (fake inode so FrameSet dedup keeps every row).
    @discardableResult
    func addRatedLight(target: String, date: String, name: String) throws -> Int64 {
        let path = "sessions/\(target)/\(date)/lights/\(name).fit"
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        ))
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 300))
        try db.upsertRating(RatingRecord(
            fileID: fileID, fwhm: 3.0, starCount: 500, background: 400,
            score: 0.5, ratedAt: 1_700_000_200, inputSig: "sig-\(name)"
        ))
        return fileID
    }

    /// `beginOperation` flips `isBusy` synchronously before this is called;
    /// `endOperation` flips it back only when the whole operation is done.
    func waitUntilIdle() async throws {
        var polls = 0
        while state.isBusy {
            polls += 1
            try #require(polls < 3000, "the operation never finished")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Test func statsTabCombinedLoadAppliesBothStatsAndPlan() async throws {
    let fixture = try AppStateFixture.make()
    defer { fixture.cleanup() }
    try fixture.addRatedLight(target: "M42_Orion", date: "2026-08-10", name: "l1")

    fixture.state.loadStatsTabIfNeeded()
    try await fixture.waitUntilIdle()

    #expect(fixture.state.lastError == nil)
    // Under the old `loadStats(); loadPlan()` chain the stats result was
    // always cancelled away and only the plan landed.
    #expect(!fixture.state.stats.isEmpty)
    #expect(fixture.state.plan != nil)
}

@MainActor
@Test func calibTabCombinedLoadAppliesAllThreeDataSets() async throws {
    let fixture = try AppStateFixture.make()
    defer { fixture.cleanup() }
    try fixture.db.upsertSensorProfile(SensorProfileRecord(
        camera: "ZWO ASI2600MC Pro", gain: 100, offset: 50, biasLevelADU: 500, measuredAt: 1_700_000_000
    ))

    fixture.state.loadCalibTabIfNeeded()
    try await fixture.waitUntilIdle()

    #expect(fixture.state.lastError == nil)
    // Under the old three-call chain only the sensor profiles (the last
    // link) ever landed on first appearance; `calibHealth` stayed nil.
    #expect(fixture.state.calibHealth != nil)
    #expect(!fixture.state.sensorProfiles.isEmpty)
}

@MainActor
@Test func qualityPanelsCombinedLoadAppliesBothSummariesAndAdvice() async throws {
    let fixture = try AppStateFixture.make()
    defer { fixture.cleanup() }
    try fixture.addRatedLight(target: "M42_Orion", date: "2026-08-10", name: "l1")
    try fixture.addRatedLight(target: "M42_Orion", date: "2026-08-10", name: "l2")

    fixture.state.loadQualityPanels(target: "M42_Orion")
    try await fixture.waitUntilIdle()

    #expect(fixture.state.lastError == nil)
    // Under the old `loadQualitySummaries(); loadExposureAdvice()` chain
    // the summaries were cancelled away on every target change.
    #expect(!fixture.state.qualitySummaries.isEmpty)
    #expect(fixture.state.exposureAdvice != nil)
}
