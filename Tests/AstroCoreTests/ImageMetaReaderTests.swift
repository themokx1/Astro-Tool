import Foundation
import Testing
@testable import AstroCore

// `writeTestTIFF` lives in ImageTestBuilder.swift, shared with ScannerTests.

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-imagemeta-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func readReturnsFocalLengthCameraModelAndDateFromGeneratedTIFF() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("test.tif")
    try writeTestTIFF(to: url)

    let meta = ImageMetaReader.read(url: url)
    #expect(meta?.focalLengthMM == 50.0)
    #expect(meta?.cameraModel == "Canon EOS R6")
    #expect(meta?.dateTaken == "2026:01:15 20:30:00")
}

@Test func readReturnsNilForNonexistentFile() throws {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString).tif")
    #expect(ImageMetaReader.read(url: missingURL) == nil)
}

@Test func readReturnsNilForTextFileWithTifExtension() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("not-really-a-tiff.tif")
    try "this is just plain text, not image data\n".write(to: url, atomically: true, encoding: .utf8)

    #expect(ImageMetaReader.read(url: url) == nil)
}
