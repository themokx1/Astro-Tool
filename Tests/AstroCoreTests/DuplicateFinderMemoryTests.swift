import Darwin
import Foundation
import Testing
@testable import AstroCore

/// Opt-in memory repro/smoke test for the `audit` OOM bug: thousands of
/// same-camera FITS frames share an identical file size, so the size
/// prefilter alone passes almost everything through to full-content
/// hashing. Combined with a missing `autoreleasepool` around the chunked
/// reads, peak RSS grew unboundedly with total bytes hashed instead of
/// staying flat.
///
/// This test is a no-op under plain `swift test` (so it never adds runtime
/// or flakiness to the normal 249-test suite) and only does real work -- and
/// asserts a bound -- when `ASTROTOOL_MEMORY_SMOKE=1` is set in the
/// environment. Run it explicitly to reproduce/verify:
///
///   ASTROTOOL_MEMORY_SMOKE=1 /usr/bin/time -l \
///     swift test --filter memorySmokeTestBoundedRSSDuringDuplicateHashing
///
/// and read "maximum resident set size" from `time -l`'s output, or the
/// in-test `ru_maxrss` delta printed to stdout.
private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-dup-mem-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func currentMaxRSSBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    // Darwin reports ru_maxrss in bytes already (unlike Linux, which reports
    // KiB) -- this test only runs on macOS (Package.swift pins .macOS(.v14)).
    return Int64(usage.ru_maxrss)
}

@Test func memorySmokeTestBoundedRSSDuringDuplicateHashing() throws {
    guard ProcessInfo.processInfo.environment["ASTROTOOL_MEMORY_SMOKE"] != nil else { return }

    let libraryDir = try makeTempDir("lib")
    let dbDir = try makeTempDir("db")
    defer {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
    let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
    var config = AstroConfig()
    config.rootPath = libraryDir.path

    // Mirrors the real-world shape: many files sharing one identical size
    // (same camera, same sensor -> same byte count every time), almost all
    // content-distinct, with a handful of genuine full-content duplicates
    // mixed in.
    let fileCount = 60
    let fileSize = 5 * 1_048_576 // 5 MiB
    // Three real dup pairs, each pair sharing a distinct fill byte so the
    // pairs don't collide with each other -- only within a pair.
    let dupPairs: [Int: UInt8] = [10: 0xAB, 11: 0xAB, 30: 0xCD, 31: 0xCD, 50: 0xEF, 51: 0xEF]

    for i in 0..<fileCount {
        let path = libraryDir.appendingPathComponent("stacks/T/2026-01-01/frame\(i).fit")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var data: Data
        if let fillByte = dupPairs[i] {
            // Both members of a dup pair get identical content so they
            // collide at full-hash time; distinct fill byte per pair keeps
            // pairs from colliding with each other.
            data = Data(repeating: fillByte, count: fileSize)
        } else {
            // Distinct content per file: seed a few bytes with the index so
            // files don't accidentally collide, without paying to fill 5 MiB
            // of true randomness for 60 files.
            data = Data(count: fileSize)
            data[0] = UInt8(i % 256)
            data[1] = UInt8((i / 256) % 256)
            data[fileSize - 1] = UInt8(i % 251)
        }
        try data.write(to: path)
    }

    let scanner = LibraryScanner(config: config, db: db)
    _ = try scanner.scan()

    let before = currentMaxRSSBytes()
    let findings = try DuplicateFinder.findDuplicates(db: db, config: config)
    let after = currentMaxRSSBytes()

    let deltaMB = Double(after - before) / 1_048_576
    let totalDataMB = Double(fileCount * fileSize) / 1_048_576
    print("[memory-smoke] fixture: \(fileCount) files x \(fileSize / 1_048_576) MiB = \(Int(totalDataMB)) MiB total")
    print("[memory-smoke] ru_maxrss before=\(before) after=\(after) delta=\(String(format: "%.1f", deltaMB)) MiB")

    #expect(findings.count == 3) // three dup pairs -> three findings

    // Bounded-memory contract: peak RSS growth from doing the hashing must
    // stay far below the total bytes read (which the old whole-bucket
    // full-hash path with no autoreleasepool would approach), and under an
    // absolute ~150 MB ceiling regardless of fixture size.
    #expect(deltaMB < 150, "peak RSS grew by \(deltaMB) MiB during hashing of \(Int(totalDataMB)) MiB of fixture data -- expected bounded (<150 MB) growth")
}
