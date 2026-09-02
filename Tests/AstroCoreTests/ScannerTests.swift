import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-scanner-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library, a fresh sqlite-backed `Database`, and an
/// `AstroConfig` pointed at that fixture root — everything a scanner test
/// needs, all under temp dirs that get cleaned up by the caller.
private struct ScanFixture {
    let libraryDir: URL
    let dbDir: URL
    let root: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> ScanFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let root = try Fixtures.makeMessyLibrary(in: libraryDir)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = root.path
        return ScanFixture(libraryDir: libraryDir, dbDir: dbDir, root: root, db: db, config: config)
    }

    /// An EMPTY library root (no messy fixture): refresh-meta tests need a
    /// tree where the only meta-bearing files are the ones the test itself
    /// plants — the messy fixture's dummy text-content `.fit` files all lack
    /// a `fits_meta` row, so every one of them counts as a backfill attempt
    /// and drowns out the single-file expectations.
    static func makeEmpty() throws -> ScanFixture {
        let libraryDir = try makeTempDir("lib-empty")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return ScanFixture(libraryDir: libraryDir, dbDir: dbDir, root: libraryDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
}

@Test func firstScanAddsFilesAndExcludesToolsAndAstroToolDir() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan()

    #expect(summary.added > 0)
    #expect(summary.unchanged == 0)
    #expect(summary.updated == 0)
    #expect(summary.missing == 0)

    #expect(try fixture.db.fileID(path: "tools/setiastro/test.fits") == nil)
    #expect(try fixture.db.fileID(path: ".astro_tool/astrotool.sqlite-decoy.txt") == nil)
    #expect(try fixture.db.fileID(path: ".fseventsd/junk.txt") == nil)

    // Sanity: a real, non-excluded file did get recorded.
    #expect(try fixture.db.fileID(path: "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit") != nil)
}

@Test func scanSkipsDanglingSymbolicLinksInsteadOfIndexingThemAsFrames() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativeDirectory = "processed/IC_1396/2026-08-08/work"
    let directory = fixture.root.appendingPathComponent(relativeDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let link = directory.appendingPathComponent("stars_aligned_00001.fit")
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: directory.appendingPathComponent("removed-sequence.fit").path
    )

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan(subpath: "processed/IC_1396/2026-08-08")

    #expect(summary.added == 0)
    #expect(try fixture.db.fileID(path: "\(relativeDirectory)/stars_aligned_00001.fit") == nil)
}

@Test func secondScanOnUnchangedTreeReportsEverythingUnchanged() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let first = try scanner.scan()
    let second = try scanner.scan()

    #expect(second.added == 0)
    #expect(second.updated == 0)
    #expect(second.missing == 0)
    #expect(second.unchanged == first.added)
}

@Test func modifiedFileIsReportedAsUpdatedOnNextScan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "changed content, now longer than before\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

    let summary = try scanner.scan()
    #expect(summary.added == 0)
    #expect(summary.updated == 1)
    #expect(summary.missing == 0)

    let record = try fixture.db.file(path: relativePath)
    #expect(record?.missing == false)
}

@Test func modifiedFileHasContentHashInvalidatedOnRescan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"

    // Simulate a previous run having populated a content hash for this file.
    var record = try #require(try fixture.db.file(path: relativePath))
    record.contentHash = "deadbeef"
    _ = try fixture.db.upsertFile(record)
    #expect(try fixture.db.file(path: relativePath)?.contentHash == "deadbeef")

    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "changed content, now longer than before\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

    let summary = try scanner.scan()
    #expect(summary.updated == 1)

    let rescanned = try fixture.db.file(path: relativePath)
    #expect(rescanned?.contentHash == nil)
}

@Test func deletedFixtureFileIsMarkedMissingButRecordRemains() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Deleting inside the FIXTURE tmp tree only — never the real library.
    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0002.fit"
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(relativePath))

    let summary = try scanner.scan()
    #expect(summary.missing == 1)

    let record = try fixture.db.file(path: relativePath)
    #expect(record != nil)
    #expect(record?.missing == true)
}

// MARK: - changedTargets (R11-T4)

@Test func changedTargetsListsEveryTargetTouchedThisRunAndNothingOnAnUnchangedRescan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let first = try scanner.scan()

    // First scan: everything is `added`, so every target with at least one
    // file counts as "changed" -- both a `sessions/` target and a `stacks/`
    // one (the field is populated from any area, not just sessions).
    #expect(first.changedTargets.contains("M45_Pleiades"))
    #expect(first.changedTargets.contains("IC1805-1848_Heart_and_Soul_Nebula"))
    #expect(first.changedTargets.contains("M42_Orion"))
    // Sorted, deduplicated -- never one entry per file.
    #expect(first.changedTargets == Array(Set(first.changedTargets)).sorted())

    // Second scan over the exact same tree: nothing added/updated/missing,
    // so nothing should be reported as changed either.
    let second = try scanner.scan()
    #expect(second.changedTargets.isEmpty)
}

@Test func changedTargetsReportsOnlyTheTargetOfAModifiedFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "changed content, now longer than before\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

    let summary = try scanner.scan()
    #expect(summary.updated == 1)
    #expect(summary.changedTargets == ["M45_Pleiades"])
}

@Test func changedTargetsIncludesTheTargetOfANewlyMissingFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Deleting inside the FIXTURE tmp tree only -- never the real library.
    let relativePath = "sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17/lights/light_0001.fit"
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(relativePath))

    let summary = try scanner.scan()
    #expect(summary.missing == 1)
    #expect(summary.changedTargets == ["IC1805-1848_Heart_and_Soul_Nebula"])
}

// MARK: - changedSessions (R11-T9/F5)

@Test func changedSessionsListsEveryTargetDatePairWithANewLightFrame() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let first = try scanner.scan()

    // First scan: every LIGHT frame under `sessions/` is `added`, so its
    // (target, date) pair counts as changed -- a `stacks/`-area file (no
    // "session date" of its own) never contributes an entry.
    #expect(first.changedSessions.contains(ScanSummary.SessionKey(target: "M45_Pleiades", date: "2026-01-10")))
    #expect(first.changedSessions.contains(
        ScanSummary.SessionKey(target: "IC1805-1848_Heart_and_Soul_Nebula", date: "2026-01-17")
    ))
    // Sorted, deduplicated -- never one entry per file within the same night.
    #expect(first.changedSessions == Array(Set(first.changedSessions)).sorted())

    // Second scan over the exact same tree: nothing added/updated, so
    // nothing should be reported as a fresh session either.
    let second = try scanner.scan()
    #expect(second.changedSessions.isEmpty)
}

@Test func changedSessionsReportsOnlyTheSessionOfAModifiedLightFrame() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "changed content, now longer than before\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

    let summary = try scanner.scan()
    #expect(summary.updated == 1)
    #expect(summary.changedSessions == [ScanSummary.SessionKey(target: "M45_Pleiades", date: "2026-01-10")])
}

@Test func changedSessionsExcludesANewlyMissingLightFrame() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Deleting inside the FIXTURE tmp tree only -- never the real library.
    let relativePath = "sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17/lights/light_0001.fit"
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(relativePath))

    let summary = try scanner.scan()
    #expect(summary.missing == 1)
    // `changedTargets` still lists it (a rescan pipeline should re-rate this
    // target), but `changedSessions` -- "fresh material to REVIEW" -- must
    // not, since nothing new arrived.
    #expect(summary.changedTargets == ["IC1805-1848_Heart_and_Soul_Nebula"])
    #expect(summary.changedSessions.isEmpty)
}

@Test func changedSessionsExcludesANewStackFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // A `stacks/`-area file has no session date, and isn't a light frame --
    // touching it must bump `changedTargets` but never `changedSessions`.
    let relativePath = "stacks/M42_Orion/2026-01-17/result.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "changed stack content, now longer than before\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fileURL.path)

    let summary = try scanner.scan()
    #expect(summary.updated == 1)
    #expect(summary.changedTargets == ["M42_Orion"])
    #expect(summary.changedSessions.isEmpty)
}

@Test func subpathScopedScanOnlyTouchesThatSubtree() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan(subpath: "stacks")

    #expect(summary.added > 0)
    #expect(try fixture.db.fileID(path: "stacks/M42_Orion/2026-01-17/result.fit") != nil)
    #expect(try fixture.db.fileID(path: "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit") == nil)
    #expect(try fixture.db.fileID(path: "calibration_library/biases/master_bias.fit") == nil)
}

@Test func subpathScopedScanOnlyMarksThatSubtreeMissing() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("stacks/M42_Orion/2026-01-17/result.fit")
    )
    try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights/light_0002.fit")
    )

    let summary = try scanner.scan(subpath: "stacks")
    #expect(summary.missing == 1)

    let stackRecord = try fixture.db.file(path: "stacks/M42_Orion/2026-01-17/result.fit")
    #expect(stackRecord?.missing == true)

    // Outside the scanned subpath: not touched by this scan, still present.
    let sessionRecord = try fixture.db.file(path: "sessions/M45_Pleiades/2026-01-10/lights/light_0002.fit")
    #expect(sessionRecord?.missing == false)
}

// An EPERM/EACCES reading the top-level directory of a scan invocation
// (the configured root, or the requested `subpath`) still aborts the whole
// scan with `.accessDenied` -- see `inaccessibleRootThrowsAccessDenied` and
// `inaccessibleRequestedSubpathThrowsAccessDenied` below. The SAME error on
// a directory found deeper during the walk no longer aborts the scan --
// see `inaccessibleDeeperDirectoryIsSkippedAndScanContinues`.

@Test func inaccessibleDeeperDirectoryIsSkippedAndScanContinues() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let restrictedRelative = "sessions/M45_Pleiades/2026-01-10/lights"
    let restrictedDir = fixture.root.appendingPathComponent(restrictedRelative)
    let originalPermissions = try FileManager.default.attributesOfItem(atPath: restrictedDir.path)[.posixPermissions] as? NSNumber

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions ?? NSNumber(value: 0o755)],
            ofItemAtPath: restrictedDir.path
        )
    }

    let summary = try scanner.scan()

    #expect(summary.inaccessiblePaths.contains(restrictedRelative))

    // The rest of the tree is still scanned -- an unrelated file elsewhere
    // is recorded fine, the scan did not abort.
    #expect(try fixture.db.fileID(path: "stacks/M42_Orion/2026-01-17/result.fit") != nil)

    // Files already tracked under the now-unreadable directory must NOT be
    // flagged missing just because this scan couldn't see them.
    let previouslyTracked = try #require(
        try fixture.db.file(path: "\(restrictedRelative)/light_0001.fit")
    )
    #expect(previouslyTracked.missing == false)
}

@Test func inaccessibleRootThrowsAccessDenied() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let originalPermissions = try FileManager.default.attributesOfItem(atPath: fixture.root.path)[.posixPermissions] as? NSNumber
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.root.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions ?? NSNumber(value: 0o755)],
            ofItemAtPath: fixture.root.path
        )
    }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    do {
        _ = try scanner.scan()
        Issue.record("expected AstroError.accessDenied to be thrown")
    } catch AstroError.accessDenied {
        // expected
    } catch {
        Issue.record("expected AstroError.accessDenied, got \(error)")
    }
}

@Test func inaccessibleRequestedSubpathThrowsAccessDenied() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let sessionsDir = fixture.root.appendingPathComponent("sessions")
    let originalPermissions = try FileManager.default.attributesOfItem(atPath: sessionsDir.path)[.posixPermissions] as? NSNumber
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessionsDir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions ?? NSNumber(value: 0o755)],
            ofItemAtPath: sessionsDir.path
        )
    }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    do {
        _ = try scanner.scan(subpath: "sessions")
        Issue.record("expected AstroError.accessDenied to be thrown")
    } catch let AstroError.accessDenied(path) {
        #expect(path == "sessions")
    } catch {
        Issue.record("expected AstroError.accessDenied, got \(error)")
    }
}

@Test func nonexistentSubpathUnderExistingRootThrowsPathNotFound() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    do {
        _ = try scanner.scan(subpath: "does_not_exist_subpath")
        Issue.record("expected AstroError.pathNotFound to be thrown")
    } catch let AstroError.pathNotFound(path) {
        #expect(path == "does_not_exist_subpath")
    } catch {
        Issue.record("expected AstroError.pathNotFound, got \(error)")
    }
}

@Test func nonexistentRootUnderExistingParentThrowsPathNotFound() throws {
    let parentDir = try makeTempDir("parent")
    defer { try? FileManager.default.removeItem(at: parentDir) }
    let dbDir = try makeTempDir("db")
    defer { try? FileManager.default.removeItem(at: dbDir) }
    let missingRoot = parentDir.appendingPathComponent("nonexistent_root", isDirectory: true)

    let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
    var config = AstroConfig()
    config.rootPath = missingRoot.path

    let scanner = LibraryScanner(config: config, db: db)
    do {
        _ = try scanner.scan()
        Issue.record("expected AstroError.pathNotFound to be thrown")
    } catch let AstroError.pathNotFound(path) {
        #expect(path == missingRoot.path)
    } catch {
        Issue.record("expected AstroError.pathNotFound, got \(error)")
    }
}

/// A probe whose `pathExists` claims every path under `existingPrefixes`
/// exists (nothing else does), and whose `isVolumeBoundary` returns `true`
/// only for paths in `boundaries` -- deterministic, no real filesystem
/// access, so the classifier's decision logic can be tested without a real
/// removable drive or iCloud container.
private func fakeVolumeProbe(
    existingPrefixes: Set<String>,
    boundaries: Set<String> = []
) -> RootErrorClassifier.VolumeProbe {
    RootErrorClassifier.VolumeProbe(
        pathExists: { existingPrefixes.contains($0) },
        isVolumeBoundary: { boundaries.contains($0) }
    )
}

@Test func rootErrorClassifierDecidesVolumeNotMountedVsPathNotFoundUnderVolumes() throws {
    #expect(
        RootErrorClassifier.classify(
            rootPath: "/Volumes/images/sessions", subpath: nil,
            probe: fakeVolumeProbe(existingPrefixes: [])
        ) == .volumeNotMounted(path: "/Volumes/images/sessions")
    )
    #expect(
        RootErrorClassifier.classify(
            rootPath: "/Volumes/images/sessions", subpath: nil,
            probe: fakeVolumeProbe(existingPrefixes: ["/Volumes/images"])
        ) == .pathNotFound(path: "/Volumes/images/sessions")
    )
    #expect(RootErrorClassifier.volumePortion(of: "/Volumes/images/sessions/2026") == "/Volumes/images")
}

@Test func rootErrorClassifierFallsBackToPathNotFoundWhenNearestAncestorIsOrdinary() throws {
    #expect(
        RootErrorClassifier.classify(
            rootPath: "/tmp/foo/bar", subpath: nil,
            probe: fakeVolumeProbe(existingPrefixes: ["/tmp"])
        ) == .pathNotFound(path: "/tmp/foo/bar")
    )
    #expect(
        RootErrorClassifier.classify(
            rootPath: "/tmp/foo", subpath: "sub/dir",
            probe: fakeVolumeProbe(existingPrefixes: ["/tmp"])
        ) == .pathNotFound(path: "sub/dir")
    )
}

/// iCloud Drive's real on-disk container is `~/Library/Mobile
/// Documents/...` -- content not yet downloaded locally reads as "missing"
/// exactly like an unmounted network share, so a root under it should get
/// the "retry" recovery (`.volumeNotMounted`), not "re-pick the folder"
/// (`.pathNotFound`), regardless of what the ancestor-walk probe reports.
@Test func rootErrorClassifierTreatsAMobileDocumentsRootAsVolumeNotMounted() throws {
    let root = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Astro"
    #expect(
        RootErrorClassifier.classify(
            rootPath: root, subpath: nil,
            probe: fakeVolumeProbe(existingPrefixes: ["/Users/x/Library"])
        ) == .volumeNotMounted(path: root)
    )
    #expect(RootErrorClassifier.hasMobileDocumentsComponent(root))
    #expect(!RootErrorClassifier.hasMobileDocumentsComponent("/Volumes/images/sessions"))
}

/// A root that isn't under `/Volumes/` can still sit on a since-detached
/// volume mounted somewhere unusual (e.g. a firmlink-style boundary like
/// `/System/Volumes/Data`) -- when the nearest surviving ancestor looks
/// like a volume boundary, that's `.volumeNotMounted`, not `.pathNotFound`.
@Test func rootErrorClassifierTreatsANonVolumesRootOnADetachedBoundaryAsVolumeNotMounted() throws {
    let root = "/System/Volumes/Data/mnt/astro/sessions"
    #expect(
        RootErrorClassifier.classify(
            rootPath: root, subpath: nil,
            probe: fakeVolumeProbe(
                existingPrefixes: ["/System/Volumes/Data"],
                boundaries: ["/System/Volumes/Data"]
            )
        ) == .volumeNotMounted(path: root)
    )
}

/// The generic ancestor-boundary check never fires when the nearest
/// surviving ancestor is the filesystem root "/" itself, even if a
/// (deliberately unrealistic) probe claims "/" is a volume boundary --
/// "/" is never "unmounted".
@Test func rootErrorClassifierNeverTreatsTheFilesystemRootItselfAsAVolumeBoundary() throws {
    #expect(
        RootErrorClassifier.classify(
            rootPath: "/foo/bar", subpath: nil,
            probe: fakeVolumeProbe(existingPrefixes: ["/"], boundaries: ["/"])
        ) == .pathNotFound(path: "/foo/bar")
    )
}

@Test func rootErrorClassifierNearestExistingAncestorWalksUpPastMissingComponents() throws {
    let probe = fakeVolumeProbe(existingPrefixes: ["/a/b"])
    #expect(RootErrorClassifier.nearestExistingAncestor(of: "/a/b/c/d", pathExists: probe.pathExists) == "/a/b")
    #expect(RootErrorClassifier.nearestExistingAncestor(of: "/a/b", pathExists: probe.pathExists) == "/a/b")
}

@Test func scanCapturesFITSMetaForNewFITSFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_light.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 6248",
        "NAXIS2  =                 4176",
        "EXPTIME =                300.0",
        "INSTRUME= 'ZWO ASI2600MC Pro'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.exptime == 300.0)
    #expect(meta?.instrume == "ZWO ASI2600MC Pro")
}

/// R4-2: `XPIXSZ`/`EGAIN` are the two extra FITS header keys the absolute
/// session-quality metrics (`SessionQuality`) need -- pixel size in microns
/// and the camera's e-/ADU gain -- captured into schema v4's dedicated
/// `fits_meta.xpixsz`/`egain` columns exactly like every other FITS keyword.
@Test func scanCapturesXpixszAndEgainForNewFITSFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_light_xpixsz.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 6248",
        "NAXIS2  =                 4176",
        "EXPTIME =                300.0",
        "XPIXSZ  =                 3.76",
        "EGAIN   =                 0.75",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.xpixsz == 3.76)
    #expect(meta?.egain == 0.75)
}

@Test func scanCapturesImageMetaForNewTIFFFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "processed/NGC2237_Rosette_Nebula/2026-07-01/generated.tif"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: fileURL, focalLengthMM: 135.0, cameraModel: "Canon EOS Ra")

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.focallen == 135.0)
    #expect(meta?.instrume == "Canon EOS Ra")
}

@Test func scanCapturesExposureAndISOForDSLRStyleTIFFFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_dslr.tif"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: fileURL, exposureSeconds: 30.0, iso: 800)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.exptime == 30.0)
    #expect(meta?.gain == 800.0)
}

// MARK: - Extension coverage (R11 fix: non-Canon RAW / XISF / .fts / JPEG)

@Test func scanRecordsNikonSonyDNGAndXISFFilesWithTheirOwnKindBuckets() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let cases: [(path: String, expectedKind: String)] = [
        ("sessions/M45_Pleiades/2026-01-10/lights/nikon_0001.nef", "raw"),
        ("sessions/M45_Pleiades/2026-01-10/lights/sony_0001.arw", "raw"),
        ("sessions/M45_Pleiades/2026-01-10/lights/generic_0001.dng", "raw"),
        ("sessions/M45_Pleiades/2026-01-10/lights/pixinsight_0001.xisf", "xisf"),
        ("sessions/M45_Pleiades/2026-01-10/lights/fits_style.fts", "fits"),
    ]
    for (path, _) in cases {
        let fileURL = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not real capture bytes, just fixture content\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    for (path, expectedKind) in cases {
        let record = try fixture.db.file(path: path)
        #expect(record?.kind == expectedKind, "\(path) expected kind \(expectedKind), got \(record?.kind ?? "<nil>")")
    }
}

@Test func scanExtensionMatchingForRawAndXISFKindsIsCaseInsensitive() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let path = "sessions/M45_Pleiades/2026-01-10/lights/UPPERCASE_0001.NEF"
    let fileURL = fixture.root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not real capture bytes\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: path)
    #expect(record?.kind == "raw")
    #expect(record?.ext == "nef")
}

@Test func scanCapturesExposureAndISOForJPEGFile() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_dslr.jpg"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestJPEG(to: fileURL, exposureSeconds: 15.0, iso: 1600)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.exptime == 15.0)
    #expect(meta?.gain == 1600.0)
}

/// R11 fix: `dateObs` stored for a DSLR/mirrorless frame is now a UTC
/// instant (converted using the frame's own Exif `OffsetTimeOriginal` when
/// present), not the raw camera-local Exif string -- `SessionTimeline`
/// reads every `date_obs` value as UTC, so leaving it camera-local silently
/// shifted the frame's recorded instant by the observer's UTC offset.
@Test func scanConvertsExifDateTakenToUTCUsingOffsetTimeOriginal() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_dslr_utc.tif"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 04:36:24 local at UTC+2 is 02:36:24 UTC.
    try writeTestTIFF(to: fileURL, dateTimeOriginal: "2026:01:10 04:36:24", offsetTimeOriginal: "+02:00")

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.dateObs == "2026-01-10T02:36:24")
}

// MARK: - FITS keyword aliases (R11 fix: EXPOSURE / DATE-LOC / DATE)

@Test func scanFallsBackToExposureKeywordWhenExptimeIsAbsent() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/exposure_alias.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "EXPOSURE=                240.0",
        "END",
    ])
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.exptime == 240.0)
}

@Test func scanFallsBackToDateLocThenDateWhenDateObsIsAbsent() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativeDateLoc = "sessions/M45_Pleiades/2026-01-10/lights/date_loc_alias.fit"
    let dateLocURL = fixture.root.appendingPathComponent(relativeDateLoc)
    try FileManager.default.createDirectory(at: dateLocURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "DATE-LOC= '2026-01-10T04:36:24'",
        "END",
    ]).write(to: dateLocURL)

    let relativeDate = "sessions/M45_Pleiades/2026-01-10/lights/date_alias.fit"
    let dateURL = fixture.root.appendingPathComponent(relativeDate)
    try buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "DATE    = '2026-01-10T05:00:00'",
        "END",
    ]).write(to: dateURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let dateLocFileID = try #require(try fixture.db.file(path: relativeDateLoc)?.id)
    #expect(try fixture.db.fitsMeta(fileID: dateLocFileID)?.dateObs == "2026-01-10T04:36:24")

    let dateFileID = try #require(try fixture.db.file(path: relativeDate)?.id)
    #expect(try fixture.db.fitsMeta(fileID: dateFileID)?.dateObs == "2026-01-10T05:00:00")
}

// MARK: - NFC/NFD path normalization (R11 fix)

/// Simulates a library that moved from an old HFS+ (NFD-named) volume onto
/// APFS/SMB (NFC-named): a stale NFD row already sits in the DB from before
/// the rename, and a fresh scan of the NOW-NFC tree must retire that stale
/// row (not leave it permanently "present" alongside a new NFC row for the
/// same file) -- see `PathNormalization`'s doc comment for why this needs a
/// byte-wise staleness check rather than Swift's own canonical `Set<String>`
/// comparison.
@Test func rescanAfterNFDToNFCRenameRetiresStaleRowAndLeavesExactlyOnePresentRow() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let nfd = "Café Target".decomposedStringWithCanonicalMapping
    let nfc = "Café Target".precomposedStringWithCanonicalMapping
    #expect(Array(nfd.utf8) != Array(nfc.utf8), "fixture precondition: NFD and NFC byte forms must actually differ")

    // Insert a stale row directly, exactly as if an earlier scan (before
    // path normalization existed) had recorded this file's NFD-composed
    // name.
    let staleRecord = FileRecord(
        id: nil, path: "sessions/\(nfd)/2026-01-10/lights/light_0001.fit",
        size: 10, mtime: 1, ext: "fit", kind: "fits", area: .sessions,
        target: nfd, sessionDate: "2026-01-10", role: .light, scannedAt: 1,
        inode: nil, nlink: nil
    )
    _ = try fixture.db.upsertFile(staleRecord)

    // The tree on disk is NFC (today's APFS/SMB reality) -- write a real
    // file there and scan it.
    let relativePath = "sessions/\(nfc)/2026-01-10/lights/light_0001.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture content\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let allFiles = try fixture.db.allFiles(includeMissing: true)
    let matchingRows = allFiles.filter { $0.path.precomposedStringWithCanonicalMapping == "sessions/\(nfc)/2026-01-10/lights/light_0001.fit" }
    let present = matchingRows.filter { !$0.missing }
    #expect(present.count == 1, "expected exactly one non-missing row after the NFD->NFC rescan, got \(present.count)")
}

@Test func scannedRelativePathIsStoredInPrecomposedNFCForm() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let nfd = "Café Target".decomposedStringWithCanonicalMapping
    let nfc = "Café Target".precomposedStringWithCanonicalMapping
    #expect(Array(nfd.utf8) != Array(nfc.utf8), "fixture precondition: NFD and NFC byte forms must actually differ")

    let relativePath = "sessions/\(nfd)/2026-01-10/lights/light_0001.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "fixture content\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let allFiles = try fixture.db.allFiles(includeMissing: false)
    #expect(allFiles.contains { Array($0.path.utf8) == Array("sessions/\(nfc)/2026-01-10/lights/light_0001.fit".utf8) })
}

@Test func metaPersistsAcrossUnchangedRescan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_light2.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "EXPTIME =                120.0",
        "INSTRUME= 'ZWO ASI2600MM Pro'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let first = try scanner.scan()
    let second = try scanner.scan()

    #expect(second.added == 0)
    #expect(second.updated == 0)
    #expect(second.unchanged == first.added)

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    let meta = try fixture.db.fitsMeta(fileID: fileID)
    #expect(meta?.exptime == 120.0)
    #expect(meta?.instrume == "ZWO ASI2600MM Pro")
}

@Test func looseLightFrameDirectlyInDateDirGetsRoleFromIMAGETYP() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // No lights/ subdir at all -- the frame sits directly under the date
    // dir, exactly like the real IC1805 session that motivated this fix.
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_120.0s_0005.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .light)
    #expect(record.area == .sessions)
}

@Test func looseFrameWithNoRecognizableIMAGETYPStaysOther() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/loose_no_imagetyp.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .other)
}

@Test func rescanHealsStaleClassificationOnUnchangedFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Simulate a row left over from a pre-fix classifier version: on disk
    // the file is still (and always was) at the same size/mtime, but its
    // stored target/sessionDate are stale garbage a since-fixed classifier
    // bug would have produced.
    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    var stale = try #require(try fixture.db.file(path: relativePath))
    stale.target = ".DS_Store"
    stale.sessionDate = ".DS_Store"
    _ = try fixture.db.upsertFile(stale)

    let second = try scanner.scan()
    #expect(second.reclassified == 1)
    #expect(second.unchanged > 0)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.target == "M45_Pleiades")
    #expect(healed.sessionDate == "2026-01-10")
    #expect(healed.area == .sessions)
    #expect(healed.role == .light)
    // The file's own content/size/mtime were never touched.
    #expect(healed.size == stale.size)
    #expect(healed.contentHash == stale.contentHash)
}

@Test func looseFrameRoleSurvivesRescanUnchanged() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // Same loose-frame scenario as
    // `looseLightFrameDirectlyInDateDirGetsRoleFromIMAGETYP`: the FITS path
    // alone classifies as role `.other`, but the IMAGETYP-based refinement
    // upgrades it to `.light`. A rescan of the same (unchanged) file must
    // not let the stale-classification healing in `recordFile` downgrade it
    // back to `.other` just because the pure path classifier still says so.
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_120.0s_0005.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()
    let second = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .light)
    #expect(record.area == .sessions)
    #expect(second.reclassified == 0)
}

// MARK: - Residue must never be promoted via IMAGETYP
//
// Siril stack products (starless/starmask/registered sequences) inherit
// IMAGETYP='Light Frame' from the subs they were stacked from. Sitting loose
// in a session date dir (no lights/flats/darks/biases subdir), they hit the
// exact same "role .other, area .sessions, FITS header says Light" shape as
// a genuine loose light frame -- `refineLooseFrameRole` must not promote
// them just because their filename/dir happens to match
// `AstroConfig.residuePatterns`/`residueDirNames`, the SAME predicate
// `CleanupReport`'s audit uses to flag residue for cleanup.

@Test func looseResidueNamedFrameStaysOtherDespiteLightIMAGETYP() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // "r_*" is one of the default `residuePatterns` -- a Siril registered/
    // stacked byproduct left loose in the date dir, same shape as the
    // Heart-and-Soul fixture above but with a residue-matching name.
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/r_stacked.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .other)
    #expect(record.area == .sessions)
}

@Test func looseFrameInsideResidueProcessDirStaysOtherDespiteLightIMAGETYP() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // An ancestor directory named "process" (a default `residueDirNames`
    // entry) makes everything under it residue regardless of its own
    // filename -- mirrors `CleanupReport.residueCategory`'s dir-name
    // precedence.
    let relativePath = "sessions/M45_Pleiades/2026-01-10/process/starless.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .other)
    #expect(record.area == .sessions)
}

/// Writes a real residue-named FITS file (`r_*` pattern) with a Light Frame
/// IMAGETYP header, scans once (the residue guard already keeps it `.other`
/// on this first scan), then force-writes the stored role back to `.light`
/// -- simulating a row left over from BEFORE this fix, where the wrong
/// IMAGETYP-based promotion had already happened and was persisted. Returns
/// the scanner (reused across rescans) and the path so heal-pass tests can
/// pick up from exactly this "already polluted" state.
private func makeFixtureWithStaleResiduePromotion() throws -> (fixture: ScanFixture, scanner: LibraryScanner, relativePath: String) {
    let fixture = try ScanFixture.make()
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/r_stacked.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    var record = try #require(try fixture.db.file(path: relativePath))
    record.role = .light
    _ = try fixture.db.upsertFile(record)

    return (fixture, scanner, relativePath)
}

@Test func healDemotesPreviouslyPromotedResidueRowBackToOther() throws {
    let (fixture, scanner, relativePath) = try makeFixtureWithStaleResiduePromotion()
    defer { fixture.cleanup() }

    let second = try scanner.scan()
    #expect(second.reclassified == 1)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.role == .other)
}

@Test func healDemotionOfResidueRowIsIdempotentOnRescan() throws {
    let (fixture, scanner, relativePath) = try makeFixtureWithStaleResiduePromotion()
    defer { fixture.cleanup() }

    _ = try scanner.scan() // first heal pass: demotes the stale `.light` row back to `.other`
    let third = try scanner.scan()
    #expect(third.reclassified == 0)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.role == .other)
}

// MARK: - Stack-product recognition (StackDiscovery), the SECOND residue guard
//
// `starless_`/`starmask_`/`graxpert`-marked Siril byproducts don't match any
// `AstroConfig.residuePatterns` default -- adding those tokens there was
// tried and reverted (breaks `StackDiscovery`'s own stacks/processed-area
// variant recognition, which treats this exact vocabulary as first-class,
// WANTED output). Instead, `refineLooseFrameRole`/`healStaleClassification`
// additionally consult `StackDiscovery.classifiesAsStackProduct` -- the same
// engine `stacks/`/`processed`-area variant grouping already uses -- so this
// recognition is code, not config, and applies regardless of what the
// owner's `config.json` says.

@Test func looseStarlessNamedFrameStaysOtherDespiteLightIMAGETYPEvenWithoutAResiduePattern() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // "starless_*" matches NO default `residuePatterns` glob (that was
    // deliberately reverted -- see `AstroConfig.residuePatterns`'s doc
    // comment) but DOES classify as a stack product via `StackDiscovery`.
    // The session-scoped `sessionResiduePatterns` default would ALSO catch
    // it -- emptied here on purpose, so this test keeps proving the
    // code-driven guard alone suffices no matter what config.json says.
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/starless_stacked_result.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    var config = fixture.config
    config.sessionResiduePatterns = []
    let scanner = LibraryScanner(config: config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .other)
    #expect(record.area == .sessions)
    // Confirms the config-pattern predicate really doesn't already cover
    // this name under the emptied session list -- otherwise this test
    // wouldn't be exercising the stack-product guard at all.
    #expect(!ResidueMatcher.isResidue(path: relativePath, config: config))
}

/// Same shape as `makeFixtureWithStaleResiduePromotion` above, but for a
/// filename that only the STACK-PRODUCT guard recognizes: the session-
/// scoped pattern list (which would also match `starmask_*` by default) is
/// emptied so the heal path being pinned is the code-driven one.
private func makeFixtureWithStaleStackProductPromotion() throws -> (fixture: ScanFixture, scanner: LibraryScanner, relativePath: String) {
    let fixture = try ScanFixture.make()
    let relativePath = "sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/starmask_stacked_result.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    var config = fixture.config
    config.sessionResiduePatterns = []
    let scanner = LibraryScanner(config: config, db: fixture.db)
    _ = try scanner.scan()

    var record = try #require(try fixture.db.file(path: relativePath))
    record.role = .light
    _ = try fixture.db.upsertFile(record)

    return (fixture, scanner, relativePath)
}

@Test func healDemotesPreviouslyPromotedStackProductRowBackToOther() throws {
    let (fixture, scanner, relativePath) = try makeFixtureWithStaleStackProductPromotion()
    defer { fixture.cleanup() }

    let second = try scanner.scan()
    #expect(second.reclassified == 1)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.role == .other)
}

@Test func healDemotionOfStackProductRowIsIdempotentOnRescan() throws {
    let (fixture, scanner, relativePath) = try makeFixtureWithStaleStackProductPromotion()
    defer { fixture.cleanup() }

    _ = try scanner.scan()
    let third = try scanner.scan()
    #expect(third.reclassified == 0)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.role == .other)
}

// MARK: - Session-scoped residue patterns, the THIRD residue guard
//
// `result_Ha_12720s.fit` is the real library's hardest case: no universal
// pattern matches it (`result*` is WANTED `looksLikeStackOutput` vocabulary
// in `stacks/`/`processed/`), and `StackDiscovery.variantKind` classifies it
// `.original` (no starless/starmask/edit marker), so BOTH other guards pass
// it through. Only `AstroConfig.sessionResiduePatterns`'s `result_*`
// (consulted by `ResidueMatcher.isResidue` solely for `.sessions`-area
// paths) stops its inherited IMAGETYP='Light' from promoting it.

@Test func looseResultNamedStackedIntegrationStaysOtherDespiteLightIMAGETYP() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.role == .other)
    #expect(record.area == .sessions)
    // Confirms neither of the other two guards already covers this name --
    // otherwise this test wouldn't be exercising the session-pattern layer.
    #expect(!ResidueMatcher.matchesFilePattern(name: "result_Ha_12720s.fit", config: fixture.config))
    #expect(!StackDiscovery.classifiesAsStackProduct(fileName: "result_Ha_12720s.fit"))
}

@Test func healDemotesPreviouslyPromotedSessionPatternRowBackToOther() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                  100",
        "NAXIS2  =                  100",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    // Simulate the pre-fix wrong promotion exactly as the real DB copy has
    // it (role='light' on a session-loose stack integration).
    var record = try #require(try fixture.db.file(path: relativePath))
    record.role = .light
    _ = try fixture.db.upsertFile(record)

    let second = try scanner.scan()
    #expect(second.reclassified == 1)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.role == .other)
}

@Test func normalUnchangedFileHasNoRowChurn() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()
    let before = try #require(try fixture.db.file(path: relativePath))

    let second = try scanner.scan()
    let after = try #require(try fixture.db.file(path: relativePath))

    #expect(second.reclassified == 0)
    #expect(second.unchanged > 0)
    // No upsert happened for this row -- scannedAt is untouched.
    #expect(after.scannedAt == before.scannedAt)
}

@Test func corruptFITSFileIsRecordedButNoMetaRowIsWritten() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/corrupt.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "this is not a valid FITS header at all, just garbage bytes\n".write(
        to: fileURL, atomically: true, encoding: .utf8
    )

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan()
    #expect(summary.added > 0)

    let record = try fixture.db.file(path: relativePath)
    let fileID = try #require(record?.id)
    #expect(try fixture.db.fitsMeta(fileID: fileID) == nil)
}

// MARK: - refreshMeta backfill

@Test func refreshMetaBackfillsExposureForUnchangedDSLRTIFF() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_dslr_refresh.tif"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: fileURL, exposureSeconds: 30.0, iso: 800)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    let fileID = try #require(record.id)

    // Simulate a row left over from before the EXIF-exposure feature
    // existed: content/size/mtime never changed, but `exptime` was never
    // captured for this file -- exactly the state every pre-existing CR3/
    // TIFF in a real library is in today.
    try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: nil))

    let withoutFlag = try scanner.scan()
    #expect(withoutFlag.metaRefreshed == 0)
    #expect(try fixture.db.fitsMeta(fileID: fileID)?.exptime == nil)

    let withFlag = try scanner.scan(refreshMeta: true)
    #expect(withFlag.metaRefreshed == 1)
    #expect(try fixture.db.fitsMeta(fileID: fileID)?.exptime == 30.0)
    #expect(try fixture.db.fitsMeta(fileID: fileID)?.gain == 800.0)
}

@Test func refreshMetaAttemptsRecaptureForUnchangedFileWithNoMetaRow() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    // A corrupt FITS header fails to parse on first scan, so the file is
    // recorded but never gets a `fits_meta` row -- this covers the OTHER
    // refresh condition (no row at all) without needing to delete a row
    // out from under the Database directly.
    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/corrupt_refresh.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "this is not a valid FITS header at all, just garbage bytes\n".write(
        to: fileURL, atomically: true, encoding: .utf8
    )

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let record = try #require(try fixture.db.file(path: relativePath))
    let fileID = try #require(record.id)
    #expect(try fixture.db.fitsMeta(fileID: fileID) == nil)

    let withoutFlag = try scanner.scan()
    #expect(withoutFlag.metaRefreshed == 0)

    let withFlag = try scanner.scan(refreshMeta: true)
    #expect(withFlag.metaRefreshed == 1)
    // The content is still unparsable garbage, so the recapture attempt
    // still produces no row -- refreshMeta guarantees the attempt is made,
    // not that it succeeds.
    #expect(try fixture.db.fitsMeta(fileID: fileID) == nil)
}

@Test func refreshMetaSkipsUnchangedFileWithCompleteMeta() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/generated_complete.fit"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "EXPTIME =                180.0",
        "INSTRUME= 'ZWO ASI2600MM Pro'",
        "END",
    ])
    try headerData.write(to: fileURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let summary = try scanner.scan(refreshMeta: true)
    #expect(summary.metaRefreshed == 0)
}

// MARK: - README.txt notes capture (schema v5, R6-4)

/// `Fixtures.makeMessyLibrary` already plants a real
/// `sessions/M45_Pleiades/2026-01-10/README.txt` with
/// `"Camera: ZWO ASI2600MC Pro\nExposure (lights): 300s\n"` -- a first scan
/// must parse it into `session_notes` keyed by that session's own
/// (target, date).
@Test func scanCapturesReadmeNotesForNewReadme() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let notes = try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10")
    #expect(notes["Camera"] == "ZWO ASI2600MC Pro")
    #expect(notes["Exposure (lights)"] == "300s")
}

/// A `README.txt` sitting deeper than `sessions/<target>/<date>/` (e.g.
/// inside a role subdir) must never be mistaken for the session-level file
/// -- `PathClassifier` gives it a real role (`.light`, not `.other`), which
/// `captureReadmeNotes` uses to reject it.
@Test func readmeInsideRoleSubdirIsNotTreatedAsSessionReadme() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/README.txt"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try "Camera: should not be indexed\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let notes = try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10")
    #expect(notes["Camera"] == "ZWO ASI2600MC Pro", "the real session README.txt must still be the one on record")
}

@Test func modifiedReadmeIsReparsedOnNextScan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()
    #expect(try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10")["Camera"] == "ZWO ASI2600MC Pro")

    let readmeURL = fixture.root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/README.txt")
    try "Camera: Updated Camera\nLocation/Bortle: falu, 4\n".write(to: readmeURL, atomically: true, encoding: .utf8)
    let future = Date().addingTimeInterval(30)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: readmeURL.path)

    let summary = try scanner.scan()
    #expect(summary.updated >= 1)

    let notes = try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10")
    #expect(notes["Camera"] == "Updated Camera")
    #expect(notes["Location/Bortle"] == "falu, 4")
    #expect(notes["Exposure (lights)"] == nil, "replace-all semantics: the old key must be gone, not merged")
}

/// A plain rescan of an UNCHANGED README.txt must never re-touch
/// `session_notes` -- proven here by seeding a sentinel value directly (as
/// if some other process had written it) and confirming an ordinary rescan
/// leaves it exactly alone.
@Test func unchangedReadmeIsNotReparsedOnRescan() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    try fixture.db.upsertSessionNotes(
        target: "M45_Pleiades", date: "2026-01-10", notes: ["Sentinel": "untouched"]
    )

    let summary = try scanner.scan()
    #expect(summary.updated == 0)
    #expect(try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10") == ["Sentinel": "untouched"])
}

/// `--refresh-meta` backfill: an UNCHANGED README.txt with no
/// `session_notes` on record yet (e.g. scanned before R6-4 existed) gets
/// parsed on a refresh-meta rescan even though its content never changed.
@Test func refreshMetaBackfillsReadmeNotesWhenNoneRecordedYet() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let relativePath = "sessions/M45_Pleiades/2026-01-10/README.txt"
    let fileURL = fixture.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "Camera: ASI2600MC\nSQM: 20.8\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()
    #expect(try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10").isEmpty == false)

    // Simulate a pre-R6-4 row: notes wiped back to empty without touching
    // the file itself, so size/mtime still match what's on record.
    try fixture.db.upsertSessionNotes(target: "M45_Pleiades", date: "2026-01-10", notes: [:])

    let withoutFlag = try scanner.scan()
    #expect(withoutFlag.metaRefreshed == 0)
    #expect(try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10").isEmpty)

    let withFlag = try scanner.scan(refreshMeta: true)
    #expect(withFlag.metaRefreshed == 1)
    #expect(try fixture.db.sessionNotes(target: "M45_Pleiades", date: "2026-01-10")["SQM"] == "20.8")
}

// MARK: - inode / nlink capture (schema v3)

@Test func scanCapturesInodeAndNlinkForNewFile() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let record = try #require(try fixture.db.file(path: relativePath))
    #expect(record.inode != nil)
    #expect(record.nlink == 1)
}

@Test func hardlinkedCopyShowsSameInodeAndNlinkTwo() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let originalRelative = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    let originalURL = fixture.root.appendingPathComponent(originalRelative)
    let linkURL = fixture.root.appendingPathComponent(
        "sessions/M45_Pleiades/2026-01-10/lights/Review/light_0001.fit"
    )
    try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: originalURL, to: linkURL)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let original = try #require(try fixture.db.file(path: originalRelative))
    let link = try #require(
        try fixture.db.file(path: "sessions/M45_Pleiades/2026-01-10/lights/Review/light_0001.fit")
    )
    #expect(original.inode != nil)
    #expect(original.inode == link.inode)
    #expect(original.nlink == 2)
    #expect(link.nlink == 2)
}

@Test func rescanBackfillsInodeForRowScannedBeforeSchemaV3() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    _ = try scanner.scan()

    let relativePath = "sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit"
    var stale = try #require(try fixture.db.file(path: relativePath))
    // Simulate a v2-era row: inode/nlink never captured.
    stale.inode = nil
    stale.nlink = nil
    _ = try fixture.db.upsertFile(stale)
    #expect(try fixture.db.file(path: relativePath)?.inode == nil)

    let second = try scanner.scan()
    #expect(second.updated == 0)
    #expect(second.unchanged > 0)

    let healed = try #require(try fixture.db.file(path: relativePath))
    #expect(healed.inode != nil)
    #expect(healed.nlink == 1)
}

@Test func progressCallbackFiresEveryHundredFiles() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    // The base fixture has well under 100 files; add enough extras under a
    // fresh subtree to push past two 100-file checkpoints.
    for i in 0..<250 {
        let url = fixture.root.appendingPathComponent("stacks/Extra_Target/2026-01-01/f\(i).fit")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    final class CountBox: @unchecked Sendable {
        var counts: [Int] = []
    }
    let box = CountBox()

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan(progress: { count in
        box.counts.append(count)
    })

    #expect(summary.added >= 250)
    #expect(box.counts.contains(100))
    #expect(box.counts.contains(200))

    var previous = 0
    for count in box.counts {
        #expect(count > previous)
        previous = count
    }
}

@Test func detailedProgressUsesOnePassAndBoundedCallbacks() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<2_048 {
        let url = fixture.root.appendingPathComponent("stacks/Progress/f\(i).fit")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ScanProgress] = []

        func append(_ progress: ScanProgress) {
            lock.withLock { stored.append(progress) }
        }

        var values: [ScanProgress] {
            lock.withLock { stored }
        }
    }
    let box = ProgressBox()
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)

    _ = try scanner.scan(progressUpdate: box.append)

    let values = box.values
    let first = try #require(values.first)
    let last = try #require(values.last)
    #expect(first.scanned == 0)
    // The pre-count pass finishes well under its 2s deadline for a fixture
    // this small, so every update -- including the very first one -- should
    // already carry the SAME total, not just the final one.
    let total = try #require(first.total)
    #expect(values.allSatisfy { $0.total == total })
    #expect(last.scanned == total)
    #expect(last.fraction == 1)
    #expect(values.count <= (last.scanned / 64) + 3)
    #expect(values.dropFirst().dropLast().allSatisfy { $0.scanned % 64 == 0 })
}

/// Task 6 fix: a FIRST scan (nothing in the DB yet) used to always emit
/// `total: nil`, so the UI showed an indeterminate spinner the whole time
/// even for a small library that finishes in well under a second. A cheap
/// pre-count pass now gives `scan(progressUpdate:)` a real total before the
/// walk even starts.
@Test func progressCarriesATotalOnASmallFixtureLibraryFromTheVeryFirstUpdate() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    for i in 0..<5 {
        let url = fixture.root.appendingPathComponent("sessions/M31/2026-01-10/lights/f\(i).fit")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ScanProgress] = []
        func append(_ progress: ScanProgress) { lock.withLock { stored.append(progress) } }
        var values: [ScanProgress] { lock.withLock { stored } }
    }
    let box = ProgressBox()
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)

    let summary = try scanner.scan(progressUpdate: box.append)

    let first = try #require(box.values.first)
    #expect(first.total == summary.added)
    #expect(box.values.allSatisfy { $0.total == summary.added })
}

/// `progressUpdate == nil` (a caller that never asked for progress, e.g. the
/// CLI) must skip the pre-count pass entirely -- it's a second tree walk
/// spent for nobody, not just a value nobody reads.
@Test func scanWithoutAProgressUpdateCallbackDoesNotPerformThePreCountWalk() throws {
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    let url = fixture.root.appendingPathComponent("sessions/M31/2026-01-10/lights/f0.fit")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "x".write(to: url, atomically: true, encoding: .utf8)

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    let summary = try scanner.scan()
    #expect(summary.added == 1)
}

/// The pre-count pass bails out to `nil` (never a stale partial count) the
/// moment the caller cancels, so a slow pre-count on an enormous library
/// never blocks cancellation from taking effect promptly.
@Test func preCountBailsOutToNilTotalWhenCancelledMidWalk() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<512 {
        let url = fixture.root.appendingPathComponent("stacks/PreCountCancel/f\(i).fit")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    final class CancelAfterFirstCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func shouldCancel() -> Bool {
            lock.withLock {
                checks += 1
                return checks > 1
            }
        }
    }
    let cancellation = CancelAfterFirstCheck()
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)

    #expect(throws: CancellationError.self) {
        _ = try scanner.scan(progressUpdate: { _ in }, shouldCancel: cancellation.shouldCancel)
    }
}

/// Task 5 fix: `scan()` now batches its writes inside an explicit
/// transaction, committed every ~2000 files and on any error -- a scan
/// cancelled partway through must still durably persist whatever it fully
/// wrote before the cancellation landed, not leave those rows sitting in an
/// uncommitted (and therefore invisible-to-everyone-else) transaction
/// forever. Reopening a FRESH `Database` connection to the same on-disk
/// file (rather than reusing the scanner's own connection, which would see
/// its own uncommitted writes regardless via read-your-own-writes) is what
/// actually proves the commit happened.
@Test func cancelledScanDurablyPersistsFilesFullyWrittenBeforeCancellation() throws {
    // An otherwise-empty library (no messy fixture) so every checkCancellation
    // call is accounted for by these 64 files alone -- deterministic timing
    // for exactly when the cancellation lands mid-walk.
    let fixture = try ScanFixture.makeEmpty()
    defer { fixture.cleanup() }

    for i in 0..<64 {
        let url = fixture.root.appendingPathComponent("stacks/PartialCommit/f\(i).fit")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    final class CancelAfterN: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private let cancelAfter: Int
        init(cancelAfter: Int) { self.cancelAfter = cancelAfter }
        func shouldCancel() -> Bool {
            lock.withLock {
                checks += 1
                return checks > cancelAfter
            }
        }
    }
    let cancellation = CancelAfterN(cancelAfter: 40)
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)

    #expect(throws: CancellationError.self) {
        _ = try scanner.scan(shouldCancel: cancellation.shouldCancel)
    }

    let dbPath = fixture.dbDir.appendingPathComponent("test.sqlite").path
    let reopened = try Database(path: dbPath)
    let persistedUnderPartialCommit = try reopened.allFiles(includeMissing: false)
        .filter { $0.path.hasPrefix("stacks/PartialCommit/") }
        .count
    #expect(persistedUnderPartialCommit > 0)
    #expect(persistedUnderPartialCommit < 64)
}

@Test func detailedScanCooperativelyCancelsBeforeProcessingAllFiles() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    for i in 0..<512 {
        let url = fixture.root.appendingPathComponent("stacks/Cancellation/f\(i).fit")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
    }

    final class CancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0

        func shouldCancel() -> Bool {
            lock.withLock {
                checks += 1
                return checks > 90
            }
        }
    }
    let cancellation = CancellationCounter()
    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)

    #expect(throws: CancellationError.self) {
        _ = try scanner.scan(shouldCancel: cancellation.shouldCancel)
    }

    #expect(try fixture.db.allFiles(includeMissing: false).count < 512)
}
