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

    // Message text is deliberately not asserted exactly here (Hungarian
    // wording may still evolve) -- category + path is the stable contract.
    #expect(hits.contains { $0.path == "stacks/NGC_7000_North_America/2026-06-06" })
    #expect(hits.contains { $0.path == "stacks/NGC_7000_North_America/2026-06-29" })
    #expect(hits.contains { $0.path == "processed/NGC2237_Rosette_Nebula/2026-07-01" })
    #expect(hits.contains { $0.path == "sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17" })
    #expect(hits.allSatisfy { $0.severity == .suspicious })

    // Spot check: messages must actually be Hungarian, not the old English
    // wording.
    let stackHit = try #require(hits.first { $0.path == "stacks/NGC_7000_North_America/2026-06-06" })
    #expect(stackHit.message == "stack session nélkül")
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

    // Spot check: residue messages must be Hungarian, not the old English
    // wording -- this is the exact row the user complained reads as
    // nonsense in the app.
    let dsStoreHit = try #require(hits.first { $0.path == "stacks/M42_Orion/2026-01-17/.DS_Store" })
    #expect(dsStoreHit.message == "\".DS_Store\" feldolgozási maradéknak tűnik.")
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

    // Spot check: another of the user's exact "reads as nonsense" examples.
    #expect(hit.message == "A FITS IMAGETYP (\"Flat Field\") nem illik a fájl helyéhez (várt hely: flats/).")
}

/// W5-4 item 2: `CalibInWrongDirRule` used to carry its own private
/// IMAGETYP->role copy (`impliedRole`) instead of delegating to
/// `FrameRoleFromHeader` (the shared predicate `LibraryScanner` already
/// uses). The two copies checked the same four substrings in a DIFFERENT
/// order -- `FrameRoleFromHeader` tries `"light"` FIRST, the old
/// `CalibInWrongDirRule` copy tried it LAST (flat, dark, bias, then light) --
/// so for an (admittedly pathological, but real headers are free-text)
/// IMAGETYP value containing more than one of those substrings at once, the
/// two implementations disagreed about the implied role. A light frame whose
/// IMAGETYP happens to also contain the word "dark" (e.g. an operator note
/// like "Dark corrected Light") is exactly this case: the file's own path
/// role (`.light`) agrees with what `FrameRoleFromHeader` derives (`.light`,
/// since it checks "light" first) -- correctly finding NOTHING wrong -- but
/// the OLD private copy derived `.dark` instead (it never reaches the
/// "light" check once "dark" already matched) and would have wrongly flagged
/// a correctly-placed light frame as misplaced, suggesting a bogus move into
/// `darks/`. This test pins `FrameRoleFromHeader`'s order as the correct
/// behavior -- the rule must delegate to it instead of its own copy.
@Test func calibInWrongDirAgreesWithFrameRoleFromHeaderOnAmbiguousImagetyp() throws {
    let file = FileRecord(
        path: "sessions/M45_Pleiades/2026-01-10/lights/ambiguous.fit",
        size: 0, mtime: 0, ext: "fit", kind: "fits",
        area: .sessions, target: "M45_Pleiades", sessionDate: "2026-01-10", role: .light, scannedAt: 0
    )
    let imagetyp = "Dark corrected Light"

    // `FrameRoleFromHeader` -- the shared, canonical predicate -- reads this
    // as `.light`, matching the file's actual path role, so there is nothing
    // to flag.
    #expect(FrameRoleFromHeader.role(fromImagetyp: imagetyp) == .light)

    let finding = CalibInWrongDirRule.misplacedFinding(file: file, imagetyp: imagetyp, id: "calib-in-wrong-dir")
    #expect(finding == nil, "a light frame whose IMAGETYP also mentions \"dark\" must not be flagged once the rule delegates to FrameRoleFromHeader")
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

@Test func auditSuppressesCalibInWrongDirUnderNestedSessionTree() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    // A whole extra session tree nested a level too deep inside an existing
    // session -- mirrors the real bug report
    // (sessions/<target>/<date>/flats/sessions/session1/darks/...): every
    // file underneath has its role fixed by the outer "flats" path
    // component (`PathClassifier` only ever looks at the 4th component), so
    // a real dark frame down in the nested tree's own "darks" folder always
    // looks misplaced relative to that path -- exactly the flood of
    // per-file `calib-in-wrong-dir` rows (dozens in the real library) the
    // engine-level suppression exists to collapse down to the single
    // `nested-session-tree` finding that's actually actionable.
    let nestedDarkPath = "sessions/M45_Pleiades/2026-01-10/flats/sessions/session1/darks/dark_0001.fit"
    let nestedDarkURL = fixture.root.appendingPathComponent(nestedDarkPath)
    try FileManager.default.createDirectory(at: nestedDarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Dark Frame'",
        "END",
    ])
    try headerData.write(to: nestedDarkURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let nestedTreeHits = findings(all, category: "nested-session-tree")
    #expect(nestedTreeHits.contains { $0.path == "sessions/M45_Pleiades/2026-01-10/flats/sessions" })

    let calibHits = findings(all, category: "calib-in-wrong-dir")
    #expect(!calibHits.contains { $0.path == nestedDarkPath })
}

@Test func auditSkipsCalibInWrongDirUnderMastersToolOutputDir() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    // `masters/` right next to the raws is a deliberate convention for
    // stacking outputs, not a misplaced frame -- a stacked darks master
    // dropped there must never be flagged as calib-in-wrong-dir just
    // because its enclosing role folder ("flats", here) doesn't match the
    // master's own IMAGETYP.
    let mastersPath = "sessions/M45_Pleiades/2026-01-10/flats/masters/session1_60s_-10c_darks_stacked.fit"
    let mastersURL = fixture.root.appendingPathComponent(mastersPath)
    try FileManager.default.createDirectory(at: mastersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Dark Frame'",
        "END",
    ])
    try headerData.write(to: mastersURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    #expect(!findings(all, category: "calib-in-wrong-dir").contains { $0.path == mastersPath })

    let toolOutputHits = findings(all, category: "tool-output")
    #expect(toolOutputHits.contains { $0.path == "sessions/M45_Pleiades/2026-01-10/flats/masters" })
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

// MARK: - corrupt-fits (R11-T4)

@Test func auditFlagsFITSLightWithUnreadableHeaderAsCorruptFITS() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    // Same "garbage bytes, not a real FITS header" fixture
    // `ScannerTests.corruptFITSFileIsRecordedButNoMetaRowIsWritten` uses --
    // the scanner still records the file, just with no `fits_meta` row.
    let corruptPath = "sessions/M45_Pleiades/2026-01-10/lights/corrupt.fit"
    let corruptURL = fixture.root.appendingPathComponent(corruptPath)
    try "this is not a valid FITS header at all, just garbage bytes\n".write(
        to: corruptURL, atomically: true, encoding: .utf8
    )

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "corrupt-fits")
    let hit = try #require(hits.first { $0.path == corruptPath })
    #expect(hit.severity == .sureError)
    #expect(hit.suggestion == nil)

    // The fixture's OWN `flat_stray.fit` (added by `AuditFixture.make`) has a
    // real, parseable FITS header (`buildHeaderData`) -- it must NOT be
    // flagged even though it sits right next to the corrupt one.
    #expect(!hits.contains { $0.path == "sessions/M45_Pleiades/2026-01-10/lights/flat_stray.fit" })
}

/// A wide-field DSLR light (CR3) never gets a `fits_meta` row either -- it
/// isn't FITS at all, its metadata comes from `ImageIO`/EXIF instead -- so
/// the rule must never flag one just because `fits_meta` happens to be empty
/// for it (the false-positive case the rule is explicitly scoped against).
@Test func auditDoesNotFlagWideFieldCR3AsCorruptFITS() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let cr3Path = "sessions/WideField_Target/2026-02-01/lights/light_0001.cr3"
    let cr3URL = fixture.root.appendingPathComponent(cr3Path)
    try FileManager.default.createDirectory(at: cr3URL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not a real CR3 file, just fixture bytes\n".write(to: cr3URL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (_, all) = try engine.run()

    let hits = findings(all, category: "corrupt-fits")
    #expect(!hits.contains { $0.path == cr3Path })
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

// MARK: - Findings retention (B20)

/// `AuditEngine.run` calls `Database.pruneFindings(keepRuns: 3)` at the end
/// of every run (see its own unit tests in `DatabaseTests.swift` for the
/// DAO-level behavior) -- this is the integration-level guard that the real
/// call site actually wires it up, using the same fixture library every
/// other `AuditEngine` test in this file uses.
@Test func auditEngineRunPrunesFindingsToNewestThreeRunsAutomatically() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    var runIDs: [Int64] = []
    for _ in 0..<5 {
        let (runID, _) = try engine.run()
        runIDs.append(runID)
    }

    var seenRunIDs: Set<Int64> = []
    try fixture.db.db.query("SELECT DISTINCT run_id FROM findings;") { row in
        if let id = row.int64(0) { seenRunIDs.insert(id) }
    }

    #expect(seenRunIDs == Set(runIDs.suffix(3)))
}

// MARK: - Cooperative cancellation (R12-W3 fix): `progress` widened to `throws`

/// Thread-safe tick counter for the `@Sendable` `progress` callback -- a
/// plain captured `var` can't be mutated from inside a `@Sendable` closure
/// under strict concurrency checking, even though `AuditEngine.run` only
/// ever calls it synchronously on the calling thread (same shape
/// `FixityVerifierTests`' own `ProgressRecorder` uses).
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
}

/// `AuditEngine.run`'s own rule-evaluation loop now ticks `progress` once per
/// rule (in addition to forwarding `DuplicateFinder`'s own per-file ticks,
/// see the next test) -- a caller (`AuditRunCommand`) can turn a `throw
/// CancellationError()` inside its own wrapping closure into a stop that
/// lands between two rules, never waiting for every rule (and the duplicate
/// scan) to finish first the way only checking `isCancelled` at the outer
/// phase boundary would.
@Test func auditEngineRunProgressCallbackThrowsToStopBetweenRules() throws {
    let libraryDir = try makeTempDir("empty-lib")
    let dbDir = try makeTempDir("empty-db")
    defer {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
    let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
    var config = AstroConfig()
    config.rootPath = libraryDir.path

    let engine = AuditEngine(config: config, db: db)
    let counter = TickCounter()
    #expect(throws: CancellationError.self) {
        _ = try engine.run(includeDuplicates: false) {
            if counter.increment() == 2 { throw CancellationError() }
        }
    }

    // Stopped after the second rule -- never reached the rest of the 20.
    #expect(counter.value == 2)
    #expect(counter.value < AuditEngine.defaultRules().count)
}

/// `DuplicateFinder.findDuplicates`'s own per-file hash ticks (`onPrefixHash`/
/// `onFullHash`) are forwarded through the SAME `progress` hook
/// `AuditEngine.run` ticks once per rule with -- so a full audit's
/// cancellation point reaches into the slow duplicate-hashing pass itself,
/// not just between rules (the rules alone are fast, in-memory, and
/// evaluating all 20 of them is not where a real audit's wall-clock time
/// goes; the hash scan is).
@Test func auditEngineRunForwardsDuplicateFinderTicksThroughTheSameProgressHook() throws {
    let libraryDir = try makeTempDir("dup-lib")
    let dbDir = try makeTempDir("dup-db")
    defer {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
    let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
    var config = AstroConfig()
    config.rootPath = libraryDir.path

    // Two identical, uncached, >= 1 MiB files -- exactly what forces
    // `DuplicateFinder` to actually hash something (see its own doc comment
    // on the size floor and two-tier prefix/full scheme).
    let payload = Data(repeating: 0xAB, count: 1_100_000)
    let dup1 = libraryDir.appendingPathComponent("stacks/A/2026-01-01/dup1.fit")
    let dup2 = libraryDir.appendingPathComponent("stacks/A/2026-01-01/dup2.fit")
    try FileManager.default.createDirectory(at: dup1.deletingLastPathComponent(), withIntermediateDirectories: true)
    try payload.write(to: dup1)
    try payload.write(to: dup2)

    let scanner = LibraryScanner(config: config, db: db)
    _ = try scanner.scan()

    let ruleCount = AuditEngine.defaultRules().count
    let engine = AuditEngine(config: config, db: db)
    let counter = TickCounter()
    // Cancel two ticks past the rule loop's own boundary -- only reachable
    // if `DuplicateFinder`'s per-file ticks really do flow through this same
    // callback rather than being invisible to it.
    let cancelAt = ruleCount + 2
    #expect(throws: CancellationError.self) {
        _ = try engine.run(includeDuplicates: true) {
            if counter.increment() == cancelAt { throw CancellationError() }
        }
    }

    #expect(counter.value == cancelAt)
    #expect(counter.value > ruleCount)
}

// MARK: - Diff against the previous run (R11-T8/F6 integration)

@Test func auditEnginePersistsDuplicateSettingAndDecodesLegacyConfig() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let (runID, _) = try AuditEngine(config: fixture.config, db: fixture.db)
        .run(includeDuplicates: false)
    let run = try #require(try fixture.db.runSummary(id: runID))
    let metadata = try #require(AuditEngine.decodeRunConfig(run.configJSON))
    #expect(metadata.astroConfig.rootPath == fixture.config.rootPath)
    #expect(metadata.includeDuplicates == false)

    let legacyJSON = String(data: try JSONEncoder().encode(fixture.config), encoding: .utf8)
    let legacy = try #require(AuditEngine.decodeRunConfig(legacyJSON))
    #expect(legacy.includeDuplicates == nil)
}

/// End-to-end proof that the pieces `AppState.runAudit`/`Commands.cmdAudit`
/// actually wire together at their call sites -- `Database.previousRunID`,
/// `AuditEngine.run`'s own `pruneFindings(keepRuns: 3)` call, and
/// `AuditDiff.compute` -- really do fit together the way the doc comments on
/// each piece claim, using the SAME fixture library every other
/// `AuditEngine` test in this file uses (rather than `AuditDiffTests`'s
/// hand-built `Finding` arrays).
@Test func auditEngineRunsTwiceInARowDiffCleanlyAgainstThePreviousRun() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (firstRunID, firstFindings) = try engine.run()

    // Nothing on disk changed between the two runs -- every group from the
    // first run must still be there, unchanged, on the second.
    let (secondRunID, secondFindings) = try engine.run()

    let previousRunID = try fixture.db.previousRunID(before: secondRunID, kind: "audit")
    #expect(previousRunID == firstRunID)

    let previousFindings = try fixture.db.findings(runID: try #require(previousRunID))
    let diff = AuditDiff.compute(previous: previousFindings, current: secondFindings, config: fixture.config)

    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == FindingGrouper.group(firstFindings, config: fixture.config).count)
    #expect(diff.unchangedCount > 0)
}

/// A brand-new finding category (a fresh placeholder-named stack directory
/// dropped between the two runs) shows up as `newGroups`, with everything
/// else from the first run reported unchanged -- not folded into "resolved"
/// or dropped silently.
@Test func auditEngineDiffFlagsAFreshlyIntroducedFindingAsNew() throws {
    let fixture = try AuditFixture.make()
    defer { fixture.cleanup() }

    let engine = AuditEngine(config: fixture.config, db: fixture.db)
    let (firstRunID, _) = try engine.run()

    // Same "please_enter" placeholder pattern `PlaceholderNameRule` already
    // catches in the fixture's `Please_enter_a_value.._Milkyway`, just under
    // a different target name -- a genuinely NEW group, not a duplicate of
    // the one the first run already found.
    let newStrayURL = fixture.root.appendingPathComponent("stacks/Please_enter_a_value.._Andromeda/2026-05-01/stack.fit")
    try FileManager.default.createDirectory(at: newStrayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture dummy content\n".write(to: newStrayURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let (secondRunID, secondFindings) = try engine.run()
    let previousRunID = try #require(try fixture.db.previousRunID(before: secondRunID, kind: "audit"))
    #expect(previousRunID == firstRunID)
    let previousFindings = try fixture.db.findings(runID: previousRunID)

    let diff = AuditDiff.compute(previous: previousFindings, current: secondFindings, config: fixture.config)

    // The new stray stack directory trips TWO rules at once (a placeholder
    // name AND -- since it has no matching `sessions/` counterpart --
    // `missing-counterpart`), so both show up as new groups; nothing from
    // the first run disappears.
    #expect(diff.resolvedCount == 0)
    let newHit = try #require(diff.newGroups.first {
        $0.key.category == "placeholder-name" && $0.key.groupKey == "stacks/Please_enter_a_value.._Andromeda"
    })
    #expect(newHit.key.severity == .sureError)
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
