import Foundation
import Testing
@testable import AstroCore

private func makeSourceDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-import-scanner-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func scanFindsFitsAndCr3FilesAndIgnoresEverythingElse() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let subdir = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

    try Data("fits bytes".utf8).write(to: root.appendingPathComponent("light_0001.fits"))
    try Data("raw bytes".utf8).write(to: subdir.appendingPathComponent("IMG_0001.CR3"))
    try Data("notes".utf8).write(to: root.appendingPathComponent("readme.txt"))
    try Data("thumb".utf8).write(to: subdir.appendingPathComponent("IMG_0001.JPG"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".DS_Store"))

    let found = try CaptureImportScanner.scan(sourceRoot: root)

    #expect(found.map(\.relativeSourcePath).sorted() == [
        "DCIM/100EOS_R/IMG_0001.CR3",
        "light_0001.fits",
    ])
    #expect(found.first { $0.fileName == "light_0001.fits" }?.kind == "fits")
    #expect(found.first { $0.fileName == "IMG_0001.CR3" }?.kind == "raw")
}

@Test func scanThrowsPathNotFoundForAMissingSourceRoot() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-import-scanner-missing-\(UUID().uuidString)", isDirectory: true)

    do {
        _ = try CaptureImportScanner.scan(sourceRoot: missing)
        Issue.record("expected pathNotFound to be thrown")
    } catch let AstroError.pathNotFound(path) {
        #expect(!path.isEmpty)
    } catch {
        Issue.record("expected AstroError.pathNotFound, got \(error)")
    }
}

@Test func scanProposesARoleFromFitsImagetypUsingTheSharedClassifier() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    0",
        "IMAGETYP= 'Flat Field'",
        "DATE-OBS= '2026-08-16T21:34:00'",
        "END",
    ])
    let url = root.appendingPathComponent("flat_0001.fits")
    try headerData.write(to: url)

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.proposedRole == .flat)
    #expect(file.captureDate == "2026-08-16")
    #expect(file.captureDateSource == .fitsDateObs)
}

@Test func scanLeavesCr3FilesUnclassifiedSinceThereIsNoEquivalentHeader() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appendingPathComponent("IMG_0002.cr3")
    try Data("not a real CR3, but the scanner never throws on an unreadable image".utf8).write(to: url)

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.proposedRole == nil, "CR3 has no IMAGETYP-equivalent header -- never silently guessed")
    #expect(file.kind == "raw")
    // No Exif could be read from this fake file either, so the fallback is
    // the file's own modification date -- still present, never `nil`.
    #expect(file.captureDate != nil)
    #expect(file.captureDateSource == .fileModificationDate)
}

@Test func scanFallsBackToFileModificationDateWhenAFitsHeaderHasNoDateObs() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    0",
        "IMAGETYP= 'Dark Frame'",
        "END",
    ])
    let url = root.appendingPathComponent("dark_0001.fits")
    try headerData.write(to: url)

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.proposedRole == .dark)
    #expect(file.captureDateSource == .fileModificationDate)
    #expect(file.captureDate != nil)
}

@Test func scanReadsExposureIsoAndApertureFromARawFilesExif() throws {
    // ImageIO reads by content, not extension -- a real CR3 can't be
    // synthesized in a test (see `ImageMetaReader`'s own doc comment), but a
    // valid TIFF named `.cr3` exercises the EXACT same ImageIO/Exif
    // dictionary codepath a real CR3 would hit through `ImageMetaReader
    // .read`, which is the honest limit of what this test can prove.
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appendingPathComponent("IMG_0003.cr3")
    // Explicit "+00:00" offset keeps the expected hour/minute/second below
    // independent of the machine's own time zone -- `ExifDateConversion`
    // (W5-4 fix) now converts camera-local Exif time to UTC using the
    // frame's own `OffsetTimeOriginal` when present, same as the library
    // scanner already does for a scanned CR3/RAW light.
    try writeTestTIFF(
        to: url, dateTimeOriginal: "2026:08:16 21:34:05", offsetTimeOriginal: "+00:00",
        exposureSeconds: 0.0002, iso: 100, apertureFNumber: 2.0
    )

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.exposureSeconds == 0.0002)
    #expect(file.iso == 100)
    #expect(file.apertureFNumber == 2.0)
    #expect(file.captureDate == "2026-08-16")
    // The display date is a truncated day string; captureInstant keeps the
    // seconds `CaptureBurstGrouper` needs to tell adjacent shots apart.
    let calendar = Calendar(identifier: .gregorian)
    var utcCalendar = calendar
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    let components = utcCalendar.dateComponents([.hour, .minute, .second], from: file.captureInstant)
    #expect(components.hour == 21)
    #expect(components.minute == 34)
    #expect(components.second == 5)
}

/// The card-import wizard's `captureDate`/`captureInstant` for a raw
/// (CR3/RAW) frame come from Exif `DateTimeOriginal`, which is camera-LOCAL
/// wall-clock time -- before this fix, `classify(fileURL:ext:kind:)` handed
/// that string straight to `SessionTimeline.parseDateObs`, which parses
/// every value (FITS or Exif shape) as UTC, so a card imported from a
/// non-UTC-observing session got every date silently off by the offset. Now
/// routed through the SAME `ExifDateConversion` the library scanner already
/// applies when it introspects a scanned CR3/RAW light.
@Test func scanConvertsRawExifDateTakenToUTCUsingOffsetTimeOriginal() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = root.appendingPathComponent("IMG_0004.cr3")
    // 04:36:24 local at UTC+2 is 02:36:24 UTC.
    try writeTestTIFF(to: url, dateTimeOriginal: "2026:01:10 04:36:24", offsetTimeOriginal: "+02:00")

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.captureDate == "2026-01-10")
    #expect(file.captureDateSource == .exifDateTaken)
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    let components = utcCalendar.dateComponents([.hour, .minute, .second], from: file.captureInstant)
    #expect(components.hour == 2)
    #expect(components.minute == 36)
    #expect(components.second == 24)
}

/// W5-4 item 4: the import wizard's FITS groups used to show no exposure
/// summary at all -- CR3 groups get exposure/ISO/aperture from Exif
/// (`CaptureGroupExposureSummary`), but a FITS light's own `EXPTIME` header
/// was never read by this scanner, so `DiscoveredCaptureFile.exposureSeconds`
/// stayed `nil` for every FITS file and the Classify step's group row
/// rendered no exposure line for a real Light group. `classify(fileURL:)`
/// already opens the FITS header once for `IMAGETYP`/`DATE-OBS` -- this only
/// adds one more key read from that SAME already-open header, no second file
/// open.
@Test func scanReadsExptimeFromFitsHeaderIntoExposureSeconds() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    0",
        "IMAGETYP= 'Light Frame'",
        "DATE-OBS= '2026-08-16T21:34:00'",
        "EXPTIME =                300.0",
        "END",
    ])
    let url = root.appendingPathComponent("light_0001.fits")
    try headerData.write(to: url)

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.proposedRole == .light)
    #expect(file.exposureSeconds == 300.0)
}

/// A FITS file with no `EXPTIME` card at all (or an unreadable header) must
/// report `nil`, never a guessed or stale value -- same "no exposure line at
/// all" honesty the Classify step already relies on for a group with no Exif
/// data.
@Test func scanReportsNilExposureSecondsWhenFitsHeaderHasNoExptime() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let headerData = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    0",
        "IMAGETYP= 'Dark Frame'",
        "END",
    ])
    let url = root.appendingPathComponent("dark_0001.fits")
    try headerData.write(to: url)

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    let file = try #require(found.first)

    #expect(file.exposureSeconds == nil)
}

@Test func scanIsCaseInsensitiveOnExtensionAndSortsByRelativePath() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("x".utf8).write(to: root.appendingPathComponent("b.FIT"))
    try Data("x".utf8).write(to: root.appendingPathComponent("a.Fits"))

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    #expect(found.map(\.relativeSourcePath) == ["a.Fits", "b.FIT"])
    #expect(found.allSatisfy { $0.kind == "fits" })
}
