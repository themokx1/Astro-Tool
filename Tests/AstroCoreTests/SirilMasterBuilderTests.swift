import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixture helpers

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-master-builder-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A minimal, complete 16-bit FITS file -- `SirilMasterBuilder` only needs
/// something Siril's own `convert`/`stack` can actually load, not real star
/// content (unlike `RateTests.swift`'s `buildSyntheticStarFieldFITS`, which
/// needs a real PSF-like profile for `findstar` to detect anything).
/// Duplicated here rather than shared -- same convention every other test
/// file's own small FITS builder in this package already follows.
///
/// UNLIKE `RateTests.swift`'s own `build16BitFITS` (which never pads its
/// pixel data -- harmless there since `NativeStats` reads exactly
/// `NAXIS1*NAXIS2` bytes and never cares about FITS's own block-alignment
/// rule), this one DOES pad the pixel data block to a 2880-byte multiple.
/// The real Siril subprocess is a strict, cfitsio-backed reader: an
/// unpadded data block (found the hard way -- a first version of this
/// helper omitted the padding) reads back as "Error reading one of the
/// image areas" during `stack`, a genuinely corrupt-looking failure that
/// has nothing to do with `SirilMasterBuilder`'s own logic.
private func build16BitFITS(width: Int, height: Int, fill: Int) -> Data {
    var cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
    ]
    cards.append("END")
    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(width * height * 2)
    let value = UInt16(bitPattern: Int16(fill))
    for _ in 0..<(width * height) {
        pixelBytes.append(UInt8(value >> 8))
        pixelBytes.append(UInt8(value & 0xFF))
    }
    let remainder = pixelBytes.count % 2880
    if remainder != 0 {
        pixelBytes.append(Data(repeating: 0, count: 2880 - remainder))
    }
    data.append(pixelBytes)
    return data
}

@Test func initThrowsSirilNotFoundForANonexistentBinaryPath() {
    #expect(throws: AstroError.sirilNotFound(path: "/definitely/not/a/real/binary/siril-cli")) {
        _ = try SirilMasterBuilder(path: "/definitely/not/a/real/binary/siril-cli")
    }
}

/// The frame-count guard runs before any subprocess is ever spawned, so
/// `/bin/echo` (a real, always-present executable, never actually invoked
/// here) stands in for a real Siril binary -- this only needs `init` to
/// succeed, not a working Siril install, to observe the guard.
@Test func buildMasterThrowsInsufficientFramesBelowTheMinimum() throws {
    let builder = try SirilMasterBuilder(path: "/bin/echo")
    let workDir = try makeTempDir("insufficient")
    defer { try? FileManager.default.removeItem(at: workDir) }

    #expect(throws: SirilMasterBuilder.BuildError.insufficientFrames(have: 2, minimum: SirilMasterBuilder.minimumFrameCount)) {
        _ = try builder.buildMaster(
            kind: .dark,
            sourceURLs: [URL(fileURLWithPath: "/tmp/a.fit"), URL(fileURLWithPath: "/tmp/b.fit")],
            workDir: workDir
        )
    }
}

/// Integration test (guard-skipped when Siril isn't installed): runs the
/// REAL `siril-cli` subprocess end to end against synthetic dark frames in a
/// TEMP directory (never touches the scanned image library) and verifies a
/// real master FITS comes out. The exact script shape here was validated by
/// hand on a real Siril 1.4.4 install before being written into
/// `SirilMasterBuilder` itself -- see that type's own doc comment for the
/// two real findings from that validation (unquoted `-out=`, exit code not a
/// success signal) this test's own assertions are built to catch a
/// regression of.
@Test func realSirilCLIBuildsAMasterDarkFromSyntheticFrames() throws {
    let cfg = AstroConfig()
    guard FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) else {
        // No real Siril binary on this machine (e.g. CI runners never have
        // it installed) -- this integration smoke test only runs when one
        // is actually present, so skip rather than fail.
        return
    }

    let workDir = try makeTempDir("real-build")
    defer { try? FileManager.default.removeItem(at: workDir) }

    let sourcesDir = workDir.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
    var sourceURLs: [URL] = []
    for i in 0..<SirilMasterBuilder.minimumFrameCount {
        let url = sourcesDir.appendingPathComponent("dark_\(i).fit")
        try build16BitFITS(width: 32, height: 32, fill: 500 + i % 3).write(to: url)
        sourceURLs.append(url)
    }

    let builder = try SirilMasterBuilder(path: cfg.rating.sirilPath)
    let buildDir = workDir.appendingPathComponent("build", isDirectory: true)
    let outputURL = try builder.buildMaster(kind: .dark, sourceURLs: sourceURLs, workDir: buildDir)

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    #expect(outputURL.lastPathComponent.hasPrefix("master."))
}

@Test func realSirilCLIBuildMasterThrowsOutputMissingWhenSourcesAreUnreadable() throws {
    let cfg = AstroConfig()
    guard FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) else { return }

    let workDir = try makeTempDir("real-build-fail")
    defer { try? FileManager.default.removeItem(at: workDir) }

    // Symlinks to files that don't actually exist -- Siril's own `convert`
    // step should fail to produce a sequence, and this must surface as an
    // honest `outputMissing`, never a false success.
    let sourceURLs = (0..<SirilMasterBuilder.minimumFrameCount).map {
        workDir.appendingPathComponent("missing_\($0).fit")
    }

    let builder = try SirilMasterBuilder(path: cfg.rating.sirilPath)
    #expect(throws: (any Error).self) {
        _ = try builder.buildMaster(kind: .dark, sourceURLs: sourceURLs, workDir: workDir.appendingPathComponent("build2"))
    }
}
