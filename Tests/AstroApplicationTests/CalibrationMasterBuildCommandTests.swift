@testable import AstroApplication
import AstroCore
import Foundation
import Testing

// MARK: - Fixture helpers

private func calibBuildCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func calibBuildHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(calibBuildCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// Fresh fixture library + fresh sqlite-backed `Database`, mirroring
/// `SensorMeasurementCommandTests.swift`'s own fixture shape.
private struct CalibBuildFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> Self {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-build-command-tests-\(UUID().uuidString)", isDirectory: true)
        let libraryDir = base.appendingPathComponent("library", isDirectory: true)
        let dbDir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("astrotool.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return Self(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir.deletingLastPathComponent())
    }

    /// Writes `count` homogeneous session dark subs at the given (exposure,
    /// temp, gain, offset, camera) combo, one directory-worth of `.fit`
    /// files under `sessions/T1/2026-01-10/darks/`.
    func writeDarkSubs(
        count: Int, exptime: Double, setTemp: Double, gain: Double, offset: Double, instrume: String,
        target: String = "T1", date: String = "2026-01-10"
    ) throws {
        for i in 0..<count {
            let url = libraryDir.appendingPathComponent("sessions/\(target)/\(date)/darks/d\(i).fit")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cards = [
                "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
                "EXPTIME =                \(exptime)", "SET-TEMP=                \(setTemp)",
                "GAIN    =                \(gain)", "OFFSET  =                \(offset)",
                "INSTRUME= '\(instrume)'", "END",
            ]
            try calibBuildHeaderData(cards).write(to: url)
        }
    }

    /// Writes `count` usable session LIGHT frames at the given combo -- only
    /// needed by tests that also exercise `CalibAnalyzer.coverage()` itself
    /// (which enumerates combos from scanned LIGHTS, never from the dark
    /// subs a master would be built from).
    func writeLightFrames(
        count: Int, exptime: Double, setTemp: Double, gain: Double, offset: Double, instrume: String,
        target: String = "T1", date: String = "2026-01-10"
    ) throws {
        for i in 0..<count {
            let url = libraryDir.appendingPathComponent("sessions/\(target)/\(date)/lights/l\(i).fit")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cards = [
                "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
                "EXPTIME =                \(exptime)", "SET-TEMP=                \(setTemp)",
                "GAIN    =                \(gain)", "OFFSET  =                \(offset)",
                "INSTRUME= '\(instrume)'", "END",
            ]
            try calibBuildHeaderData(cards).write(to: url)
        }
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

private let sampleNeed = CalibNeed(
    kind: .dark, exposureSeconds: 120.0, tempC: -10.0, lightCount: 40,
    targets: ["T1"], matchedMasterPath: nil, masterAgeDays: nil, isStale: false, todo: nil
)

/// A fake master-file build: creates a small, real file at `workDir/process/
/// master.fit` and returns its URL, without ever spawning a subprocess --
/// exercises `CalibrationMasterBuildCommand`'s own write/rescan path in
/// isolation from `SirilMasterBuilder`/a real Siril install.
private func fakeSuccessfulBuilder(_ kind: FrameRole, _ sourceURLs: [URL], _ workDir: URL) throws -> URL {
    let processDir = workDir.appendingPathComponent("process", isDirectory: true)
    try FileManager.default.createDirectory(at: processDir, withIntermediateDirectories: true)
    let outputURL = processDir.appendingPathComponent("master.fit")
    try Data("fake master bytes".utf8).write(to: outputURL)
    return outputURL
}

@Suite("CalibrationMasterBuildCommand (V3 pre-stack program section 5.2, Kalibrációs automata)")
struct CalibrationMasterBuildCommandTests {
    @Test(".readOnly access mode refuses before ever touching Siril")
    func readOnlyModeRefusesImmediately() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .readOnly,
            masterBuilder: { _, _, _ in
                Issue.record("masterBuilder must never be called in .readOnly mode")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        #expect(throws: LibraryMutationError.readOnly) {
            try command.buildDarkMaster(need: sampleNeed)
        }
    }

    @Test("autoMasterBuildEnabled == false refuses even with write access")
    func autoBuildDisabledRefuses() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        // `autoMasterBuildEnabled` defaults to false -- left untouched.

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in
                Issue.record("masterBuilder must never be called with autoMasterBuildEnabled == false")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        #expect(throws: CalibrationMasterBuildError.autoBuildDisabled) {
            try command.buildDarkMaster(need: sampleNeed)
        }
    }

    @Test("A combo with no recorded temperature refuses -- there is no honest directory to place it in")
    func noTemperatureRefuses() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        let needWithoutTemp = CalibNeed(
            kind: .dark, exposureSeconds: 120.0, tempC: nil, lightCount: 10,
            targets: ["T1"], matchedMasterPath: nil, masterAgeDays: nil, isStale: false, todo: nil
        )

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in
                Issue.record("masterBuilder must never be called for a temperature-less combo")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        #expect(throws: CalibrationMasterBuildError.noTemperature) {
            try command.buildDarkMaster(need: needWithoutTemp)
        }
    }

    @Test("Fewer than the minimum source darks refuses with the exact have/minimum counts")
    func insufficientFramesRefuses() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        try fixture.writeDarkSubs(count: 3, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        try fixture.scan()

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in
                Issue.record("masterBuilder must never be called below the minimum frame count")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        #expect(throws: CalibrationMasterBuildError.insufficientFrames(have: 3, minimum: SirilMasterBuilder.minimumFrameCount)) {
            try command.buildDarkMaster(need: sampleNeed)
        }
    }

    @Test("Electronically heterogeneous source darks refuse rather than silently pick one identity")
    func heterogeneousSourcesRefuses() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        try fixture.writeDarkSubs(
            count: 5, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro", date: "2026-01-10"
        )
        try fixture.writeDarkSubs(
            count: 5, exptime: 120, setTemp: -10, gain: 200, offset: 50, instrume: "ZWO ASI2600MC Pro", date: "2026-01-11"
        )
        try fixture.scan()

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in
                Issue.record("masterBuilder must never be called over a heterogeneous source set")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        do {
            _ = try command.buildDarkMaster(need: sampleNeed)
            Issue.record("Expected heterogeneousSources to be thrown")
        } catch CalibrationMasterBuildError.heterogeneousSources(let reasons) {
            #expect(!reasons.isEmpty)
        }
    }

    @Test("A masterBuilder throwing AstroError.sirilNotFound surfaces as sirilUnavailable")
    func sirilUnavailableSurfacesHonestly() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        try fixture.writeDarkSubs(count: 10, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        try fixture.scan()

        let sirilPath = fixture.config.rating.sirilPath
        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in throw AstroError.sirilNotFound(path: sirilPath) }
        )

        #expect(throws: CalibrationMasterBuildError.sirilUnavailable(path: sirilPath)) {
            try command.buildDarkMaster(need: sampleNeed)
        }
    }

    @Test("A masterBuilder throwing any other error surfaces as an honest buildFailed, no partial file left behind")
    func otherBuildFailuresSurfaceAsBuildFailed() throws {
        struct SomeProcessError: Error {}
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        try fixture.writeDarkSubs(count: 10, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        try fixture.scan()

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: { _, _, _ in throw SomeProcessError() }
        )

        do {
            _ = try command.buildDarkMaster(need: sampleNeed)
            Issue.record("Expected buildFailed to be thrown")
        } catch CalibrationMasterBuildError.buildFailed {
            // Expected.
        }
        // Never wrote anything into calibration_library/.
        let calibDir = fixture.libraryDir.appendingPathComponent("calibration_library/darks/120sec_-10deg")
        #expect(!FileManager.default.fileExists(atPath: calibDir.path))
    }

    @Test("A successful build writes into calibration_library/darks/, and coverage() sees it on the very next read")
    func successfulBuildWritesMasterAndCoverageSeesItImmediately() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        fixture.config.calib.autoMasterBuildEnabled = true
        try fixture.writeDarkSubs(count: 10, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        // `coverage()` enumerates combos from scanned LIGHTS, never from the
        // dark subs a master is built from -- without at least one usable
        // light at this exact combo, this combo would never appear as a
        // "need" row for the before/after assertions below to check at all.
        try fixture.writeLightFrames(count: 5, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        try fixture.scan()

        // Before the build: the combo is a genuine gap.
        let before = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
        let beforeNeed = before.first { $0.exposureSeconds == 120.0 && $0.tempC == -10.0 }
        #expect(beforeNeed?.matchedMasterPath == nil)

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled,
            masterBuilder: fakeSuccessfulBuilder
        )

        let receipt = try command.buildDarkMaster(need: sampleNeed)

        #expect(receipt.masterPath.hasPrefix("calibration_library/darks/120sec_-10deg/"))
        #expect(receipt.sourceFrameCount == 10)
        #expect(FileManager.default.fileExists(atPath: fixture.libraryDir.appendingPathComponent(receipt.masterPath).path))

        // After the build: the same combo is no longer a gap -- the gap
        // list is the only source of truth, per this feature's own spec.
        let after = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
        let afterNeed = after.first { $0.exposureSeconds == 120.0 && $0.tempC == -10.0 }
        #expect(afterNeed?.matchedMasterPath == receipt.masterPath.split(separator: "/").dropLast().joined(separator: "/"))
    }

    // MARK: - preview

    @Test("preview() reports the honest source count and gates, without writing anything")
    func previewReportsHonestState() throws {
        var fixture = try CalibBuildFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeDarkSubs(count: 4, exptime: 120, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro")
        try fixture.scan()

        let command = CalibrationMasterBuildCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .readOnly,
            masterBuilder: { _, _, _ in
                Issue.record("preview() must never invoke masterBuilder")
                return URL(fileURLWithPath: "/tmp/never.fit")
            }
        )

        let preview = try command.preview(need: sampleNeed)
        #expect(preview.sourceFrameCount == 4)
        #expect(preview.minimumFrameCount == SirilMasterBuilder.minimumFrameCount)
        #expect(preview.mismatchReasons.isEmpty)
        // autoMasterBuildEnabled defaults to false -- canBuild must be false
        // even though nothing else here would block it.
        #expect(preview.autoBuildEnabled == false)
        #expect(!preview.canBuild)
    }
}
