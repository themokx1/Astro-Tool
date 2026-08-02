import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-dup-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 1.5 MiB -- comfortably above the default 1 MiB `minSizeBytes` threshold.
private let dupSize = Int64(1_048_576 + 1_048_576 / 2)

private func writeFile(at url: URL, byte: UInt8, size: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(repeating: byte, count: size)
    try data.write(to: url)
}

private func makeFileRecord(path: String, size: Int64, area: LibraryArea = .stacks, contentHash: String? = nil) -> FileRecord {
    FileRecord(
        path: path,
        size: size,
        mtime: 0,
        ext: "fit",
        kind: "fits",
        area: area,
        role: .stack,
        contentHash: contentHash,
        scannedAt: 0
    )
}

/// A fresh tmp library dir + fresh DB, with the caller responsible for
/// populating both. Bundles cleanup so every test can `defer`.
private struct DupFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> DupFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return DupFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
}

@Test func duplicateFinderFindsDuplicateContentAcrossDifferentSizeMatchedFiles() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"
    let other = "stacks/A/2026-01-02/other.fit"

    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup1), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup2), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(other), byte: 0xCD, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let findings = try DuplicateFinder.findDuplicates(db: fixture.db, config: fixture.config)

    #expect(findings.count == 1)
    let hit = try #require(findings.first)
    #expect(hit.category == "duplicate-content")
    #expect(hit.severity == .suspicious)
    #expect(hit.path == dup2) // "processed/..." sorts before "stacks/..."
    #expect(hit.message.contains(dup1))
    #expect(hit.message.contains(dup2))
    #expect(!hit.message.contains(other))

    let wastedBytes = dupSize // size * (count - 1) == size * 1
    #expect(hit.message.contains("\(wastedBytes)"))
}

@Test func duplicateFinderPersistsHashesBackToDB() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"

    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup1), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup2), byte: 0xAB, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Sanity: freshly scanned files have no hash yet.
    let before1 = try #require(try fixture.db.file(path: dup1))
    let before2 = try #require(try fixture.db.file(path: dup2))
    #expect(before1.contentHash == nil)
    #expect(before2.contentHash == nil)

    _ = try DuplicateFinder.findDuplicates(db: fixture.db, config: fixture.config)

    let after1 = try #require(try fixture.db.file(path: dup1))
    let after2 = try #require(try fixture.db.file(path: dup2))
    #expect(after1.contentHash != nil)
    #expect(after2.contentHash != nil)
    #expect(after1.contentHash == after2.contentHash)
}

@Test func duplicateFinderHonorsCachedHashesWithoutReadingFiles() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    // rootPath points at an empty directory -- the files referenced by the
    // DB records below do NOT exist on disk. If the finder tried to read
    // them (i.e. ignored the cache), it would throw.
    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"
    let sharedHash = String(repeating: "a", count: 64)

    try fixture.db.upsertFile(makeFileRecord(path: dup1, size: dupSize, contentHash: sharedHash))
    try fixture.db.upsertFile(makeFileRecord(path: dup2, size: dupSize, area: .processed, contentHash: sharedHash))

    let findings = try DuplicateFinder.findDuplicates(db: fixture.db, config: fixture.config)

    #expect(findings.count == 1)
    let hit = try #require(findings.first)
    #expect(hit.message.contains(dup1))
    #expect(hit.message.contains(dup2))
}

@Test func duplicateFinderSkipsFilesBelowMinSizeBytes() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"

    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup1), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup2), byte: 0xAB, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let findings = try DuplicateFinder.findDuplicates(
        db: fixture.db,
        config: fixture.config,
        minSizeBytes: dupSize + 1
    )

    #expect(findings.isEmpty)
}

@Test func duplicateFinderAllowsSessionsMemberButNeverSuggestsTouchingIt() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let sessionsCopy = "sessions/M1/2026-01-01/lights/dup1.fit"
    let stacksCopy = "stacks/M1/2026-01-01/dup2.fit"

    try writeFile(at: fixture.libraryDir.appendingPathComponent(sessionsCopy), byte: 0xEF, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(stacksCopy), byte: 0xEF, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let findings = try DuplicateFinder.findDuplicates(db: fixture.db, config: fixture.config)

    #expect(findings.count == 1)
    let hit = try #require(findings.first)
    // Both paths ARE reportable as group members.
    #expect(hit.message.contains(sessionsCopy))
    #expect(hit.message.contains(stacksCopy))

    guard case .review(let note) = hit.suggestion else {
        Issue.record("expected a .review suggestion, got \(String(describing: hit.suggestion))")
        return
    }
    // The suggestion must never propose touching the sessions/ copy -- only
    // the non-sessions copy is a legitimate dedup candidate.
    #expect(note.contains(stacksCopy))
    #expect(!note.contains(sessionsCopy))
}

@Test func auditEngineRunIncludesDuplicateFindingsWithSharedRunID() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"

    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup1), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup2), byte: 0xAB, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (runID, all) = try engine.run()

    let hits = all.filter { $0.category == "duplicate-content" }
    #expect(hits.count == 1)

    let persisted = try fixture.db.findings(runID: runID)
    #expect(persisted.contains { $0.category == "duplicate-content" })
}

/// Behavioral regression test for the prefix-hash tier: same-camera FITS
/// libraries have many files sharing an identical size but differing
/// content, so a naive "hash every same-size file" approach full-hashes
/// everything. The prefix-hash tier (first 64 KiB) should filter those
/// out cheaply, so only files whose (size, prefix) both collide ever pay
/// for a full-content SHA-256. Verified via injected counters rather than
/// a memory measurement, which is more reliable in CI.
@Test func duplicateFinderPrefixTierSkipsFullHashingForNonMatchingSameSizeFiles() throws {
    let fixture = try DupFixture.make()
    defer { fixture.cleanup() }

    let dup1 = "stacks/A/2026-01-01/dup1.fit"
    let dup2 = "processed/A/2026-01-01/dup2.fit"
    let other1 = "stacks/A/2026-01-02/other1.fit"
    let other2 = "stacks/A/2026-01-03/other2.fit"
    let other3 = "stacks/A/2026-01-04/other3.fit"

    // All five files share the same size (the realistic same-camera
    // scenario), but only dup1/dup2 share content -- the "other" files are
    // each uniformly filled with their own distinct byte, so they differ
    // from everything else within their very first byte (well inside the
    // 64 KiB prefix window).
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup1), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(dup2), byte: 0xAB, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(other1), byte: 0xCD, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(other2), byte: 0xEE, size: Int(dupSize))
    try writeFile(at: fixture.libraryDir.appendingPathComponent(other3), byte: 0xFF, size: Int(dupSize))

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    var prefixHashCount = 0
    var fullHashCount = 0
    let findings = try DuplicateFinder.findDuplicates(
        db: fixture.db,
        config: fixture.config,
        onPrefixHash: { prefixHashCount += 1 },
        onFullHash: { fullHashCount += 1 }
    )

    // Still finds the one real duplicate pair -- behavior contract unchanged.
    #expect(findings.count == 1)
    let hit = try #require(findings.first)
    #expect(hit.message.contains(dup1))
    #expect(hit.message.contains(dup2))
    #expect(!hit.message.contains(other1))
    #expect(!hit.message.contains(other2))
    #expect(!hit.message.contains(other3))

    // All 5 same-size, uncached files get prefix-hashed (cheap: 64 KiB
    // each)...
    #expect(prefixHashCount == 5)
    // ...but only the 2 files whose prefix actually collided (the real
    // dup pair) ever pay for a full-content SHA-256 -- not all 5.
    #expect(fullHashCount == 2)
}
