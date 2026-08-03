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
/// synchronous stdout read, so a command that writes a lot to one stream
/// while the other pipe's buffer fills can never deadlock this helper.
private func runCLI(_ args: [String]) throws -> CLIResult {
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

@Test func scanJSONReportsAddedFiles() throws {
    let root = try makeTempRoot("scan-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let result = try runCLI(["scan", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let added = try #require(json?["added"] as? Int)
    #expect(added > 0)
}

@Test func secondScanReportsUnchanged() throws {
    let root = try makeTempRoot("scan-twice")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try runCLI(["scan", "--root", root.path, "--json"])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let second = try runCLI(["scan", "--root", root.path, "--json"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any]
    let unchanged = try #require(json?["unchanged"] as? Int)
    #expect(unchanged > 0)
}

@Test func scanRefreshMetaFlagRunsAndExitsZero() throws {
    let root = try makeTempRoot("scan-refresh-meta")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try runCLI(["scan", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let second = try runCLI(["scan", "--root", root.path, "--refresh-meta"])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")
}

@Test func scanWithInaccessibleSubdirectoryStillExitsZeroAndWarnsOnStderr() throws {
    let root = try makeTempRoot("scan-inaccessible-subdir")
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights").path
        )
        try? FileManager.default.removeItem(at: root)
    }
    try Fixtures.makeMessyLibrary(in: root)

    let first = try runCLI(["scan", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")

    let restrictedDir = root.appendingPathComponent("sessions/M45_Pleiades/2026-01-10/lights")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)

    let second = try runCLI(["scan", "--root", root.path])
    #expect(second.exitCode == 0, "stdout: \(second.stdout), stderr: \(second.stderr)")
    #expect(second.stderr.contains("sessions/M45_Pleiades/2026-01-10/lights"))
}

// MARK: - audit

@Test func auditJSONAfterScanReportsKnownCategories() throws {
    let root = try makeTempRoot("audit-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let audit = try runCLI(["audit", "--root", root.path, "--json"])
    #expect(audit.exitCode == 0, "stderr: \(audit.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(audit.stdout.utf8)) as? [[String: Any]]
    let findings = try #require(json)
    let categories = Set(findings.compactMap { $0["category"] as? String })
    #expect(categories.contains("placeholder-name"))
}

@Test func auditSuggestWritesSuggestionScript() throws {
    let root = try makeTempRoot("audit-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["audit", "--root", root.path, "--suggest"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let suggestionsDir = root.appendingPathComponent(".astro_tool/suggestions")
    let contents = try FileManager.default.contentsOfDirectory(atPath: suggestionsDir.path)
    #expect(!contents.isEmpty)
}

@Test func auditJSONStdoutIsPureJSON() throws {
    let root = try makeTempRoot("audit-pure-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    // --suggest on top of --json: the "suggestion written to ..." message
    // must NOT leak onto stdout -- only findings JSON belongs there.
    let result = try runCLI(["audit", "--root", root.path, "--json", "--suggest"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    // Decoding from the FULL stdout data must succeed -- any stray
    // non-JSON line anywhere in stdout would break this.
    _ = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
}

// MARK: - cleanup

@Test func cleanupJSONAfterScanReportsResidueGroups() throws {
    let root = try makeTempRoot("cleanup-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["cleanup", "--root", root.path, "--json"])
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

@Test func cleanupHumanOutputPrintsGroupsAndTotal() throws {
    let root = try makeTempRoot("cleanup-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["cleanup", "--root", root.path])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("residue-seq"))
    #expect(result.stdout.contains("összesen felszabadítható"))
}

@Test func cleanupSuggestWritesQuarantineScriptWithNoRM() throws {
    let root = try makeTempRoot("cleanup-suggest")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["cleanup", "--root", root.path, "--suggest"])
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

// MARK: - stats

@Test func statsJSONContainsFixtureTarget() throws {
    let root = try makeTempRoot("stats-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let stats = try #require(json)
    let targets = Set(stats.compactMap { $0["target"] as? String })
    #expect(targets.contains("M45_Pleiades"))
}

@Test func statsTargetNotFoundExitsWithError() throws {
    let root = try makeTempRoot("stats-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "NONEXISTENT_TARGET"])
    #expect(result.exitCode == 1)
}

@Test func statsSessionsJSONDecodesForFixtureTarget() throws {
    let root = try makeTempRoot("stats-sessions-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--sessions", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let sessions = try #require(json)
    #expect(!sessions.isEmpty)
    #expect(sessions.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
}

@Test func statsJSONCarriesUsableAndGrossIntegrationFields() throws {
    let root = try makeTempRoot("stats-json-r4-1")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--json"])
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

@Test func statsHumanOutputWithGrossFlagShowsGrossLine() throws {
    let root = try makeTempRoot("stats-gross-flag")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--gross"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("gross (undeduped):"))
}

@Test func statsSessionsWithoutTargetExitsWithError() throws {
    let root = try makeTempRoot("stats-sessions-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--sessions", "--json"])
    #expect(result.exitCode == 1)
}

@Test func statsTimelineJSONDecodesForFixtureTarget() throws {
    let root = try makeTempRoot("stats-timeline-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--timeline", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let timelines = try #require(json)
    #expect(!timelines.isEmpty)
    #expect(timelines.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
    #expect(timelines.allSatisfy { $0["integration_seconds"] != nil })
    #expect(timelines.allSatisfy { $0["gaps"] != nil })
}

@Test func statsTimelineHumanOutputPrintsWindowAndIntegration() throws {
    let root = try makeTempRoot("stats-timeline-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--timeline"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("window:"))
    #expect(result.stdout.contains("integration:"))
}

@Test func statsTimelineWithoutTargetExitsWithError() throws {
    let root = try makeTempRoot("stats-timeline-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["stats", "--root", root.path, "--timeline", "--json"])
    #expect(result.exitCode == 1)
}

// MARK: - quality

@Test func qualityJSONAfterRateDecodesForFixtureTarget() throws {
    let root = try makeTempRoot("quality-json")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let rate = try runCLI(["rate", "--root", root.path, "--target", "M45_Pleiades", "--no-siril"])
    #expect(rate.exitCode == 0, "stderr: \(rate.stderr)")

    let result = try runCLI(["quality", "--root", root.path, "--target", "M45_Pleiades", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let summaries = try #require(json)
    #expect(!summaries.isEmpty)
    #expect(summaries.allSatisfy { $0["target"] as? String == "M45_Pleiades" })
    #expect(summaries.allSatisfy { $0["frame_count"] != nil })
}

@Test func qualityHumanOutputPrintsTable() throws {
    let root = try makeTempRoot("quality-human")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["quality", "--root", root.path, "--target", "M45_Pleiades"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("DATE"))
}

@Test func qualityWithoutTargetExitsWithError() throws {
    let root = try makeTempRoot("quality-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["quality", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - tag

@Test func tagAddThenListShowsIt() throws {
    let root = try makeTempRoot("tag-add-list")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let list = try runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String]
    #expect(tags == ["favorite"])
}

@Test func tagAddSameTwiceStaysIdempotent() throws {
    let root = try makeTempRoot("tag-idempotent")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let second = try runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")

    let list = try runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String]
    #expect(tags == ["favorite"])
}

@Test func tagRemoveDeletesIt() throws {
    let root = try makeTempRoot("tag-remove")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")
    let remove = try runCLI(["tag", "remove", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(remove.exitCode == 0, "stderr: \(remove.stderr)")

    let list = try runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(list.exitCode == 0, "stderr: \(list.stderr)")
    let tags = try JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [String]
    #expect(tags == [])
}

@Test func tagSessionScopedTagOnlyListedWithMatchingDate() throws {
    let root = try makeTempRoot("tag-session-scoped")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let sessionsResult = try runCLI(["stats", "--root", root.path, "--target", "M45_Pleiades", "--sessions", "--json"])
    #expect(sessionsResult.exitCode == 0, "stderr: \(sessionsResult.stderr)")
    let sessions = try #require(try JSONSerialization.jsonObject(with: Data(sessionsResult.stdout.utf8)) as? [[String: Any]])
    let date = try #require(sessions.first?["date_raw"] as? String)

    let add = try runCLI(["tag", "add", "--target", "M45_Pleiades", "--date", date, "clouds", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let sessionList = try runCLI(["tag", "list", "--target", "M45_Pleiades", "--date", date, "--root", root.path, "--json"])
    #expect(sessionList.exitCode == 0, "stderr: \(sessionList.stderr)")
    let sessionTags = try JSONSerialization.jsonObject(with: Data(sessionList.stdout.utf8)) as? [String]
    #expect(sessionTags == ["clouds"])

    let targetList = try runCLI(["tag", "list", "--target", "M45_Pleiades", "--root", root.path, "--json"])
    #expect(targetList.exitCode == 0, "stderr: \(targetList.stderr)")
    let targetTags = try JSONSerialization.jsonObject(with: Data(targetList.stdout.utf8)) as? [String]
    #expect(targetTags == [])
}

@Test func statsTagFilterOnlyShowsTaggedTargets() throws {
    let root = try makeTempRoot("stats-tag-filter")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let add = try runCLI(["tag", "add", "--target", "M45_Pleiades", "favorite", "--root", root.path])
    #expect(add.exitCode == 0, "stderr: \(add.stderr)")

    let filtered = try runCLI(["stats", "--root", root.path, "--tag", "favorite", "--json"])
    #expect(filtered.exitCode == 0, "stderr: \(filtered.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [[String: Any]]
    let stats = try #require(json)
    #expect(!stats.isEmpty)
    #expect(stats.allSatisfy { ($0["target"] as? String) == "M45_Pleiades" })

    let filteredOut = try runCLI(["stats", "--root", root.path, "--tag", "nonexistent-tag", "--json"])
    #expect(filteredOut.exitCode == 0, "stderr: \(filteredOut.stderr)")
    let jsonOut = try JSONSerialization.jsonObject(with: Data(filteredOut.stdout.utf8)) as? [[String: Any]]
    #expect(try #require(jsonOut).isEmpty)
}

@Test func tagAddRejectsEmptyTagText() throws {
    let root = try makeTempRoot("tag-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["tag", "add", "--target", "M45_Pleiades", "   ", "--root", root.path])
    #expect(result.exitCode == 1)
}

@Test func tagAddWithoutTargetExitsWithError() throws {
    let root = try makeTempRoot("tag-no-target")
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixtures.makeMessyLibrary(in: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["tag", "add", "favorite", "--root", root.path])
    #expect(result.exitCode == 1)
}

// MARK: - new-session

@Test func newSessionCreatesThenRerunFails() throws {
    let root = try makeTempRoot("new-session")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let first = try runCLI([
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

    let second = try runCLI([
        "new-session", "--root", root.path,
        "--catalog", "M1", "--name", "Crab Nebula", "--date", "2026-08-02",
    ])
    #expect(second.exitCode == 1)
}

@Test func newSessionRejectsNonCanonicalDate() throws {
    let root = try makeTempRoot("new-session-bad-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try runCLI([
        "new-session", "--root", root.path,
        "--catalog", "M1", "--name", "Test", "--date", "2026-08-02-2",
    ])
    #expect(result.exitCode == 1)
}

// MARK: - permission errors -> exit 2

@Test func scanOnReadOnlyRootExitsWithTCCGuidance() throws {
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

    let result = try runCLI(["scan", "--root", root.path])
    #expect(result.exitCode == 2, "stdout: \(result.stdout), stderr: \(result.stderr)")
    #expect(result.stderr.contains("Teljes lemezhozzáférés"))
}

// MARK: - link-calib

/// Writes a minimal real FITS header (not the plain dummy content
/// `Fixtures.makeMessyLibrary` uses) so `link-calib`'s underlying
/// `CalibLinker.plan` -- which needs actual EXPTIME/SET-TEMP meta -- has
/// something to match against.
private func writeLinkCalibFITS(_ relativePath: String, root: URL, exptime: Double, setTemp: Double) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let cards = [
        "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
        "EXPTIME =                \(exptime)", "SET-TEMP=                \(setTemp)", "END",
    ]
    try buildHeaderData(cards).write(to: url)
}

private func writeLinkCalibDummy(_ relativePath: String, root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "dummy master".write(to: url, atomically: true, encoding: .utf8)
}

@Test func linkCalibDryRunPrintsPlanAndCreatesNothing() throws {
    let root = try makeTempRoot("link-calib-dry-run")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l2.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI([
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

@Test func linkCalibWithYesLinksThenRerunReportsSkipped() throws {
    let root = try makeTempRoot("link-calib-yes")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let first = try runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--yes", "--json",
    ])
    #expect(first.exitCode == 0, "stderr: \(first.stderr)")
    let firstJSON = try JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any]
    let linked = try #require(firstJSON?["linked"] as? [String])
    #expect(linked == ["sessions/T1/2026-01-10/darks/master.fit"])
    #expect((firstJSON?["skipped"] as? [String])?.isEmpty == true)

    let destURL = root.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(FileManager.default.fileExists(atPath: destURL.path))

    let second = try runCLI([
        "link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--yes", "--json",
    ])
    #expect(second.exitCode == 0, "stderr: \(second.stderr)")
    let secondJSON = try JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any]
    #expect((secondJSON?["linked"] as? [String])?.isEmpty == true)
    #expect(secondJSON?["skipped"] as? [String] == ["sessions/T1/2026-01-10/darks/master.fit"])
}

@Test func linkCalibJSONWithoutYesOrDryRunExitsWithError() throws {
    let root = try makeTempRoot("link-calib-no-yes")
    defer { try? FileManager.default.removeItem(at: root) }

    try writeLinkCalibFITS("sessions/T1/2026-01-10/lights/l1.fit", root: root, exptime: 300.0, setTemp: -10.0)
    try writeLinkCalibDummy("calibration_library/darks/300sec_-10deg/master.fit", root: root)

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["link-calib", "--root", root.path, "--target", "T1", "--date", "2026-01-10", "--json"])
    #expect(result.exitCode == 1)

    let destURL = root.appendingPathComponent("sessions/T1/2026-01-10/darks/master.fit")
    #expect(!FileManager.default.fileExists(atPath: destURL.path))
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

@Test func planJSONAfterScanReportsVerdictsForFixtureTarget() throws {
    let root = try makeTempRoot("plan-json")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")

    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let plans = try #require(json)
    let plan = try #require(plans.first { $0["target"] as? String == "M31_Andromeda" })
    #expect(plan["verdict"] as? String != nil)
    #expect(plan["ra_deg"] != nil)
    #expect(plan["dec_deg"] != nil)
    #expect((plan["verdict"] as? String)?.isEmpty == false)
}

@Test func planHumanOutputShowsHeaderAndTableWithoutSiteCoordinates() throws {
    let root = try makeTempRoot("plan-human")
    defer { try? FileManager.default.removeItem(at: root) }

    try writePlanFITS("sessions/M31_Andromeda/2026-08-01/lights/l1.fit", root: root, crval1: 10.6847, crval2: 41.2687, dateObs: "2026-08-01T22:00:00")

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["plan", "--root", root.path, "--date", "2026-08-10"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.contains("Ma este"))
    #expect(result.stdout.contains("M31_Andromeda"))
    #expect(result.stdout.contains("VERDIKT"))

    // PRIVACY: the human table must never print the site's actual
    // coordinates (47.5 / 19.0), only derived times/phase.
    #expect(!result.stdout.contains("47.5"))
    #expect(!result.stdout.contains("19.0"))
}

@Test func planRespectsMinAltFlag() throws {
    let root = try makeTempRoot("plan-min-alt")
    defer { try? FileManager.default.removeItem(at: root) }

    // dec -80 at lat 47.5 never rises anywhere near minAlt.
    try writePlanFITS("sessions/T_Low/2026-08-01/lights/l1.fit", root: root, crval1: 10.0, crval2: -80.0, dateObs: "2026-08-01T22:00:00")

    let scan = try runCLI(["scan", "--root", root.path])
    #expect(scan.exitCode == 0, "stderr: \(scan.stderr)")

    let result = try runCLI(["plan", "--root", root.path, "--date", "2026-08-10", "--min-alt", "30", "--json"])
    #expect(result.exitCode == 0, "stderr: \(result.stderr)")
    let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
    let plans = try #require(json)
    let plan = try #require(plans.first { $0["target"] as? String == "T_Low" })
    #expect((plan["verdict"] as? String)?.hasPrefix("alacsony") == true)
}

@Test func planWithInvalidDateExitsWithError() throws {
    let root = try makeTempRoot("plan-bad-date")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let result = try runCLI(["plan", "--root", root.path, "--date", "not-a-date"])
    #expect(result.exitCode == 1)
}

// MARK: - misc

@Test func unknownSubcommandExitsWithUsage() throws {
    let result = try runCLI(["bogus-command"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.lowercased().contains("usage"))
}

@Test func versionFlagPrintsVersion() throws {
    let result = try runCLI(["--version"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "astrotool 0.1.0")
}

} // CLISmokeTests
