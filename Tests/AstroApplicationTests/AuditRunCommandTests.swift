@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// A fresh fixture library + fresh sqlite-backed `Database` (real schema, via
/// `LibraryScanner`, mirroring `CalibrationLinkCommandTests`' own fixture),
/// plus a standalone `MetadataStore.temporary()` -- `AuditRunCommand` writes
/// to both, but they're deliberately two independent sqlite files, the same
/// separation production code keeps between the library's own index database
/// and this app's external metadata store.
private struct AuditCommandFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig
    let metadata: MetadataStore

    static func make() throws -> AuditCommandFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-run-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-run-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        let metadata = try MetadataStore.temporary()
        return AuditCommandFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config, metadata: metadata)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func writeFile(_ relativePath: String, bytes: Data) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }

    func command() -> AuditRunCommand {
        AuditRunCommand(db: db, config: config, metadata: metadata)
    }
}

@Suite("AuditRunCommand")
struct AuditRunCommandTests {
    @Test("A full audit finds residue and records a new audit_run_history row")
    func fullAuditRecordsFindingsAndHistory() async throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            "sessions/T1/2026-01-10/lights/light1.fit", bytes: Data("light".utf8)
        )
        try fixture.writeFile(
            "sessions/T1/2026-01-10/lights/.DS_Store", bytes: Data()
        )
        try fixture.scan()

        #expect(try await fixture.metadata.auditRunHistory().isEmpty)

        let outcome = try await fixture.command().runAudit(mode: .full)

        #expect(outcome.findings.contains { $0.category == "residue" })
        #expect(outcome.auditRun.findingCount == outcome.findings.count)
        #expect(!outcome.groupKeys.isEmpty)

        let history = try await fixture.metadata.auditRunHistory()
        #expect(history.count == 1)
        #expect(history.first?.findingCount == outcome.findings.count)
    }

    @Test("A second audit run diffs against the first")
    func secondAuditDiffsAgainstFirst() async throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFile(
            "sessions/T1/2026-01-10/lights/light1.fit", bytes: Data("light".utf8)
        )
        try fixture.writeFile(
            "sessions/T1/2026-01-10/lights/.DS_Store", bytes: Data()
        )
        try fixture.scan()

        _ = try await fixture.command().runAudit(mode: .full)

        try fixture.writeFile(
            "sessions/T1/2026-01-10/lights/stray.seq", bytes: Data("seq".utf8)
        )
        try fixture.scan()

        let second = try await fixture.command().runAudit(mode: .full)

        let history = try await fixture.metadata.auditRunHistory()
        #expect(history.count == 2)

        let diff = try await fixture.metadata.auditRunDiff()
        let unwrappedDiff = try #require(diff)
        #expect(!unwrappedDiff.newGroupKeys.isEmpty)
        #expect(second.groupKeys.count > history[1].groupKeys.count)
    }

    @Test("Fast mode skips the duplicate-content scan; full mode finds it")
    func fastModeSkipsDuplicateScan() async throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        // DuplicateFinder only ever hashes files >= 1 MiB, so both copies
        // need to clear that floor to actually be candidates.
        let payload = Data(repeating: 0xAB, count: 1_100_000)
        try fixture.writeFile("sessions/T1/2026-01-10/lights/light1.fit", bytes: payload)
        try fixture.writeFile("sessions/T1/2026-01-10/lights/light2.fit", bytes: payload)
        try fixture.scan()

        let fastOutcome = try await fixture.command().runAudit(mode: .fast)
        #expect(!fastOutcome.findings.contains { $0.category == "duplicate-content" })

        let fullOutcome = try await fixture.command().runAudit(mode: .full)
        #expect(fullOutcome.findings.contains { $0.category == "duplicate-content" })
    }

    @Test("isCancelled true before starting throws CancellationError and records no history")
    func cancellationBeforeStartSkipsTheRun() async throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFile("sessions/T1/2026-01-10/lights/light1.fit", bytes: Data("light".utf8))
        try fixture.scan()

        await #expect(throws: CancellationError.self) {
            try await fixture.command().runAudit(mode: .full, isCancelled: { true })
        }

        #expect(try await fixture.metadata.auditRunHistory().isEmpty)
    }

    @Test("A cancel that lands mid-run (after a few progress ticks, not just at the start/end phase boundary) stops the audit early and records no history")
    func cancellationMidRunStopsEarlyAndRecordsNoHistory() async throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFile("sessions/T1/2026-01-10/lights/light1.fit", bytes: Data("light".utf8))
        try fixture.scan()

        // `runAudit` itself only ever checks `isCancelled` twice at its own
        // phase boundaries (immediately before starting, and right after
        // `engine.run` returns) -- that's 2 calls. Before R12-W3's fix,
        // `AuditEngine.run` never called `isCancelled` at all in between, so
        // a canceller that only flips true on its 3rd-or-later call would
        // never actually fire (the audit would run to completion and record
        // history) -- exactly the bug this test guards against. After the
        // fix, `AuditEngine.run` ticks `progress` once per rule (20 rules by
        // default), and `runAudit` wraps that tick with its own
        // `isCancelled` check, so the 3rd call now lands on the SECOND
        // rule's tick, well before all 20 rules (let alone the duplicate
        // scan) finish.
        let canceller = CancelAfterN(threshold: 3)
        await #expect(throws: CancellationError.self) {
            try await fixture.command().runAudit(mode: .full, isCancelled: { canceller.check() })
        }

        #expect(try await fixture.metadata.auditRunHistory().isEmpty)
    }

    @Test("Filling missing checksums baselines every tracked file")
    func fillMissingChecksumsBaselinesAllFiles() throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        for index in 0..<10 {
            try fixture.writeFile(
                "sessions/T1/2026-01-10/lights/light\(index).fit",
                bytes: Data("light-\(index)".utf8)
            )
        }
        try fixture.scan()

        let outcome = try fixture.command().runVerify(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true)
        )

        #expect(outcome.baselineHashed == 10)
        #expect(outcome.baselineErrors.isEmpty)
        #expect(outcome.summary.checked == 10)
        #expect(outcome.summary.ok == 10)
    }

    @Test("Sample mode verifies only a fraction of the already-hashed files")
    func sampleModeChecksFewerFilesThanFull() throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        for index in 0..<20 {
            try fixture.writeFile(
                "sessions/T1/2026-01-10/lights/light\(index).fit",
                bytes: Data("light-\(index)".utf8)
            )
        }
        try fixture.scan()

        // Baseline first so every file has a cached hash and is eligible.
        let fullOutcome = try fixture.command().runVerify(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true)
        )
        #expect(fullOutcome.summary.checked == 20)

        let sampledOutcome = try fixture.command().runVerify(
            options: VerifyRunOptions(sampleFraction: 0.1, fillMissingChecksums: false)
        )

        // `FixityVerifier.eligibleFiles`'s own rounding: max(1, round(20 * 0.1)) == 2.
        #expect(sampledOutcome.summary.checked == 2)
        #expect(sampledOutcome.summary.checked < fullOutcome.summary.checked)
        #expect(sampledOutcome.baselineHashed == 0)
    }

    @Test("A cancel that lands mid-verify (after a few per-file progress ticks) stops the run early")
    func verifyCancellationMidRunStopsEarly() throws {
        let fixture = try AuditCommandFixture.make()
        defer { fixture.cleanup() }

        for index in 0..<5 {
            try fixture.writeFile(
                "sessions/T1/2026-01-10/lights/light\(index).fit",
                bytes: Data("light-\(index)".utf8)
            )
        }
        try fixture.scan()

        // Baseline every file first so all 5 are eligible for the verify
        // pass below.
        _ = try fixture.command().runVerify(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true)
        )

        // With `fillMissingChecksums: false` here, `runVerify` itself only
        // checks `isCancelled` twice at its own phase boundaries (before
        // starting, and -- since the baseline step is skipped -- once more
        // immediately after, before the verify pass). Before R12-W3's fix,
        // `FixityVerifier.verify`'s own per-file `progress` callback never
        // checked `isCancelled` at all, so a canceller that only flips true
        // on its 3rd-or-later call would never fire (all 5 files would be
        // verified normally). After the fix, `runVerify` wraps `progress`
        // with an `isCancelled` check, so the 3rd call lands on the FIRST
        // file's own per-file tick, well before all 5 files are checked.
        let canceller = CancelAfterN(threshold: 3)
        #expect(throws: CancellationError.self) {
            _ = try fixture.command().runVerify(
                options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: false),
                isCancelled: { canceller.check() }
            )
        }
    }
}

/// Flips to reporting `true` only once it has been called `threshold` times
/// -- simulates a user's cancel request landing mid-run (after a few
/// progress ticks) rather than before the very first check, so a caller is
/// proven to react to cancellation between two units of work, not just at
/// its own outer phase boundaries. Backed by an `NSLock` (same shape as
/// `AuditTests`' own `TickCounter`) since a plain captured `var` can't be
/// mutated from inside a `@Sendable` closure under strict concurrency
/// checking.
private final class CancelAfterN: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let threshold: Int

    init(threshold: Int) {
        self.threshold = threshold
    }

    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return callCount >= threshold
    }
}
