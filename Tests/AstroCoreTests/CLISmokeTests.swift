import Foundation
import Testing
@testable import AstroCore

// MARK: - Binary + process helpers

/// Locates the repo root by walking up from this test file's own path until
/// a `Package.swift` is found, then returns the built debug binary under
/// `.build/debug/astrotool`. `swift test` always builds every target in the
/// package first (including the `astrotool` executable, since it's a
/// dependency-free sibling target in the same package), so this binary is
/// guaranteed to exist by the time these tests run.
private func repoRoot() -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while true {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        precondition(parent.path != dir.path, "reached filesystem root without finding Package.swift")
        dir = parent
    }
}

private func astrotoolBinary() -> URL {
    repoRoot().appendingPathComponent(".build/debug/astrotool")
}

private struct CLIResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

/// Thread-safe one-shot box for bytes read off a pipe on a background
/// queue -- mirrors `SirilCLI`'s own `OutputCollector` pattern for the same
/// reason: a plain `var` written from a background closure and read back
/// after a semaphore wait is a data race as far as the compiler's
/// `Sendable` checking is concerned, even though the semaphore establishes
/// a real happens-before edge.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return _data
    }
    func set(_ data: Data) {
        lock.lock(); _data = data; lock.unlock()
    }
}

/// Runs the built `astrotool` binary with `args` and captures stdout/stderr/
/// exit code. Reads stderr on a background queue concurrently with the
/// stdout read, so a command that writes a lot to one stream while the other
/// pipe's buffer fills can never deadlock this helper.
///
/// `async`, and every blocking call inside it happens on a Dispatch queue
/// rather than on the caller's thread, because the caller's thread belongs
/// to the Swift concurrency cooperative pool -- and that pool is
/// process-wide, fixed-width (one thread per active core, 10 on this
/// machine) and shared by every one of the 112 suites `swift test` runs in
/// parallel.
///
/// This used to be a synchronous function called from 204 synchronous
/// `@Test func`s, each of which therefore parked a cooperative thread for
/// the whole lifetime of a subprocess. With 204 of them and only 10 threads,
/// the pool sat fully occupied for the ~16 seconds this file takes, and
/// nothing else in the run could get a thread: any test elsewhere waiting on
/// a `Task.detached` to start simply did not get one inside its deadline.
/// That is what made the suite's failures load-dependent and made them land
/// on tests that have nothing to do with the CLI -- `LibraryLaunchScanTests`,
/// `LibraryHealthStoreTests`, `ReviewStoreTests`, all of them merely waiting
/// on `OperationHost.run`'s detached task. Skipping this one file took the
/// full run from ~27s with a rotating cast of failures to ~10s clean, which
/// is how it was identified.
///
/// Suspending instead of blocking costs nothing here (this file runs in
/// about the same wall time either way -- subprocess spawn dominates) and
/// hands those ten threads back to the rest of the run.
private func runCLI(_ args: [String]) async throws -> CLIResult {
    // The throttle is not optional. Blocking used to cap this file at ~10
    // subprocesses in flight (one per cooperative thread) purely as a side
    // effect of the bug above; suspending removes that accidental cap, and
    // without a deliberate replacement all 204 tests spawn at once and
    // several hundred blocking pipe reads pile onto `DispatchQueue.global`,
    // which tops out around 64 threads. Eight keeps roughly the concurrency
    // this file always had, and it is not competing with anything now.
    await CLISubprocessLimiter.shared.acquire()
    do {
        let result = try await runCLIOffTheCooperativePool(args)
        await CLISubprocessLimiter.shared.release()
        return result
    } catch {
        await CLISubprocessLimiter.shared.release()
        throw error
    }
}

/// Caps concurrent `astrotool` subprocesses, restoring the throughput the
/// old thread-blocking runner got by accident without taking the
/// cooperative pool hostage to do it. Waiters suspend; they hold no thread.
private actor CLISubprocessLimiter {
    static let shared = CLISubprocessLimiter(limit: 8)

    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        guard inFlight >= limit else {
            inFlight += 1
            return
        }
        // Resumed by `release()`, which hands its slot over directly rather
        // than decrementing -- so `inFlight` stays accurate without this
        // side having to re-increment after waking.
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Hands the whole original, synchronous body to a Dispatch queue and awaits
/// it through a continuation. Deliberately NOT decomposed into concurrent
/// async reads: `Process.waitUntilExit()` is not safe to call from a
/// different thread than the one draining the pipes -- doing so hangs
/// forever on an already-exited process (observed: a sample of the stalled
/// run showed 2630 of 3000 samples parked inside `waitUntilExit`, with zero
/// `astrotool` processes actually alive). The sequence below is byte-for-byte
/// the one that has always worked; the only thing that changed is which
/// thread pool it blocks.
private func runCLIOffTheCooperativePool(_ args: [String]) async throws -> CLIResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            do {
                continuation.resume(returning: try runCLIBlocking(args))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Reads stderr on a second background queue concurrently with the
/// synchronous stdout read, so a command that writes a lot to one stream
/// while the other pipe's buffer fills can never deadlock this helper.
private func runCLIBlocking(_ args: [String]) throws -> CLIResult {
    let process = Process()
    process.executableURL = astrotoolBinary()
    process.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()

    let errBox = OutputBox()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        errDone.signal()
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()

    return CLIResult(
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errBox.data, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
    )
}

private func makeTempRoot(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astrotool-cli-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func rootRequiredCommandWithoutRootExplainsHowToContinue() async throws {
    let result = try await runCLI(["stats"])

    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("no library root selected"))
    #expect(result.stderr.contains("--root /path/to/library"))
    #expect(!result.stderr.contains("path not found: \n"))
}

@Test func sessionConvertPlanRequiresOneExactTargetAndDate() async throws {
    let root = try makeTempRoot("convert-scope")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["session-convert", "plan", "--root", root.path, "--target", "IC_1396"])

    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--target and --date are required"))
}

@Test func captureCreateAndListRoundTripThroughCLIJSON() async throws {
    let root = try makeTempRoot("capture-cli")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("sessions/IC_1396/2026-08-08", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

    let created = try await runCLI([
        "capture", "create", "--root", root.path, "--target", "IC_1396", "--date", "2026-08-08",
        "--name", "SV220 köd sorozat", "--slug", "sv220-300s", "--sensor", "osc",
        "--signal", "dual_band", "--filter-maker", "SVBONY", "--filter-model", "SV220", "--json"
    ])
    #expect(created.exitCode == 0)
    #expect(created.stdout.contains("\"slug\" : \"sv220-300s\""))

    let listed = try await runCLI([
        "capture", "list", "--root", root.path, "--target", "IC_1396", "--date", "2026-08-08", "--json"
    ])
    #expect(listed.exitCode == 0)
    #expect(listed.stdout.contains("SV220 köd sorozat"))
}

@Test func sessionConvertPlanJSONNamesExactSingleSessionPathsAndApplyNeedsConfirmation() async throws {
    let root = try makeTempRoot("convert-preview")
    defer { try? FileManager.default.removeItem(at: root) }
    let light = root.appendingPathComponent(
        "sessions/IC_1396/2026-08-08/lights_osc/light_001.fit"
    )
    try FileManager.default.createDirectory(at: light.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not-a-real-fits-but-indexable".utf8).write(to: light)
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let planURL = root.appendingPathComponent("preview-plan.json")
    let preview = try await runCLI([
        "session-convert", "plan", "--root", root.path, "--target", "IC_1396",
        "--date", "2026-08-08", "--out", planURL.path, "--json"
    ])
    #expect(preview.exitCode == 0)
    #expect(preview.stdout.contains("\"target\" : \"IC_1396\""))
    #expect(preview.stdout.contains("sessions\\/IC_1396\\/2026-08-08\\/lights_osc\\/light_001.fit"))
    #expect(!preview.stdout.contains("2026-08-09"))

    let refused = try await runCLI([
        "session-convert", "apply", "--root", root.path, "--plan", planURL.path
    ])
    #expect(refused.exitCode == 1)
    #expect(refused.stderr.contains("--plan and --yes are required"))
}

// MARK: - R11-T14/F9 verify fixture helpers
//
// `FixityVerifier` only ever re-checks a file that already has a cached
// `content_hash`, and that cache is only ever populated by `DuplicateFinder`
// (part of a normal `audit` run) for same-size files >= its 1 MiB
// threshold -- so, same as `DuplicateFinderTests`, these CLI-level fixtures
// need two BYTE-IDENTICAL files above that threshold for `scan` + `audit` to
// actually cache a hash worth re-verifying.

/// 1.5 MiB -- comfortably above `DuplicateFinder`'s default 1 MiB
/// `minSizeBytes` threshold, mirroring `DuplicateFinderTests`' own constant.
private let verifyDupSize = 1_048_576 + 1_048_576 / 2

private func writeVerifyFixtureFile(at url: URL, byte: UInt8, size: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: byte, count: size).write(to: url)
}

/// Overwrites `url` with `byte` repeated `size` times, then forces its
/// on-disk mtime back to `mtime` -- simulates silent disk-level corruption
/// (bitrot never touches a file's own mtime/size), so `verify` classifies
/// the result as `content-changed` rather than `modified`.
private func corruptFileInPlacePreservingMTime(at url: URL, byte: UInt8, size: Int, mtime: Date) throws {
    try Data(repeating: byte, count: size).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

// MARK: - R11-T4 JSON envelope helpers
//
// Every `--json` root now carries a `schema_version` field (see
// `printJSON`'s doc comment in Commands.swift); a command whose root used
// to be a bare JSON array wraps it into `{"schema_version": ..., "items":
// [...]}` instead, since an array has no key namespace of its own to add
// `schema_version` to. These helpers unwrap that envelope so the rest of
// this file can keep asserting on the actual payload shape.

/// The parsed `--json` root as a keyed object -- every command's root is
/// one now, either its own natural shape or the `{schema_version, items}`
/// envelope.
private func jsonObject(_ stdout: String) throws -> [String: Any]? {
    try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
}

/// `root.items` as `[[String: Any]]` -- for commands whose payload used to
/// be a bare `[{...}, ...]` array.
private func jsonItems(_ stdout: String) throws -> [[String: Any]]? {
    try jsonObject(stdout)?["items"] as? [[String: Any]]
}

/// `root.items` as `[String]` -- for commands whose payload used to be a
/// bare `["a", "b", ...]` array (e.g. `tag list`).
private func jsonStringItems(_ stdout: String) throws -> [String]? {
    try jsonObject(stdout)?["items"] as? [String]
}

// MARK: - Tests
//
// Grouped in one `.serialized` suite: each test shells out to a real
// `Process` (the built `astrotool` binary). Swift Testing runs free `@Test`
// functions concurrently by default, and launching many `Process` instances
// at once from concurrent tasks was observed to deadlock (Foundation's
// `Process` child-termination monitoring appears not to be safe under that
// much concurrent launch/read pressure) -- `.serialized` forces these to run
// one at a time, which is also simply more realistic for CLI smoke tests
// that each build/scan/audit their own throwaway fixture root anyway.
@Suite(.serialized)
struct CLISmokeTests {

// MARK: - scan

@Test func scanJSONReportsAddedFiles() async throws {
    let root = try makeTempRoot("scan-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let result = try await runCLI(["scan", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let added = try #require(json?["added"] as? Int)
    #expect(added > 0)
}

@Test func secondScanReportsUnchanged() async throws {
    let root = try makeTempRoot("scan-twice")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try await runCLI(["scan", "--root", root.path, "--json"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let second = try await runCLI(["scan", "--root", root.path, "--json"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any]
    let unchanged = try #require(json?["unchanged"] as? Int)
    #expect(unchanged > 0)
}

@Test func scanRefreshMetaFlagRunsAndExitsZero() async throws {
    let root = try makeTempRoot("scan-refresh-meta")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try await runCLI(["scan", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let second = try await runCLI(["scan", "--root", root.path, "--refresh-meta"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")
}

@Test func scanWithInaccessibleSubdirectoryStillExitsZeroAndWarnsOnStderr() async throws {
    let root = try makeTempRoot("scan-inaccessible-subdir")
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights").path
        )
        try? FileManager.default.removeItem(at: root)
    }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try await runCLI(["scan", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let restrictedDir = root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)

    let second = try await runCLI(["scan", "--root", root.path])
    #expect(second.exitCode == 0, "stdout: \(second.stdout), stderr: \(second.stderr)")
    #expect(second.stderr.contains("sessions/M45_Pleiades/2026-01-10/lights"))
}

// MARK: - audit

@Test func auditJSONAfterScanReportsKnownCategories() async throws {
    let root = try makeTempRoot("audit-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let audit = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let json = try jsonItems(audit.stdout)
    let findings = try #require(json)
    let categories = Set(findings.compactMap { $0["category"] as? String })
    #expect(categories.contains("placeholder-name"))
}

// MARK: - audit --json diff (R11-T8/F6)

@Test func auditJSONFirstRunHasNoDiffBlock() async throws {
    let root = try makeTempRoot("audit-diff-first")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let audit = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let json = try jsonObject(audit.stdout)
    #expect(json?["diff"] == nil)
    // `items` (the pre-existing bare-array shape, R11-T4) must still be
    // there unchanged, additive-only.
    #expect((json?["items"] as? [[String: Any]])?.isEmpty == false)
}

@Test func auditJSONSecondRunHasDiffBlockWithUnchangedGroups() async throws {
    let root = try makeTempRoot("audit-diff-second")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    // Nothing changed on disk between the two runs -- every group should
    // come back "unchanged", none new/resolved.
    let second = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let diff = try #require(try jsonObject(second.stdout)?["diff"] as? [String: Any])
    #expect(diff["new_count"] as? Int == 0)
    #expect(diff["resolved_count"] as? Int == 0)
    #expect((diff["unchanged_count"] as? Int ?? 0) > 0)
    #expect((diff["new_groups"] as? [Any])?.isEmpty == true)
}

@Test func auditJSONReportsNewGroupKeysAfterALibraryChange() async throws {
    let root = try makeTempRoot("audit-diff-new")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    // A brand-new placeholder-named stack directory the first audit never
    // saw.
    let strayDir = root.appendingPathComponent("stacks/Please_enter_a_value.._Andromeda/2026-05-01")
    try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
    try "fixture dummy content\n".write(to: strayDir.appendingPathComponent("stack.fit"), atomically: true, encoding: .utf8)

    let rescan = try await runCLI(["scan", "--root", root.path])
    #expect(rescan.exitCode == 0, "stderr: \(rescan.stderr)")

    let second = try await runCLI(["audit", "--root", root.path, "--json"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let diff = try #require(try jsonObject(second.stdout)?["diff"] as? [String: Any])
    #expect((diff["new_count"] as? Int ?? 0) > 0)
    let newGroups = try #require(diff["new_groups"] as? [[String: Any]])
    #expect(newGroups.contains {
        $0["category"] as? String == "placeholder-name" && $0["group_key"] as? String == "stacks/Please_enter_a_value.._Andromeda"
    })
}

@Test func auditHumanOutputPrintsDiffSummaryLineOnlyFromTheSecondRunOnward() async throws {
    let root = try makeTempRoot("audit-diff-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["audit", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    #expect(!first.stdout.contains("diff (vs previous run)"))

    let second = try await runCLI(["audit", "--root", root.path])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")
    #expect(second.stdout.contains("diff (vs previous run): 0 new, 0 resolved,"))
}

@Test func auditSuggestWritesSuggestionScript() async throws {
    let root = try makeTempRoot("audit-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["audit", "--root", root.path, "--suggest"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let suggestionsDir = root.appendingPathComponent(".astro_tool/suggestions")
    let contents = try FileManager.default.contentsOfDirectory(atPath: suggestionsDir.path)
    #expect(!contents.isEmpty)
}

@Test func auditJSONStdoutIsPureJSON() async throws {
    let root = try makeTempRoot("audit-pure-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // --suggest on top of --json: the "suggestion written to ..." message
    // must NOT leak onto stdout -- only findings JSON belongs there.
    let result = try await runCLI(["audit", "--root", root.path, "--json", "--suggest"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    // Decoding from the FULL stdout data must succeed -- any stray
    // non-JSON line anywhere in stdout would break this.
    _ = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
}

// MARK: - audit --suggest --out (R11-T4)

@Test func auditSuggestOutWritesScriptToCustomPathOutsideRoot() async throws {
    let root = try makeTempRoot("audit-suggest-out")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let outDir = try makeTempRoot("audit-suggest-out-dest")
    defer { try? FileManager.default.removeItem(at: outDir) }
    let outPath = outDir.appendingPathComponent("suggest.sh").path

    let result = try await runCLI(["audit", "--root", root.path, "--suggest", "--out", outPath])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(FileManager.default.fileExists(atPath: outPath))

    // Must NOT also write the default `.astro_tool/suggestions/` location.
    let defaultDir = root.appendingPathComponent(".astro_tool/suggestions")
    #expect(!FileManager.default.fileExists(atPath: defaultDir.path))
}

@Test func auditSuggestOutDashPrintsScriptToStdoutInsteadOfWritingAFile() async throws {
    let root = try makeTempRoot("audit-suggest-out-dash")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["audit", "--root", root.path, "--suggest", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("#!/bin/bash"))

    let defaultDir = root.appendingPathComponent(".astro_tool/suggestions")
    #expect(!FileManager.default.fileExists(atPath: defaultDir.path))
}

@Test func auditOutWithoutSuggestExitsWithUsageError() async throws {
    let root = try makeTempRoot("audit-out-no-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["audit", "--root", root.path, "--out", "-"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--out requires --suggest"))
}

@Test func auditSuggestOutInsideLibraryRootIsRejected() async throws {
    let root = try makeTempRoot("audit-suggest-out-inside")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let insidePath = root.appendingPathComponent("sneaky.sh").path
    let result = try await runCLI(["audit", "--root", root.path, "--suggest", "--out", insidePath])
    #expect(result.exitCode == 1)
    #expect(!FileManager.default.fileExists(atPath: insidePath))
}

// MARK: - verify (R11-T14/F9)

@Test func verifyOnAnEmptyDatabaseReportsZeroCheckedAndHintsToScanFirst() async throws {
    let root = try makeTempRoot("verify-empty")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["verify", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("scan"))

    let root2 = try #require(try jsonObject(result.stdout))
    let summary = try #require(root2["summary"] as? [String: Any])
    #expect(summary["checked"] as? Int == 0)
}

/// `scan` + `audit` on two byte-identical files above `DuplicateFinder`'s
/// size threshold caches a hash for both -- `verify` then re-checks them,
/// finds nothing wrong, and exits 0.
@Test func verifyJSONAfterAuditReportsOkForUnchangedFiles() async throws {
    let root = try makeTempRoot("verify-ok")
    defer { try? FileManager.default.removeItem(at: root) }

    let path1 = "sessions/M31/2026-01-01/lights/a.fit"
    let path2 = "sessions/M31/2026-01-01/lights/b.fit"
    try writeVerifyFixtureFile(at: root.appendingPathComponent(path1), byte: 0xAB, size: verifyDupSize)
    try writeVerifyFixtureFile(at: root.appendingPathComponent(path2), byte: 0xAB, size: verifyDupSize)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    let audit = try await runCLI(["audit", "--root", root.path])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let result = try await runCLI(["verify", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let root2 = try #require(try jsonObject(result.stdout))
    let summary = try #require(root2["summary"] as? [String: Any])
    #expect(summary["checked"] as? Int == 2)
    #expect(summary["ok"] as? Int == 2)
    #expect(summary["content_changed"] as? Int == 0)
    #expect(try #require(root2["items"] as? [[String: Any]]).isEmpty)
}

/// The end-to-end exit-5 contract (F9/F10-a): a same-size, same-mtime
/// content mismatch -- silent corruption -- must be reported as
/// `content-changed` and exit 5, distinctly from every other exit code.
@Test func verifyDetectsContentChangedAndExitsWithCode5() async throws {
    let root = try makeTempRoot("verify-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }

    let path1 = "sessions/M31/2026-01-01/lights/a.fit"
    let path2 = "sessions/M31/2026-01-01/lights/b.fit"
    let url1 = root.appendingPathComponent(path1)
    let url2 = root.appendingPathComponent(path2)
    try writeVerifyFixtureFile(at: url1, byte: 0xAB, size: verifyDupSize)
    try writeVerifyFixtureFile(at: url2, byte: 0xAB, size: verifyDupSize)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    let audit = try await runCLI(["audit", "--root", root.path])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let mtimeBeforeCorruption = try url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
    // Same length, different byte value, mtime forced back -- classic
    // bitrot shape: content changed, metadata didn't.
    try corruptFileInPlacePreservingMTime(at: url1, byte: 0xCD, size: verifyDupSize, mtime: mtimeBeforeCorruption)

    let result = try await runCLI(["verify", "--root", root.path, "--json"])
    #expect(result.exitCode == 5, "stdout: \(result.stdout), stderr: \(result.stderr)")

    let root2 = try #require(try jsonObject(result.stdout))
    let summary = try #require(root2["summary"] as? [String: Any])
    #expect(summary["content_changed"] as? Int == 1)
    #expect(summary["ok"] as? Int == 1)

    let items = try #require(root2["items"] as? [[String: Any]])
    #expect(items.count == 1)
    #expect(items.first?["category"] as? String == "content-changed")
    #expect(items.first?["severity"] as? String == "sure_error")
    #expect(items.first?["path"] as? String == path1)

    // Human output surfaces the same mismatch under an "ELTÉRÉS" line.
    let humanResult = try await runCLI(["verify", "--root", root.path])
    #expect(humanResult.exitCode == 5)
    #expect(humanResult.stdout.contains("ELTÉRÉS"))
    #expect(humanResult.stdout.contains(path1))
}

/// A same-size rewrite with a newer mtime is suspicious and must be visible
/// in the human CLI output, but it is not a confirmed-corruption exit-5.
@Test func verifyHumanOutputReportsModifiedInPlaceSeparately() async throws {
    let root = try makeTempRoot("verify-modified-in-place")
    defer { try? FileManager.default.removeItem(at: root) }

    let path1 = "sessions/M31/2026-01-01/lights/a.fit"
    let path2 = "sessions/M31/2026-01-01/lights/b.fit"
    let url1 = root.appendingPathComponent(path1)
    let url2 = root.appendingPathComponent(path2)
    try writeVerifyFixtureFile(at: url1, byte: 0xAB, size: verifyDupSize)
    try writeVerifyFixtureFile(at: url2, byte: 0xAB, size: verifyDupSize)

    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)
    #expect(try await runCLI(["audit", "--root", root.path]).exitCode == 0)

    let oldMTime = try url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
    try writeVerifyFixtureFile(at: url1, byte: 0xCD, size: verifyDupSize)
    try FileManager.default.setAttributes(
        [.modificationDate: oldMTime.addingTimeInterval(100)],
        ofItemAtPath: url1.path
    )

    let result = try await runCLI(["verify", "--root", root.path])
    #expect(result.exitCode == 0, "stdout: \(result.stdout), stderr: \(result.stderr)")
    #expect(result.stdout.contains("helyben módosult 1"))
    #expect(result.stdout.contains(path1))
}

@Test func verifySampleFlagRejectsOutOfRangeOrNonNumericValues() async throws {
    let root = try makeTempRoot("verify-sample-invalid")
    defer { try? FileManager.default.removeItem(at: root) }

    for badValue in ["0", "101", "abc", "-5"] {
        let result = try await runCLI(["verify", "--root", root.path, "--sample", badValue])
        #expect(result.exitCode == 1, "sample=\(badValue) should be rejected")
        #expect(result.stderr.contains("--sample"))
    }
}

@Test func verifyBaselineRejectsSampling() async throws {
    let root = try makeTempRoot("verify-baseline-sample")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI([
        "verify", "--root", root.path, "--baseline", "--sample", "10",
    ])

    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--baseline"))
    #expect(result.stderr.contains("--sample"))
}

@Test func verifyBaselineHumanOutputHashesMissingChecksumsAndIsIdempotent() async throws {
    let root = try makeTempRoot("verify-baseline-human")
    defer { try? FileManager.default.removeItem(at: root) }

    let relativePath = "sessions/M31/2026-01-01/lights/a.fit"
    try writeVerifyFixtureFile(
        at: root.appendingPathComponent(relativePath), byte: 0xAB, size: 128
    )
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let first = try await runCLI(["verify", "--root", root.path, "--baseline"])
    #expect(first.exitCode == 0, "stdout: \(first.stdout), stderr: \(first.stderr)")
    #expect(first.stdout.contains("új hash 1"))
    #expect(first.stdout.contains("lefedettség 1/1"))
    #expect(first.stdout.contains("100"))

    let second = try await runCLI(["verify", "--root", root.path, "--baseline"])
    #expect(second.exitCode == 0, "stdout: \(second.stdout), stderr: \(second.stderr)")
    #expect(second.stdout.contains("új hash 0"))
    #expect(second.stdout.contains("lefedettség 1/1"))
}

@Test func verifyBaselineJSONReportsCoverageForAnEmptyLibrary() async throws {
    let root = try makeTempRoot("verify-baseline-empty-json")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI([
        "verify", "--root", root.path, "--baseline", "--json",
    ])
    #expect(result.exitCode == 0, "stdout: \(result.stdout), stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let summary = try #require(payload["summary"] as? [String: Any])
    let coverage = try #require(payload["coverage"] as? [String: Any])
    #expect(summary["hashed"] as? Int == 0)
    #expect(summary["errors"] as? Int == 0)
    #expect(coverage["tracked"] as? Int == 0)
    #expect(coverage["hashed"] as? Int == 0)
    #expect(coverage["unhashed"] as? Int == 0)
    #expect(coverage["percent"] as? Double == 0)
    #expect(try #require(payload["items"] as? [[String: Any]]).isEmpty)
}

@Test func verifyTargetFlagScopesToOneTargetOnly() async throws {
    let root = try makeTempRoot("verify-target-scope")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeVerifyFixtureFile(at: root.appendingPathComponent("sessions/M31/2026-01-01/lights/a.fit"), byte: 0xAB, size: verifyDupSize)
    try writeVerifyFixtureFile(at: root.appendingPathComponent("sessions/M31/2026-01-01/lights/b.fit"), byte: 0xAB, size: verifyDupSize)
    try writeVerifyFixtureFile(at: root.appendingPathComponent("sessions/M42/2026-02-02/lights/c.fit"), byte: 0xCD, size: verifyDupSize)
    try writeVerifyFixtureFile(at: root.appendingPathComponent("sessions/M42/2026-02-02/lights/d.fit"), byte: 0xCD, size: verifyDupSize)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    let audit = try await runCLI(["audit", "--root", root.path])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let result = try await runCLI(["verify", "--root", root.path, "--target", "M42", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let root2 = try #require(try jsonObject(result.stdout))
    let summary = try #require(root2["summary"] as? [String: Any])
    #expect(summary["checked"] as? Int == 2)
}

// MARK: - cleanup

@Test func cleanupJSONAfterScanReportsResidueGroups() async throws {
    let root = try makeTempRoot("cleanup-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["cleanup", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let groups = try #require(json?["groups"] as? [[String: Any]])
    let categories = Set(groups.compactMap { $0["category"] as? String })
    // Fixtures.makeMessyLibrary plants x.seq/x.lst/r_lights.fit/.DS_Store
    // plus a process/ dir under stacks/M42_Orion/2026-01-17.
    #expect(categories.contains("residue-seq"))
    #expect(categories.contains("residue-lst"))
    #expect(categories.contains("residue-process-dir"))
    #expect((json?["grand_total_bytes"] as? Int ?? 0) > 0)
}

// MARK: - cleanup --json storage block (R11-T8/F19)

@Test func cleanupJSONReportsPerTargetStorageBreakdown() async throws {
    let root = try makeTempRoot("cleanup-storage-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["cleanup", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonObject(result.stdout)
    // `groups`/`grand_total_bytes` (the pre-existing `CleanupSummary` shape)
    // must still be there unchanged -- `storage` is a purely additive third
    // sibling key.
    #expect(json?["groups"] != nil)
    #expect(json?["grand_total_bytes"] != nil)

    let storage = try #require(json?["storage"] as? [String: Any])
    let targets = try #require(storage["targets"] as? [[String: Any]])
    #expect(!targets.isEmpty)
    #expect((storage["grand_total_bytes"] as? Int ?? 0) > 0)

    // `Fixtures.makeMessyLibrary` gives `M45_Pleiades` several session light
    // files -- it must show up as a target row somewhere in the list.
    let names = targets.compactMap { $0["target"] as? String }
    #expect(names.contains("M45_Pleiades"))
    let firstRow = try #require(targets.first)
    #expect(firstRow["display_name"] != nil)
    #expect((firstRow["total_bytes"] as? Int ?? 0) > 0)

    // Sorted size-descending.
    let totals = targets.compactMap { $0["total_bytes"] as? Int }
    #expect(totals == totals.sorted(by: >))
}

@Test func cleanupHumanOutputPrintsGroupsAndTotal() async throws {
    let root = try makeTempRoot("cleanup-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["cleanup", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("residue-seq"))
    #expect(result.stdout.contains("összesen felszabadítható"))
}

@Test func cleanupSuggestWritesQuarantineScriptWithNoRM() async throws {
    let root = try makeTempRoot("cleanup-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["cleanup", "--root", root.path, "--suggest"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let suggestionsDir = root.appendingPathComponent(".astro_tool/suggestions")
    let contents = try FileManager.default.contentsOfDirectory(atPath: suggestionsDir.path)
    #expect(!contents.isEmpty)

    let scriptURL = suggestionsDir.appendingPathComponent(try #require(contents.first))
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    // Quarantine mv, active (not commented out).
    #expect(script.contains(".astro_tool/cleanup_quarantine/"))
    #expect(script.contains("mv "))
    let hasActiveMv = script.components(separatedBy: "\n").contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("mv ") && !trimmed.hasPrefix("#")
    }
    #expect(hasActiveMv)

    // Never a delete of any kind.
    #expect(!script.contains("rm "))
    #expect(!script.contains("rm\t"))
    #expect(!script.contains("rmdir"))

    // Every mv target lands under .astro_tool -- reversible quarantine, not
    // a real library location.
    #expect(!script.contains("# (suspicious — uncomment only after review)"))
}

// MARK: - cleanup --suggest --out (R11-T4)

@Test func cleanupSuggestOutWritesScriptToCustomPath() async throws {
    let root = try makeTempRoot("cleanup-suggest-out")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let outDir = try makeTempRoot("cleanup-suggest-out-dest")
    defer { try? FileManager.default.removeItem(at: outDir) }
    let outPath = outDir.appendingPathComponent("cleanup.sh").path

    let result = try await runCLI(["cleanup", "--root", root.path, "--suggest", "--out", outPath])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(FileManager.default.fileExists(atPath: outPath))

    let defaultDir = root.appendingPathComponent(".astro_tool/suggestions")
    #expect(!FileManager.default.fileExists(atPath: defaultDir.path))
}

@Test func cleanupOutWithoutSuggestExitsWithUsageError() async throws {
    let root = try makeTempRoot("cleanup-out-no-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["cleanup", "--root", root.path, "--out", "-"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--out requires --suggest"))
}

// MARK: - stats

@Test func statsJSONContainsFixtureTarget() async throws {
    let root = try makeTempRoot("stats-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let stats = try #require(json)
    let targets = Set(stats.compactMap { $0["target"] as? String })
    #expect(targets.contains("M45_Pleiades"))
}

@Test func statsTargetNotFoundExitsWithError() async throws {
    let root = try makeTempRoot("stats-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "NONEXISTENT_TARGET"])
    // R11-T4: target/session-lookup failures get their own exit code (3),
    // carved out of the generic usage/error bucket (1).
    #expect(result.exitCode == 3)
}

@Test func statsSessionsJSONDecodesForFixtureTarget() async throws {
    let root = try makeTempRoot("stats-sessions-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--sessions", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let sessions = try #require(json)
    #expect(!sessions.isEmpty)
    #expect(sessions.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
}

@Test func statsJSONCarriesUsableAndGrossIntegrationFields() async throws {
    let root = try makeTempRoot("stats-json-r4-1")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let stats = try #require(json)
    #expect(stats["usable_integration_seconds"] != nil)
    #expect(stats["gross_integration_seconds"] != nil)
    #expect(stats["usable_frame_count"] != nil)
    #expect(stats["duplicate_link_count"] != nil)
    #expect(stats["rejected_frame_count"] != nil)
    #expect(stats["non_frame_file_count"] != nil)
    #expect(stats["excluded_session_dates"] != nil)
}

@Test func statsHumanOutputWithGrossFlagShowsGrossLine() async throws {
    let root = try makeTempRoot("stats-gross-flag")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--gross"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("gross (undeduped):"))
}

@Test func statsSessionsWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("stats-sessions-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--sessions", "--json"])
    #expect(result.exitCode == 1)
}

@Test func statsTimelineJSONDecodesForFixtureTarget() async throws {
    let root = try makeTempRoot("stats-timeline-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--timeline", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let timelines = try #require(json)
    #expect(!timelines.isEmpty)
    #expect(timelines.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
    #expect(timelines.allSatisfy { $0["integration_seconds"] != nil })
    #expect(timelines.allSatisfy { $0["gaps"] != nil })
}

@Test func statsTimelineHumanOutputPrintsWindowAndIntegration() async throws {
    let root = try makeTempRoot("stats-timeline-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--timeline"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("window:"))
    #expect(result.stdout.contains("integration:"))
}

@Test func statsTimelineWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("stats-timeline-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--timeline", "--json"])
    #expect(result.exitCode == 1)
}

@Test func rateForceFlagReRatesAnAlreadyRatedTargetSuccessfully() async throws {
    let root = try makeTempRoot("rate-force")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["rate", "--root", root.path, "--target", "M45_Pleiades", "--no-siril"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    // A second `rate` run with `--force` must succeed too (end-to-end CLI
    // wiring for `Rater.rate`'s `force` parameter, R7-B6 item 1) -- not
    // just short-circuit as an already-cached hit.
    let forced = try await runCLI(["rate", "--root", root.path, "--target", "M45_Pleiades", "--no-siril", "--force"])
    #expect(forced.exitCode == 0, "stderr: \(forced.stderr)")
    #expect(!forced.stdout.isEmpty)
}

// MARK: - stats --filters (R10-B8)

@Test func statsFiltersJSONFrameCountsSumToPlainStatsUsableFrameCount() async throws {
    let root = try makeTempRoot("stats-filters-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let plain = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(plain.exitCode == 0, "stderr: \(plain.stderr)")
    let plainJSON = try #require(try JSONSerialization.jsonObject(with: Data(plain.stdout.utf8)) as? [String: Any])
    let expectedFrameCount = try #require(plainJSON["usable_frame_count"] as? Int)
    #expect(expectedFrameCount > 0)

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--filters", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try jsonItems(result.stdout)
    let rows = try #require(json)
    let totalFrames = rows.compactMap { $0["usable_frame_count"] as? Int }.reduce(0, +)
    // The per-filter rows must add up to the exact same usable-frame total
    // the plain (non-broken-down) `stats` reports -- both share the same
    // dedup + `_hibas`-exclusion convention, so they can never disagree.
    #expect(totalFrames == expectedFrameCount)
}

@Test func statsFiltersHumanOutputPrintsHungarianHeaders() async throws {
    let root = try makeTempRoot("stats-filters-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--filters"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("SZŰRŐ"))
    #expect(result.stdout.contains("KERET"))
    #expect(result.stdout.contains("INTEGRÁCIÓ"))
}

/// The `2026-03-15_hibas` session in `Fixtures.makeMessyLibrary` is excluded
/// from `M45_Pleiades`'s whole-target roll-up (asserted indirectly above,
/// via the frame-count-sum invariant) -- scoping `--filters` to exactly that
/// date must still report its own real frame, never an empty result.
@Test func statsFiltersWithDateStillReportsAnExcludedHibasSessionsOwnFrames() async throws {
    let root = try makeTempRoot("stats-filters-date-hibas")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "stats", "--root", root.path, "--target", "M45_Pleiades", "--filters", "--date", "2026-03-15_hibas", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try jsonItems(result.stdout)
    let rows = try #require(json)
    let totalFrames = rows.compactMap { $0["usable_frame_count"] as? Int }.reduce(0, +)
    #expect(totalFrames == 1)
}

@Test func statsFiltersWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("stats-filters-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stats", "--root", root.path, "--filters", "--json"])
    #expect(result.exitCode == 1)
}

// MARK: - quality

@Test func qualityJSONAfterRateDecodesForFixtureTarget() async throws {
    let root = try makeTempRoot("quality-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let rate = try await runCLI(["rate", "--root", root.path, "--target", "M45_Pleiades", "--no-siril"])
    #expect(rate.exitCode == 0, "stderr: \(rate.stderr)")

    let result = try await runCLI(["quality", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let summaries = try #require(json)
    #expect(!summaries.isEmpty)
    #expect(summaries.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
    #expect(summaries.allSatisfy { $0["frame_count"] != nil })
}

@Test func qualityHumanOutputPrintsTable() async throws {
    let root = try makeTempRoot("quality-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["quality", "--root", root.path, "--target", "M45_Pleiades"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("DATE"))
}

@Test func qualityWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("quality-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["quality", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - nights (R10-A3)

/// `Fixtures.makeMessyLibrary` plants session lights under BOTH
/// `M45_Pleiades` and `IC1805-1848_Heart_and_Soul_Nebula` -- the minimum
/// needed to exercise the CROSS-target join `stats --sessions`/`quality`
/// (both scoped to one target) never had to do.
@Test func nightsJSONAfterScanCoversMultipleTargetsNewestFirst() async throws {
    let root = try makeTempRoot("nights-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["nights", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let rows = try #require(json)
    let targets = Set(rows.compactMap { $0["target"] as? String })
    #expect(targets.contains("M45_Pleiades"))
    #expect(targets.contains("IC1805-1848_Heart_and_Soul_Nebula"))
    #expect(rows.allSatisfy { $0["usable_light_count"] != nil && $0["exposure_summary"] != nil })

    // Newest calendar date first across the WHOLE list, not just within one
    // target. Same-night variants (the fixture's run-suffix/labeled dates
    // all sharing one calendar day, e.g. "2026-03-15-OSC" and
    // "2026-03-15_hibas") may tie and land in either order -- only the
    // underlying calendar date (its first 10 characters) must never
    // increase later in the list.
    let dates = rows.compactMap { $0["date"] as? String }
    let calendarDates = dates.map { String($0.prefix(10)) }
    #expect(calendarDates == calendarDates.sorted(by: >))

    // The fixture's own `_hibas`-labeled date-dir variant must still be
    // listed here (browsing surface), just flagged.
    let excludedRow = try #require(rows.first { $0["date"] as? String == "2026-03-15_hibas" })
    #expect(excludedRow["is_excluded_from_totals"] as? Bool == true)
}

@Test func nightsHumanOutputPrintsHungarianHeaders() async throws {
    let root = try makeTempRoot("nights-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["nights", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("DÁTUM"))
    #expect(result.stdout.contains("CÉLPONT"))
}

@Test func nightsHumanOutputKeepsDisplayNameWhenFolderNameIsLong() async throws {
    let root = try makeTempRoot("nights-long-name")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)
    // A real-world long folder name whose resolved display name differs.
    // The name column must keep the human-facing display name and drop the
    // raw folder name when the combined form doesn't fit -- the original
    // helper did the reverse and printed "N… (NGC_7000_North_American_Nebula)".
    let lights = root.appendingPathComponent(
        "sessions/NGC_7000_North_American_Nebula/2026-03-01/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
    try "dummy light\n".write(
        to: lights.appendingPathComponent("Light_001.fit"), atomically: true, encoding: .utf8)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["nights", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("NGC 7000"), "display name was truncated away: \(result.stdout)")
    #expect(!result.stdout.contains("… ("), "raw name kept while display name truncated: \(result.stdout)")
}

@Test func nightsYearAndMonthFilterOnlyShowsMatchingSessions() async throws {
    let root = try makeTempRoot("nights-year-filter")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // The fixture's "2026-04-06-2" run-suffix date-dir is the only session
    // whose canonical start date falls in April 2026.
    let result = try await runCLI(["nights", "--root", root.path, "--year", "2026", "--month", "4", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try jsonItems(result.stdout)
    let rows = try #require(json)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { ($0["date"] as? String)?.hasPrefix("2026-04") == true })
}

@Test func nightsMonthWithoutYearExitsWithError() async throws {
    let root = try makeTempRoot("nights-month-no-year")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["nights", "--root", root.path, "--month", "3"])
    #expect(result.exitCode == 1)
}

// MARK: - trends (R11-T10/F7)

/// Writes a LIGHT frame with real `DATE-OBS`/`FOCALLEN`/`XPIXSZ` cards --
/// none of `writeSensorFITS`/`writeBayerLightFITS` above carry those, but
/// the "hatékonyság%" (duty-cycle) metric needs `DATE-OBS`+`EXPTIME` to
/// derive a session window at all, and the setup-fingerprint filter needs
/// `FOCALLEN`/`XPIXSZ`/`INSTRUME` to differ meaningfully between two
/// sessions.
private func writeTrendLightFITS(
    _ relativePath: String, root: URL,
    width: Int = 8, height: Int = 8, pixelValue: Int = 500,
    instrume: String = "ASI2600MC", focallen: Double = 500, xpixsz: Double = 3.76,
    exptime: Double = 60, dateObs: String
) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "NAXIS1  =                 \(width)", "NAXIS2  =                 \(height)",
        "INSTRUME= '\(instrume)'",
        "FOCALLEN=                \(focallen)",
        "XPIXSZ  =                \(xpixsz)",
        "EXPTIME =                \(exptime)",
        "DATE-OBS= '\(dateObs)'",
        "END",
    ]
    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(width * height * 2)
    let unsigned = UInt16(bitPattern: Int16(pixelValue))
    for _ in 0..<(width * height) {
        pixelBytes.append(UInt8(unsigned >> 8))
        pixelBytes.append(UInt8(unsigned & 0xFF))
    }
    data.append(pixelBytes)
    try data.write(to: url)
}

@Test func trendsRequiresMetricFlag() async throws {
    let root = try makeTempRoot("trends-no-metric")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["trends", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func trendsRejectsUnknownMetric() async throws {
    let root = try makeTempRoot("trends-bad-metric")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["trends", "--root", root.path, "--metric", "bogus"])
    #expect(result.exitCode == 1)
}

/// Duty-cycle (efficiency%) needs no `rate`/Siril at all -- two frames with
/// real `DATE-OBS` timestamps are already enough for `SessionTimeline` to
/// derive a window, unlike FWHM/background which need a real Siril-measured
/// rating (out of scope for a CI-safe CLI smoke test; `TrendQueriesTests`
/// covers those numerically against a direct in-memory DB instead).
@Test func trendsEfficiencyJSONAfterScanReportsSessionsOldestFirst() async throws {
    let root = try makeTempRoot("trends-efficiency-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeTrendLightFITS(
        "sessions/M42/2026-03-10/lights/a.fit", root: root, dateObs: "2026-03-10T20:00:00"
    )
    try writeTrendLightFITS(
        "sessions/M42/2026-03-10/lights/b.fit", root: root, dateObs: "2026-03-10T20:02:00"
    )
    try writeTrendLightFITS(
        "sessions/M31/2026-01-05/lights/a.fit", root: root, dateObs: "2026-01-05T20:00:00"
    )
    try writeTrendLightFITS(
        "sessions/M31/2026-01-05/lights/b.fit", root: root, dateObs: "2026-01-05T20:02:00"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["trends", "--root", root.path, "--metric", "efficiency", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let items = try #require(try jsonItems(result.stdout))
    #expect(items.map { $0["date"] as? String } == ["2026-01-05", "2026-03-10"])
    #expect(items.allSatisfy { $0["value"] != nil })
    #expect(items.allSatisfy { $0["is_pixel_fallback"] == nil })
}

@Test func trendsHumanOutputPrintsHungarianHeader() async throws {
    let root = try makeTempRoot("trends-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeTrendLightFITS("sessions/M42/2026-03-10/lights/a.fit", root: root, dateObs: "2026-03-10T20:00:00")
    try writeTrendLightFITS("sessions/M42/2026-03-10/lights/b.fit", root: root, dateObs: "2026-03-10T20:02:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["trends", "--root", root.path, "--metric", "efficiency"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("DÁTUM"))
    #expect(result.stdout.contains("CÉLPONT"))
    #expect(result.stdout.contains("HATÉKONYSÁG%"))
}

@Test func trendsFromToFiltersToTheGivenInclusiveRange() async throws {
    let root = try makeTempRoot("trends-from-to")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeTrendLightFITS("sessions/M42/2026-01-01/lights/a.fit", root: root, dateObs: "2026-01-01T20:00:00")
    try writeTrendLightFITS("sessions/M42/2026-01-01/lights/b.fit", root: root, dateObs: "2026-01-01T20:02:00")
    try writeTrendLightFITS("sessions/M42/2026-02-15/lights/a.fit", root: root, dateObs: "2026-02-15T20:00:00")
    try writeTrendLightFITS("sessions/M42/2026-02-15/lights/b.fit", root: root, dateObs: "2026-02-15T20:02:00")
    try writeTrendLightFITS("sessions/M42/2026-03-30/lights/a.fit", root: root, dateObs: "2026-03-30T20:00:00")
    try writeTrendLightFITS("sessions/M42/2026-03-30/lights/b.fit", root: root, dateObs: "2026-03-30T20:02:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "trends", "--root", root.path, "--metric", "efficiency",
        "--from", "2026-02-01", "--to", "2026-03-01", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let items = try #require(try jsonItems(result.stdout))
    #expect(items.map { $0["date"] as? String } == ["2026-02-15"])
}

@Test func trendsSetupFilterRestrictsToTheMatchingSetupDescriptorOnly() async throws {
    let root = try makeTempRoot("trends-setup-filter")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeTrendLightFITS(
        "sessions/M42/2026-01-01/lights/a.fit", root: root,
        instrume: "CamA", focallen: 500, xpixsz: 3.76, dateObs: "2026-01-01T20:00:00"
    )
    try writeTrendLightFITS(
        "sessions/M42/2026-01-01/lights/b.fit", root: root,
        instrume: "CamA", focallen: 500, xpixsz: 3.76, dateObs: "2026-01-01T20:02:00"
    )
    try writeTrendLightFITS(
        "sessions/M31/2026-02-01/lights/a.fit", root: root,
        instrume: "CamB", focallen: 200, xpixsz: 2.4, dateObs: "2026-02-01T20:00:00"
    )
    try writeTrendLightFITS(
        "sessions/M31/2026-02-01/lights/b.fit", root: root,
        instrume: "CamB", focallen: 200, xpixsz: 2.4, dateObs: "2026-02-01T20:02:00"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let unfiltered = try #require(try jsonItems(
        try await runCLI(["trends", "--root", root.path, "--metric", "efficiency", "--json"]).stdout
    ))
    #expect(unfiltered.count == 2)

    // "CamA·500mm·3.76µm" -- `EquipmentProfile.fingerprint`'s own descriptor
    // format (camera, rounded focal length, 2-decimal pixel size, joined by
    // "·"), no binning/Bayer/guide-cam cards written here.
    let camASetup = "CamA·500mm·3.76µm"
    let filtered = try #require(try jsonItems(
        try await runCLI(["trends", "--root", root.path, "--metric", "efficiency", "--setup", camASetup, "--json"]).stdout
    ))
    #expect(filtered.map { $0["date"] as? String } == ["2026-01-01"])

    let noMatch = try #require(try jsonItems(
        try await runCLI(["trends", "--root", root.path, "--metric", "efficiency", "--setup", "no-such-setup", "--json"]).stdout
    ))
    #expect(noMatch.isEmpty)
}

@Test func trendsWithNoMatchingDataPrintsEmptyResultAndHumanMessage() async throws {
    let root = try makeTempRoot("trends-empty")
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let jsonResult = try await runCLI(["trends", "--root", root.path, "--metric", "fwhm", "--json"])
    #expect(jsonResult.exitCode == 0, "stderr: \(jsonResult.stderr)")
    #expect(try jsonItems(jsonResult.stdout)?.isEmpty == true)

    let humanResult = try await runCLI(["trends", "--root", root.path, "--metric", "fwhm"])
    #expect(humanResult.exitCode == 0, "stderr: \(humanResult.stderr)")
    #expect(humanResult.stdout.contains("nincs adat"))
}

// MARK: - health

@Test func healthJSONAfterScanDecodesForFixtureTarget() async throws {
    let root = try makeTempRoot("health-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["health", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let reports = try #require(json)
    #expect(!reports.isEmpty)
    #expect(reports.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
    #expect(reports.allSatisfy { $0["cooler"] != nil && $0["focus"] != nil })
}

@Test func healthHumanOutputPrintsCoolerAndFocusLines() async throws {
    let root = try makeTempRoot("health-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["health", "--root", root.path, "--target", "M45_Pleiades"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Hűtés:"))
    #expect(result.stdout.contains("Fókusz:"))
}

@Test func healthWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("health-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["health", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func healthWithDateFlagFiltersToSingleSession() async throws {
    let root = try makeTempRoot("health-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["health", "--root", root.path, "--target", "M45_Pleiades", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let reports = try #require(json)
    #expect(reports.count == 1)
    #expect(reports.first?["date"] as? String == "2026-01-10")
}

// MARK: - panels

@Test func panelsJSONAfterScanDecodesForFixtureTarget() async throws {
    let root = try makeTempRoot("panels-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["panels", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let report = try #require(json)
    #expect(report["target"] as? String == "M45_Pleiades")
    #expect(report["panels"] is [Any])
}

@Test func panelsHumanOutputReportsNoWCSSolvedFramesForFixtureWithoutCRVAL() async throws {
    let root = try makeTempRoot("panels-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["panels", "--root", root.path, "--target", "M45_Pleiades"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("no WCS-solved frames"))
}

@Test func panelsWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("panels-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["panels", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - stacks (R8-1)

/// `Fixtures.makeMessyLibrary` already plants `stacks/M42_Orion/2026-01-17/
/// result.fit` -- a real "location signal only" case (the filename `result.fit`
/// doesn't mention the target at all, so this exercises the "mappa"
/// `match_source` path with zero extra fixture setup).
@Test func stacksJSONAfterScanFindsExistingFixtureStack() async throws {
    let root = try makeTempRoot("stacks-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacks", "--root", root.path, "--target", "M42_Orion", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let reports = try #require(json)
    let report = try #require(reports.first { $0["target"] as? String == "M42_Orion" })
    let stacks = try #require(report["stacks"] as? [[String: Any]])
    #expect(stacks.contains { $0["path"] as? String == "stacks/M42_Orion/2026-01-17/result.fit" })
    let found = try #require(stacks.first { $0["path"] as? String == "stacks/M42_Orion/2026-01-17/result.fit" })
    #expect(found["match_source"] as? String == "mappa")
    #expect(found["kind"] as? String == "stack")
}

@Test func stacksHumanOutputPrintsFileAndBestLine() async throws {
    let root = try makeTempRoot("stacks-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacks", "--root", root.path, "--target", "M42_Orion"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("result.fit"))
    // R8-3: human output is grouped now -- one "N stack-csoport, M fájl"
    // header line per target instead of a flat per-file table.
    #expect(result.stdout.contains("stack-csoport"))
}

@Test func stacksWithoutTargetListsEveryTargetWithDiscoveredStacks() async throws {
    let root = try makeTempRoot("stacks-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacks", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let reports = try #require(json)
    #expect(reports.contains { $0["target"] as? String == "M42_Orion" })
}

// MARK: - stacks --grouped / --verbose (R8-3)

@Test func stacksJSONGroupedReturnsStackGroupShapeInsteadOfFlatTargetStacks() async throws {
    let root = try makeTempRoot("stacks-grouped-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacks", "--root", root.path, "--target", "M42_Orion", "--json", "--grouped"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let groups = try #require(json)
    let group = try #require(groups.first)
    // `StackGroup`'s own shape -- "stem"/"base"/"variants" -- not
    // `TargetStacks`'s "target"/"displayName"/"stacks".
    #expect(group["stem"] != nil)
    let base = try #require(group["base"] as? [String: Any])
    #expect(base["path"] as? String == "stacks/M42_Orion/2026-01-17/result.fit")
}

@Test func stacksHumanVerboseListsVariantsIndentedUnderneathTheirGroup() async throws {
    let root = try makeTempRoot("stacks-verbose")
    defer { try? FileManager.default.removeItem(at: root) }

    let fm = FileManager.default
    func writeStackFile(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy stack bytes".write(to: url, atomically: true, encoding: .utf8)
    }
    // Real on-disk family shape, NGC2237_Rosette_Nebula -- an `_og` original
    // plus its `starless_` variant, same stem.
    try writeStackFile(
        "stacks/NGC2237_Rosette_Nebula/2026-04-04/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit"
    )
    try writeStackFile(
        "stacks/NGC2237_Rosette_Nebula/2026-04-04/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956.fit"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let plain = try await runCLI(["stacks", "--root", root.path, "--target", "NGC2237_Rosette_Nebula"])
    #expect(plain.exitCode == 0, "stderr: \(plain.stderr)")
    #expect(plain.stdout.contains("(+1 starless)"))
    #expect(!plain.stdout.contains("starless_NGC"))

    let verbose = try await runCLI(["stacks", "--root", root.path, "--target", "NGC2237_Rosette_Nebula", "--verbose"])
    #expect(verbose.exitCode == 0, "stderr: \(verbose.stderr)")
    #expect(verbose.stdout.contains("starless_NGC"))
}

// MARK: - search

/// `Fixtures.makeMessyLibrary` plants a real `README.txt` for
/// `M45_Pleiades/2026-01-10` containing "Camera: ZWO ASI2600MC Pro" -- a
/// scan must index it so `search` can find it by a substring of that value.
@Test func searchFindsMatchAfterScanOfFixtureReadme() async throws {
    let root = try makeTempRoot("search-hit")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["search", "ZWO", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let rows = try #require(json)
    #expect(rows.contains { ($0["target"] as? String) == "M45_Pleiades" && ($0["date"] as? String) == "2026-01-10" })
}

@Test func searchWithNoMatchesStillExitsZero() async throws {
    let root = try makeTempRoot("search-miss")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["search", "nonexistent-term-xyz", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("no matches"))
}

// MARK: - search --all (R10-B8)

@Test func searchAllJSONFindsTargetByFolderNameSubstring() async throws {
    let root = try makeTempRoot("search-all-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["search", "Pleiades", "--root", root.path, "--all", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let targets = try #require(json["targets"] as? [[String: Any]])
    #expect(targets.contains { ($0["target"] as? String) == "M45_Pleiades" })
    // The plain shape check: every documented section key is present, even
    // when empty, so a caller never has to special-case a missing key.
    #expect(json["sessions"] != nil)
    #expect(json["files"] != nil)
    #expect(json["notes"] != nil)
    #expect(json["total_file_matches"] != nil)
}

/// `search --all` must union in `SessionNoteStore`-written notes (the same
/// merge `AppState.runSearch` performs), not just `Database.searchAll`'s
/// own README-only notes section -- write one via `note set`, then confirm
/// `search --all` finds it by value.
@Test func searchAllFindsNoteWrittenThroughNoteSetCommand() async throws {
    let root = try makeTempRoot("search-all-store-note")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let setNote = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Seeing", "--value", "kivételesen stabil éjszaka", "--root", root.path,
    ])
    #expect(setNote.exitCode == 0, "stderr: \(setNote.stderr)")

    let result = try await runCLI(["search", "kivételesen stabil", "--root", root.path, "--all", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let notes = try #require(json["notes"] as? [[String: Any]])
    #expect(notes.contains {
        ($0["target"] as? String) == "M45_Pleiades" && ($0["key"] as? String) == "Seeing"
    })
}

@Test func searchAllHumanOutputListsSectionsInPageOrder() async throws {
    let root = try makeTempRoot("search-all-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["search", "Pleiades", "--root", root.path, "--all"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Célpontok"))
    #expect(result.stdout.contains("M45_Pleiades"))
}

@Test func searchAllWithNoMatchesStillExitsZero() async throws {
    let root = try makeTempRoot("search-all-miss")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["search", "nonexistent-term-xyz", "--root", root.path, "--all"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("no matches"))
}

// MARK: - tag

@Test func tagAddThenListShowsIt() async throws {
    let root = try makeTempRoot("tag-add-list")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let list = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try jsonStringItems(list.stdout)
    #expect(tags == ["favorite"])
}

@Test func tagAddSameTwiceStaysIdempotent() async throws {
    let root = try makeTempRoot("tag-idempotent")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let second = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let list = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try jsonStringItems(list.stdout)
    #expect(tags == ["favorite"])
}

@Test func tagRemoveDeletesIt() async throws {
    let root = try makeTempRoot("tag-remove")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")
    let remove = try await runCLI(["tag", "remove", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(remove.exitCode == 0, "stderr: \(remove.stderr)")

    let list = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try jsonStringItems(list.stdout)
    #expect(tags == [])
}

@Test func tagSessionScopedTagOnlyListedWithMatchingDate() async throws {
    let root = try makeTempRoot("tag-session-scoped")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let sessionsResult = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--sessions", "--json"])
    #expect(sessionsResult.exitCode == 0, "stderr: \(sessionsResult.stderr)")
    let sessions = try #require(try jsonItems(sessionsResult.stdout))
    let date = try #require(sessions.first?["date_raw"] as? String)

    let add = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "--date", date, "clouds", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let sessionList = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--date", date, "--root", root.path, "--json"])
    #expect(sessionList.exitCode == 0, "stderr: \(sessionList.stderr)")
    let sessionTags = try jsonStringItems(sessionList.stdout)
    #expect(sessionTags == ["clouds"])

    let targetList = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(targetList.exitCode == 0, "stderr: \(targetList.stderr)")
    let targetTags = try jsonStringItems(targetList.stdout)
    #expect(targetTags == [])
}

@Test func statsTagFilterOnlyShowsTaggedTargets() async throws {
    let root = try makeTempRoot("stats-tag-filter")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let filtered = try await runCLI(["stats", "--root", root.path, "--tag", "favorite", "--json"])
    #expect(filtered.exitCode == 0, "stderr: \(filtered.stderr)")
    let json = try jsonItems(filtered.stdout)
    let stats = try #require(json)
    #expect(!stats.isEmpty)
    #expect(stats.allSatisfy { ($0["target"] as? String) == "M45_Pleiades" })

    let filteredOut = try await runCLI(["stats", "--root", root.path, "--tag", "nonexistent-tag", "--json"])
    #expect(filteredOut.exitCode == 0, "stderr: \(filteredOut.stderr)")
    let jsonOut = try jsonItems(filteredOut.stdout)
    #expect(try #require(jsonOut).isEmpty)
}

@Test func tagAddRejectsEmptyTagText() async throws {
    let root = try makeTempRoot("tag-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["tag", "add", "--target", "M45_Pleiades", "   ", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func tagAddWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("tag-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["tag", "add", "favorite", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - ack (R10-B8)

@Test func ackAddThenListShowsAckedKeyAndNote() async throws {
    let root = try makeTempRoot("ack-add-list")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let add = try await runCLI(["ack", "add", "residue|*.seq", "--note", "ismert, szándékos", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let list = try await runCLI(["ack", "list", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let json = try jsonItems(list.stdout)
    let acks = try #require(json)
    #expect(acks.count == 1)
    #expect(acks[0]["category"] as? String == "residue")
    #expect(acks[0]["group_key"] as? String == "*.seq")
    #expect(acks[0]["note"] as? String == "ismert, szándékos")
    #expect(acks[0]["acked_at"] != nil)
}

@Test func ackAddThenRemoveClearsIt() async throws {
    let root = try makeTempRoot("ack-add-remove")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let add = try await runCLI(["ack", "add", "misplaced-file|sessions/M31/2026-01-01", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")
    let remove = try await runCLI(["ack", "remove", "misplaced-file|sessions/M31/2026-01-01", "--root", root.path])
    #expect(remove.exitCode == 0, "stderr: \(remove.stderr)")

    let list = try await runCLI(["ack", "list", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let json = try jsonItems(list.stdout)
    #expect(try #require(json).isEmpty)
}

@Test func ackListHumanOutputPrintsKeyAndTimestamp() async throws {
    let root = try makeTempRoot("ack-list-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let add = try await runCLI(["ack", "add", "residue|*.seq", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let list = try await runCLI(["ack", "list", "--root", root.path])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    #expect(list.stdout.contains("residue|*.seq"))
    #expect(list.stdout.contains("acked:"))
}

/// The positional must look exactly like an `ack_key` (`category|groupKey`)
/// -- missing the `|` separator is a usage error, not a silent no-op.
@Test func ackAddRejectsPositionalWithoutPipeSeparator() async throws {
    let root = try makeTempRoot("ack-bad-positional")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["ack", "add", "no-pipe-here", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func ackAddWithoutPositionalExitsWithError() async throws {
    let root = try makeTempRoot("ack-no-positional")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["ack", "add", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - note (R10-B8)

@Test func noteSetThenShowRoundTrips() async throws {
    let root = try makeTempRoot("note-set-show")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Bortle", "--value", "5", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path, "--json",
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: String]
    #expect(json?["Bortle"] == "5")

    // Never touches README.txt -- the iron rule, directly asserted here too.
    let readmeURL = root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/README.txt")
    let readmeContentAfter = try String(contentsOf: readmeURL, encoding: .utf8)
    #expect(readmeContentAfter.contains("Camera: ZWO ASI2600MC Pro"))
    #expect(!readmeContentAfter.contains("Bortle"))
}

/// `SessionStatsQueries.computeSessionDetail`'s own "README nyer" merge:
/// a store-written key that ALSO exists in the README-sourced
/// `session_notes` (populated by `scan` from `README.txt`) must show the
/// README's value, not the store's.
@Test func noteShowLetsReadmeWinAKeyCollisionWithTheStore() async throws {
    let root = try makeTempRoot("note-show-readme-wins")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // The fixture's README has "Camera: ZWO ASI2600MC Pro" -- collide with
    // that exact key via the store and confirm the README's value wins.
    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Camera", "--value", "store-value-should-lose", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path, "--json",
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    // R11-T13/F20: this collision is now ALSO a conflict, so the root object
    // is no longer plain `[String: String]` (a "conflicts" sub-object is
    // additive alongside it) -- cast to `[String: Any]` and reach into the
    // "Camera" key specifically.
    let json = try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any]
    #expect(json?["Camera"] as? String == "ZWO ASI2600MC Pro")
}

/// R11-T13/F20: `note show --json` adds an additive `conflicts` block
/// whenever the app-store note and the README disagree on a key -- keyed by
/// the exact (verbatim, un-mangled) key text, `app_value`/`readme_value`
/// after `printJSON`'s snake_case conversion of the FIXED schema field
/// names (never applied to the user's own arbitrary key text, see
/// `NoteShowJSONValue`'s own doc comment for why that distinction matters).
@Test func noteShowJSONIncludesConflictsBlockWhenReadmeAndStoreDisagree() async throws {
    let root = try makeTempRoot("note-show-conflicts-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Camera", "--value", "store-value-should-lose", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path, "--json",
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any]
    let conflicts = try #require(json?["conflicts"] as? [String: Any])
    let camera = try #require(conflicts["Camera"] as? [String: String])
    #expect(camera["app_value"] == "store-value-should-lose")
    #expect(camera["readme_value"] == "ZWO ASI2600MC Pro")
}

/// The human-readable side of the same conflict: a "⚠ eltér a README-től"
/// suffix on the disagreeing key's line, nothing extra on a non-conflicting
/// one.
@Test func noteShowHumanOutputFlagsConflictingKeyWithWarningSuffix() async throws {
    let root = try makeTempRoot("note-show-conflicts-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Camera", "--value", "store-value-should-lose", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path,
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    let cameraLine = show.stdout.split(separator: "\n").first { $0.hasPrefix("Camera:") }
    #expect(cameraLine?.contains("⚠ eltér a README-től") == true)
}

/// No conflict at all -- `note show --json`'s root object stays the plain
/// flat `[String: String]` it always was, with no "conflicts" key added.
@Test func noteShowJSONHasNoConflictsKeyWhenNothingDisagrees() async throws {
    let root = try makeTempRoot("note-show-no-conflicts")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Bortle", "--value", "5", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path, "--json",
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: String]
    #expect(json?["Bortle"] == "5")
    #expect(json?["conflicts"] == nil)
}

/// An empty (or omitted) `--value` removes that key -- `SessionNoteStore`
/// already drops blank-value pairs on save; this asserts the CLI round-trip
/// of that behavior end to end.
@Test func noteSetWithEmptyValueRemovesTheKey() async throws {
    let root = try makeTempRoot("note-set-empty-removes")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Szél", "--value", "erős", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")
    let clear = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10",
        "--key", "Szél", "--value", "", "--root", root.path,
    ])
    #expect(clear.exitCode == 0, "stderr: \(clear.stderr)")

    let show = try await runCLI([
        "note", "show", "--target", "M45_Pleiades", "--date", "2026-01-10", "--root", root.path, "--json",
    ])
    #expect(show.exitCode == 0, "stderr: \(show.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: String]
    #expect(json?["Szél"] == nil)
}

@Test func noteShowWithoutTargetOrDateExitsWithError() async throws {
    let root = try makeTempRoot("note-show-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["note", "show", "--target", "M45_Pleiades", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func noteSetWithoutKeyExitsWithError() async throws {
    let root = try makeTempRoot("note-set-no-key")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI([
        "note", "set", "--target", "M45_Pleiades", "--date", "2026-01-10", "--value", "x", "--root", root.path,
    ])
    #expect(result.exitCode == 1)
}

// MARK: - goal (R10-B8)

@Test func goalSetThenClearRoundTrips() async throws {
    let root = try makeTempRoot("goal-set-clear")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "6", "--root", root.path, "--json"])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")
    let setJSON = try #require(try JSONSerialization.jsonObject(with: Data(set.stdout.utf8)) as? [String: Any])
    // Integral hours print without a decimal -- must match
    // `AppState.formatGoalTag`'s exact text so app and CLI round-trip.
    #expect(setJSON["goal_tag"] as? String == "goal:6h")

    let tagList = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(tagList.exitCode == 0, "stderr: \(tagList.stderr)")
    let tags = try jsonStringItems(tagList.stdout)
    #expect(tags == ["goal:6h"])

    let clear = try await runCLI(["goal", "clear", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(clear.exitCode == 0, "stderr: \(clear.stderr)")
    let clearJSON = try #require(try JSONSerialization.jsonObject(with: Data(clear.stdout.utf8)) as? [String: Any])
    #expect(clearJSON["goal_tag"] == nil || clearJSON["goal_tag"] is NSNull)

    let tagListAfterClear = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(tagListAfterClear.exitCode == 0, "stderr: \(tagListAfterClear.stderr)")
    let tagsAfterClear = try jsonStringItems(tagListAfterClear.stdout)
    #expect(tagsAfterClear == [])
}

/// Fractional hours format with exactly one decimal place, same as
/// `AppState.formatGoalTag`'s non-integral branch.
@Test func goalSetWithFractionalHoursFormatsWithOneDecimal() async throws {
    let root = try makeTempRoot("goal-set-fractional")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "6.5", "--root", root.path, "--json"])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")
    let setJSON = try #require(try JSONSerialization.jsonObject(with: Data(set.stdout.utf8)) as? [String: Any])
    #expect(setJSON["goal_tag"] as? String == "goal:6.5h")
}

/// Setting a new goal must replace (not accumulate alongside) any prior
/// `goal:*` tag -- same "there should only ever be at most one" invariant
/// `AppState.setGoal` documents.
@Test func goalSetReplacesAnyPriorGoalTagRatherThanAddingASecondOne() async throws {
    let root = try makeTempRoot("goal-set-replaces")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "4", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let second = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "8", "--root", root.path])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let tagList = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(tagList.exitCode == 0, "stderr: \(tagList.stderr)")
    let tags = try jsonStringItems(tagList.stdout)
    #expect(tags == ["goal:8h"])
}

@Test func goalSetRejectsZeroOrMissingHours() async throws {
    let root = try makeTempRoot("goal-set-bad-hours")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let zero = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "0", "--root", root.path])
    #expect(zero.exitCode == 1)

    let missing = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--root", root.path])
    #expect(missing.exitCode == 1)
}

@Test func goalSetWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("goal-set-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["goal", "set", "--hours", "6", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - goal --filter / goal list (R11-T5/F2)

@Test func goalSetFilterThenClearRoundTrips() async throws {
    let root = try makeTempRoot("goal-set-filter-clear")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path, "--json",
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")
    let setJSON = try #require(try JSONSerialization.jsonObject(with: Data(set.stdout.utf8)) as? [String: Any])
    #expect(setJSON["goal_tag"] as? String == "goal:Ha=12h")
    #expect(setJSON["filter"] as? String == "Ha")

    let tagList = try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(tagList.exitCode == 0, "stderr: \(tagList.stderr)")
    let tags = try jsonStringItems(tagList.stdout)
    #expect(tags == ["goal:Ha=12h"])

    let clear = try await runCLI(["goal", "clear", "--target", "M45_Pleiades", "--filter", "Ha", "--root", root.path, "--json"])
    #expect(clear.exitCode == 0, "stderr: \(clear.stderr)")
    let clearJSON = try #require(try JSONSerialization.jsonObject(with: Data(clear.stdout.utf8)) as? [String: Any])
    #expect(clearJSON["goal_tag"] == nil || clearJSON["goal_tag"] is NSNull)

    let tagsAfterClear = try jsonStringItems(
        try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"]).stdout
    )
    #expect(tagsAfterClear == [])
}

/// The two goal conventions must coexist -- setting a per-filter goal must
/// never touch (or be touched by) the overall `goal:<hours>h` tag.
@Test func goalSetFilterAndOverallGoalCoexistIndependently() async throws {
    let root = try makeTempRoot("goal-set-filter-coexist")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let setOverall = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--hours", "30", "--root", root.path])
    #expect(setOverall.exitCode == 0, "stderr: \(setOverall.stderr)")
    let setFilter = try await runCLI([
        "goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path,
    ])
    #expect(setFilter.exitCode == 0, "stderr: \(setFilter.stderr)")

    let tags = try #require(try jsonStringItems(
        try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"]).stdout
    ))
    #expect(Set(tags) == ["goal:30h", "goal:Ha=12h"])

    // Clearing the OVERALL goal must leave the filter goal untouched.
    let clearOverall = try await runCLI(["goal", "clear", "--target", "M45_Pleiades", "--root", root.path])
    #expect(clearOverall.exitCode == 0, "stderr: \(clearOverall.stderr)")
    let tagsAfter = try jsonStringItems(
        try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"]).stdout
    )
    #expect(tagsAfter == ["goal:Ha=12h"])
}

/// Setting a new goal for one filter must replace only THAT filter's prior
/// tag (not any other filter's), same "replace, don't accumulate"
/// invariant the overall goal already has.
@Test func goalSetFilterReplacesOnlyThatFiltersPriorTag() async throws {
    let root = try makeTempRoot("goal-set-filter-replace")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    _ = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "4", "--root", root.path])
    _ = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "OIII", "--hours", "6", "--root", root.path])
    let second = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "8", "--root", root.path])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let tags = try #require(try jsonStringItems(
        try await runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"]).stdout
    ))
    #expect(Set(tags) == ["goal:Ha=8h", "goal:OIII=6h"])
}

@Test func goalListJSONShowsAGoalOnlyFilterAsZeroUsableWithFullMissing() async throws {
    let root = try makeTempRoot("goal-list-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let set = try await runCLI([
        "goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path,
    ])
    #expect(set.exitCode == 0, "stderr: \(set.stderr)")

    let list = try await runCLI(["goal", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String: Any])
    #expect(json["target"] as? String == "M45_Pleiades")
    #expect(json["overall_goal_seconds"] == nil || json["overall_goal_seconds"] is NSNull)
    let filters = try #require(json["filters"] as? [[String: Any]])
    let ha = try #require(filters.first { $0["filter"] as? String == "Ha" })
    #expect(ha["usable_frame_count"] as? Int == 0)
    #expect(ha["goal_seconds"] as? Double == 12 * 3600.0)
    #expect(ha["missing_seconds"] as? Double == 12 * 3600.0)
}

@Test func goalListHumanOutputPrintsTargetAndFilterTable() async throws {
    let root = try makeTempRoot("goal-list-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    _ = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path])

    let list = try await runCLI(["goal", "list", "--target", "M45_Pleiades", "--root", root.path])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    #expect(list.stdout.contains("M45_Pleiades"))
    #expect(list.stdout.contains("SZŰRŐ"))
    #expect(list.stdout.contains("HIÁNYZIK"))
}

/// `stats --filters --json` (whole-target mode) must reflect a filter goal
/// once one is set -- same merge `goal list` uses.
@Test func statsFiltersJSONIncludesGoalAndMissingWhenAFilterGoalIsSet() async throws {
    let root = try makeTempRoot("stats-filters-with-goal")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    _ = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path])

    let result = try await runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--filters", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let rows = try #require(try jsonItems(result.stdout))
    let ha = try #require(rows.first { $0["filter"] as? String == "Ha" })
    #expect(ha["goal_seconds"] as? Double == 12 * 3600.0)
    #expect(ha["missing_seconds"] as? Double == 12 * 3600.0)
}

/// A date-scoped `stats --filters --json --date D` must NOT merge in goal
/// data -- a single night has no goal of its own.
@Test func statsFiltersWithDateNeverMergesInGoalData() async throws {
    let root = try makeTempRoot("stats-filters-date-no-goal")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    _ = try await runCLI(["goal", "set", "--target", "M45_Pleiades", "--filter", "Ha", "--hours", "12", "--root", root.path])

    let result = try await runCLI([
        "stats", "--root", root.path, "--target", "M45_Pleiades", "--filters", "--date", "2026-01-10", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let rows = try #require(try jsonItems(result.stdout))
    for row in rows {
        #expect(row["goal_seconds"] == nil || row["goal_seconds"] is NSNull)
    }
}

@Test func goalListWithoutTargetExitsWithError() async throws {
    let root = try makeTempRoot("goal-list-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["goal", "list", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - config (R11-T4)

@Test func configShowHumanReadableByDefaultPrintsSectionsAndRootPath() async throws {
    let root = try makeTempRoot("config-show-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["config", "show", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("rootPath: \(root.path)"))
    #expect(result.stdout.contains("Kalibráció"))
    // Must not look like JSON any more -- no schema_version noise, no braces.
    #expect(!result.stdout.contains("schema_version"))
    #expect(!result.stdout.contains("{"))
}

@Test func configShowJSONFlagStillPrintsFullStructure() async throws {
    let root = try makeTempRoot("config-show-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["config", "show", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonObject(result.stdout)
    #expect(json?["root_path"] as? String == root.path)
    #expect(json?["schema_version"] as? String == "1")
    #expect(json?["calib"] != nil)
}

@Test func configPathHumanReadableUnaffectedByJSONFix() async throws {
    let root = try makeTempRoot("config-path")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["config", "path", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        == root.appendingPathComponent(".astro_tool/config.json").path)
}

// MARK: - new-session

@Test func newSessionCreatesThenRerunFails() async throws {
    let root = try makeTempRoot("new-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let first = try await runCLI([
        "new-session", "--root", root.path,
        "--catalog", "M1", "--name", "Crab Nebula", "--date", "2026-08-02",
    ])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let sessionDir = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-02")
    #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("lights").path))
    #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("flats").path))
    #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("darks").path))
    #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("biases").path))
    #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("README.txt").path))

    let second = try await runCLI([
        "new-session", "--root", root.path,
        "--catalog", "M1", "--name", "Crab Nebula", "--date", "2026-08-02",
    ])
    #expect(second.exitCode == 1)
}

@Test func newSessionRejectsNonCanonicalDate() async throws {
    let root = try makeTempRoot("new-session-bad-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI([
        "new-session", "--root", root.path,
        "--catalog", "M1", "--name", "Test", "--date", "2026-08-02-2",
    ])
    #expect(result.exitCode == 1)
}

// MARK: - calib --health

@Test func calibHealthJSONReportsFlatDisciplineBiasAndDarkMasters() async throws {
    let root = try makeTempRoot("calib-health-json")
    defer { try? FileManager.default.removeItem(at: root) }

    // T1 has lights but no flats at all -> "nincs flat".
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["calib", "--root", root.path, "--health", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let flats = try #require(json?["flats"] as? [[String: Any]])
    let t1Flat = try #require(flats.first { $0["target"] as? String == "T1" })
    #expect(t1Flat["status"] as? String == "nincs flat")

    #expect(json?["bias_groups"] != nil)
    #expect(json?["missing_bias_combos"] != nil)
    let darkMasters = try #require(json?["dark_masters"] as? [[String: Any]])
    #expect(darkMasters.contains { $0["path"] as? String == "calibration_library/darks/300sec_-10deg" })
}

@Test func calibHealthHumanOutputPrintsHungarianHeaders() async throws {
    let root = try makeTempRoot("calib-health-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["calib", "--root", root.path, "--health"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Flat-fegyelem"))
    #expect(result.stdout.contains("Bias-készlet"))
    #expect(result.stdout.contains("Dark-készlet egészség"))
}

@Test func calibWithoutHealthFlagStaysOnCoverageReport() async throws {
    let root = try makeTempRoot("calib-no-health")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["calib", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let needs = try #require(json)
    #expect(needs.contains { $0["exposure_seconds"] as? Double == 300 })
}

// MARK: - calib --flats (R11-T16/F17)

@Test func calibFlatsFlagListsOnlyFlatCoverageRows() async throws {
    let root = try makeTempRoot("calib-flats-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0, filter: "OIII")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["calib", "--root", root.path, "--flats", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let needs = try #require(json)
    #expect(needs.allSatisfy { $0["kind"] as? String == "flat" })
    #expect(needs.contains { $0["filter"] as? String == "OIII" })
}

@Test func calibPlainHumanSummaryMentionsFlatTodoCount() async throws {
    let root = try makeTempRoot("calib-plain-human")
    defer { try? FileManager.default.removeItem(at: root) }

    // No flat anywhere for this OIII light -- one flat todo.
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0, filter: "OIII")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["calib", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("flat)"))
    #expect(result.stdout.contains("Készíts OIII flatet"))
}

// MARK: - calib --shopping (R12-U5)

@Test func calibShoppingJSONCarriesNightSiteAndEmptyItems() async throws {
    let root = try makeTempRoot("calib-shopping-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let result = try await runCLI([
        "calib", "--root", root.path, "--shopping", "--date", "2026-08-10",
        "--site", "Del", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try #require(try jsonObject(result.stdout))
    #expect(json["night"] as? String == "2026-08-10")
    #expect(json["site"] as? String == "Del")
    #expect((json["items"] as? [[String: Any]])?.isEmpty == true)
}

@Test func calibShoppingRejectsUnknownSiteAndConflictingModes() async throws {
    let root = try makeTempRoot("calib-shopping-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let unknown = try await runCLI(["calib", "--root", root.path, "--shopping", "--site", "Sehol"])
    #expect(unknown.exitCode == 1)
    #expect(unknown.stderr.contains("ismeretlen helyszín"))

    let conflict = try await runCLI(["calib", "--root", root.path, "--shopping", "--health"])
    #expect(conflict.exitCode == 1)
    #expect(conflict.stderr.contains("egyszerre csak egy"))
}

@Test func calibShoppingHumanHeaderNamesTheRequestedNight() async throws {
    let root = try makeTempRoot("calib-shopping-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let result = try await runCLI(["calib", "--root", root.path, "--shopping", "--date", "2026-08-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Kalibrációs bevásárlólista — 2026-08-10 éjszakájára"))
    #expect(result.stdout.contains("Helyszín: Otthon"))
}

// MARK: - permission errors -> exit 2

@Test func scanOnReadOnlyRootExitsWithTCCGuidance() async throws {
    // Deliberately NOT `Fixtures.makeMessyLibrary` -- one of its fixture
    // files lives under `.astro_tool/`, which would pre-create that
    // directory (with its own, still-writable permissions) before the
    // chmod below, masking the exact failure this test targets: `scan`
    // needing to CREATE `.astro_tool/` under a root it can no longer write
    // into.
    let root = try makeTempRoot("scan-readonly-root")
    defer {
        // Restore write permission before cleanup -- a still-555 directory
        // can't be removed either.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

    let result = try await runCLI(["scan", "--root", root.path])
    #expect(result.exitCode == 2, "stdout: \(result.stdout), stderr: \(result.stderr)")
    #expect(result.stderr.contains("Teljes lemezhozzáférés"))
}

// MARK: - link-calib

/// Writes a minimal real FITS header (not the plain dummy content
/// `Fixtures.makeMessyLibrary` uses) so `link-calib`'s underlying
/// `CalibLinker.plan` -- which needs actual EXPTIME/SET-TEMP meta -- has
/// something to match against.
private func writeLinkCalibFITS(_ relativePath: String, root: URL, exptime: Double, setTemp: Double, filter: String? = nil) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "EXPTIME =                \(exptime)", "SET-TEMP=                \(setTemp)",
    ]
    if let filter { cards.append("FILTER  = '\(filter)'") }
    cards.append("END")
    try buildHeaderData(cards).write(to: url)
}

private func writeLinkCalibDummy(_ relativePath: String, root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "dummy master".write(to: url, atomically: true, encoding: .utf8)
}

@Test func linkCalibDryRunPrintsPlanAndCreatesNothing() async throws {
    let root = try makeTempRoot("link-calib-dry-run")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l2.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--dry-run", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let items = try #require(json?["items"] as? [[String: Any]])
    #expect(items.count == 1)
    #expect(items.first?["source_path"] as? String == "calibration_library/darks/300sec_-10deg/master.fit")

    let destURL = root.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(!FileManager.default.fileExists(atPath: destURL.path))
}

@Test func linkCalibWithYesLinksThenRerunReportsSkipped() async throws {
    let root = try makeTempRoot("link-calib-yes")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--yes", "--json",
    ])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let firstJSON = try JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any]
    let linked = try #require(firstJSON?["linked"] as? [String])
    #expect(linked == ["sessions/T1/2026-01-10/darks/master.fit"])
    #expect((firstJSON?["skipped"] as? [String])?.isEmpty == true)

    let destURL = root.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(FileManager.default.fileExists(atPath: destURL.path))

    let second = try await runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--yes", "--json",
    ])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")
    let secondJSON = try JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any]
    #expect((secondJSON?["linked"] as? [String])?.isEmpty == true)
    #expect(secondJSON?["skipped"] as? [String] == ["sessions/T1/2026-01-10/darks/master.fit"])
}

@Test func linkCalibJSONWithoutYesOrDryRunExitsWithError() async throws {
    let root = try makeTempRoot("link-calib-no-yes")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 1)

    let destURL = root.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(!FileManager.default.fileExists(atPath: destURL.path))
}

@Test func linkCalibWithUnknownSessionExitsWithTargetNotFoundError() async throws {
    let root = try makeTempRoot("link-calib-unknown-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "1999-01-01", "--dry-run",
    ])
    // R11-T4: target/session-lookup failure gets its own exit code (3).
    #expect(result.exitCode == 3)
}

// MARK: - match (R11-T4)

@Test func matchJSONAfterScanReportsCalibrationForFixtureSession() async throws {
    let root = try makeTempRoot("match-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["match", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonObject(result.stdout)
    #expect(json?["target"] as? String == "T1")
    #expect(json?["date"] as? String == "2026-01-10")
    #expect(json?["lights"] as? Int == 1)
}

@Test func matchWithUnknownSessionExitsWithTargetNotFoundError() async throws {
    let root = try makeTempRoot("match-unknown-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["match", "--root", root.path, "--target", "T1", "--date", "1999-01-01"])
    // R11-T4: target/session-lookup failure gets its own exit code (3).
    #expect(result.exitCode == 3)
    #expect(result.stderr.contains("no such session"))
}

// MARK: - plan

/// Writes a light frame carrying plate-solved WCS (`CRVAL1`/`CRVAL2`) plus
/// `SITELAT`/`SITELONG` -- fixture coordinates only (Budapest-ish, per the
/// R5-1 spec's own suggestion), never the real user's site.
private func writePlanFITS(_ relativePath: String, root: URL, crval1: Double, crval2: Double, dateObs: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "EXPTIME =                300.0", "DATE-OBS= '\(dateObs)'",
        "CRVAL1  =                \(crval1)", "CRVAL2  =                \(crval2)",
        "SITELAT =                 47.5", "SITELONG=                 19.0", "END",
    ]
    try buildHeaderData(cards).write(to: url)
}

@Test func planJSONAfterScanReportsVerdictsForFixtureTarget() async throws {
    let root = try makeTempRoot("plan-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let plans = try #require(json)
    let plan = try #require(plans.first { $0["target"] as? String == "M31_Andromeda" })
    #expect(plan["verdict"] as? String != nil)
    #expect(plan["ra_deg"] != nil)
    #expect(plan["dec_deg"] != nil)
    #expect((plan["verdict"] as? String)?.isEmpty == false)
}

@Test func planHumanOutputShowsHeaderAndTableWithoutSiteCoordinates() async throws {
    let root = try makeTempRoot("plan-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Ma este"))
    #expect(result.stdout.contains("M31_Andromeda"))
    #expect(result.stdout.contains("VERDIKT"))

    // PRIVACY: the human table must never print the site's actual
    // coordinates (47.5 / 19.0), only derived times/phase.
    #expect(!result.stdout.contains("47.5"))
    #expect(!result.stdout.contains("19.0"))
}

@Test func planRespectsMinAltFlag() async throws {
    let root = try makeTempRoot("plan-min-alt")
    defer { try? FileManager.default.removeItem(at: root) }

    // dec -80 at lat 47.5 never rises anywhere near minAlt.
    try writePlanFITS("sessions/T_Low/2026-08-01/lights/l1.fit", root: root, crval1: 10.0, crval2: -80.0, dateObs: "2026-08-01T22:00:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--min-alt", "30", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try jsonItems(result.stdout)
    let plans = try #require(json)
    let plan = try #require(plans.first { $0["target"] as? String == "T_Low" })
    #expect((plan["verdict"] as? String)?.hasPrefix("alacsony") == true)
}

@Test func planWithInvalidDateExitsWithError() async throws {
    let root = try makeTempRoot("plan-bad-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["plan", "--root", root.path, "--date", "not-a-date"])
    #expect(result.exitCode == 1)
}

// MARK: - plan --out (R11-T6/F18a)

@Test func planOutDashPrintsCSVToStdout() async throws {
    let root = try makeTempRoot("plan-out-dash")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.hasPrefix(PlanExport.csvHeader + "\n"))
    #expect(result.stdout.contains("M31_Andromeda"))
}

@Test func planOutPathWritesCSVToCustomPathOutsideRoot() async throws {
    let root = try makeTempRoot("plan-out-path")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let outDir = try makeTempRoot("plan-out-path-dest")
    defer { try? FileManager.default.removeItem(at: outDir) }
    let outPath = outDir.appendingPathComponent("plan.csv").path

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--out", outPath])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(FileManager.default.fileExists(atPath: outPath))

    let content = try String(contentsOfFile: outPath, encoding: .utf8)
    #expect(content.contains("M31_Andromeda"))
}

@Test func planOutWithMonthExitsWithUsageError() async throws {
    let root = try makeTempRoot("plan-out-month")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["plan", "--root", root.path, "--month", "--out", "-"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--out is not supported together with --month"))
}

// MARK: - night-info (R10-B8)

@Test func nightInfoJSONReportsDarkHoursAndMoonWhenSiteResolvable() async throws {
    let root = try makeTempRoot("night-info-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS(
        "sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root,
        crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["night-info", "--root", root.path, "--date", "2026-08-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    #expect(json["moon_illumination_percent"] != nil)
    #expect(json["dark_hours"] != nil)
}

@Test func nightInfoHumanOutputPrintsDarkHoursAndMoonLinesWithoutLeakingCoordinates() async throws {
    let root = try makeTempRoot("night-info-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS(
        "sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root,
        crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["night-info", "--root", root.path, "--date", "2026-08-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("sötét óra:"))
    #expect(result.stdout.contains("Hold:"))

    // PRIVACY: same rule `printPlanHeader` follows -- never leak the site's
    // actual coordinates (47.5 / 19.0) into human output.
    #expect(!result.stdout.contains("47.5"))
    #expect(!result.stdout.contains("19.0"))
}

@Test func nightInfoWithoutSiteCoordinatesStillReportsMoonIlluminationAndExplainsWhy() async throws {
    let root = try makeTempRoot("night-info-no-site")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["night-info", "--root", root.path, "--date", "2026-08-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    #expect(json["dark_hours"] == nil || json["dark_hours"] is NSNull)
    #expect(json["note"] as? String == "nincs site-koordináta")
    #expect(json["moon_illumination_percent"] != nil)
}

@Test func nightInfoWithInvalidDateExitsWithError() async throws {
    let root = try makeTempRoot("night-info-bad-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["night-info", "--root", root.path, "--date", "not-a-date"])
    #expect(result.exitCode == 1)
}

// MARK: - plan/night-info --site (R11-T15/F16)

private func writeSitesConfig(root: URL, sitesJSON: String) throws {
    let toolDir = root.appendingPathComponent(".astro_tool", isDirectory: true)
    try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
    let configURL = toolDir.appendingPathComponent("config.json", isDirectory: false)
    try Data(sitesJSON.utf8).write(to: configURL)
}

private let twoSitesConfigJSON = """
{
  "sites": [
    { "name": "Otthon", "latitudeDeg": 47.5, "longitudeDeg": 19.0, "isDefault": true },
    { "name": "Del", "latitudeDeg": -40.0, "longitudeDeg": 19.0, "isDefault": false }
  ]
}
"""

@Test func planSiteFlagSelectsNamedSiteOverDefault() async throws {
    let root = try makeTempRoot("plan-site-flag")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)
    try writePlanFITS(
        "sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root,
        crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00"
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let defaultResult = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--json"])
    #expect(defaultResult.exitCode == 0, "stderr: \(defaultResult.stderr)")
    let defaultPlan = try #require(try jsonItems(defaultResult.stdout)?.first { $0["target"] as? String == "M31_Andromeda" })
    let defaultAlt = try #require(defaultPlan["max_altitude_deg"] as? Double)

    // "Del" is a far-southern site sharing the same longitude -- the very
    // same target/night gives a dramatically lower max altitude from there.
    let southResult = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--site", "Del", "--json"])
    #expect(southResult.exitCode == 0, "stderr: \(southResult.stderr)")
    let southPlan = try #require(try jsonItems(southResult.stdout)?.first { $0["target"] as? String == "M31_Andromeda" })
    let southAlt = try #require(southPlan["max_altitude_deg"] as? Double)

    #expect(abs(defaultAlt - southAlt) > 20)
}

@Test func planWithUnknownSiteNameExitsWithErrorListingConfiguredNames() async throws {
    let root = try makeTempRoot("plan-site-unknown")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--site", "Nemletezo"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("Otthon"))
    #expect(result.stderr.contains("Del"))
}

@Test func planMonthSiteFlagSelectsNamedSite() async throws {
    let root = try makeTempRoot("plan-month-site-flag")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--month", "--nights", "1", "--site", "Del", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
}

@Test func nightInfoSiteFlagSelectsNamedSite() async throws {
    let root = try makeTempRoot("night-info-site-flag")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["night-info", "--root", root.path, "--date", "2026-08-10", "--site", "Del", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    #expect(json["moon_illumination_percent"] != nil)
}

@Test func nightInfoWithUnknownSiteNameExitsWithError() async throws {
    let root = try makeTempRoot("night-info-site-unknown")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["night-info", "--root", root.path, "--site", "Nemletezo"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("Otthon"))
}

@Test func configShowHumanReadablePrintsConfiguredSitesWithDefaultMarker() async throws {
    let root = try makeTempRoot("config-show-sites")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSitesConfig(root: root, sitesJSON: twoSitesConfigJSON)

    let result = try await runCLI(["config", "show", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Helyszínek (sites)"))
    #expect(result.stdout.contains("Otthon"))
    #expect(result.stdout.contains("[alapértelmezett]"))
    #expect(result.stdout.contains("Del"))
}

// MARK: - projects

private func writeProjectsFITS(_ relativePath: String, root: URL, exptime: Double, filter: String? = nil) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "EXPTIME =                \(exptime)",
    ]
    if let filter { cards.append("FILTER  = '\(filter)'") }
    cards.append("END")
    try buildHeaderData(cards).write(to: url)
}

@Test func projectsJSONDecodesAndReportsPhaseForFixtureTarget() async throws {
    let root = try makeTempRoot("projects-json")
    defer { try? FileManager.default.removeItem(at: root) }

    // No explicit goal tag: the brightness- and setup-aware automatic goal
    // keeps this short M31 fixture in collection.
    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 3 * 3600)
    try "notes".write(to: root.appendingPathComponent("sessions/M31_Andromeda/2026-08-01/README.txt"), atomically: true, encoding: .utf8)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["projects", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let projects = try #require(json)
    let project = try #require(projects.first { $0["target"] as? String == "M31_Andromeda" })
    #expect(project["phase"] as? String == "gyujtes")
    let todos = try #require(project["todos"] as? [String])
    #expect(todos.contains { $0.contains("automatikus cél") })
    #expect(todos.contains { $0.contains("hiányzik még") })
}

@Test func projectsHumanOutputShowsPhaseHeaders() async throws {
    let root = try makeTempRoot("projects-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 3 * 3600)
    try "notes".write(to: root.appendingPathComponent("sessions/M31_Andromeda/2026-08-01/README.txt"), atomically: true, encoding: .utf8)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["projects", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Gyűjtés alatt"))
    #expect(result.stdout.contains("automatikus cél"))
    #expect(result.stdout.contains("M31_Andromeda"))
}

// MARK: - export

@Test func exportOutDashPrintsContentToStdoutWithoutWritingAFile() async throws {
    let root = try makeTempRoot("export-stdout")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 300.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["export", "--root", root.path, "--target", "M31_Andromeda", "--format", "astrobin", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.hasPrefix("date,filter,number,duration,binning,gain,sensorCooling,darks,flats,flatDarks,bias,bortle,meanSqm"))
    #expect(result.stdout.contains("2026-08-01"))

    let exportsDir = root.appendingPathComponent(".astro_tool/exports")
    #expect(!FileManager.default.fileExists(atPath: exportsDir.path))
}

@Test func exportDefaultModeWritesFileUnderExportsAndPrintsPath() async throws {
    let root = try makeTempRoot("export-file")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 300.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["export", "--root", root.path, "--target", "M31_Andromeda", "--format", "md"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let printedPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(printedPath.hasPrefix(root.appendingPathComponent(".astro_tool/exports").path))
    #expect(printedPath.hasSuffix(".md"))
    #expect(FileManager.default.fileExists(atPath: printedPath))
}

@Test func exportAstrobinWarnsOnStderrAboutAnUnmappedFilter() async throws {
    let root = try makeTempRoot("export-astrobin-unmapped-filter")
    defer { try? FileManager.default.removeItem(at: root) }

    // No `astrobin.filterIds` mapping configured at all -- OIII must warn.
    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 300.0, filter: "OIII")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["export", "--root", root.path, "--target", "M31_Andromeda", "--format", "astrobin", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("OIII"))
    #expect(result.stderr.contains("AstroBin filter-ID"))
}

@Test func exportMissingTargetOrFormatExitsWithError() async throws {
    let root = try makeTempRoot("export-missing-flags")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["export", "--root", root.path, "--format", "csv"])
    #expect(result.exitCode == 1)
}

// MARK: - solve (R7-1)
//
// Real plate-solving needs an actual Siril install and a real star field --
// neither is feasible to fake for a CLI-level smoke test (the mock-backend
// path is exercised in depth by `PlateSolverTests`, which drives
// `PlateSolver` directly). These smoke tests only cover the CLI's own
// input-validation/error-reporting paths, which don't need Siril to actually
// run: a `--target`/`--all`-less invocation, an unknown `--target`, and a
// missing-Siril-binary error message -- forced deterministically via a
// config.json `rating.sirilPath` override, so the test doesn't depend on
// whether the machine running it happens to have a real Siril installed.

/// Writes `<root>/.astro_tool/config.json` with `rating.sirilPath` pointed
/// at a path that is guaranteed not to exist, so `solve` deterministically
/// hits its "siril not found" path regardless of whether this machine has a
/// real Siril install.
private func writeBogusSirilPathConfig(root: URL) throws {
    let toolDir = root.appendingPathComponent(".astro_tool", isDirectory: true)
    try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
    let configURL = toolDir.appendingPathComponent("config.json", isDirectory: false)
    let json = """
    {"rating": {"sirilPath": "/definitely/not/a/real/siril-cli"}}
    """
    try Data(json.utf8).write(to: configURL)
}

@Test func solveWithoutTargetOrAllExitsWithError() async throws {
    let root = try makeTempRoot("solve-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["solve", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func solveWithUnknownTargetExitsWithError() async throws {
    let root = try makeTempRoot("solve-unknown-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["solve", "--root", root.path, "--target", "NoSuchTarget12345"])
    // R11-T4: target-lookup failure gets its own exit code (3).
    #expect(result.exitCode == 3)
    #expect(result.stderr.contains("target not found"))
}

@Test func solveWithSirilMissingExitsWithClearError() async throws {
    let root = try makeTempRoot("solve-siril-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)
    try writeBogusSirilPathConfig(root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // A real target on record (`Fixtures.makeMessyLibrary` always plants
    // M45_Pleiades), so this fails specifically on the missing Siril binary
    // rather than on an unknown-target check.
    let result = try await runCLI(["solve", "--root", root.path, "--target", "M45_Pleiades"])
    // R11-T4: an external-tool failure (Siril missing) gets its own exit
    // code (4), carved out of the generic usage/error bucket (1).
    #expect(result.exitCode == 4)
    #expect(result.stderr.contains("siril not found"))
}

// MARK: - sensor (R7-B1 item C)

/// Writes a full 16-bit FITS (real pixel data, not just a header) with the
/// `GAIN`/`OFFSET`/`INSTRUME`/`EGAIN` cards `SensorProfiler` groups by --
/// `writeLinkCalibFITS` above only writes `EXPTIME`/`SET-TEMP`, which isn't
/// enough for a `sensor` CLI test to exercise the real grouping/measurement
/// path end to end.
private func writeSensorFITS(
    _ relativePath: String, root: URL,
    width: Int = 8, height: Int = 8, pixelValue: Int,
    gain: Double? = 100, offset: Double? = 50, instrume: String = "ASI2600MC",
    egain: Double? = 0.25, exptime: Double? = nil, ccdTemp: Double? = nil
) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "NAXIS1  =                 \(width)", "NAXIS2  =                 \(height)",
    ]
    if let gain { cards.append("GAIN    =                \(gain)") }
    if let offset { cards.append("OFFSET  =                \(offset)") }
    cards.append("INSTRUME= '\(instrume)'")
    if let egain { cards.append("EGAIN   =                \(egain)") }
    if let exptime { cards.append("EXPTIME =                \(exptime)") }
    if let ccdTemp { cards.append("CCD-TEMP=                \(ccdTemp)") }
    cards.append("END")

    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(width * height * 2)
    let unsigned = UInt16(bitPattern: Int16(pixelValue))
    for _ in 0..<(width * height) {
        pixelBytes.append(UInt8(unsigned >> 8))
        pixelBytes.append(UInt8(unsigned & 0xFF))
    }
    data.append(pixelBytes)
    try data.write(to: url)
}

@Test func sensorWithoutMeasureFlagPrintsAlreadyStoredProfilesOnly() async throws {
    let root = try makeTempRoot("sensor-no-measure")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 500)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // No `--measure` yet -- nothing has ever been persisted to
    // `sensor_profile`, so this must print "nothing measured" rather than
    // silently running a measurement itself.
    let result = try await runCLI(["sensor", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try jsonItems(result.stdout)
    #expect(json?.isEmpty == true)
}

@Test func sensorMeasureFlagRunsMeasurementAndPersistsThenJSONReportsBiasLevel() async throws {
    let root = try makeTempRoot("sensor-measure-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 500, egain: 0.25)
    try writeSensorFITS("calibration_library/biases/bias_b.fit", root: root, pixelValue: 500, egain: 0.25)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["sensor", "--root", root.path, "--measure", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    let profiles = try #require(json)
    let profile = try #require(profiles.first { $0["camera"] as? String == "ASI2600MC" })
    #expect(profile["bias_level_adu"] as? Double == 500)
    #expect(profile["gain"] as? Double == 100)
    #expect(profile["offset"] as? Double == 50)

    // A second, non-measuring call must still see the persisted profile.
    let rerun = try await runCLI(["sensor", "--root", root.path, "--json"])
    #expect(rerun.exitCode == 0, "stderr: \(rerun.stderr)")
    let rerunJSON = try jsonItems(rerun.stdout)
    #expect(rerunJSON?.count == 1)
}

@Test func sensorHumanOutputPrintsHungarianLabelsWithBiasAndEGain() async throws {
    let root = try makeTempRoot("sensor-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 501, egain: 0.243)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["sensor", "--root", root.path, "--measure"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("ASI2600MC"))
    #expect(result.stdout.contains("gain 100"))
    #expect(result.stdout.contains("offset 50"))
    #expect(result.stdout.contains("bias 501"))
    #expect(result.stdout.contains("EGAIN"))
}

@Test func sensorPrintsDriftWarningWhenLightsUseAComboWithNoMeasuredProfile() async throws {
    let root = try makeTempRoot("sensor-drift-warning")
    defer { try? FileManager.default.removeItem(at: root) }

    // A light frame at gain 100/offset 50 -- but NOT ONE bias frame at that
    // combo anywhere, so `sensor_profile` never gets a row for it.
    try writeSensorFITS(
        "sessions/M31/2026-01-01/lights/light_0001.fit", root: root,
        pixelValue: 600, gain: 100, offset: 50
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["sensor", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stderr.contains("nincs mérés ehhez"))
    #expect(result.stderr.contains("ASI2600MC"))
}

// MARK: - sensor --history (R11-T10/F8)

@Test func sensorHistoryJSONGroupsTwoMeasureRunsOldestFirstWithEstimatorVersion() async throws {
    let root = try makeTempRoot("sensor-history-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 500, egain: 0.25)
    let scan1 = try await runCLI(["scan", "--root", root.path])
    #expect(scan1.exitCode == 0, "stderr: \(scan1.stderr)")
    let measure1 = try await runCLI(["sensor", "--root", root.path, "--measure"])
    #expect(measure1.exitCode == 0, "stderr: \(measure1.stderr)")

    // Re-measure against a changed bias level, simulating fresh frames --
    // `SensorProfiler.measure` re-reads the file's pixel bytes straight off
    // disk at measurement time (not from any cached DB metadata), so no
    // rescan is needed just to pick up the new pixel VALUES at the same
    // already-tracked path.
    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 520, egain: 0.25)
    let measure2 = try await runCLI(["sensor", "--root", root.path, "--measure"])
    #expect(measure2.exitCode == 0, "stderr: \(measure2.stderr)")

    let result = try await runCLI(["sensor", "--root", root.path, "--history", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let groups = try jsonItems(result.stdout)
    let allGroups = try #require(groups)
    let group = try #require(allGroups.first { $0["camera"] as? String == "ASI2600MC" })
    let history = try #require(group["history"] as? [[String: Any]])
    #expect(history.count == 2)
    #expect(history.map { $0["bias_level_adu"] as? Double } == [500, 520])
    #expect(history.allSatisfy { ($0["estimator_version"] as? Int) != nil })

    // The "latest view" (plain `sensor --json`) still only ever has ONE row
    // per combo -- history is additive, not a replacement.
    let latest = try jsonItems(try await runCLI(["sensor", "--root", root.path, "--json"]).stdout)
    #expect(latest?.count == 1)
    #expect(latest?.first?["bias_level_adu"] as? Double == 520)
}

@Test func sensorHistoryHumanOutputPrintsPerComboEntriesWithEstimatorVersion() async throws {
    let root = try makeTempRoot("sensor-history-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 500, egain: 0.25)
    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    let measure = try await runCLI(["sensor", "--root", root.path, "--measure"])
    #expect(measure.exitCode == 0, "stderr: \(measure.stderr)")

    let result = try await runCLI(["sensor", "--root", root.path, "--history"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("ASI2600MC"))
    #expect(result.stdout.contains("becslő v"))
}

@Test func sensorHistoryCombinedWithMeasureExitsWithUsageError() async throws {
    let root = try makeTempRoot("sensor-history-measure-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try await runCLI(["sensor", "--root", root.path, "--history", "--measure"])
    #expect(result.exitCode == 1)
}

@Test func sensorHistoryWithNoProfilesPrintsEmptyResult() async throws {
    let root = try makeTempRoot("sensor-history-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let jsonResult = try await runCLI(["sensor", "--root", root.path, "--history", "--json"])
    #expect(jsonResult.exitCode == 0, "stderr: \(jsonResult.stderr)")
    #expect(try jsonItems(jsonResult.stdout)?.isEmpty == true)

    let humanResult = try await runCLI(["sensor", "--root", root.path, "--history"])
    #expect(humanResult.exitCode == 0, "stderr: \(humanResult.stderr)")
    #expect(humanResult.stdout.contains("nincs mért szenzor-profil"))
}

// MARK: - expose (R7-B3)

/// Same header-writing approach as `writeSensorFITS` above, but the pixel
/// data varies by `(row%2, col%2)` grid position (`value00`/`01`/`10`/`11`)
/// so `NativeStats.compute`'s per-Bayer-parity medians actually differ, and
/// a `BAYERPAT` card is always written so `ExposureAdvisor` can map those
/// positions to R/G/G/B.
private func writeBayerLightFITS(
    _ relativePath: String, root: URL,
    width: Int = 8, height: Int = 8,
    value00: Int, value01: Int, value10: Int, value11: Int,
    gain: Double? = 100, offset: Double? = 50, instrume: String = "ASI2600MC",
    egain: Double? = 0.25, exptime: Double? = 120, bayerPattern: String = "RGGB"
) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "NAXIS1  =                 \(width)", "NAXIS2  =                 \(height)",
    ]
    if let gain { cards.append("GAIN    =                \(gain)") }
    if let offset { cards.append("OFFSET  =                \(offset)") }
    cards.append("INSTRUME= '\(instrume)'")
    if let egain { cards.append("EGAIN   =                \(egain)") }
    if let exptime { cards.append("EXPTIME =                \(exptime)") }
    cards.append("BAYERPAT= '\(bayerPattern)'")
    cards.append("END")

    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(width * height * 2)
    for row in 0..<height {
        for col in 0..<width {
            let value: Int
            switch (row % 2, col % 2) {
            case (0, 0): value = value00
            case (0, 1): value = value01
            case (1, 0): value = value10
            default: value = value11
            }
            let unsigned = UInt16(bitPattern: Int16(value))
            pixelBytes.append(UInt8(unsigned >> 8))
            pixelBytes.append(UInt8(unsigned & 0xFF))
        }
    }
    data.append(pixelBytes)
    try data.write(to: url)
}

@Test func exposeJSONAfterSensorMeasureAndRateReportsNumericAdviceForFixtureTarget() async throws {
    let root = try makeTempRoot("expose-numeric")
    defer { try? FileManager.default.removeItem(at: root) }

    // Two bias frames (mild checkerboard vs flat, same convention as
    // `SensorProfileTests`) -- gives a measured bias level + nonzero read
    // noise + EGAIN, all needed before `expose` can compute anything.
    try writeSensorFITS("calibration_library/biases/bias_a.fit", root: root, pixelValue: 505, egain: 0.25)
    try writeSensorFITS("calibration_library/biases/bias_b.fit", root: root, pixelValue: 495, egain: 0.25)

    // R (00) brightest, G (01/10) medium, B (11) faintest -- B is the
    // weakest (read-noise-limited) channel.
    try writeBayerLightFITS(
        "sessions/M42/2026-08-01/lights/light_0001.fit", root: root,
        value00: 700, value01: 650, value10: 650, value11: 520, egain: 0.25, exptime: 120
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let measure = try await runCLI(["sensor", "--root", root.path, "--measure", "--json"])
    #expect(measure.exitCode == 0, "stderr: \(measure.stderr)")

    let rate = try await runCLI(["rate", "--root", root.path, "--target", "M42", "--no-siril", "--json"])
    #expect(rate.exitCode == 0, "stderr: \(rate.stderr)")

    let result = try await runCLI(["expose", "--root", root.path, "--target", "M42", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let advice = try #require(json)
    #expect(advice["not_available_reason"] == nil)
    #expect(advice["weakest_channel"] as? String == "B")
    #expect((advice["optimal_sub_seconds"] as? Double) != nil)
    #expect((advice["current_sub_seconds"] as? Double) == 120)
}

@Test func exposeWithoutSensorProfileReportsHonestNAReason() async throws {
    let root = try makeTempRoot("expose-no-profile")
    defer { try? FileManager.default.removeItem(at: root) }

    // A rated light frame, but not a single bias frame anywhere -- no
    // `sensor_profile` row can ever exist for this combo.
    try writeBayerLightFITS(
        "sessions/M31/2026-08-01/lights/light_0001.fit", root: root,
        value00: 700, value01: 650, value10: 650, value11: 520
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let rate = try await runCLI(["rate", "--root", root.path, "--target", "M31", "--no-siril", "--json"])
    #expect(rate.exitCode == 0, "stderr: \(rate.stderr)")

    let jsonResult = try await runCLI(["expose", "--root", root.path, "--target", "M31", "--json"])
    #expect(jsonResult.exitCode == 0, "stderr: \(jsonResult.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any]
    let advice = try #require(json)
    let reason = try #require(advice["not_available_reason"] as? String)
    #expect(reason.contains("sensor --measure"))
    #expect(advice["optimal_sub_seconds"] == nil)

    let humanResult = try await runCLI(["expose", "--root", root.path, "--target", "M31"])
    #expect(humanResult.exitCode == 0, "stderr: \(humanResult.stderr)")
    #expect(humanResult.stdout.contains("sensor --measure"))
}

@Test func exposeWithoutTargetPrintsOneRowPerTarget() async throws {
    let root = try makeTempRoot("expose-all-targets")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeBayerLightFITS(
        "sessions/M31/2026-08-01/lights/light_0001.fit", root: root,
        value00: 700, value01: 650, value10: 650, value11: 520
    )

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")
    let rate = try await runCLI(["rate", "--root", root.path, "--target", "M31", "--no-siril", "--json"])
    #expect(rate.exitCode == 0, "stderr: \(rate.stderr)")

    let jsonResult = try await runCLI(["expose", "--root", root.path, "--json"])
    #expect(jsonResult.exitCode == 0, "stderr: \(jsonResult.stderr)")
    let json = try jsonItems(jsonResult.stdout)
    let rows = try #require(json)
    #expect(rows.count == 1)
    #expect(rows.first?["target"] as? String == "M31")

    let humanResult = try await runCLI(["expose", "--root", root.path])
    #expect(humanResult.exitCode == 0, "stderr: \(humanResult.stderr)")
    #expect(humanResult.stdout.contains("M31"))
    #expect(humanResult.stdout.contains("CÉLPONT"))
}

// MARK: - stacklist

private func writeStackListLight(_ relativePath: String, root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "dummy light: \(relativePath)".write(to: url, atomically: true, encoding: .utf8)
}

@Test func stackListJSONExportsHardlinksDssfilelistAndSsf() async throws {
    let root = try makeTempRoot("stacklist-json")
    defer { try? FileManager.default.removeItem(at: root) }

    for i in 1...3 {
        try writeStackListLight("sessions/T1/2026-01-10/lights/l\(i).fit", root: root)
    }

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let payload = try #require(json)
    let selection = try #require(payload["selection"] as? [String: Any])
    #expect(selection["total_frames"] as? Int == 3)
    #expect(selection["selected_frames"] as? Int == 3)

    let stackListDirPath = try #require(payload["stack_list_dir"] as? String)
    let stackListDir = URL(fileURLWithPath: stackListDirPath, isDirectory: true)
    #expect(stackListDir.path == root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10").path)

    for i in 1...3 {
        #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("lights/l\(i).fit").path))
    }
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("stack.dssfilelist").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("stack.ssf").path))
}

@Test func stackListHumanReadableOutputPrintsSummaryAndDir() async throws {
    let root = try makeTempRoot("stacklist-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l2.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l3.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("T1"))
    #expect(result.stdout.contains("2026-01-10"))
    #expect(result.stdout.contains("stacklists/T1-2026-01-10"))
}

@Test func stackListWithoutTargetOrDateExitsWithError() async throws {
    let root = try makeTempRoot("stacklist-missing-args")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--target and --date are required"))
}

@Test func stackListRerunIsIdempotent() async throws {
    let root = try makeTempRoot("stacklist-idempotent")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l2.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l3.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let second = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let stackListDir = root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights")
    let contents = try FileManager.default.contentsOfDirectory(atPath: stackListDir.path)
    #expect(Set(contents) == Set(["l1.fit", "l2.fit", "l3.fit"]))
}

// MARK: - stacklist re-export sync (R12-U2, point 2)

/// Sets up a 4-light session, exports it once (all 4 link), then drops a
/// real DeepSkyStacker `.dssfilelist` DSS-rejecting 2 of the 4 into the
/// session and runs `ingest-dss` -- purely through the normal CLI/library
/// surface, no direct DB access from the test. Returns after that setup,
/// right before the SECOND `stacklist` call the caller makes (with either
/// `--json` or plain human output) to observe the re-export sync.
private func setUpStackListStaleSyncFixture(_ label: String) async throws -> URL {
    let root = try makeTempRoot(label)

    for i in 1...4 {
        try writeStackListLight("sessions/T1/2026-01-10/lights/l\(i).fit", root: root)
    }
    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // Every frame is unrated and un-verdicted, so this FIRST export links
    // all 4.
    let first = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let lightsDir = root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path)) == Set(["l1.fit", "l2.fit", "l3.fit", "l4.fit"]))

    let filelistText = """
    DSS file list
    CHECKED\tTYPE\tFILE
    1\tlight\tlights/l1.fit
    1\tlight\tlights/l2.fit
    0\tlight\tlights/l3.fit
    0\tlight\tlights/l4.fit
    """
    try filelistText.write(
        to: root.appendingPathComponent("sessions/T1/2026-01-10/session.dssfilelist"),
        atomically: true, encoding: .utf8
    )
    let rescan = try await runCLI(["scan", "--root", root.path])
    #expect(rescan.exitCode == 0, "stderr: \(rescan.stderr)")
    let ingest = try await runCLI(["ingest-dss", "--root", root.path])
    #expect(ingest.exitCode == 0, "stderr: \(ingest.stderr)")

    return root
}

@Test func stackListRerunAfterNewDSSRejectsReportsRemovedStaleLinksInJSON() async throws {
    let root = try await setUpStackListStaleSyncFixture("stacklist-stale-sync-json")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    #expect(selection["selected_frames"] as? Int == 2, "the 2 DSS-rejected frames are a HARD drop regardless of --keep")
    #expect(payload["removed_stale_links"] as? Int == 2)
    #expect(payload["copy_fallback_used"] as? Bool == false)

    // The DSS-rejected frames' hardlinks are gone from the export tree; the
    // still-selected ones remain; the LIBRARY (source) files are untouched
    // either way.
    let lightsDir = root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: lightsDir.path)) == Set(["l1.fit", "l2.fit"]))
    for i in 1...4 {
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/T1/2026-01-10/lights/l\(i).fit").path))
    }
}

@Test func stackListRerunAfterNewDSSRejectsPrintsRemovedStaleLinkCountInHumanOutput() async throws {
    let root = try await setUpStackListStaleSyncFixture("stacklist-stale-sync-human")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("2 elavult link eltávolítva"))
}

// MARK: - stacklist --out (R11-T4)

@Test func stackListOutWritesDirectlyIntoGivenDirectory() async throws {
    let root = try makeTempRoot("stacklist-out")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l2.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l3.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let outDir = try makeTempRoot("stacklist-out-dest")
    defer { try? FileManager.default.removeItem(at: outDir) }

    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--out", outDir.path,
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("lights/l1.fit").path))
    #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("stack.dssfilelist").path))
    #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("stack.ssf").path))

    // Must NOT also write the default `.astro_tool/stacklists/` location.
    let defaultDir = root.appendingPathComponent(".astro_tool/stacklists")
    #expect(!FileManager.default.fileExists(atPath: defaultDir.path))
}

@Test func stackListOutDashIsRejectedWithClearError() async throws {
    let root = try makeTempRoot("stacklist-out-dash")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--out", "-",
    ])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--out -"))
}

@Test func stackListOutInsideLibraryRootIsRejected() async throws {
    let root = try makeTempRoot("stacklist-out-inside")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let insideDir = root.appendingPathComponent("sneaky-stacklist-dir").path
    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--out", insideDir,
    ])
    #expect(result.exitCode == 1)
    #expect(!FileManager.default.fileExists(atPath: insideDir))
}

// MARK: - stacklist --keep-filter / multi-filter export (R11-T11 / F15)

/// Writes a real (small, but well-formed) FITS light frame carrying a
/// `FILTER` header card -- unlike `writeStackListLight`'s plain dummy text,
/// this is needed so a real `scan` actually populates `fits_meta.filter`,
/// which is what `StackList.select`'s per-filter grouping keys off.
private func writeStackListFilteredLight(_ relativePath: String, root: URL, filter: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let paddedFilter = filter.padding(toLength: max(filter.count, 3), withPad: " ", startingAt: 0)
    let cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "NAXIS1  =                    4", "NAXIS2  =                    4",
        "FILTER  = '\(paddedFilter)'",
        "EXPTIME =                 60.0",
        "END",
    ]
    var data = buildHeaderData(cards)
    data.append(Data(repeating: 0, count: 4 * 4 * 2))
    try data.write(to: url)
}

@Test func stackListKeepFilterFlagIsAcceptedAndIgnoredForBucketsItDoesNotName() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-noop")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l2.fit", root: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l3.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // No filter data at all in this library -- "Ha=0.5" names a bucket that
    // doesn't exist, so it's a harmless no-op, not an error.
    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "Ha=0.5", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    #expect(selection["selected_frames"] as? Int == 3)
    #expect(selection["per_filter"] == nil)
}

@Test func stackListKeepFilterRejectsMalformedValue() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-bad")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "Ha=not-a-number",
    ])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--keep-filter"))
}

@Test func stackListMultiFilterJSONAndExportTreeUseSeparateFilterSubfolders() async throws {
    let root = try makeTempRoot("stacklist-multi-filter")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha1.fit", root: root, filter: "Ha")
    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha2.fit", root: root, filter: "Ha")
    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/oiii1.fit", root: root, filter: "OIII")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    #expect(selection["selected_frames"] as? Int == 3)
    let perFilter = try #require(selection["per_filter"] as? [[String: Any]])
    #expect(perFilter.count == 2)
    let filterNames = Set(perFilter.compactMap { $0["filter"] as? String })
    #expect(filterNames == Set(["Ha", "OIII"]))

    let stackListDirPath = try #require(payload["stack_list_dir"] as? String)
    let stackListDir = URL(fileURLWithPath: stackListDirPath, isDirectory: true)

    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("lights/Ha/ha1.fit").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("lights/Ha/ha2.fit").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("lights/OIII/oiii1.fit").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("T1-2026-01-10-Ha.dssfilelist").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("T1-2026-01-10-OIII.dssfilelist").path))
    #expect(FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("manifest.csv").path))
    #expect(!FileManager.default.fileExists(atPath: stackListDir.appendingPathComponent("stack.dssfilelist").path))

    let manifestText = try String(contentsOf: stackListDir.appendingPathComponent("manifest.csv"), encoding: .utf8)
    #expect(manifestText.contains("Ha"))
    #expect(manifestText.contains("OIII"))
}

@Test func stackListKeepFilterOverridesOneFilterOnly() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-override")
    defer { try? FileManager.default.removeItem(at: root) }

    for i in 1...4 {
        try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha\(i).fit", root: root, filter: "Ha")
    }
    for i in 1...4 {
        try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/oiii\(i).fit", root: root, filter: "OIII")
    }

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // Neither filter has any rated/verdict data, so every frame is
    // "unrated -- always kept" regardless of keepFraction; this only checks
    // that the flag parses and threads through without affecting the
    // (unrelated) unrated-frame floor.
    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "Ha=0.5,OIII=1.0", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    #expect(selection["selected_frames"] as? Int == 8)
}

// MARK: - stacklist --keep-filter case-insensitivity, "none" alias, unknown-name warning (R12-U2, point 3)

@Test func stackListKeepFilterWarnsOnStderrForAnUnknownFilterNameButStillSucceeds() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-unknown")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha1.fit", root: root, filter: "Ha")
    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/oiii1.fit", root: root, filter: "OIII")

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "Bogus=0.5",
    ])
    #expect(result.exitCode == 0, "a typo'd filter name warns, it doesn't fail the command; stderr: \(result.stderr)")
    #expect(result.stderr.contains("ismeretlen szűrőnév"))
    #expect(result.stderr.contains("Bogus"))
}

@Test func stackListKeepFilterMatchesActualFilterNamesCaseInsensitivelyWithoutWarning() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-case")
    defer { try? FileManager.default.removeItem(at: root) }

    for i in 1...4 {
        try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha\(i).fit", root: root, filter: "Ha")
    }
    for i in 1...4 {
        try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/oiii\(i).fit", root: root, filter: "OIII")
    }

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // Deliberately wrong case on both names -- must still match, so NO
    // "ismeretlen szűrőnév" warning for either.
    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "ha=0.5,OIII=1.0", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(!result.stderr.contains("ismeretlen szűrőnév"), "stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    // Every frame here is unrated -- "unrated -- always kept" regardless of
    // keepFraction (same caveat `stackListKeepFilterOverridesOneFilterOnly`
    // already notes) -- this only pins that the case-insensitive match
    // doesn't warn, not the keepFraction math itself.
    #expect(selection["selected_frames"] as? Int == 8)
}

@Test func stackListKeepFilterNoneAliasTargetsTheNoFilterBucketWithoutWarning() async throws {
    let root = try makeTempRoot("stacklist-keep-filter-none-alias")
    defer { try? FileManager.default.removeItem(at: root) }

    // A named-filter frame (Ha) plus a filterless one (plain dummy light,
    // no FITS FILTER header at all) -- two buckets: "Ha" and the no-filter
    // sentinel.
    try writeStackListFilteredLight("sessions/T1/2026-01-10/lights/ha1.fit", root: root, filter: "Ha")
    try writeStackListLight("sessions/T1/2026-01-10/lights/plain1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI([
        "stacklist", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--keep-filter", "none=0.9", "--json",
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(!result.stderr.contains("ismeretlen szűrőnév"), "\"none\" must resolve to the actual no-filter bucket -- stderr: \(result.stderr)")

    let payload = try #require(try jsonObject(result.stdout))
    let selection = try #require(payload["selection"] as? [String: Any])
    let perFilter = try #require(selection["per_filter"] as? [[String: Any]])
    #expect(perFilter.count == 2)
}

// MARK: - report (R7-B5)

@Test func reportOutDashPrintsHTMLToStdoutWithoutWritingAFile() async throws {
    let root = try makeTempRoot("report-stdout")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["report", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.hasPrefix("<!doctype html>"))
    #expect(result.stdout.contains("T1"))
    #expect(!result.stdout.contains("<script"))

    let reportsDir = root.appendingPathComponent(".astro_tool/reports")
    #expect(!FileManager.default.fileExists(atPath: reportsDir.path))
}

@Test func reportDefaultModeWritesFileUnderReportsAndPrintsPath() async throws {
    let root = try makeTempRoot("report-file")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["report", "--root", root.path, "--target", "T1", "--date", "2026-01-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let printedPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedPath = root.appendingPathComponent(".astro_tool/reports/T1-2026-01-10.html").path
    #expect(printedPath == expectedPath)
    #expect(FileManager.default.fileExists(atPath: printedPath))
}

@Test func reportExplicitOutPathWritesExactlyThereWithoutDefaultReport() async throws {
    let root = try makeTempRoot("report-explicit-out")
    defer { try? FileManager.default.removeItem(at: root) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-report-out-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: out) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let result = try await runCLI([
        "report", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--out", out.path,
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == out.path)
    #expect(FileManager.default.fileExists(atPath: out.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astro_tool/reports").path))
}

@Test func reportExplicitOutSymlinkIntoLibraryIsRejected() async throws {
    let root = try makeTempRoot("report-symlink-escape")
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-report-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: link) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let escapedDestination = link.appendingPathComponent("must-not-write.html")
    let result = try await runCLI([
        "report", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--out", escapedDestination.path,
    ])

    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("inside the library root"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-write.html").path))
}

@Test func reportExplicitOutDanglingFileSymlinkIntoLibraryIsRejected() async throws {
    let root = try makeTempRoot("report-dangling-symlink-escape")
    defer { try? FileManager.default.removeItem(at: root) }
    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-report-file-link-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: link) }
    let insideDestination = root.appendingPathComponent("must-not-materialize.html")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: insideDestination)
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let result = try await runCLI([
        "report", "--root", root.path, "--target", "T1", "--date", "2026-01-10",
        "--out", link.path,
    ])

    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("inside the library root"))
    #expect(!FileManager.default.fileExists(atPath: insideDestination.path))
}

@Test func reportWithoutTargetOrDateExitsWithError() async throws {
    let root = try makeTempRoot("report-missing-args")
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await runCLI(["report", "--root", root.path, "--target", "T1"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("--target and --date are required"))
}

@Test func reportWithUnknownSessionExitsWithTargetNotFoundError() async throws {
    let root = try makeTempRoot("report-unknown-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["report", "--root", root.path, "--target", "T1", "--date", "1999-01-01"])
    // R11-T4: target/session-lookup failure gets its own exit code (3).
    #expect(result.exitCode == 3)
}

// MARK: - target-report (R8-2)

@Test func targetReportOutDashPrintsHTMLToStdoutWithoutWritingAFile() async throws {
    let root = try makeTempRoot("target-report-stdout")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["target-report", "--root", root.path, "--target", "T1", "--out", "-"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.hasPrefix("<!doctype html>"))
    #expect(result.stdout.contains("T1"))
    #expect(!result.stdout.contains("<script"))

    let reportsDir = root.appendingPathComponent(".astro_tool/reports")
    #expect(!FileManager.default.fileExists(atPath: reportsDir.path))
}

@Test func targetReportDefaultModeWritesFileUnderReportsAndPrintsPath() async throws {
    let root = try makeTempRoot("target-report-file")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["target-report", "--root", root.path, "--target", "T1"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let printedPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedPath = root.appendingPathComponent(".astro_tool/reports/target-T1.html").path
    #expect(printedPath == expectedPath)
    #expect(FileManager.default.fileExists(atPath: printedPath))
}

@Test func targetReportExplicitOutPathWritesExactlyThereWithoutDefaultReport() async throws {
    let root = try makeTempRoot("target-report-explicit-out")
    defer { try? FileManager.default.removeItem(at: root) }
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-target-report-out-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: out) }
    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)
    #expect(try await runCLI(["scan", "--root", root.path]).exitCode == 0)

    let result = try await runCLI([
        "target-report", "--root", root.path, "--target", "T1", "--out", out.path,
    ])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == out.path)
    #expect(FileManager.default.fileExists(atPath: out.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".astro_tool/reports").path))
}

@Test func targetReportWithUnknownTargetExitsWithError() async throws {
    let root = try makeTempRoot("target-report-unknown")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStackListLight("sessions/T1/2026-01-10/lights/l1.fit", root: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["target-report", "--root", root.path, "--target", "Nope"])
    // R11-T4: target-lookup failure gets its own exit code (3).
    #expect(result.exitCode == 3)
}

// MARK: - plan --month (R7-B5)

@Test func planMonthJSONReportsThirtyNightsForFixtureLibrary() async throws {
    let root = try makeTempRoot("plan-month-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 300.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--month", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try jsonItems(result.stdout)
    #expect(json?.count == 30)
}

@Test func planMonthHumanOutputShowsTableHeader() async throws {
    let root = try makeTempRoot("plan-month-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeProjectsFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, exptime: 300.0)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["plan", "--root", root.path, "--month", "--nights", "5"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("DÁTUM"))
    #expect(result.stdout.contains("SÖTÉT ÓRA"))
}

// MARK: - schema_version (R11-T4)

@Test func jsonObjectRootCommandsCarrySchemaVersion() async throws {
    let root = try makeTempRoot("schema-version-object")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path, "--json"])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let json = try jsonObject(scan.stdout)
    #expect(json?["schema_version"] as? String == "1")
    // scan --json's own object fields are still there, unwrapped.
    #expect(json?["added"] != nil)
}

/// The breaking-shape half of R11-T4's schema_version change: any command
/// whose `--json` root used to be a bare array now wraps it into
/// `{"schema_version": "1", "items": [...]}` instead -- documented in
/// CHANGELOG.md as the tool's first JSON-schema-breaking change.
@Test func jsonArrayRootCommandsWrapIntoSchemaVersionAndItemsEnvelope() async throws {
    let root = try makeTempRoot("schema-version-array")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try await runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try await runCLI(["nights", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let root2 = try #require(try jsonObject(result.stdout))
    #expect(root2["schema_version"] as? String == "1")
    #expect(root2["items"] is [Any])
    // The old shape (a bare top-level array) no longer parses as one.
    #expect((try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [[String: Any]] == nil)
}

// MARK: - misc

@Test func unknownSubcommandExitsWithUsage() async throws {
    let result = try await runCLI(["bogus-command"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.lowercased().contains("usage"))
}

@Test func versionFlagPrintsVersion() async throws {
    let result = try await runCLI(["--version"])
    #expect(result.exitCode == 0)
    // Format check rather than a pinned literal, so a release version bump
    // in main.swift can't silently break the suite (which is exactly what
    // happened at v0.10.0 with the old `== "astrotool 0.1.0"` expectation).
    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(output.wholeMatch(of: /astrotool \d+\.\d+\.\d+/) != nil, "unexpected --version output: \(output)")
}

} // CLISmokeTests
