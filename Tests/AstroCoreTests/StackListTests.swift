import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixtures

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-stacklist-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Pure in-memory DB fixture, same spirit as `SessionQualityTests`' -- these
/// tests build exactly the `files`/`fits_meta`/`ratings`/`user_verdicts` rows
/// `StackList.select` reads, with no scanner and no real image files.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one light-frame row and returns its `fileID`. Uses the fileID
/// itself as a fake `inode` (same trick `SessionQualityTests` uses) so
/// `FrameSet`'s dedup never collapses these synthetic rows into each other.
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    score: Double? = nil,
    hasRating: Bool = false,
    accepted: Bool? = nil
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)

    if hasRating || score != nil {
        try db.upsertRating(
            RatingRecord(fileID: fileID, score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
        )
    }
    if let accepted {
        try db.upsertUserVerdict(
            UserVerdictRecord(fileID: fileID, accepted: accepted, source: "dssfilelist", recordedAt: 1_700_000_300)
        )
    }
    return fileID
}

// MARK: - 1. No usable frames -> empty selection

@Test func selectReturnsEmptySelectionWhenNoUsableFrames() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    #expect(selection.totalFrames == 0)
    #expect(selection.selectedFrames == 0)
    #expect(selection.selectedPaths.isEmpty)
    #expect(selection.rejectedPaths.isEmpty)
    #expect(!selection.criteria.isEmpty)
}

// MARK: - 2. DSS-rejected verdict -> hard drop

@Test func selectDropsFramesRejectedByUserVerdict() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "a", accepted: true)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "b", accepted: false)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "c")

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    #expect(selection.totalFrames == 3)
    #expect(!selection.selectedPaths.contains("sessions/T1/2026-01-10/lights/b.fit"))
    #expect(selection.rejectedPaths.contains("sessions/T1/2026-01-10/lights/b.fit"))
    #expect(selection.criteria.contains("DSS-ben elvetett: 1"))
}

// MARK: - 3. Outlier score -> hard drop

@Test func selectDropsOutlierScoredFrames() throws {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.rating.outlierZScore = 2.0

    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "good1", score: 0.5)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "good2", score: 0.3)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "bad", score: -3.0)

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    #expect(!selection.selectedPaths.contains("sessions/T1/2026-01-10/lights/bad.fit"))
    #expect(selection.rejectedPaths.contains("sessions/T1/2026-01-10/lights/bad.fit"))
    #expect(selection.criteria.contains("kiugróan gyenge: 1"))
}

// MARK: - 4. Unrated frames are never dropped, regardless of keepFraction

@Test func selectNeverDropsUnratedFramesEvenWithLowKeepFraction() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "u\(i)")
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.1, db: db, config: config)

    #expect(selection.totalFrames == 10)
    #expect(selection.selectedFrames == 10)
    #expect(selection.rejectedPaths.isEmpty)
    #expect(selection.criteria.contains("nem pontozott: 10 — megtartva"))
}

// MARK: - 5. keepFraction cuts the SCORED remainder

@Test func selectAppliesKeepFractionToScoredFramesOnly() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // 10 distinctly scored frames, descending score s10 (best) .. s1 (worst).
    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s\(i)", score: Double(i))
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.5, db: db, config: config)

    // ceil(0.5 * 10) == 5 -> top 5 scores (s6..s10) selected.
    #expect(selection.selectedFrames == 5)
    let expectedSelected = Set((6...10).map { "sessions/T1/2026-01-10/lights/s\($0).fit" })
    #expect(Set(selection.selectedPaths) == expectedSelected)
    let expectedRejected = Set((1...5).map { "sessions/T1/2026-01-10/lights/s\($0).fit" })
    #expect(Set(selection.rejectedPaths) == expectedRejected)
}

// MARK: - 6. Never fewer than 3 kept when available

@Test func selectNeverKeepsFewerThanThreeScoredFramesWhenAvailable() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s\(i)", score: Double(i))
    }

    // ceil(0.1 * 5) == 1, but the floor of 3 wins.
    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.1, db: db, config: config)

    #expect(selection.selectedFrames == 3)
    let expectedSelected = Set((3...5).map { "sessions/T1/2026-01-10/lights/s\($0).fit" })
    #expect(Set(selection.selectedPaths) == expectedSelected)
}

// MARK: - 7. Fewer than 3 remaining -> keep all

@Test func selectKeepsAllWhenFewerThanThreeRemain() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s1", score: 1.0)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s2", score: 2.0)

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.1, db: db, config: config)

    #expect(selection.selectedFrames == 2)
    #expect(selection.rejectedPaths.isEmpty)
}

// MARK: - 8. Codable round-trip

@Test func stackSelectionRoundTripsThroughJSON() throws {
    let selection = StackSelection(
        target: "T1", date: "2026-01-10", totalFrames: 3, selectedFrames: 2,
        criteria: ["használható: 3"],
        selectedPaths: ["sessions/T1/2026-01-10/lights/a.fit", "sessions/T1/2026-01-10/lights/b.fit"],
        rejectedPaths: ["sessions/T1/2026-01-10/lights/c.fit"]
    )
    let data = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(StackSelection.self, from: data)
    #expect(decoded.target == selection.target)
    #expect(decoded.selectedPaths == selection.selectedPaths)
    #expect(decoded.rejectedPaths == selection.rejectedPaths)
}

// MARK: - Export fixture (real files + scanner, same style as CalibLinkerTests)

private struct StackListExportFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> StackListExportFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return StackListExportFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeLight(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy light content: \(relativePath)".write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

private func inode(_ url: URL) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

// MARK: - 9. End-to-end export: hardlinks, .dssfilelist, .ssf

@Test func exportEndToEndCreatesHardlinksDssfilelistAndSsf() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeLight("sessions/T1/2026-01-10/lights/l\(i).fit")
    }
    try fixture.scan()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(selection.selectedFrames == 3)

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)

    let expectedDir = fixture.libraryDir.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10", isDirectory: true)
    #expect(stacklistDir.standardizedFileURL.path == expectedDir.standardizedFileURL.path)

    for i in 1...3 {
        let sourceURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/l\(i).fit")
        let linkedURL = stacklistDir.appendingPathComponent("lights/l\(i).fit")
        #expect(FileManager.default.fileExists(atPath: linkedURL.path))
        #expect(try inode(linkedURL) == inode(sourceURL))
    }

    let dssURL = stacklistDir.appendingPathComponent("stack.dssfilelist")
    let dssText = try String(contentsOf: dssURL, encoding: .utf8)
    let dssLines = dssText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(dssLines[0] == "DSS file list")
    #expect(dssLines[1] == "CHECKED\tTYPE\tFILE")
    let dataRows = Set(dssLines.dropFirst(2).filter { !$0.isEmpty })
    #expect(dataRows == Set((1...3).map { "1\tlight\tlights/l\($0).fit" }))

    let ssfURL = stacklistDir.appendingPathComponent("stack.ssf")
    let ssfText = try String(contentsOf: ssfURL, encoding: .utf8)
    #expect(ssfText.contains("requires 1.2.0"))
    #expect(ssfText.contains("convert light -out=."))
    #expect(ssfText.contains("register light"))
    #expect(ssfText.contains("stack r_light rej 3 3 -norm=addscale -out=result"))
    #expect(ssfText.contains("cd \"\(stacklistDir.path)\""))
    #expect(!ssfText.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rm") })
}

// MARK: - 10. Idempotent re-export

@Test func exportIsIdempotentOnRerun() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/l1.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l2.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l3.fit")
    try fixture.scan()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    let writeGuard = WriteGuard(root: fixture.libraryDir)

    let firstDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)
    let firstInode = try inode(firstDir.appendingPathComponent("lights/l1.fit"))

    // Re-export the same selection -- must not throw, must not disturb the
    // already-linked frames, and must leave exactly the same set of files.
    let secondDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)
    let secondInode = try inode(secondDir.appendingPathComponent("lights/l1.fit"))

    #expect(firstDir.standardizedFileURL.path == secondDir.standardizedFileURL.path)
    #expect(firstInode == secondInode)

    let lightsDir = firstDir.appendingPathComponent("lights", isDirectory: true)
    let contents = try FileManager.default.contentsOfDirectory(atPath: lightsDir.path)
    #expect(Set(contents) == Set(["l1.fit", "l2.fit", "l3.fit"]))
}
