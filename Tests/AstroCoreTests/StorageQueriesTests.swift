import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-storage-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `StorageQueries.perTarget` only ever reads the DB (same as
/// `CleanupReport.build`), so these tests insert `FileRecord`s directly via
/// `db.upsertFile`, exactly like `CleanupReportTests`.
private struct StorageFixture {
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> StorageFixture {
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = "/nonexistent/does/not/matter"
        return StorageFixture(dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }
}

private func makeFileRecord(
    path: String,
    size: Int64,
    area: LibraryArea,
    target: String? = nil,
    missing: Bool = false
) -> FileRecord {
    FileRecord(
        path: path,
        size: size,
        mtime: 0,
        ext: (path as NSString).pathExtension,
        kind: "other",
        area: area,
        target: target,
        role: .other,
        scannedAt: 0,
        missing: missing
    )
}

private func target(_ summary: StorageSummary, _ name: String) -> TargetStorage? {
    summary.targets.first { $0.target == name }
}

@Test func storageQueriesSumsBytesPerAreaForOneTarget() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M42/2026-01-17/lights/a.fit", size: 1_000, area: .sessions, target: "M42"))
    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M42/2026-01-17/lights/b.fit", size: 2_000, area: .sessions, target: "M42"))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/stack.fit", size: 5_000, area: .stacks, target: "M42"))
    try fixture.db.upsertFile(makeFileRecord(path: "processed/M42/2026-01-17/final.tif", size: 500, area: .processed, target: "M42"))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)
    let m42 = try #require(target(summary, "M42"))

    #expect(m42.sessionsBytes == 3_000)
    #expect(m42.stacksBytes == 5_000)
    #expect(m42.processedBytes == 500)
    #expect(m42.otherBytes == 0)
    #expect(m42.totalBytes == 8_500)
}

@Test func storageQueriesSortsTargetsBySizeDescending() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "stacks/Small/2026-01-01/s.fit", size: 100, area: .stacks, target: "Small"))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/Big/2026-01-01/s.fit", size: 100_000, area: .stacks, target: "Big"))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/Medium/2026-01-01/s.fit", size: 5_000, area: .stacks, target: "Medium"))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)

    #expect(summary.targets.map(\.target) == ["Big", "Medium", "Small"])
    #expect(summary.grandTotalBytes == 105_100)
}

@Test func storageQueriesExcludesMissingFiles() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M1/2026-01-01/gone.fit", size: 999_999, area: .stacks, target: "M1", missing: true))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M1/2026-01-01/still-here.fit", size: 100, area: .stacks, target: "M1"))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)
    let m1 = try #require(target(summary, "M1"))

    #expect(m1.totalBytes == 100)
}

@Test func storageQueriesExcludesFilesWithNoTarget() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    // `calibration_library/` files never carry a target (`PathClassifier`) --
    // must not show up as some phantom "nil" target row.
    try fixture.db.upsertFile(makeFileRecord(path: "calibration_library/darks/300sec/master.fit", size: 1_000_000, area: .calibration, target: nil))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)

    #expect(summary.targets.isEmpty)
    #expect(summary.grandTotalBytes == 0)
}

@Test func storageQueriesOnEmptyDBIsEmptySummary() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)

    #expect(summary.targets.isEmpty)
    #expect(summary.grandTotalBytes == 0)
}

@Test func storageQueriesResolvesDisplayNameLikeStatsQueries() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M_45_Pleiades/2026-01-01/lights/a.fit", size: 100, area: .sessions, target: "M_45_Pleiades"))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)
    let stats = try #require(try StatsQueries.target("M_45_Pleiades", db: fixture.db, config: fixture.config))
    let storageRow = try #require(target(summary, "M_45_Pleiades"))

    #expect(storageRow.displayName == stats.displayName)
}

@Test func storageSummaryRoundTripsThroughJSON() throws {
    let fixture = try StorageFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/stack.fit", size: 12_345, area: .stacks, target: "M42"))

    let summary = try StorageQueries.perTarget(db: fixture.db, config: fixture.config)

    let encoder = JSONEncoder()
    let data = try encoder.encode(summary)
    let decoded = try JSONDecoder().decode(StorageSummary.self, from: data)
    #expect(decoded == summary)
}
