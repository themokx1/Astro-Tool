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

@Test func scanIsCaseInsensitiveOnExtensionAndSortsByRelativePath() throws {
    let root = try makeSourceDir()
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("x".utf8).write(to: root.appendingPathComponent("b.FIT"))
    try Data("x".utf8).write(to: root.appendingPathComponent("a.Fits"))

    let found = try CaptureImportScanner.scan(sourceRoot: root)
    #expect(found.map(\.relativeSourcePath) == ["a.Fits", "b.FIT"])
    #expect(found.allSatisfy { $0.kind == "fits" })
}
