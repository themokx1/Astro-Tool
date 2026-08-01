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

@Test func inaccessibleDirectoryThrowsAccessDenied() throws {
    let fixture = try ScanFixture.make()
    defer { fixture.cleanup() }

    let restrictedDir = fixture.root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights")
    let originalPermissions = try FileManager.default.attributesOfItem(atPath: restrictedDir.path)[.posixPermissions] as? NSNumber

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: originalPermissions ?? NSNumber(value: 0o755)],
            ofItemAtPath: restrictedDir.path
        )
    }

    let scanner = LibraryScanner(config: fixture.config, db: fixture.db)
    do {
        _ = try scanner.scan()
        Issue.record("expected AstroError.accessDenied to be thrown")
    } catch let AstroError.accessDenied(path) {
        #expect(path.contains("lights"))
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

@Test func rootErrorClassifierDecidesVolumeNotMountedVsPathNotFound() throws {
    #expect(
        RootErrorClassifier.classify(rootPath: "/Volumes/images/sessions", subpath: nil, volumeExists: { _ in false })
            == .volumeNotMounted(path: "/Volumes/images/sessions")
    )
    #expect(
        RootErrorClassifier.classify(rootPath: "/Volumes/images/sessions", subpath: nil, volumeExists: { _ in true })
            == .pathNotFound(path: "/Volumes/images/sessions")
    )
    #expect(
        RootErrorClassifier.classify(rootPath: "/tmp/foo/bar", subpath: nil, volumeExists: { _ in true })
            == .pathNotFound(path: "/tmp/foo/bar")
    )
    #expect(
        RootErrorClassifier.classify(rootPath: "/tmp/foo", subpath: "sub/dir", volumeExists: { _ in true })
            == .pathNotFound(path: "sub/dir")
    )
    #expect(RootErrorClassifier.volumePortion(of: "/Volumes/images/sessions/2026") == "/Volumes/images")
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
