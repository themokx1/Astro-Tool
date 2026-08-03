import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-cleanup-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `CleanupReport.build` only ever reads the DB (see its doc comment), so
/// these tests never need real files on disk or a scanner run -- every
/// `FileRecord` (including a pre-set `contentHash`) is inserted directly via
/// `db.upsertFile`, exactly like `DuplicateFinderTests`'s cache-only cases.
private struct CleanupFixture {
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CleanupFixture {
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = "/nonexistent/does/not/matter"
        return CleanupFixture(dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }
}

private func makeFileRecord(
    path: String,
    size: Int64,
    area: LibraryArea = .stacks,
    contentHash: String? = nil
) -> FileRecord {
    FileRecord(
        path: path,
        size: size,
        mtime: 0,
        ext: (path as NSString).pathExtension,
        kind: "other",
        area: area,
        role: .other,
        contentHash: contentHash,
        scannedAt: 0
    )
}

private func group(_ summary: CleanupSummary, category: String) -> CleanupGroup? {
    summary.groups.first { $0.category == category }
}

@Test func cleanupReportOrdersResidueGroupsBySizeDesc() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    // A bigger .seq file vs. a tiny .lst file -- the .seq group's total
    // bytes must outrank the .lst group's, and the summary's own `groups`
    // array must reflect that order too.
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/x.seq", size: 2_000_000))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/x.lst", size: 10_000))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)

    let seq = try #require(group(summary, category: "residue-seq"))
    let lst = try #require(group(summary, category: "residue-lst"))
    #expect(seq.totalBytes == 2_000_000)
    #expect(lst.totalBytes == 10_000)
    #expect(summary.groups.first?.category == "residue-seq")
    #expect(summary.grandTotalBytes == 2_010_000)
}

@Test func cleanupReportSubcategorizesResidueByExtensionAndProcessDir() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/x.seq", size: 100))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/x.lst", size: 100))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/.DS_Store", size: 100))
    // Anything under a `process/` dir is residue-process-dir regardless of
    // its own filename, even one that wouldn't otherwise match a pattern.
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/process/leftover.tmp", size: 100))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)
    let categories = Set(summary.groups.map(\.category))

    #expect(categories.contains("residue-seq"))
    #expect(categories.contains("residue-lst"))
    #expect(categories.contains("residue-other")) // .DS_Store
    #expect(categories.contains("residue-process-dir"))
}

@Test func cleanupReportComputesDuplicateWastedBytesExcludingKeeper() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    let hash = String(repeating: "a", count: 64)
    // Three copies of the same content, none under sessions/ -- the keeper
    // (alphabetically first) is excluded from the reported wasted bytes.
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/dup1.fit", size: 5_000_000, contentHash: hash))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/dup2.fit", size: 5_000_000, area: .processed, contentHash: hash))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/dup3.fit", size: 5_000_000, area: .processed, contentHash: hash))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)
    let dup = try #require(group(summary, category: "duplicate-content"))

    // 3 copies, 1 kept -> 2 wasted copies worth of bytes.
    #expect(dup.fileCount == 2)
    #expect(dup.totalBytes == 10_000_000)
    #expect(!dup.paths.contains("stacks/A/dup1.fit")) // alphabetically-first keeper
}

@Test func cleanupReportPrefersSessionsCopyAsKeeper() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    let hash = String(repeating: "b", count: 64)
    let sessionsCopy = "sessions/M1/2026-01-01/lights/dup.fit"
    let stacksCopy = "stacks/M1/2026-01-01/dup.fit"

    try fixture.db.upsertFile(makeFileRecord(path: sessionsCopy, size: 1_000_000, area: .sessions, contentHash: hash))
    try fixture.db.upsertFile(makeFileRecord(path: stacksCopy, size: 1_000_000, contentHash: hash))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)
    let dup = try #require(group(summary, category: "duplicate-content"))

    #expect(dup.fileCount == 1)
    #expect(dup.paths == [stacksCopy])
    #expect(!dup.paths.contains(sessionsCopy))
}

@Test func cleanupReportTruncatesPathsPastMaxPathsPerGroup() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<5 {
        try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/2026-01-01/r_\(i).fit", size: Int64(100 - i)))
    }

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config, maxPathsPerGroup: 2)
    let residue = try #require(group(summary, category: "residue-other"))

    #expect(residue.fileCount == 5)
    #expect(residue.paths.count == 2)
    #expect(residue.truncatedCount == 3)
    // Still size-desc even when truncated.
    #expect(residue.paths == ["stacks/A/2026-01-01/r_0.fit", "stacks/A/2026-01-01/r_1.fit"])
}

@Test func cleanupReportOnEmptyDBIsEmptySummary() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)

    #expect(summary.groups.isEmpty)
    #expect(summary.grandTotalBytes == 0)
}

@Test func cleanupReportOmitsDuplicateGroupWhenNoContentHashCached() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    // Two same-size files with matching names but NO content_hash set --
    // as would be the case before any duplicate-scan audit has ever run.
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/a.fit", size: 5_000_000))
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/A/b.fit", size: 5_000_000))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)

    #expect(group(summary, category: "duplicate-content") == nil)
}

@Test func cleanupReportExcludesFilesUnderToolOutputDir() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    // Matches a residue pattern (r_*) AND sits under a known tool-output
    // dir (Stack) -- must NOT be counted as residue.
    try fixture.db.upsertFile(makeFileRecord(path: "sessions/T/2026-01-10/lights/Stack/Best/r_leftover.fit", size: 999_999))
    // A normal residue file elsewhere, to prove the DB/config aren't just
    // empty.
    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/r_other.fit", size: 111))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)

    let allPaths = summary.groups.flatMap(\.paths)
    #expect(!allPaths.contains("sessions/T/2026-01-10/lights/Stack/Best/r_leftover.fit"))
    #expect(allPaths.contains("stacks/M42/2026-01-17/r_other.fit"))
}

@Test func cleanupReportSummaryRoundTripsThroughJSON() throws {
    let fixture = try CleanupFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "stacks/M42/2026-01-17/x.seq", size: 2_000_000))

    let summary = try CleanupReport.build(db: fixture.db, config: fixture.config)

    let encoder = JSONEncoder()
    let data = try encoder.encode(summary)
    let decoded = try JSONDecoder().decode(CleanupSummary.self, from: data)
    #expect(decoded == summary)
}
