import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-verify-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(at url: URL, bytes: [UInt8]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

private func setModificationDate(_ timestamp: Double, at path: String) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: path)
}

private func statInfo(_ url: URL) throws -> (size: Int64, mtime: Double) {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let mtime = (values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970
    return (Int64(values.fileSize ?? 0), mtime)
}

/// Thread-safe recorder for the `@Sendable` `progress` callback -- same
/// shape as `RateTests`' own `ProgressRecorder`, needed because a plain
/// captured `var` can't be mutated from inside a `@Sendable` closure under
/// strict concurrency checking, even though `verify(...)` only ever calls
/// it synchronously from the same thread the test runs on.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(done: Int, total: Int)] = []
    var calls: [(done: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    func record(_ done: Int, _ total: Int) {
        lock.lock(); _calls.append((done, total)); lock.unlock()
    }
}

private func makeFileRecord(
    path: String,
    size: Int64,
    mtime: Double,
    contentHash: String?,
    target: String? = nil,
    missing: Bool = false
) -> FileRecord {
    FileRecord(
        path: path,
        size: size,
        mtime: mtime,
        ext: "fit",
        kind: "fits",
        area: .sessions,
        target: target,
        sessionDate: "2026-01-01",
        role: .light,
        contentHash: contentHash,
        scannedAt: 0,
        missing: missing
    )
}

/// A fresh tmp library dir + fresh DB, with the caller responsible for
/// populating both -- same shape as `DuplicateFinderTests`' own fixture.
private struct VerifyFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> VerifyFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return VerifyFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func url(_ relativePath: String) -> URL {
        libraryDir.appendingPathComponent(relativePath)
    }
}

// MARK: - verify(...): ok / content-changed / modified / read-error

@Test func fixityVerifierReportsOkWhenHashMatchesCurrentContent() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    try writeFile(at: url, bytes: Array(repeating: 0xAB, count: 2048))
    let stat = try statInfo(url)
    let hash = try DuplicateFinder.sha256Hash(of: url)

    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: hash))

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    #expect(results.count == 1)
    #expect(results.first?.status == .ok)
}

/// Classic bitrot: the bytes change but nothing about the file's recorded
/// metadata (mtime, size) explains it -- the on-disk mtime is deliberately
/// forced back to what it was BEFORE the corrupting write bumped it, since
/// silent disk-level corruption never touches a file's mtime/size.
@Test func fixityVerifierDetectsContentChangedWhenMtimeAndSizeUnchanged() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    let originalBytes: [UInt8] = Array(repeating: 0xAB, count: 2048)
    try writeFile(at: url, bytes: originalBytes)
    let stat = try statInfo(url)
    let originalHash = try DuplicateFinder.sha256Hash(of: url)

    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: originalHash))

    var corruptedBytes = originalBytes
    corruptedBytes[10] = 0xFF
    try writeFile(at: url, bytes: corruptedBytes)
    try setModificationDate(stat.mtime, at: url.path)

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    let result = try #require(results.first)
    guard case .contentChanged(let oldHash, let newHash) = result.status else {
        Issue.record("expected contentChanged, got \(result.status)")
        return
    }
    #expect(oldHash == originalHash)
    #expect(newHash != originalHash)
}

/// Legitimate edit/resave: BOTH the size and the mtime differ from what's
/// on record -- the mtime is forced well past the 1-second "unchanged"
/// tolerance `LibraryScanner` itself uses, so the test can't flake on two
/// back-to-back writes landing within the same filesystem timestamp tick.
@Test func fixityVerifierDetectsModifiedWhenMtimeAndSizeBothChanged() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    try writeFile(at: url, bytes: Array(repeating: 0xAB, count: 2048))
    let stat = try statInfo(url)
    let originalHash = try DuplicateFinder.sha256Hash(of: url)

    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: originalHash))

    try writeFile(at: url, bytes: Array(repeating: 0xCD, count: 4096))
    try setModificationDate(stat.mtime + 100, at: url.path)

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    let result = try #require(results.first)
    guard case .modified(let oldHash, let newHash) = result.status else {
        Issue.record("expected modified, got \(result.status)")
        return
    }
    #expect(oldHash == originalHash)
    #expect(newHash != originalHash)
}

/// Edge case the spec's two named categories don't directly cover: only ONE
/// of mtime/size differs (here just the size; mtime is pinned back to what
/// it was on record). Falls back to the more cautious `content-changed`
/// bucket rather than being waved through as an intentional edit -- only a
/// change to BOTH earns the "modified" (informative, not-bitrot) read.
@Test func fixityVerifierTreatsPartialMetadataMismatchAsContentChangedNotModified() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    try writeFile(at: url, bytes: Array(repeating: 0xAB, count: 2048))
    let stat = try statInfo(url)
    let originalHash = try DuplicateFinder.sha256Hash(of: url)

    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: originalHash))

    // Size changes, but mtime is pinned back to the recorded value.
    try writeFile(at: url, bytes: Array(repeating: 0xCD, count: 4096))
    try setModificationDate(stat.mtime, at: url.path)

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    let result = try #require(results.first)
    guard case .contentChanged = result.status else {
        Issue.record("expected contentChanged, got \(result.status)")
        return
    }
}

@Test func fixityVerifierReportsReadErrorForAFileThatNoLongerExists() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/gone.fit"
    try fixture.db.upsertFile(makeFileRecord(path: path, size: 2048, mtime: 0, contentHash: String(repeating: "a", count: 64)))

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    let result = try #require(results.first)
    guard case .readError = result.status else {
        Issue.record("expected readError, got \(result.status)")
        return
    }
}

/// Iron-rule regression: a mismatch is only ever REPORTED, never "healed"
/// by adopting the freshly computed (possibly corrupt) hash as the new
/// ground truth -- doing so would make a still-corrupt file silently read
/// as "ok" on the very next verify run.
@Test func fixityVerifierNeverWritesBackContentHashEvenOnMismatch() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    let originalBytes: [UInt8] = Array(repeating: 0xAB, count: 2048)
    try writeFile(at: url, bytes: originalBytes)
    let stat = try statInfo(url)
    let originalHash = try DuplicateFinder.sha256Hash(of: url)

    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: originalHash))

    var corruptedBytes = originalBytes
    corruptedBytes[10] = 0xFF
    try writeFile(at: url, bytes: corruptedBytes)
    try setModificationDate(stat.mtime, at: url.path)

    _ = try FixityVerifier.verify(db: fixture.db, config: fixture.config)

    let stored = try fixture.db.file(path: path)
    #expect(stored?.contentHash == originalHash)
}

// MARK: - eligibleFiles(...): cached-hash filter, missing filter, scoping

@Test func fixityVerifierSkipsFilesWithoutCachedContentHash() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    try fixture.db.upsertFile(makeFileRecord(path: path, size: 2048, mtime: 0, contentHash: nil))

    let eligible = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config)
    #expect(eligible.isEmpty)

    let results = try FixityVerifier.verify(db: fixture.db, config: fixture.config)
    #expect(results.isEmpty)
}

@Test func fixityVerifierEligibleFilesExcludesMissingFiles() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    try fixture.db.upsertFile(makeFileRecord(path: path, size: 2048, mtime: 0, contentHash: "h1", missing: true))

    let eligible = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config)
    #expect(eligible.isEmpty)
}

@Test func fixityVerifierEligibleFilesScopesToTargetAndPath() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M31/2026-01-01/lights/a.fit", size: 10, mtime: 0, contentHash: "h1", target: "M31"))
    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M42/2026-01-02/lights/b.fit", size: 10, mtime: 0, contentHash: "h2", target: "M42"))
    try fixture.db.upsertFile(makeFileRecord(path: "sessions/M42/2026-01-02/flats/c.fit", size: 10, mtime: 0, contentHash: "h3", target: "M42"))

    let byTarget = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, target: "M42")
    #expect(Set(byTarget.map(\.path)) == ["sessions/M42/2026-01-02/lights/b.fit", "sessions/M42/2026-01-02/flats/c.fit"])

    let byPath = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, path: "sessions/M42/2026-01-02/lights")
    #expect(byPath.map(\.path) == ["sessions/M42/2026-01-02/lights/b.fit"])
}

@Test func fixityVerifierEligibleFilesSamplePercentWithSeedIsDeterministicAndProportional() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<20 {
        try fixture.db.upsertFile(makeFileRecord(path: "sessions/M31/2026-01-01/lights/f\(i).fit", size: 10, mtime: 0, contentHash: "h\(i)"))
    }

    let sampleA = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, samplePercent: 50, seed: 42)
    let sampleB = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, samplePercent: 50, seed: 42)
    #expect(sampleA.map(\.path) == sampleB.map(\.path))
    #expect(sampleA.count == 10)
    // Deterministically sorted back to path order regardless of the
    // shuffle, so downstream output (CLI/app) is never sample-order-flaky.
    #expect(sampleA.map(\.path) == sampleA.map(\.path).sorted())
}

@Test func fixityVerifierEligibleFilesSamplePercent100OrNilReturnsEverything() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<5 {
        try fixture.db.upsertFile(makeFileRecord(path: "sessions/M31/2026-01-01/lights/f\(i).fit", size: 10, mtime: 0, contentHash: "h\(i)"))
    }

    let withNil = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, samplePercent: nil)
    let with100 = try FixityVerifier.eligibleFiles(db: fixture.db, config: fixture.config, samplePercent: 100)
    #expect(withNil.count == 5)
    #expect(with100.count == 5)
}

// MARK: - progress callback

@Test func fixityVerifierProgressCallbackReportsCompletedAndTotal() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<3 {
        let path = "sessions/M31/2026-01-01/lights/f\(i).fit"
        let url = fixture.url(path)
        try writeFile(at: url, bytes: Array(repeating: UInt8(i), count: 1024))
        let stat = try statInfo(url)
        let hash = try DuplicateFinder.sha256Hash(of: url)
        try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: hash))
    }

    let recorder = ProgressRecorder()
    _ = try FixityVerifier.verify(db: fixture.db, config: fixture.config) { done, total in
        recorder.record(done, total)
    }

    let progressCalls = recorder.calls
    #expect(progressCalls.count == 3)
    #expect(progressCalls.allSatisfy { $0.total == 3 })
    #expect(progressCalls.map(\.done) == [1, 2, 3])
}

// MARK: - findings(from:) / summarize(_:)

@Test func fixityVerifierFindingsMapsEachStatusToTheRightSeverityAndCategory() throws {
    func file(_ path: String) -> FileRecord {
        makeFileRecord(path: path, size: 1, mtime: 0, contentHash: "h")
    }

    let results: [FixityVerifier.FileResult] = [
        FixityVerifier.FileResult(file: file("ok.fit"), status: .ok),
        FixityVerifier.FileResult(file: file("mod.fit"), status: .modified(oldHash: "a", newHash: "b")),
        FixityVerifier.FileResult(file: file("bad.fit"), status: .contentChanged(oldHash: "a", newHash: "b")),
        FixityVerifier.FileResult(file: file("err.fit"), status: .readError("boom")),
    ]

    let findings = FixityVerifier.findings(from: results)
    // `.ok` produces nothing -- only the three non-ok statuses do.
    #expect(findings.count == 3)
    #expect(!findings.contains { $0.path == "ok.fit" })

    let modified = try #require(findings.first { $0.path == "mod.fit" })
    #expect(modified.severity == .probablyIntentional)
    #expect(modified.category == "modified")
    #expect(modified.suggestion == nil)

    let corrupt = try #require(findings.first { $0.path == "bad.fit" })
    #expect(corrupt.severity == .sureError)
    #expect(corrupt.category == "content-changed")
    #expect(corrupt.suggestion == nil)

    let errorFinding = try #require(findings.first { $0.path == "err.fit" })
    #expect(errorFinding.severity == .sureError)
    #expect(errorFinding.category == "verify-read-error")
    #expect(errorFinding.suggestion == nil)
    #expect(errorFinding.message.contains("boom"))
}

@Test func fixityVerifierSummarizeCountsEachBucket() throws {
    let file = makeFileRecord(path: "x.fit", size: 1, mtime: 0, contentHash: "h")
    let results: [FixityVerifier.FileResult] = [
        FixityVerifier.FileResult(file: file, status: .ok),
        FixityVerifier.FileResult(file: file, status: .ok),
        FixityVerifier.FileResult(file: file, status: .modified(oldHash: "a", newHash: "b")),
        FixityVerifier.FileResult(file: file, status: .contentChanged(oldHash: "a", newHash: "b")),
        FixityVerifier.FileResult(file: file, status: .readError("x")),
    ]

    let summary = FixityVerifier.summarize(results)
    #expect(summary.checked == 5)
    #expect(summary.ok == 2)
    #expect(summary.modified == 1)
    #expect(summary.contentChanged == 1)
    #expect(summary.readErrors == 1)
}

// MARK: - run(...): persistence into a fresh "verify"-kind run

@Test func fixityVerifierRunPersistsFindingsUnderAFreshVerifyKindRun() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    let originalBytes: [UInt8] = Array(repeating: 0xAB, count: 2048)
    try writeFile(at: url, bytes: originalBytes)
    let stat = try statInfo(url)
    let originalHash = try DuplicateFinder.sha256Hash(of: url)
    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: originalHash))

    var corruptedBytes = originalBytes
    corruptedBytes[5] = 0x00
    try writeFile(at: url, bytes: corruptedBytes)
    try setModificationDate(stat.mtime, at: url.path)

    let (runID, results, findings) = try FixityVerifier.run(db: fixture.db, config: fixture.config)
    #expect(results.count == 1)
    #expect(findings.count == 1)

    let persisted = try fixture.db.findings(runID: runID)
    #expect(persisted.count == 1)
    #expect(persisted.first?.category == "content-changed")

    #expect(try fixture.db.lastRunID(kind: "verify") == runID)
    // A verify run must never be mistaken for an audit run by anything that
    // keys off `kind: "audit"` (e.g. `AuditEngine`'s own diff machinery).
    #expect(try fixture.db.lastRunID(kind: "audit") == nil)
}

@Test func fixityVerifierRunProducesNoFindingsWhenEverythingIsOK() throws {
    let fixture = try VerifyFixture.make()
    defer { fixture.cleanup() }

    let path = "sessions/M31/2026-01-01/lights/a.fit"
    let url = fixture.url(path)
    try writeFile(at: url, bytes: Array(repeating: 0xAB, count: 2048))
    let stat = try statInfo(url)
    let hash = try DuplicateFinder.sha256Hash(of: url)
    try fixture.db.upsertFile(makeFileRecord(path: path, size: stat.size, mtime: stat.mtime, contentHash: hash))

    let (runID, results, findings) = try FixityVerifier.run(db: fixture.db, config: fixture.config)
    #expect(results.count == 1)
    #expect(findings.isEmpty)
    #expect(try fixture.db.findings(runID: runID).isEmpty)
}
