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
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard).directory

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
    // R11-T17: the `cd` target must be the lights/ folder itself -- Siril's
    // `convert` reads only the cwd, never a subfolder -- NOT stacklistDir
    // (its parent), which was the actual bug the T11 agent flagged.
    let lightsDir = stacklistDir.appendingPathComponent("lights", isDirectory: true)
    #expect(ssfText.contains("cd \"\(lightsDir.path)\""))
    #expect(!ssfText.contains("cd \"\(stacklistDir.path)\""))
    #expect(!ssfText.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rm") })
}

// MARK: - 9b. .ssf `cd` target always matches the actual frame folder (R11-T17)

/// The T11 agent flagged a suspected bug: the flat/single-filter `.ssf`'s
/// `cd` line pointed at the stacklist root (`lights/`'s PARENT) instead of
/// `lights/` itself, so Siril's `convert light -out=.` -- which only ever
/// reads the current working directory -- would find zero frames. This test
/// pins the fix by parsing the actual `cd "..."` line out of the generated
/// script and asserting it is a directory that really exists AND really
/// contains the hardlinked frames, for both the flat (single/no-filter) and
/// the per-filter (R11-T11) export shapes -- a regression here would mean
/// `convert` fails (or silently no-ops) the moment a user runs the script.
@Test func ssfCdTargetIsTheActualFrameFolderForBothFlatAndPerFilterExports() throws {
    func cdTarget(in ssfText: String) throws -> String {
        let line = try #require(ssfText.split(separator: "\n").first { $0.hasPrefix("cd \"") })
        var target = String(line.dropFirst("cd \"".count))
        target = String(target.dropLast()) // trailing closing quote
        return target
    }

    // -- Flat/no-filter session (single bucket, perFilter == nil) --
    do {
        let fixture = try StackListExportFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeLight("sessions/T1/2026-01-10/lights/l1.fit")
        try fixture.writeLight("sessions/T1/2026-01-10/lights/l2.fit")
        try fixture.writeLight("sessions/T1/2026-01-10/lights/l3.fit")
        try fixture.scan()

        let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
        #expect(selection.perFilter == nil)
        let writeGuard = WriteGuard(root: fixture.libraryDir)
        let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard).directory

        let ssfText = try String(contentsOf: stacklistDir.appendingPathComponent("stack.ssf"), encoding: .utf8)
        let cdPath = try cdTarget(in: ssfText)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cdPath, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let frameNames = Set(try FileManager.default.contentsOfDirectory(atPath: cdPath))
        #expect(frameNames == Set(["l1.fit", "l2.fit", "l3.fit"]))
    }

    // -- Per-filter session (regression: T11 already got this branch right) --
    do {
        let fixture = try StackListExportFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeLight("sessions/T1/2026-01-11/lights/ha1.fit")
        try fixture.writeLight("sessions/T1/2026-01-11/lights/oiii1.fit")
        try fixture.scan()
        let haID = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-11/lights/ha1.fit"))
        try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: haID, filter: "Ha"))
        let oiiiID = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-11/lights/oiii1.fit"))
        try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: oiiiID, filter: "OIII"))

        let selection = try StackList.select(target: "T1", date: "2026-01-11", db: fixture.db, config: fixture.config)
        let perFilter = try #require(selection.perFilter)
        #expect(perFilter.count == 2)
        let writeGuard = WriteGuard(root: fixture.libraryDir)
        let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard).directory

        for (filter, expectedFrame) in [("Ha", "ha1.fit"), ("OIII", "oiii1.fit")] {
            let ssfText = try String(
                contentsOf: stacklistDir.appendingPathComponent("T1-2026-01-11-\(filter).ssf"), encoding: .utf8
            )
            let cdPath = try cdTarget(in: ssfText)

            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: cdPath, isDirectory: &isDir))
            #expect(isDir.boolValue)
            let frameNames = try FileManager.default.contentsOfDirectory(atPath: cdPath)
            #expect(frameNames == [expectedFrame])
        }
    }
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

    let firstResult = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)
    let firstDir = firstResult.directory
    let firstInode = try inode(firstDir.appendingPathComponent("lights/l1.fit"))
    #expect(firstResult.removedStaleCount == 0)

    // Re-export the same selection -- must not throw, must not disturb the
    // already-linked frames, must leave exactly the same set of files, and
    // (R12-U2, point 2d) the re-export sync must not consider any of them
    // stale since the selection is unchanged.
    let secondResult = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)
    let secondDir = secondResult.directory
    let secondInode = try inode(secondDir.appendingPathComponent("lights/l1.fit"))
    #expect(secondResult.removedStaleCount == 0)

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

// MARK: - R12-U2 (point 3): --keep-filter case-insensitive matching

@Test func selectMatchesKeepFractionPerFilterOverrideCaseInsensitively() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha\(i)", score: Double(i), filter: "Ha")
    }
    for i in 1...10 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "oiii\(i)", score: Double(i), filter: "OIII")
    }

    // Deliberately wrong case ("ha"/"OIII " with padding) on both sides --
    // must still hit the override exactly like an exact-case match would.
    let selection = try StackList.select(
        target: "T1", date: "2026-01-10", keepFraction: 0.5,
        keepFractionPerFilter: ["ha": 1.0, "  oiii  ": 0.3], db: db, config: config
    )

    let perFilter = try #require(selection.perFilter)
    let ha = try #require(perFilter.first { $0.filter == "Ha" })
    #expect(ha.selectedFrames == 10, "\"ha\" must override the actual \"Ha\" bucket despite the case difference")

    let oiii = try #require(perFilter.first { $0.filter == "OIII" })
    #expect(oiii.selectedFrames == 3, "ceil(0.3 * 10) == 3, from the padded/differently-cased \"  oiii  \" key")
}

@Test func selectPopulatesFilterKeysPresentRegardlessOfSingleOrMultiBucket() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    for i in 1...3 {
        try insertLight(db: db, target: "T1", date: "2026-01-10", name: "s\(i)", score: Double(i), filter: "Ha")
    }
    let singleBucket = try StackList.select(target: "T1", date: "2026-01-10", db: db, config: config)
    #expect(singleBucket.perFilter == nil, "single named-filter session -- perFilter stays nil (backward compat)")
    #expect(singleBucket.filterKeysPresent == ["Ha"], "but filterKeysPresent still reports the actual bucket key")

    try insertLight(db: db, target: "T1", date: "2026-01-11", name: "ha1", score: 1.0, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-11", name: "oiii1", score: 1.0, filter: "OIII")
    let multiBucket = try StackList.select(target: "T1", date: "2026-01-11", db: db, config: config)
    #expect(Set(multiBucket.filterKeysPresent) == Set(["Ha", "OIII"]))
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
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard).directory

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
    // R12-U2 (point 6): line 1 is the library_root comment.
    #expect(manifestLines[0].hasPrefix("# library_root: "))
    #expect(manifestLines[0].contains(fixture.libraryDir.standardizedFileURL.path))
    #expect(manifestLines[1] == "file,filter,score,fwhm_px,session_date,verdict,linked_name")
    #expect(manifestLines.count == 5) // comment + header + 3 frames across both filters
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
    let stacklistDir = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard).directory

    let manifestURL = stacklistDir.appendingPathComponent("manifest.csv")
    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
    let lines = manifestText.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
    #expect(lines.count == 5) // comment + header + 3 frames
    #expect(lines[0].hasPrefix("# library_root: "))
    #expect(lines[1] == "file,filter,score,fwhm_px,session_date,verdict,linked_name")
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

/// R11-T17: `exportToDirectory`'s flat/single-bucket branch had the exact
/// same `cd`-target bug as `export`'s (both passed the export root instead of
/// its own `lights/` subfolder) -- this pins the fix on the `--out PATH`
/// code path too (CLI `stacklist --out`), not just the default
/// `.astro_tool/stacklists/` location `export` writes to.
@Test func exportToDirectoryFlatSsfCdTargetIsTheLightsFolderItself() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/l1.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l2.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l3.fit")
    try fixture.scan()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(selection.perFilter == nil)

    let destDir = try makeTempDir("out-flat")
    defer { try? FileManager.default.removeItem(at: destDir) }
    _ = try StackList.exportToDirectory(selection, destDir: destDir, sourceRoot: fixture.libraryDir)

    let ssfText = try String(contentsOf: destDir.appendingPathComponent("stack.ssf"), encoding: .utf8)
    let expectedLightsDir = destDir.appendingPathComponent("lights", isDirectory: true)
    #expect(ssfText.contains("cd \"\(expectedLightsDir.path)\""))
    #expect(!ssfText.contains("cd \"\(destDir.path)\""))

    let frameNames = Set(try FileManager.default.contentsOfDirectory(atPath: expectedLightsDir.path))
    #expect(frameNames == Set(["l1.fit", "l2.fit", "l3.fit"]))
}

// MARK: - R12-U2 (point 1): EXDEV copy-fallback

/// The fallback decision itself (`linkOrCopyForExport`), exercised with an
/// INJECTED failing `link` closure -- a real cross-device volume isn't
/// available to a sandboxed test run, so this pins the behavior the same way
/// the ticket's own spec suggests ("a linkelő függvény injektálható
/// hibájával"): a fake `link` that throws a synthetic `EXDEV` `NSError`
/// stands in for the real cross-volume failure `exportToDirectory --out`
/// would hit.
@Test func linkOrCopyForExportFallsBackToCopyOnCrossDeviceLinkError() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    let sourceURL = fixture.libraryDir.appendingPathComponent("source.txt")
    try "cross-device content".write(to: sourceURL, atomically: true, encoding: .utf8)
    let destURL = fixture.libraryDir.appendingPathComponent("dest.txt")

    var linkAttempts = 0
    let didFallBack = try StackList.linkOrCopyForExport(
        sourceURL: sourceURL,
        destFileURL: destURL,
        link: { _, _ in
            linkAttempts += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
        },
        copy: { src, dst in try FileManager.default.copyItem(at: src, to: dst) }
    )

    #expect(didFallBack)
    #expect(linkAttempts == 1)
    #expect(FileManager.default.fileExists(atPath: destURL.path))
    #expect(try String(contentsOf: destURL, encoding: .utf8) == "cross-device content")
}

/// A NON-EXDEV link failure must propagate as-is -- the copy fallback is
/// strictly scoped to the one cross-device case, never a blanket "link
/// failed, try copying instead".
@Test func linkOrCopyForExportPropagatesNonCrossDeviceErrorsWithoutFallingBack() throws {
    struct SomeOtherError: Error {}
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }
    let sourceURL = fixture.libraryDir.appendingPathComponent("source.txt")
    try "x".write(to: sourceURL, atomically: true, encoding: .utf8)
    let destURL = fixture.libraryDir.appendingPathComponent("dest.txt")

    var copyAttempts = 0
    #expect(throws: SomeOtherError.self) {
        try StackList.linkOrCopyForExport(
            sourceURL: sourceURL, destFileURL: destURL,
            link: { _, _ in throw SomeOtherError() },
            copy: { _, _ in copyAttempts += 1 }
        )
    }
    #expect(copyAttempts == 0)
}

/// Same idempotent "already there, skip" rule every other hardlink call
/// site in this package follows -- neither `link` nor `copy` should even be
/// attempted when the destination already exists.
@Test func linkOrCopyForExportSkipsEntirelyWhenDestinationAlreadyExists() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }
    let sourceURL = fixture.libraryDir.appendingPathComponent("source.txt")
    try "x".write(to: sourceURL, atomically: true, encoding: .utf8)
    let destURL = fixture.libraryDir.appendingPathComponent("dest.txt")
    try "already-there".write(to: destURL, atomically: true, encoding: .utf8)

    var linkAttempts = 0
    let didFallBack = try StackList.linkOrCopyForExport(
        sourceURL: sourceURL, destFileURL: destURL,
        link: { _, _ in linkAttempts += 1 },
        copy: { _, _ in Issue.record("copy must not run when the destination already exists") }
    )
    #expect(!didFallBack)
    #expect(linkAttempts == 0)
    #expect(try String(contentsOf: destURL, encoding: .utf8) == "already-there")
}

@Test func isCrossDeviceLinkErrorRecognizesEXDEVDirectlyAndViaUnderlyingError() {
    let direct = NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    #expect(StackList.isCrossDeviceLinkError(direct))

    let wrapped = NSError(
        domain: NSCocoaErrorDomain, code: 512,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))]
    )
    #expect(StackList.isCrossDeviceLinkError(wrapped))

    let unrelated = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    #expect(!StackList.isCrossDeviceLinkError(unrelated))
}

// MARK: - R12-U2 (point 2): re-export sync removes stale hardlinks

@Test func reExportWithTighterKeepFractionRemovesNoLongerSelectedLinksAndLeavesSourceUntouched() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    for i in 1...10 {
        try fixture.writeLight("sessions/T1/2026-01-10/lights/s\(i).fit")
    }
    try fixture.scan()
    for i in 1...10 {
        let id = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/s\(i).fit"))
        try fixture.db.upsertRating(
            RatingRecord(fileID: id, score: Double(i), ratedAt: 1_700_000_200, inputSig: "sig-\(i)")
        )
    }

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let firstSelection = try StackList.select(
        target: "T1", date: "2026-01-10", keepFraction: 1.0, db: fixture.db, config: fixture.config
    )
    #expect(firstSelection.selectedFrames == 10)
    let firstResult = try StackList.export(firstSelection, root: fixture.libraryDir, using: writeGuard)
    #expect(firstResult.removedStaleCount == 0)

    let lightsDir = firstResult.directory.appendingPathComponent("lights", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path).count == 10)

    // (a) tighten --keep -- the tree must now match the new, SMALLER
    // selection exactly.
    let secondSelection = try StackList.select(
        target: "T1", date: "2026-01-10", keepFraction: 0.5, db: fixture.db, config: fixture.config
    )
    #expect(secondSelection.selectedFrames == 5)
    let secondResult = try StackList.export(secondSelection, root: fixture.libraryDir, using: writeGuard)

    #expect(secondResult.removedStaleCount == 5)
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path))
    let expectedRemaining = Set(secondSelection.selectedPaths.map { ($0 as NSString).lastPathComponent })
    #expect(remaining == expectedRemaining)

    // (c) the LIBRARY (source) files are never touched by the sync -- all
    // 10 originals must still be there regardless of what got unlinked from
    // the export tree.
    for i in 1...10 {
        let sourcePath = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/s\(i).fit")
        #expect(FileManager.default.fileExists(atPath: sourcePath.path), "source frame s\(i).fit must remain")
    }
}

@Test func reExportFromFlatToPerFilterRemovesStaleFlatLinks() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/l1.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l2.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/l3.fit")
    try fixture.scan()

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let flatSelection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(flatSelection.perFilter == nil)
    let flatResult = try StackList.export(flatSelection, root: fixture.libraryDir, using: writeGuard)
    let lightsDir = flatResult.directory.appendingPathComponent("lights", isDirectory: true)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path)) == Set(["l1.fit", "l2.fit", "l3.fit"]))

    // The SAME session gets FITS FILTER metadata -- the next `select()` now
    // sees more than one bucket, and `export` switches to the per-filter
    // `lights/<FILTER>/` tree shape.
    let id1 = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/l1.fit"))
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: id1, filter: "Ha"))
    let id2 = try #require(try fixture.db.fileID(path: "sessions/T1/2026-01-10/lights/l2.fit"))
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: id2, filter: "OIII"))

    let perFilterSelection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(perFilterSelection.perFilter != nil)
    let perFilterResult = try StackList.export(perFilterSelection, root: fixture.libraryDir, using: writeGuard)

    // (b) no stale FLAT link left directly under lights/.
    #expect(perFilterResult.removedStaleCount == 3)
    let topLevelAfter = try FileManager.default.contentsOfDirectory(atPath: lightsDir.path)
    #expect(!topLevelAfter.contains("l1.fit"))
    #expect(!topLevelAfter.contains("l2.fit"))
    #expect(!topLevelAfter.contains("l3.fit"))
    #expect(FileManager.default.fileExists(atPath: lightsDir.appendingPathComponent("Ha/l1.fit").path))
    #expect(FileManager.default.fileExists(atPath: lightsDir.appendingPathComponent("OIII/l2.fit").path))
}

@Test func syncLightsTreeNeverRemovesSymlinksOrDirectoriesOrAnythingOutsideGuardBase() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    let lightsDir = fixture.libraryDir.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: lightsDir, withIntermediateDirectories: true)

    let realFile = lightsDir.appendingPathComponent("stale.fit")
    try "stale".write(to: realFile, atomically: true, encoding: .utf8)

    let symlinkTarget = fixture.libraryDir.appendingPathComponent("outside.fit")
    try "outside".write(to: symlinkTarget, atomically: true, encoding: .utf8)
    let symlink = lightsDir.appendingPathComponent("linked-elsewhere.fit")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

    let emptySubDir = lightsDir.appendingPathComponent("EmptyFilterDir", isDirectory: true)
    try FileManager.default.createDirectory(at: emptySubDir, withIntermediateDirectories: true)

    let guardBase = fixture.libraryDir.appendingPathComponent(".astro_tool", isDirectory: true)
    let removed = try StackList.syncLightsTree(lightsDir: lightsDir, expectedRelativePaths: [], guardBase: guardBase)

    // Only the ONE real regular file with no matching expected path counts.
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: realFile.path))
    // The symlink itself is left alone (never a regular file), and its
    // target is completely untouched either way.
    #expect(FileManager.default.fileExists(atPath: symlinkTarget.path))
    // The (now-empty) subdirectory itself is never removed -- only files.
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: emptySubDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
}

// MARK: - R12-U2 (point 4): slug/filename collision handling

@Test func resolvedFilterSlugsFallsBackToNumberedNamesForEmptySlugs() {
    let perFilter = [
        StackFilterSelection(filter: "###", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
        StackFilterSelection(filter: "Ha", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
        StackFilterSelection(filter: "%%%", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
    ]

    let slugs = StackList.resolvedFilterSlugs(for: perFilter)

    #expect(slugs == ["filter_1", "Ha", "filter_2"])
}

@Test func resolvedFilterSlugsDisambiguatesTwoFiltersThatSanitizeToTheSameSlug() {
    let perFilter = [
        StackFilterSelection(filter: "Ha!", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
        StackFilterSelection(filter: "Ha?", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
        StackFilterSelection(filter: "Ha#", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
    ]

    let slugs = StackList.resolvedFilterSlugs(for: perFilter)

    // All three sanitize to plain "Ha" -- first keeps it, the rest get a
    // numeric suffix, and every slug is still distinct.
    #expect(slugs == ["Ha", "Ha_2", "Ha_3"])
    #expect(Set(slugs).count == 3)
}

@Test func resolvedFilterSlugsWithNoCollisionMatchesPlainSanitizeOutput() {
    let perFilter = [
        StackFilterSelection(filter: "Ha", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
        StackFilterSelection(filter: "OIII", totalFrames: 1, selectedFrames: 1, selectedPaths: [], rejectedPaths: []),
    ]

    #expect(StackList.resolvedFilterSlugs(for: perFilter) == ["Ha", "OIII"])
}

@Test func disambiguatedFileNamesKeepsFirstOccurrencePlainAndSuffixesLaterCollisions() {
    let paths = [
        "sessions/T1/2026-01-10/lights/part1/img_0001.fit",
        "sessions/T1/2026-01-10/lights/part2/img_0001.fit",
        "sessions/T1/2026-01-10/lights/img_0002.fit",
    ]

    let names = StackList.disambiguatedFileNames(forPaths: paths)

    #expect(names["sessions/T1/2026-01-10/lights/part1/img_0001.fit"] == "img_0001.fit")
    #expect(names["sessions/T1/2026-01-10/lights/part2/img_0001.fit"] == "part2__img_0001.fit")
    #expect(names["sessions/T1/2026-01-10/lights/img_0002.fit"] == "img_0002.fit")
}

@Test func disambiguatedFileNamesWithNoCollisionReturnsPlainBasenames() {
    let paths = ["a/x.fit", "b/y.fit", "c/z.fit"]
    let names = StackList.disambiguatedFileNames(forPaths: paths)
    #expect(names == ["a/x.fit": "x.fit", "b/y.fit": "y.fit", "c/z.fit": "z.fit"])
}

/// End-to-end: two different sessions' subfolders both contributing a
/// `img_0001.fit`-named frame to the SAME (single, filterless) bucket used
/// to mean the SECOND one silently never got linked at all (`WriteGuard`'s
/// idempotent "already there, skip" swallowed it). Now both actually land
/// on disk under distinct names, and the `.dssfilelist`/manifest both name
/// the ACTUAL link used.
@Test func exportDisambiguatesCollidingBasenamesWithinOneBucket() throws {
    let fixture = try StackListExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeLight("sessions/T1/2026-01-10/lights/part1/img_0001.fit")
    try fixture.writeLight("sessions/T1/2026-01-10/lights/part2/img_0001.fit")
    try fixture.scan()

    let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(selection.selectedFrames == 2)

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let result = try StackList.export(selection, root: fixture.libraryDir, using: writeGuard)

    let lightsDir = result.directory.appendingPathComponent("lights", isDirectory: true)
    let linkedNames = Set(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path))
    #expect(linkedNames == Set(["img_0001.fit", "part2__img_0001.fit"]), "both distinct source frames must actually be linked")

    let dssText = try String(contentsOf: result.directory.appendingPathComponent("stack.dssfilelist"), encoding: .utf8)
    #expect(dssText.contains("lights/img_0001.fit"))
    #expect(dssText.contains("lights/part2__img_0001.fit"))

    let manifestText = try String(contentsOf: result.directory.appendingPathComponent("manifest.csv"), encoding: .utf8)
    #expect(manifestText.contains("sessions/T1/2026-01-10/lights/part1/img_0001.fit"))
    #expect(manifestText.contains("sessions/T1/2026-01-10/lights/part2/img_0001.fit"))
    #expect(manifestText.contains("part2__img_0001.fit"), "manifest's linked_name column must carry the disambiguated name")
}
