import Foundation
import Testing
@testable import AstroCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-ingest-classifier-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func classifierFindsAFitsFileAFewLevelsDeep() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let subdir = root.appendingPathComponent("DCIM/100EOS_R", isDirectory: true)
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    try Data("fits bytes".utf8).write(to: subdir.appendingPathComponent("light_0001.fits"))

    #expect(IngestVolumeClassifier.isLikelyCaptureVolume(at: root))
}

@Test func classifierFindsACR3FileAtTheRoot() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("raw bytes".utf8).write(to: root.appendingPathComponent("IMG_0001.CR3"))

    #expect(IngestVolumeClassifier.isLikelyCaptureVolume(at: root))
}

@Test func classifierReportsFalseForAVolumeWithNoCaptureFiles() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("hello".utf8).write(to: root.appendingPathComponent("readme.txt"))
    try Data("thumb".utf8).write(to: root.appendingPathComponent("IMG_0001.JPG"))

    #expect(!IngestVolumeClassifier.isLikelyCaptureVolume(at: root))
}

@Test func classifierIgnoresHiddenEntriesAndSymlinks() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("spotlight".utf8).write(to: root.appendingPathComponent(".Spotlight-V100"))
    let target = root.appendingPathComponent("target.fits")
    try Data("fits".utf8).write(to: target)
    // A symlink whose NAME still ends in .fits must never count -- only a
    // real, resident capture file should ever flip this to `true`.
    let linkRoot = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: linkRoot) }
    try FileManager.default.createSymbolicLink(
        at: linkRoot.appendingPathComponent("linked.fits"), withDestinationURL: target
    )

    #expect(!IngestVolumeClassifier.isLikelyCaptureVolume(at: linkRoot))
}

@Test func classifierGivesUpAfterSampleLimitWithNoHit() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<10 {
        try Data("junk".utf8).write(to: root.appendingPathComponent("junk_\(index).txt"))
    }
    // The one real capture file sits past the sample limit -- a bounded
    // walk must not find it, honestly trading a rare false negative for a
    // guaranteed-cheap check on every volume mount.
    try Data("fits".utf8).write(to: root.appendingPathComponent("zzz_last.fits"))

    #expect(!IngestVolumeClassifier.isLikelyCaptureVolume(at: root, sampleLimit: 5))
}
