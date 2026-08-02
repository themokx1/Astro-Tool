import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-audit-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library, scanned into a fresh DB, with one extra
/// generated flat-frame FITS file dropped into a `lights/` folder (so
/// `calib-in-wrong-dir` has something real to find), then re-scanned so its
/// FITS meta is captured before the audit runs.
private struct AuditFixture {
    let libraryDir: URL
    let dbDir: URL
    let root: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> AuditFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let root = try Fixtures.makeMessyLibrary(in: libraryDir)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = root.path

        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()

        let flatStrayPath = "sessions/M45_Pleiades/2026-01-10/lights/flat_stray.fit"
        let flatStrayURL = root.appendingPathComponent(flatStrayPath)
        let headerData = buildHeaderData([
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                  100",
            "NAXIS2  =                  100",
            "IMAGETYP= 'Flat Field'",
            "END",
        ])
        try headerData.write(to: flatStrayURL)

        _ = try scanner.scan()

        return AuditFixture(libraryDir: libraryDir, dbDir: dbDir, root: root, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
}

private func findings(_ all: [Finding], category: String) -> [Finding] {
    all.filter { $0.category == category }
}

@Test func auditFindsPlaceholderName() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "placeholder-name")
    #expect(hits.contains { $0.path == "stacks/Please_enter_a_value.._Milkyway" && $0.severity == .sureError })
}

@Test func auditFindsOrphanCalibDirAndMisplacedFile() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let orphanHits = findings(all, category: "orphan-calib-dir")
    #expect(orphanHits.contains { $0.path == "calibration_library/bias" && $0.severity == .sureError })

    let misplaced = findings(all, category: "misplaced-file")
    let strayHit = try #require(misplaced.first { $0.path == "calibration_library/bias/stray.fit" })
    #expect(strayHit.severity == .sureError)
    #expect(strayHit.suggestion == .move(from: "calibration_library/bias/stray.fit", to: "calibration_library/biases/stray.fit"))
}

@Test func auditFindsDuplicatedCatalogPrefix() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "duplicated-catalog-prefix")
    #expect(hits.count == 2)

    let plain = try #require(hits.first { $0.path == "stacks/C2025_R3_C2025_R3_Panstarrs" })
    #expect(plain.severity == .sureError)
    #expect(plain.suggestion == .rename(from: "stacks/C2025_R3_C2025_R3_Panstarrs", to: "stacks/C2025_R3_Panstarrs"))

    let wide = try #require(hits.first { $0.path == "stacks/C2025_R3_C2025_R3_Panstarrs_Wide" })
    #expect(wide.suggestion == .rename(from: "stacks/C2025_R3_C2025_R3_Panstarrs_Wide", to: "stacks/C2025_R3_Panstarrs_Wide"))

    // Not a duplicated prefix -- must not appear.
    #expect(!hits.contains { $0.path == "stacks/R3_C2025" })
}

@Test func auditFindsNestedSessionTree() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "nested-session-tree")
    #expect(hits.contains { $0.path == "stacks/M42_Orion/2026-01-17/sessions" && $0.severity == .sureError })
    // The legitimate top-level sessions/ dir must never be flagged.
    #expect(!hits.contains { $0.path == "sessions" })
}

@Test func auditFindsNoncanonicalSubdir() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "noncanonical-subdir")
    #expect(hits.contains { $0.path == "stacks/M42_Orion/2026-01-17/collected_lights" && $0.severity == .suspicious })
    #expect(hits.contains { $0.path == "stacks/M_Milky_Way/2026-04-19/paneled_mosaic_process" && $0.severity == .suspicious })
}

@Test func auditFindsAssetsWithoutDate() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    // `light_frame_rating_report_assets` is a known tool-output dir name
    // (tools/rate/LightFrameRater.py's report bundle) -- it must no longer
    // be flagged by assets-without-date; ToolOutputRule owns it now (see
    // auditFindsToolOutputDirs below).
    let hits = findings(all, category: "assets-without-date")
    #expect(!hits.contains { $0.path == "stacks/NGC2237_Rosette_Nebula/light_frame_rating_report_assets" })
}

@Test func auditFindsToolOutputDirs() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "tool-output")

    // The report-assets dir under stacks/ -- previously assets-without-date.
    let assetsHit = try #require(hits.first { $0.path == "stacks/NGC2237_Rosette_Nebula/light_frame_rating_report_assets" })
    #expect(assetsHit.severity == .probablyIntentional)
    #expect(assetsHit.suggestion == nil)

    // The LightFrameRater Stack/Best triage dir nested inside a session's
    // lights/ folder -- only the topmost matched dir ("Stack") is flagged,
    // not "Best" too, and it must never show up as suspicious elsewhere.
    let stackHit = try #require(hits.first { $0.path == "sessions/T/2026-01-10/lights/Stack" })
    #expect(stackHit.severity == .probablyIntentional)
    #expect(stackHit.suggestion == nil)
    #expect(!hits.contains { $0.path == "sessions/T/2026-01-10/lights/Stack/Best" })

    #expect(hits.allSatisfy { $0.severity == .probablyIntentional && $0.suggestion == nil })

    // Never flagged as suspicious by any other rule.
    let allSuspiciousPaths = Set(all.filter { $0.severity == .suspicious }.map(\.path))
    #expect(!allSuspiciousPaths.contains("sessions/T/2026-01-10/lights/Stack"))
    #expect(!allSuspiciousPaths.contains("stacks/NGC2237_Rosette_Nebula/light_frame_rating_report_assets"))
}

@Test func auditGroupsSimilarTargetNames() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "similar-target-names")

    let m42Names: Set<String> = ["M42_Orion", "M42_Orion_Nebula", "M42_Orion_wide_field", "M42_Orion_Wide_Field_70MM"]
    let m42Group = try #require(hits.first { finding in
        m42Names.allSatisfy { finding.message.contains($0) }
    })
    #expect(m42Group.severity == .suspicious)
    #expect(m42Group.suggestion == nil)

    // M_Milky_Way must never be grouped with the placeholder target.
    #expect(!hits.contains { $0.message.contains("M_Milky_Way") && $0.message.contains("Please_enter_a_value") })

    // Comet triplet: different-order token permutations sharing the same
    // {c2025, r3} catalog-designation token set must group together.
    let cometNames: Set<String> = ["R3_C2025", "C2025_R3_C2025_R3_Panstarrs", "C2025_R3_C2025_R3_Panstarrs_Wide"]
    let cometGroup = try #require(hits.first { finding in
        cometNames.allSatisfy { finding.message.contains($0) }
    })
    #expect(cometGroup.severity == .suspicious)

    // M42_Orion* (catalog m42) must never be grouped with M45_Pleiades
    // (catalog m45) even though both are single-catalog-token targets.
    #expect(!hits.contains { $0.message.contains("M42_Orion") && $0.message.contains("M45_Pleiades") })
}

@Test func auditFindsMissingCounterparts() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "missing-counterpart")

    #expect(hits.contains {
        $0.path == "stacks/NGC_7000_North_America/2026-06-06" && $0.message == "stack without session"
    })
    #expect(hits.contains {
        $0.path == "stacks/NGC_7000_North_America/2026-06-29" && $0.message == "stack without session"
    })
    #expect(hits.contains {
        $0.path == "processed/NGC2237_Rosette_Nebula/2026-07-01" && $0.message == "processed without session or stack"
    })
    #expect(hits.contains {
        $0.path == "sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17" && $0.message == "session not yet stacked"
    })
    #expect(hits.allSatisfy { $0.severity == .suspicious })
}

@Test func auditFindsIntentionalDates() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "intentional-date")
    let flaggedPaths = Set(hits.map(\.path))

    #expect(flaggedPaths.contains("sessions/M45_Pleiades/2026-04-06-2"))
    #expect(flaggedPaths.contains("sessions/M45_Pleiades/2026-02-25_2026-03-15"))
    #expect(flaggedPaths.contains("sessions/M45_Pleiades/2026-03-15-OSC"))
    #expect(flaggedPaths.contains("sessions/M45_Pleiades/2026-03-15_hibas"))
    #expect(hits.allSatisfy { $0.severity == .probablyIntentional })

    // The canonical date must never show up here.
    #expect(!flaggedPaths.contains("sessions/M45_Pleiades/2026-01-10"))
}

@Test func auditFindsResidue() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "residue")
    let flaggedPaths = Set(hits.map(\.path))

    #expect(flaggedPaths.contains("stacks/M42_Orion/2026-01-17/x.seq"))
    #expect(flaggedPaths.contains("stacks/M42_Orion/2026-01-17/x.lst"))
    #expect(flaggedPaths.contains("stacks/M42_Orion/2026-01-17/r_lights.fit"))
    #expect(flaggedPaths.contains("stacks/M42_Orion/2026-01-17/.DS_Store"))
    #expect(flaggedPaths.contains("stacks/M42_Orion/2026-01-17/process"))
    #expect(hits.allSatisfy { $0.severity == .suspicious })
}

@Test func auditFindsCalibInWrongDir() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "calib-in-wrong-dir")
    let hit = try #require(hits.first { $0.path == "sessions/M45_Pleiades/2026-01-10/lights/flat_stray.fit" })
    #expect(hit.severity == .sureError)
    #expect(hit.suggestion == .move(
        from: "sessions/M45_Pleiades/2026-01-10/lights/flat_stray.fit",
        to: "sessions/M45_Pleiades/2026-01-10/flats/flat_stray.fit"
    ))
}

@Test func auditFindsInvalidDateDir() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let unparseablePath = "sessions/M45_Pleiades/notadate/lights/x.fit"
    let fileURL = fixture.root.appendingPathComponent(unparseablePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture dummy content\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "invalid-date-dir")
    #expect(hits.contains { $0.path == "sessions/M45_Pleiades/notadate" && $0.severity == .suspicious })
}

@Test func auditFindsEmptyTargetComponent() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let dirURL = fixture.root.appendingPathComponent("stacks/_Orphan/2026-01-01", isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "empty-target-component")
    let hit = try #require(hits.first { $0.path == "stacks/_Orphan" })
    #expect(hit.severity == .sureError)
    if case .review = hit.suggestion {
        // expected
    } else {
        Issue.record("expected a .review suggestion, got \(String(describing: hit.suggestion))")
    }
}

@Test func auditFindsCalibInWrongDirUnderCalibrationLibrary() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let strayPath = "calibration_library/darks/flat_in_darks.fit"
    let strayURL = fixture.root.appendingPathComponent(strayPath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Flat Field'",
        "END",
    ])
    try headerData.write(to: strayURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "calib-in-wrong-dir")
    let hit = try #require(hits.first { $0.path == strayPath })
    #expect(hit.severity == .sureError)
    #expect(hit.suggestion == .move(from: strayPath, to: "calibration_library/flats/flat_in_darks.fit"))
}

@Test func auditFindsLooseFramesInDateDir() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    // No lights/ subdir -- the frame sits directly under the date dir, just
    // like the real IC1805 session that motivated this rule.
    let loosePath = "sessions/M45_Pleiades/2026-01-10/loose_light.fit"
    let looseURL = fixture.root.appendingPathComponent(loosePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: looseURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "loose-frames-in-date-dir")
    let hit = try #require(hits.first { $0.path == "sessions/M45_Pleiades/2026-01-10" })
    #expect(hit.severity == .suspicious)
    #expect(hit.suggestion == nil)

    // One finding per (target, date), not one per loose file -- the fixture
    // already has three canonical lights in this same date dir.
    #expect(hits.filter { $0.path == "sessions/M45_Pleiades/2026-01-10" }.count == 1)
}

@Test func auditFindingsArePersistedAndReadableFromDB() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (runID, findings) = try engine.run()

    let persisted = try fixture.db.findings(runID: runID)
    #expect(persisted.count == findings.count)
    for finding in findings {
        #expect(persisted.contains(finding))
    }
}

@Test func auditOrdersSureErrorsFirst() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let first = try #require(all.first)
    #expect(first.severity == .sureError)

    // Non-decreasing severity rank across the whole result.
    func rank(_ s: Severity) -> Int {
        switch s {
        case .sureError: return 0
        case .suspicious: return 1
        case .probablyIntentional: return 2
        }
    }
    var previousRank = 0
    for finding in all {
        #expect(rank(finding.severity) >= previousRank)
        previousRank = rank(finding.severity)
    }
}

// MARK: - Unit tests for the small helpers

@Test func globMatcherHandlesSimpleWildcards() throws {
    #expect(GlobMatcher.matches(pattern: "*.seq", name: "x.seq"))
    #expect(GlobMatcher.matches(pattern: "*.seq", name: "X.SEQ"))
    #expect(!GlobMatcher.matches(pattern: "*.seq", name: "x.lst"))
    #expect(GlobMatcher.matches(pattern: "r_*", name: "r_lights.fit"))
    #expect(!GlobMatcher.matches(pattern: "r_*", name: "lights_r.fit"))
    #expect(GlobMatcher.matches(pattern: "*_conv*", name: "target_conv_final.tif"))
    #expect(GlobMatcher.matches(pattern: ".DS_Store", name: ".DS_Store"))
    #expect(!GlobMatcher.matches(pattern: ".DS_Store", name: ".DS_Storex"))
}

@Test func duplicatedPrefixDetectorFindsLongestRepeatedRun() throws {
    #expect(DuplicatedPrefixDetector.dedupe(["C2025", "R3", "C2025", "R3", "Panstarrs"]) == ["C2025", "R3", "Panstarrs"])
    #expect(DuplicatedPrefixDetector.dedupe(["C2025", "R3", "C2025", "R3", "Panstarrs", "Wide"]) == ["C2025", "R3", "Panstarrs", "Wide"])
    #expect(DuplicatedPrefixDetector.dedupe(["R3", "C2025"]) == nil)
    #expect(DuplicatedPrefixDetector.dedupe(["M45", "Pleiades"]) == nil)
    #expect(DuplicatedPrefixDetector.dedupe(["A", "A"]) == ["A"])
}
