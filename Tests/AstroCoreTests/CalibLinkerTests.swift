import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-calib-linker-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Fresh fixture library + fresh sqlite-backed `Database`, same minimal
/// shape as `SessionMatcherFixture`/`CalibFixture` -- each test builds only
/// the small tree it cares about.
private struct CalibLinkerFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibLinkerFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibLinkerFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a generated FITS file with the given EXPTIME/SET-TEMP cards --
    /// works for any role (light/flat/dark/bias), the role is derived from
    /// the path alone.
    func writeFITS(_ relativePath: String, exptime: Double? = nil, setTemp: Double? = nil) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    /// Writes a dummy file whose content nothing here inspects -- only its
    /// path matters (master calibration files, own session frames).
    func writeDummy(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - 1. Full plan: light-dark + flat-dark + biases

@Test func planIncludesLightDarkFlatDarkAndBiasesForSessionLackingAll() throws {
    let fixture = try CalibLinkerFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/flats/f\(i).fit", exptime: 6.8, setTemp: -10.0)
    }
    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master_a.fit")
    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master_b.fit")
    try fixture.writeDummy("calibration_library/darks/6.8sec_-10deg/flatdark_a.fit")
    try fixture.writeDummy("calibration_library/biases/bias_a.fit")
    try fixture.writeDummy("calibration_library/biases/bias_b.fit")
    // Decoy: an unrelated dark master that must not leak into the plan.
    try fixture.writeDummy("calibration_library/darks/60sec_-10deg/decoy.fit")

    try fixture.scan()

    let plan = try CalibLinker.plan(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(plan.target == "T1")
    #expect(plan.date == "2026-01-10")

    let darkItems = plan.items.filter { $0.destDir == "sessions/T1/2026-01-10/darks" }
    let lightDarkItems = darkItems.filter { $0.sourcePath.contains("300sec_-10deg") }
    let flatDarkItems = darkItems.filter { $0.sourcePath.contains("6.8sec_-10deg") }

    #expect(Set(lightDarkItems.map(\.sourcePath)) == Set([
        "calibration_library/darks/300sec_-10deg/master_a.fit",
        "calibration_library/darks/300sec_-10deg/master_b.fit",
    ]))
    #expect(lightDarkItems.allSatisfy { $0.reason == "dark 300s/-10°C a lightokhoz" })

    #expect(Set(flatDarkItems.map(\.sourcePath)) == Set([
        "calibration_library/darks/6.8sec_-10deg/flatdark_a.fit",
    ]))
    #expect(flatDarkItems.allSatisfy { $0.reason == "flat-dark 6.8s/-10°C a flatokhoz" })

    let biasItems = plan.items.filter { $0.destDir == "sessions/T1/2026-01-10/biases" }
    #expect(Set(biasItems.map(\.sourcePath)) == Set([
        "calibration_library/biases/bias_a.fit",
        "calibration_library/biases/bias_b.fit",
    ]))
    #expect(biasItems.allSatisfy { $0.reason == "bias master" })

    #expect(plan.items.count == lightDarkItems.count + flatDarkItems.count + biasItems.count)
    #expect(!darkItems.contains { $0.sourcePath.contains("60sec_-10deg") })
}

// MARK: - 2. Session with own darks/biases -> no items for those parts

@Test func planExcludesDarkAndBiasItemsWhenSessionHasItsOwn() throws {
    let fixture = try CalibLinkerFixture.make()
    defer { fixture.cleanup() }

    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    try fixture.writeDummy("sessions/T1/2026-01-10/darks/own_dark.fit")
    try fixture.writeDummy("sessions/T1/2026-01-10/biases/own_bias.fit")
    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master.fit")
    try fixture.writeDummy("calibration_library/biases/bias.fit")

    try fixture.scan()

    let plan = try CalibLinker.plan(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(plan.items.isEmpty)
}

// MARK: - 3. No lights at all -> empty plan

@Test func planIsEmptyForSessionWithNoLights() throws {
    let fixture = try CalibLinkerFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    try fixture.writeDummy("calibration_library/biases/bias.fit")

    try fixture.scan()

    let plan = try CalibLinker.plan(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(plan.items.isEmpty)
}

// MARK: - 4. No matching master at all -> empty plan (not an error)

@Test func planIsEmptyWhenNoLibraryMastersMatch() throws {
    let fixture = try CalibLinkerFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    // Only a 60s master exists -- doesn't match the 300s light.
    try fixture.writeDummy("calibration_library/darks/60sec_-10deg/master.fit")

    try fixture.scan()

    let plan = try CalibLinker.plan(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    // No dark match -> no dark items; no flats -> no flat-dark items; no
    // biases in the library at all -> no bias items either.
    #expect(plan.items.isEmpty)
}

// MARK: - 5. apply() hard-links, rerun skips everything

@Test func applyLinksFilesThenRerunSkipsAllWithoutOverwriting() throws {
    let fixture = try CalibLinkerFixture.make()
    defer { fixture.cleanup() }

    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master.fit")

    try fixture.scan()

    let plan = try CalibLinker.plan(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
    #expect(plan.items.count == 1)

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let result = try CalibLinker.apply(plan, root: fixture.libraryDir, using: writeGuard)

    #expect(result.linked == ["sessions/T1/2026-01-10/darks/master.fit"])
    #expect(result.skipped.isEmpty)

    let sourceURL = fixture.libraryDir.appendingPathComponent("calibration_library/darks/300sec_-10deg/master.fit")
    let destURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(FileManager.default.fileExists(atPath: destURL.path))

    let sourceInode = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.systemFileNumber] as? NSNumber)
    let destInode = (try FileManager.default.attributesOfItem(atPath: destURL.path)[.systemFileNumber] as? NSNumber)
    #expect(sourceInode == destInode)

    let rerun = try CalibLinker.apply(plan, root: fixture.libraryDir, using: writeGuard)
    #expect(rerun.linked.isEmpty)
    #expect(rerun.skipped == ["sessions/T1/2026-01-10/darks/master.fit"])

    // Original master untouched.
    #expect(try Data(contentsOf: sourceURL) == Data(contentsOf: destURL))
}

// MARK: - 6. Codable round-trip

@Test func calibLinkPlanRoundTripsThroughJSON() throws {
    let plan = CalibLinkPlan(
        target: "T1",
        date: "2026-01-10",
        items: [
            CalibLinkPlan.Item(
                sourcePath: "calibration_library/darks/300sec_-10deg/master.fit",
                destDir: "sessions/T1/2026-01-10/darks",
                reason: "dark 300s/-10°C a lightokhoz"
            ),
        ]
    )

    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(CalibLinkPlan.self, from: data)
    #expect(decoded == plan)
}
