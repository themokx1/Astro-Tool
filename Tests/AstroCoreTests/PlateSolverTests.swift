import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixture helpers

/// A fresh fixture library + fresh sqlite-backed `Database` -- same shape as
/// `RateTests`' own `RateFixture`, since `PlateSolver` reads/writes through
/// `Database` the same way `Rater` does.
private struct PlateSolveFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> PlateSolveFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-solve-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-solve-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return PlateSolveFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a placeholder (empty) CR3 light frame at `relativePath` (its
    /// content is irrelevant -- the mock backend never actually reads it)
    /// and registers a matching `files`/`fits_meta` row for it, with no
    /// `header_json` at all (the realistic wide-field CR3 case: there's no
    /// WCS, and often no FITS header whatsoever). Returns the DB `fileID`.
    @discardableResult
    func addUnsolvedCR3Light(
        relativePath: String,
        target: String,
        sessionDate: String = "2026-01-01",
        exptime: Double? = 30
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: url)

        let record = FileRecord(
            path: relativePath, size: 11, mtime: 1_700_000_000, ext: "cr3", kind: "raw",
            area: .sessions, target: target, sessionDate: sessionDate, role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        let fileID = try db.upsertFile(record)
        // Fake inode so `FrameSet.lightBuckets`'s dedup treats each frame as
        // its own distinct exposure (same convention `FieldGeometryTests`/
        // `RateTests` use for synthetic rows with no real file to `stat()`).
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: exptime))
        return fileID
    }
}

// MARK: - Mock SolveBackend

/// Writes a synthetic solved FITS (header-only, `CRVAL`/`CD` cards) into
/// `workDir` for every `solve(originalPath:workDir:)` call, and records
/// every `workDir` it was invoked with so tests can assert it always sits
/// under `FileManager.temporaryDirectory` -- never inside the fixture
/// library.
private final class RecordingMockBackend: SolveBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _workDirs: [URL] = []
    var workDirs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _workDirs
    }

    let raDeg: Double
    let decDeg: Double
    let cdMatrix: (cd11: Double, cd12: Double, cd21: Double, cd22: Double)?

    init(raDeg: Double = 56.75, decDeg: Double = 24.1, cdMatrix: (cd11: Double, cd12: Double, cd21: Double, cd22: Double)? = nil) {
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.cdMatrix = cdMatrix
    }

    func solve(originalPath: String, workDir: URL) throws -> URL {
        lock.lock(); _workDirs.append(workDir); lock.unlock()

        var cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    0",
            "CRVAL1  =    \(raDeg)",
            "CRVAL2  =    \(decDeg)",
        ]
        if let cdMatrix {
            cards.append("CD1_1   = \(cdMatrix.cd11)")
            cards.append("CD1_2   = \(cdMatrix.cd12)")
            cards.append("CD2_1   = \(cdMatrix.cd21)")
            cards.append("CD2_2   = \(cdMatrix.cd22)")
        }
        cards.append("END")

        let data = buildHeaderData(cards)
        let url = workDir.appendingPathComponent("solved.fit")
        try data.write(to: url)
        return url
    }
}

/// Always fails -- used to verify a per-frame failure is recorded and the
/// batch continues rather than aborting.
private struct ThrowingMockBackend: SolveBackend {
    struct Boom: Error {}
    func solve(originalPath: String, workDir: URL) throws -> URL {
        throw Boom()
    }
}

// MARK: - selectFrames (frame selection)

@Test func selectFramesPicksTheMiddleFrameWhenMaxCountIsOne() throws {
    let files = (1...5).map { i in
        FileRecord(id: Int64(i), path: "f\(i).cr3", size: 0, mtime: 0, ext: "cr3", kind: "raw", area: .sessions, target: "T", sessionDate: "2026-01-01", role: .light, scannedAt: 0)
    }
    let picked = PlateSolver.selectFrames(from: files, maxCount: 1)
    #expect(picked.count == 1)
    #expect(picked[0].path == "f3.cr3", "index count/2 == 2 of the path-sorted 5-element list")
}

@Test func selectFramesReturnsEverythingWhenMaxCountExceedsCandidateCount() {
    let files = (1...2).map { i in
        FileRecord(id: Int64(i), path: "f\(i).cr3", size: 0, mtime: 0, ext: "cr3", kind: "raw", area: .sessions, target: "T", sessionDate: "2026-01-01", role: .light, scannedAt: 0)
    }
    let picked = PlateSolver.selectFrames(from: files, maxCount: 5)
    #expect(picked.count == 2)
}

@Test func selectFramesReturnsEmptyForEmptyCandidates() {
    #expect(PlateSolver.selectFrames(from: [], maxCount: 1).isEmpty)
}

// MARK: - solveTarget: selection + skip + force

@Test func solveTargetSkipsFramesThatAlreadyHaveCoordinates() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    let fileID = try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-01-01/lights/a.cr3", target: "T")
    // Already solved -- must be skipped, not re-solved, when force is false.
    try fixture.db.updateSolvedWCS(fileID: fileID, ra: 1.0, dec: 2.0, scale: nil, rotation: nil)

    let backend = RecordingMockBackend()
    let solver = PlateSolver(backend: backend)
    let summary = try solver.solveTarget("T", db: fixture.db, config: fixture.config)

    #expect(summary.attempted == 0)
    #expect(summary.skipped == 1)
    #expect(summary.solved == 0)
    #expect(backend.workDirs.isEmpty)
}

@Test func solveTargetForceReSolvesFramesThatAlreadyHaveCoordinates() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    let fileID = try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-01-01/lights/a.cr3", target: "T")
    try fixture.db.updateSolvedWCS(fileID: fileID, ra: 1.0, dec: 2.0, scale: nil, rotation: nil)

    let backend = RecordingMockBackend(raDeg: 99.0, decDeg: 45.0)
    let solver = PlateSolver(backend: backend)
    let summary = try solver.solveTarget("T", db: fixture.db, config: fixture.config, force: true)

    #expect(summary.attempted == 1)
    #expect(summary.skipped == 0, "force ignores the pre-existing coordinate entirely")
    #expect(summary.solved == 1)

    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.solvedRA == 99.0, "force must overwrite the stale coordinate with the freshly solved one")
    #expect(meta?.solvedDec == 45.0)
}

@Test func solveTargetPicksTheMiddleUnsolvedFrameOfEachSession() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    var fileIDs: [Int64] = []
    for i in 1...5 {
        let id = try fixture.addUnsolvedCR3Light(
            relativePath: "sessions/T/2026-01-01/lights/f\(i).cr3", target: "T"
        )
        fileIDs.append(id)
    }

    let backend = RecordingMockBackend()
    let solver = PlateSolver(backend: backend)
    let summary = try solver.solveTarget("T", db: fixture.db, config: fixture.config, maxFramesPerSession: 1)

    #expect(summary.attempted == 1, "maxFramesPerSession defaults to 1")
    #expect(summary.solved == 1)

    // Exactly the middle (path-sorted index count/2 == 2) frame's fits_meta
    // must be the one that got a solved coordinate -- the other 4 stay nil.
    let solvedCount = try fileIDs.map { try fixture.db.fitsMeta(fileID: $0)?.solvedRA }.filter { $0 != nil }.count
    #expect(solvedCount == 1)
    let middleMeta = try fixture.db.fitsMeta(fileID: fileIDs[2])
    #expect(middleMeta?.solvedRA != nil, "f3.cr3 (index 2 of the 5 path-sorted frames) must be the one solved")
}

// MARK: - solveTarget: mock solve persists solved_* columns

@Test func solveTargetPersistsSolvedRADecScaleAndRotationFromMockBackend() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    let fileID = try fixture.addUnsolvedCR3Light(relativePath: "sessions/M45/2026-01-01/lights/a.cr3", target: "M45")

    // A rotation-free CD matrix with scale exactly 2.0"/px (same
    // ground-truthing trick `FieldGeometryTests.frameFieldComputesRotation
    // AndScaleFromCDMatrix` uses) so both the persisted scale AND rotation
    // are exactly known.
    let scaleDeg = 2.0 / 3600
    let cd = (cd11: scaleDeg, cd12: 0.0, cd21: 0.0, cd22: scaleDeg)
    let backend = RecordingMockBackend(raDeg: 56.75, decDeg: 24.1, cdMatrix: cd)
    let solver = PlateSolver(backend: backend)

    let summary = try solver.solveTarget("M45", db: fixture.db, config: fixture.config)
    #expect(summary.solved == 1)
    #expect(summary.failed == 0)

    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(abs((meta?.solvedRA ?? 0) - 56.75) < 1e-9)
    #expect(abs((meta?.solvedDec ?? 0) - 24.1) < 1e-9)
    #expect(abs((meta?.solvedScaleArcsec ?? 0) - 2.0) < 1e-9)
    #expect(abs((meta?.solvedRotationDeg ?? 0) - 0.0) < 1e-9)
}

// MARK: - solveTarget: per-frame failure recorded, batch continues

@Test func solveTargetRecordsPerFrameFailureAndContinuesTheBatch() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-01-01/lights/a.cr3", target: "T")
    try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-02-02/lights/b.cr3", target: "T", sessionDate: "2026-02-02")

    let solver = PlateSolver(backend: ThrowingMockBackend())
    let summary = try solver.solveTarget("T", db: fixture.db, config: fixture.config, maxFramesPerSession: 1)

    #expect(summary.attempted == 2, "one candidate per session date")
    #expect(summary.failed == 2)
    #expect(summary.solved == 0)
}

// MARK: - solveTarget: summary counts

@Test func solveTargetReturnsZeroedSummaryWhenTargetHasNoFramesAtAll() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    let solver = PlateSolver(backend: RecordingMockBackend())
    let summary = try solver.solveTarget("NoSuchTarget", db: fixture.db, config: fixture.config)

    #expect(summary.attempted == 0)
    #expect(summary.solved == 0)
    #expect(summary.failed == 0)
    #expect(summary.skipped == 0)
}

// MARK: - solveTarget: workDir isolation

@Test func solveTargetWorkDirIsAlwaysUnderTemporaryDirectoryNeverTheLibrary() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-01-01/lights/a.cr3", target: "T")

    let backend = RecordingMockBackend()
    let solver = PlateSolver(backend: backend)
    _ = try solver.solveTarget("T", db: fixture.db, config: fixture.config)

    #expect(backend.workDirs.count == 1)
    let workDir = try #require(backend.workDirs.first)
    let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
    #expect(workDir.standardizedFileURL.path.hasPrefix(tempRoot))
    #expect(!workDir.standardizedFileURL.path.hasPrefix(fixture.libraryDir.standardizedFileURL.path))
}

// MARK: - solveTarget: progress callback

@Test func solveTargetProgressCallbackReportsEachAttemptedFrame() throws {
    let fixture = try PlateSolveFixture.make()
    defer { fixture.cleanup() }

    try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-01-01/lights/a.cr3", target: "T")
    try fixture.addUnsolvedCR3Light(relativePath: "sessions/T/2026-02-02/lights/b.cr3", target: "T", sessionDate: "2026-02-02")

    final class ProgressRecorder: @unchecked Sendable {
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

    let recorder = ProgressRecorder()
    let solver = PlateSolver(backend: RecordingMockBackend())
    _ = try solver.solveTarget("T", db: fixture.db, config: fixture.config) { done, total in
        recorder.record(done, total)
    }

    let calls = recorder.calls
    #expect(calls.count == 2)
    #expect(calls.map(\.done) == [1, 2])
    #expect(calls.allSatisfy { $0.total == 2 })
}

// MARK: - PlateSolver.init(sirilPath:) error contract

@Test func plateSolverInitThrowsSirilNotFoundForNonexistentPath() {
    let bogusPath = "/definitely/not/a/real/binary/siril-cli"
    do {
        _ = try PlateSolver(sirilPath: bogusPath)
        Issue.record("expected AstroError.sirilNotFound")
    } catch let AstroError.sirilNotFound(path) {
        #expect(path == bogusPath)
    } catch {
        Issue.record("expected AstroError.sirilNotFound, got \(error)")
    }
}

// MARK: - SirilSolveBackend.buildScript

@Test func sirilSolveBackendBuildScriptContainsRequiresCdLoadPlatesolveSaveClose() throws {
    let workDir = URL(fileURLWithPath: "/tmp/astrotool-solve-test", isDirectory: true)
    let script = try SirilSolveBackend.buildScript(originalPath: "/tmp/some frame.cr3", workDir: workDir)
    #expect(script.contains("requires 1.2.0"))
    #expect(script.contains("cd \"/tmp/astrotool-solve-test\""))
    #expect(script.contains("load \"/tmp/some frame.cr3\""))
    #expect(script.contains("platesolve"))
    #expect(script.contains("save solved"))
    #expect(script.contains("close"))
}

@Test func sirilSolveBackendBuildScriptRejectsPathContainingDoubleQuote() {
    let workDir = URL(fileURLWithPath: "/tmp/astrotool-solve-test", isDirectory: true)
    let evilPath = "/tmp/evil\".cr3\nclose\nrequires 1.2.0\nload \"/etc/passwd"
    #expect(throws: SolveBackendError.self) {
        _ = try SirilSolveBackend.buildScript(originalPath: evilPath, workDir: workDir)
    }
}
