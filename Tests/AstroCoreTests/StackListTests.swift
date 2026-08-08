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
    accepted: Bool? = nil,
    filter: String? = nil,
    fwhm: Double? = nil
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

    if hasRating || score != nil || fwhm != nil {
        try db.upsertRating(
            RatingRecord(fileID: fileID, fwhm: fwhm, score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
        )
    }
    if let accepted {
        try db.upsertUserVerdict(
            UserVerdictRecord(fileID: fileID, accepted: accepted, source: "dssfilelist", recordedAt: 1_700_000_300)
        )
    }
    if let filter {
        try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, filter: filter))
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

// MARK: - 11. Per-filter grouping (R11-T11 / F15)

@Test func selectGroupsByFilterSoARarerWeakerFilterIsNotSqueezedOutByABiggerBetterFilter() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // Ha: 10 frames, all scored HIGHER than every OIII frame below.
    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha\(i)", score: Double(i), filter: "Ha")
    }
    // OIII: only 4 frames, all scored far lower than any Ha frame -- a
    // pooled, session-wide ranking at keepFraction 0.5 would drop nearly
    // all of them in favor of Ha's better scores.
    for i in 1...4 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "oiii\(i)", score: Double(i) / 10, filter: "OIII")
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.5, db: db, config: config)

    #expect(selection.totalFrames == 14)
    let perFilter = try #require(selection.perFilter)
    #expect(perFilter.count == 2)

    let ha = try #require(perFilter.first { $0.filter == "Ha" })
    #expect(ha.totalFrames == 10)
    #expect(ha.selectedFrames == 5) // ceil(0.5 * 10) == 5

    let oiii = try #require(perFilter.first { $0.filter == "OIII" })
    #expect(oiii.totalFrames == 4)
    // ceil(0.5 * 4) == 2, but the "never fewer than 3 when available" floor
    // wins -- applied to OIII's OWN remaining count, not the session's.
    #expect(oiii.selectedFrames == 3)

    #expect(selection.selectedFrames == 8)
    #expect(selection.criteria.contains { $0.hasPrefix("[Ha]") })
    #expect(selection.criteria.contains { $0.hasPrefix("[OIII]") })
}

@Test func selectNeverKeepsFewerThanThreePerFilterWhenAvailable() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha\(i)", score: Double(i), filter: "Ha")
    }
    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "oiii\(i)", score: Double(i), filter: "OIII")
    }

    // ceil(0.1 * 5) == 1 per filter, but each filter's own floor of 3 wins.
    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.1, db: db, config: config)

    let perFilter = try #require(selection.perFilter)
    for entry in perFilter {
        #expect(entry.selectedFrames == 3)
    }
    #expect(selection.selectedFrames == 6)
}

@Test func selectAppliesKeepFractionPerFilterOverride() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha\(i)", score: Double(i), filter: "Ha")
    }
    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "oiii\(i)", score: Double(i), filter: "OIII")
    }

    let selection = try StackList.select(
        target: "T1", date: "2026-01-10", keepFraction: 0.5,
        keepFractionPerFilter: ["OIII": 1.0], db: db, config: config
    )

    let perFilter = try #require(selection.perFilter)
    let ha = try #require(perFilter.first { $0.filter == "Ha" })
    #expect(ha.selectedFrames == 5) // no override -- falls back to the common 0.5

    let oiii = try #require(perFilter.first { $0.filter == "OIII" })
    #expect(oiii.selectedFrames == 10) // overridden to 1.0 -- keeps everything
}

@Test func selectSingleNamedFilterSessionKeepsPerFilterNilAndCriteriaUnprefixed() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s\(i)", score: Double(i), filter: "Ha")
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.5, db: db, config: config)

    // Byte-identical-shape backward compatibility: a session shot entirely
    // through one named filter behaves exactly like it did before per-filter
    // grouping existed.
    #expect(selection.perFilter == nil)
    #expect(selection.selectedFrames == 5)
    #expect(!selection.criteria.contains { $0.hasPrefix("[") })
}

@Test func selectFilterlessSessionKeepsPerFilterNil() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "u\(i)", score: Double(i))
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    #expect(selection.perFilter == nil)
}

@Test func selectBucketsFilterlessFramesSeparatelyFromNamedFilters() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha\(i)", score: Double(i), filter: "Ha")
    }
    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "u\(i)", score: Double(i))
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    let perFilter = try #require(selection.perFilter)
    #expect(Set(perFilter.map(\.filter)) == Set(["Ha", FilterBreakdownQueries.noFilterSentinel]))
}

// MARK: - 12. manifest.csv content (R11-T11 / F15)

@Test func selectPopulatesManifestWithFilterScoreFwhmSessionDateAndVerdict() throws {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.rating.outlierZScore = 2.0

    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "good", score: 0.5, filter: "Ha", fwhm: 2.4)
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "rejected", score: 0.3, accepted: false, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "outlier", score: -3.0, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "unrated", filter: "Ha")

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)

    #expect(selection.manifest.count == 4)
    let byFile = Dictionary(uniqueKeysWithValues: selection.manifest.map { ($0.file, $0) })

    let good = try #require(byFile["sessions/T1/2026-01-10/lights/good.fit"])
    #expect(good.filter == "Ha")
    #expect(good.score == 0.5)
    #expect(good.fwhmPx == 2.4)
    #expect(good.sessionDate == "2026-01-10")
    #expect(good.verdict == "selected")

    #expect(byFile["sessions/T1/2026-01-10/lights/rejected.fit"]?.verdict == "rejected_verdict")
    #expect(byFile["sessions/T1/2026-01-10/lights/outlier.fit"]?.verdict == "rejected_outlier")
    #expect(byFile["sessions/T1/2026-01-10/lights/unrated.fit"]?.verdict == "selected")
}

@Test func selectManifestMarksKeepFractionCutFramesAsRejectedKeepfraction() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s\(i)", score: Double(i))
    }

    let selection = try StackList.select(target: "T1", date: "2026-01-10", keepFraction: 0.5, db: db, config: config)

    let rejectedByKeepFraction = selection.manifest.filter { $0.verdict == "rejected_keepfraction" }
    #expect(rejectedByKeepFraction.count == 5)
    #expect(Set(rejectedByKeepFraction.map(\.file)) == Set(selection.rejectedPaths))
}

// MARK: - 13. Multi-filter export tree (R11-T11 / F15)

@Test func exportMultiFilterCreatesPerFilterLightsSubfoldersDssfilelistAndSsf() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/ha1.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/ha2.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/oiii1.fit")
    try fixture.scan()

    for name in ["ha1", "ha2"] {
        let id = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/\(name).fit"))
        try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: id, filter: "Ha"))
    }
    let oiiiID = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/oiii1.fit"))
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: oiiiID, filter: "OIII"))

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(selection.perFilter != nil)

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)

    for name in ["ha1", "ha2"] {
        let linkedURL = stacklistDir.appendingPathComponent("lights/Ha/\(name).fit")
        #expect(FileManager.default.fileExists(atPath: linkedURL.path))
    }
    let oiiiLinkedURL = stacklistDir.appendingPathComponent("lights/OIII/oiii1.fit")
    #expect(FileManager.default.fileExists(atPath: oiiiLinkedURL.path))

    // No shared flat stack.* pair when there's more than one filter bucket.
    #expect(!FileManager.default.fileExists(atPath: stacklistDir.appendingPathComponent("stack.dssfilelist").path))
    #expect(!FileManager.default.fileExists(atPath: stacklistDir.appendingPathComponent("stack.ssf").path))

    let haDssURL = stacklistDir.appendingPathComponent("T1-2026-01-10-Ha.dssfilelist")
    let haDssText = try String(contentsOf: haDssURL, encoding: .utf8)
    #expect(haDssText.contains("lights/Ha/ha1.fit"))
    #expect(haDssText.contains("lights/Ha/ha2.fit"))
    #expect(!haDssText.contains("oiii1"))

    let haSsfURL = stacklistDir.appendingPathComponent("T1-2026-01-10-Ha.ssf")
    let haSsfText = try String(contentsOf: haSsfURL, encoding: .utf8)
    #expect(haSsfText.contains("# Filter: Ha"))
    #expect(haSsfText.contains("cd \"\(stacklistDir.appendingPathComponent("lights/Ha").path)\""))
    #expect(haSsfText.contains("convert light -out=."))

    let oiiiDssURL = stacklistDir.appendingPathComponent("T1-2026-01-10-OIII.dssfilelist")
    #expect(FileManager.default.fileExists(atPath: oiiiDssURL.path))
    let oiiiSsfURL = stacklistDir.appendingPathComponent("T1-2026-01-10-OIII.ssf")
    let oiiiSsfText = try String(contentsOf: oiiiSsfURL, encoding: .utf8)
    #expect(oiiiSsfText.contains("# Filter: OIII"))

    let manifestURL = stacklistDir.appendingPathComponent("manifest.csv")
    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
    let manifestLines = manifestText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
    #expect(manifestLines[0] == "file,filter,score,fwhm_px,session_date,verdict")
    #expect(manifestLines.count == 4) // header + 3 frames across both filters
}

@Test func exportWritesManifestCSVAlongsideFlatSingleBucketExport() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeLight("sessions/T1/2026-01-10/lights/l\(i).fit")
    }
    try fixture.scan()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)

    let manifestURL = stacklistDir.appendingPathComponent("manifest.csv")
    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
    let lines = manifestText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
    #expect(lines.count == 4) // header + 3 frames
    #expect(lines[0] == "file,filter,score,fwhm_px,session_date,verdict")
    for i in 1...3 {
        #expect(manifestText.contains("sessions/T1/2026-01-10/lights/l\(i).fit"))
    }
    #expect(manifestText.contains(FilterBreakdownQueries.noFilterSentinel))
}

@Test func exportToDirectoryMultiFilterMirrorsPerFilterTreeShape() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/ha1.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/oiii1.fit")
    try fixture.scan()

    let haID = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/ha1.fit"))
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: haID, filter: "Ha"))
    let oiiiID = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/oiii1.fit"))
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: oiiiID, filter: "OIII"))

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    let destDir = try makeTempDir("out")
    defer { try? FileManager.default.removeItem(at: destDir) }

    _ = try StackList.exportToDirectory(selection, destDir: destDir, sourceRoot: fixture.libraryDir)

    #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("lights/Ha/ha1.fit").path))
    #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("lights/OIII/oiii1.fit").path))
    #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("T1-2026-01-10-Ha.dssfilelist").path))
    #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("T1-2026-01-10-OIII.ssf").path))
    #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("manifest.csv").path))
    #expect(!FileManager.default.fileExists(atPath: destDir.appendingPathComponent("stack.dssfilelist").path))
}
