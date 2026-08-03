import AstroCore
import Foundation

// MARK: - Output plumbing

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Every `--json` code path in this tool encodes through this single
/// function, so the format is identical everywhere: snake_case keys,
/// alphabetically sorted, pretty-printed, written to stdout only. Nothing
/// else may touch stdout when `--json` is in effect -- progress/hints/
/// side-effect messages all go through `eprint` instead.
func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let usageText = """
Usage: astrotool <command> [options]

Commands:
  scan          [--root R] [--path SUB] [--json]
  audit         [--root R] [--json] [--suggest] [--include-suspicious] [--no-duplicates]
  cleanup       [--root R] [--json] [--suggest] [--limit N]
  rate          [--root R] --target T [--date D] [--json] [--no-siril]
  stats         [--root R] [--target T] [--json] [--gross] [--sessions (requires --target)] [--tag TAG]
                [--timeline (requires --target) [--date D]]
  quality       --target T [--date D] [--root R] [--json]
  calib         [--root R] [--json]
  match         [--root R] --target T --date D [--json]
  link-calib    --target T --date D [--dry-run] [--yes] [--root R] [--json]
  new-session   --catalog CAT --name NAME --date D [--root R] [--json]
  config        (show|path) [--root R] [--json]
  tag add       --target T [--date D] <tag> [--root R] [--json]
  tag remove    --target T [--date D] <tag> [--root R] [--json]
  tag list      [--target T] [--date D] [--root R] [--json]
  plan          [--date YYYY-MM-DD] [--min-alt 30] [--root R] [--json]

  --version     Print version and exit
  --help        Show this help
"""

let tccGuidance = """
Hozzáférés megtagadva, vagy a kötet nincs csatlakoztatva.

Ha a hiba oka a Teljes lemezhozzáférés hiánya:
  1. Rendszerbeállítások → Adatvédelem és biztonság → Teljes lemezhozzáférés
  2. Engedélyezd a hozzáférést az alkalmazásnak / terminálnak
  3. Az engedély megadása után indítsd újra az appot/terminált

Ha külső kötetről van szó, ellenőrizd, hogy csatlakoztatva van-e (pl. a Finderben).
"""

func describeAstroError(_ error: AstroError) -> String {
    switch error {
    case .accessDenied(let path):
        return "access denied: \(path)"
    case .volumeNotMounted(let path):
        return "volume not mounted: \(path)"
    case .pathNotFound(let path):
        return "path not found: \(path)"
    case .writeForbidden(let path):
        return "write forbidden: \(path)"
    case .corruptFITS(let path, let reason):
        return "corrupt FITS at \(path): \(reason)"
    case .databaseError(let message):
        return "database error: \(message)"
    case .sirilNotFound(let path):
        return "siril not found at \(path)"
    case .invalidInput(let reason):
        return "invalid input: \(reason)"
    }
}

// MARK: - Config / DB / WriteGuard resolution

/// Resolution order: `--root` flag > config file at `<--root or default
/// rootPath>/.astro_tool/config.json` > `AstroConfig()` defaults. When
/// `--root` is given it always wins as the effective `rootPath`, even if a
/// config file loaded from that root specifies a different one.
func resolveConfig(rootFlag: String?) throws -> AstroConfig {
    let lookupRoot = rootFlag ?? AstroConfig().rootPath
    let configURL = URL(fileURLWithPath: lookupRoot, isDirectory: true)
        .appendingPathComponent(".astro_tool", isDirectory: true)
        .appendingPathComponent("config.json", isDirectory: false)

    var config: AstroConfig
    if FileManager.default.fileExists(atPath: configURL.path) {
        config = try AstroConfig.load(from: configURL)
    } else {
        config = AstroConfig()
    }

    if let rootFlag {
        config.rootPath = rootFlag
    }
    return config
}

/// The volume mount point portion of an absolute path -- its first two path
/// components, e.g. `/Volumes/images/sessions` -> `/Volumes/images`. Mirrors
/// the equivalent (internal, not visible from here) logic in
/// `AstroCore`'s `RootErrorClassifier`.
private func volumePortion(of path: String) -> String {
    let comps = path.split(separator: "/", omittingEmptySubsequences: true)
    guard comps.count >= 2 else { return path }
    return "/" + comps[0] + "/" + comps[1]
}

/// Classifies a missing library root the same way a scan would, without
/// touching the filesystem beyond existence checks -- so every command that
/// opens the database (not just `scan`) gives the same TCC/mount guidance
/// for a bad `--root` instead of a raw filesystem error.
func ensureRootAccessible(_ config: AstroConfig) throws {
    guard !FileManager.default.fileExists(atPath: config.rootPath) else { return }

    if config.rootPath.hasPrefix("/Volumes/") {
        let volume = volumePortion(of: config.rootPath)
        if !FileManager.default.fileExists(atPath: volume) {
            throw AstroError.volumeNotMounted(path: config.rootPath)
        }
    }
    throw AstroError.pathNotFound(path: config.rootPath)
}

func dbPath(for config: AstroConfig) -> String {
    URL(fileURLWithPath: config.rootPath, isDirectory: true)
        .appendingPathComponent(".astro_tool", isDirectory: true)
        .appendingPathComponent("astrotool.sqlite", isDirectory: false)
        .path
}

func configPath(for config: AstroConfig) -> String {
    URL(fileURLWithPath: config.rootPath, isDirectory: true)
        .appendingPathComponent(".astro_tool", isDirectory: true)
        .appendingPathComponent("config.json", isDirectory: false)
        .path
}

func makeWriteGuard(config: AstroConfig) -> WriteGuard {
    WriteGuard(root: URL(fileURLWithPath: config.rootPath, isDirectory: true))
}

/// Opens (creating if needed) the DB at `<root>/.astro_tool/astrotool.sqlite`.
/// Requires `root` to already exist on disk -- see `ensureRootAccessible` --
/// so this never silently creates directories under an unmounted volume.
func makeDatabase(config: AstroConfig) throws -> Database {
    try ensureRootAccessible(config)
    let toolDir = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        .appendingPathComponent(".astro_tool", isDirectory: true)

    // A read-only root (TCC revoked mid-session, or a plain chmod 555 in
    // tests) makes `createDirectory` throw a raw `NSCocoaErrorDomain` (513,
    // wrapping POSIX EPERM) rather than an `AstroError` -- reclassify that
    // as `.accessDenied` here so main.swift's dedicated exit-2 + TCC
    // guidance branch actually fires instead of falling through to the
    // generic exit-1 path. `AstroError`s thrown by `Database(path:)` itself
    // (e.g. `.databaseError`) pass through unchanged.
    do {
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        return try Database(path: dbPath(for: config))
    } catch let error as AstroError {
        throw error
    } catch {
        if isPermissionError(error) {
            throw AstroError.accessDenied(path: toolDir.path)
        }
        throw error
    }
}

/// `audit`/`stats`/`calib`/`match`/`rate` never scan on their own -- if the
/// DB has no files at all yet, nudge the user toward `scan` instead of just
/// silently reporting empty/zeroed results.
func hintIfEmpty(_ db: Database) throws {
    let files = try db.allFiles(includeMissing: true)
    if files.isEmpty {
        eprint("hint: run 'astrotool scan' first")
    }
}

// MARK: - scan

func cmdScan(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--path", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--refresh-meta", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    let scanner = LibraryScanner(config: config, db: db)
    let summary = try scanner.scan(
        subpath: parsed.value("--path"),
        refreshMeta: parsed.has("--refresh-meta")
    )

    if parsed.has("--json") {
        try printJSON(summary)
    } else {
        var line = "scan: added \(summary.added), updated \(summary.updated), unchanged \(summary.unchanged), missing \(summary.missing)"
        if summary.reclassified > 0 {
            line += ", reclassified \(summary.reclassified)"
        }
        if summary.metaRefreshed > 0 {
            line += ", meta refreshed \(summary.metaRefreshed)"
        }
        print(line)
        if !summary.inaccessiblePaths.isEmpty {
            eprint("warning: \(summary.inaccessiblePaths.count) directories could not be read and were skipped: \(summary.inaccessiblePaths.joined(separator: ", "))")
        }
    }
    return 0
}

// MARK: - audit

func cmdAudit(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--suggest", takesValue: false),
        FlagSpec("--include-suspicious", takesValue: false),
        FlagSpec("--no-duplicates", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let includeDuplicates = !parsed.has("--no-duplicates")
    let (_, findings) = try AuditEngine(config: config, db: db).run(includeDuplicates: includeDuplicates)

    var suggestMessage: String?
    if parsed.has("--suggest") {
        let writeGuard = makeWriteGuard(config: config)
        let url = try SuggestionScript.write(
            findings: findings,
            root: writeGuard.root,
            includeSuspicious: parsed.has("--include-suspicious"),
            timestamp: Date(),
            using: writeGuard
        )
        suggestMessage = url.map { "suggestion script written to \($0.path)" } ?? "no actionable findings"
    }

    if parsed.has("--json") {
        // Keep stdout pure JSON: the suggest-path message is informational,
        // so in --json mode it goes to stderr instead of interleaving with
        // the findings array on stdout.
        if let suggestMessage { eprint(suggestMessage) }
        try printJSON(findings)
    } else {
        printAuditFindings(findings, config: config)
        if let suggestMessage { print(suggestMessage) }
    }
    return 0
}

/// Human-readable audit output, aggregated the same way as the app's
/// `AuditView` (`FindingGrouper`, shared so the two never drift): one line
/// per (severity, category, group) with a count, then up to 3 example
/// paths -- instead of one line per finding, which floods the terminal when
/// a single root cause produces dozens/hundreds of near-identical findings.
/// Full per-finding detail is always available via `--json`.
private func printAuditFindings(_ findings: [Finding], config: AstroConfig) {
    guard !findings.isEmpty else {
        print("no findings")
        return
    }

    let order: [Severity] = [.sureError, .suspicious, .probablyIntentional]
    for severity in order {
        let group = findings.filter { $0.severity == severity }
        guard !group.isEmpty else { continue }

        print("\(severity.rawValue) (\(group.count))")
        for bucket in FindingGrouper.group(group, config: config) {
            print("\(severity.rawValue)  \(bucket.key.category)  \(bucket.key.groupKey)  (\(bucket.count) db)")
            for line in bucket.firstMessage.components(separatedBy: "\n") {
                print("    \(line)")
            }
            for finding in bucket.findings.prefix(3) {
                print("    - \(finding.path)")
            }
            if bucket.count > 3 {
                print("    ... +\(bucket.count - 3) more")
            }
        }
    }
}

// MARK: - cleanup

/// Aggregated, size-ordered "what's worth cleaning up" report over residue
/// files/dirs and duplicate-content groups already known to the DB (see
/// `CleanupReport`). `--suggest` writes a reviewable script that quarantines
/// (never deletes) every listed candidate — see `cleanupFindings` below.
func cmdCleanup(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--suggest", takesValue: false),
        FlagSpec("--limit", takesValue: true),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let summary = try CleanupReport.build(db: db, config: config)

    var suggestMessage: String?
    if parsed.has("--suggest") {
        let writeGuard = makeWriteGuard(config: config)
        let timestamp = Date()
        let findings = CleanupReport.quarantineFindings(for: summary, timestamp: timestamp)
        let url = try SuggestionScript.write(
            findings: findings,
            root: writeGuard.root,
            includeSuspicious: true,
            timestamp: timestamp,
            using: writeGuard,
            commentSuspicious: false
        )
        suggestMessage = url.map { "cleanup script written to \($0.path)" } ?? "no cleanup candidates"
    }

    if parsed.has("--json") {
        // Same stdout-purity contract as `audit --json --suggest`.
        if let suggestMessage { eprint(suggestMessage) }
        try printJSON(summary)
    } else {
        let limit = parsed.value("--limit").flatMap(Int.init) ?? 10
        let sizeByPath = Dictionary(
            (try db.allFiles(includeMissing: false)).map { ($0.path, $0.size) },
            uniquingKeysWith: { first, _ in first }
        )
        printCleanupReport(summary, limit: limit, sizeByPath: sizeByPath)
        if let suggestMessage { print(suggestMessage) }
    }
    return 0
}

private func printCleanupReport(_ summary: CleanupSummary, limit: Int, sizeByPath: [String: Int64]) {
    guard !summary.groups.isEmpty else {
        print("nincs takarítható elem")
        return
    }

    for group in summary.groups {
        print("\(group.category)  \(group.fileCount) fájl  \(formatBytes(group.totalBytes))")
        for path in group.paths.prefix(limit) {
            print("  \(path)  \(formatBytes(sizeByPath[path] ?? 0))")
        }
        if group.truncatedCount > 0 {
            print("  … és még \(group.truncatedCount) fájl (nincs kilistázva)")
        }
    }
    print("")
    print("összesen felszabadítható: \(formatBytes(summary.grandTotalBytes))")
}

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - rate

func cmdRate(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--no-siril", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target") else {
        eprint("error: --target is required")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    var provider: StarMetricsProvider?
    if !parsed.has("--no-siril") {
        do {
            provider = try SirilCLI(path: config.rating.sirilPath)
        } catch {
            eprint("siril not found at \(config.rating.sirilPath), falling back to native stats")
            provider = nil
        }
    }

    let rater = Rater(db: db, config: config, provider: provider)
    let results = try rater.rate(target: target, date: parsed.value("--date"))

    if parsed.has("--json") {
        try printJSON(results)
    } else {
        printRateTable(results)
    }
    return 0
}

/// Formats an optional metric compactly for the human table, `"-"` when
/// absent (e.g. no Siril metrics for that frame, or `.fz` frames that never
/// got native `background`/`saturatedFraction`).
private func fmt(_ value: Double?, _ digits: Int) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}

private func printRateTable(_ results: [FrameScore]) {
    guard !results.isEmpty else {
        print("no frames rated")
        return
    }

    let pathWidth = results.map { $0.path.count }.max() ?? 4
    let header = "PATH".padding(toLength: pathWidth, withPad: " ", startingAt: 0)
    print("\(header)  SCORE      FWHM   ROUND  STARS  BACKGRND  SAT%    OUTLIER")
    for r in results {
        let path = r.path.padding(toLength: pathWidth, withPad: " ", startingAt: 0)
        let score = String(format: "%9.4f", r.score)
        let fwhm = fmt(r.metrics?.fwhm, 2).padding(toLength: 5, withPad: " ", startingAt: 0)
        let roundness = fmt(r.metrics?.roundness, 2).padding(toLength: 5, withPad: " ", startingAt: 0)
        let stars = (r.metrics.map { String($0.starCount) } ?? "-").padding(toLength: 5, withPad: " ", startingAt: 0)
        let background = fmt(r.background, 0).padding(toLength: 8, withPad: " ", startingAt: 0)
        let satPercent = fmt(r.saturatedFraction.map { $0 * 100 }, 2).padding(toLength: 6, withPad: " ", startingAt: 0)
        let marker = r.isOutlier ? "*" : ""
        print("\(path)  \(score)  \(fwhm)  \(roundness)  \(stars)  \(background)  \(satPercent)  \(marker)")
    }
}

// MARK: - stats

func cmdStats(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--gross", takesValue: false),
        FlagSpec("--sessions", takesValue: false),
        FlagSpec("--tag", takesValue: true),
        FlagSpec("--timeline", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)
    let showGross = parsed.has("--gross")

    guard let target = parsed.value("--target") else {
        if parsed.has("--sessions") {
            eprint("error: --sessions requires --target")
            return 1
        }
        if parsed.has("--timeline") {
            eprint("error: --timeline requires --target")
            return 1
        }
        let config = try resolveConfig(rootFlag: parsed.value("--root"))
        let db = try makeDatabase(config: config)
        try hintIfEmpty(db)
        var all = try StatsQueries.perTarget(db: db, config: config)
        if let tag = parsed.value("--tag") {
            let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            all = all.filter { $0.tags.contains(trimmedTag) }
        }
        if parsed.has("--json") {
            try printJSON(all)
        } else {
            printStatsTable(all, showGross: showGross)
        }
        return 0
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    if parsed.has("--sessions") {
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        if parsed.has("--json") {
            try printJSON(sessions)
        } else {
            printSessionDetails(target: target, sessions: sessions)
        }
        return 0
    }

    if parsed.has("--timeline") {
        let dates: [String]
        if let date = parsed.value("--date") {
            dates = [date]
        } else {
            dates = try SessionStatsQueries.sessions(target: target, db: db, config: config).map(\.dateRaw)
        }
        let timelines = try dates.map { try SessionTimeline.timeline(target: target, date: $0, db: db, config: config) }
        if parsed.has("--json") {
            try printJSON(timelines)
        } else {
            printTimelines(timelines)
        }
        return 0
    }

    guard let stats = try StatsQueries.target(target, db: db, config: config) else {
        eprint("error: target not found: \(target)")
        return 1
    }
    if parsed.has("--json") {
        try printJSON(stats)
    } else {
        printSingleTargetStats(stats, showGross: showGross)
    }
    return 0
}

private func printTimelines(_ timelines: [SessionTimeline]) {
    guard !timelines.isEmpty else {
        print("no sessions")
        return
    }
    for t in timelines {
        print("session: \(t.target) / \(t.date)")
        if let start = t.windowStart, let end = t.windowEnd {
            print("  window: \(start) → \(end)")
        } else {
            print("  window: -")
        }
        print("  window duration: \(t.windowSeconds.map(formatHoursMinutes) ?? "-")")
        print("  integration: \(formatHoursMinutes(t.integrationSeconds))")
        print("  duty cycle: \(t.dutyCycle.map { String(format: "%.0f%%", $0 * 100) } ?? "-")")
        if t.gaps.isEmpty {
            print("  gaps: none")
        } else {
            print("  gaps:")
            for gap in t.gaps {
                print("    \(gap.start) → \(gap.end)  (\(formatHoursMinutes(gap.seconds)))")
            }
        }
    }
}

private func printSessionDetails(target: String, sessions: [SessionDetail]) {
    guard !sessions.isEmpty else {
        print("no sessions for target: \(target)")
        return
    }

    for s in sessions {
        let excludedSuffix = s.isExcludedFromTotals ? "  [kizárva a célpont-összegzésből]" : ""
        print("session: \(s.target) / \(s.dateRaw)\(excludedSuffix)")
        print("  frames: \(frameCountText(s))")
        print("  integration: \(formatHoursMinutes(s.integrationSeconds))")
        let exposures = s.exposureBreakdown
            .sorted { $0.key < $1.key }
            .map { "\($0.key)s×\($0.value)" }
            .joined(separator: ", ")
        print("  exposures: \(exposures.isEmpty ? "-" : exposures)")
        print("  camera: \(s.cameras.isEmpty ? "-" : s.cameras.joined(separator: ", "))")
        print("  focal length: \(s.focalLengthsMM.isEmpty ? "-" : s.focalLengthsMM.map { "\($0)mm" }.joined(separator: ", "))")
        print("  gain/ISO: \(s.gains.isEmpty ? "-" : s.gains.map { "\($0)" }.joined(separator: ", "))")
        print("  sensor temp: \(s.sensorTempsC.isEmpty ? "-" : s.sensorTempsC.map { "\($0)°C" }.joined(separator: ", "))")
        print("  filter: \(s.filters.isEmpty ? "-" : s.filters.joined(separator: ", "))")
        print("  README: \(s.hasReadme ? "yes" : "no")")
    }
}

/// "118 light, 2 flat" plus a "(+12 elvetett · 47 link)" suffix when this
/// session has rejected/duplicate frames the naive `lightCount` doesn't
/// distinguish from real usable ones.
private func frameCountText(_ s: SessionDetail) -> String {
    var base = "\(s.usableLightCount) light, \(s.flatCount) flat, \(s.darkCount) dark, \(s.biasCount) bias"
    var extras: [String] = []
    if s.rejectedCount > 0 { extras.append("\(s.rejectedCount) elvetett") }
    if s.duplicateLinkCount > 0 { extras.append("\(s.duplicateLinkCount) link") }
    if !extras.isEmpty {
        base += "  (+\(extras.joined(separator: " · ")))"
    }
    return base
}

private func formatHoursMinutes(_ seconds: Double) -> String {
    let totalMinutes = Int((seconds / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return String(format: "%d:%02d", hours, minutes)
}

private func printStatsTable(_ stats: [TargetStats], showGross: Bool) {
    guard !stats.isEmpty else {
        print("no targets")
        return
    }

    let targetWidth = max(stats.map { $0.target.count }.max() ?? 6, 6)
    let header = "TARGET".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    let grossHeader = showGross ? "  GROSS      " : ""
    print("\(header)  INTEGRATION  \(grossHeader)SESSIONS  LAST DATE   WIDE")
    for s in stats {
        let name = s.target.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
        let integration = formatHoursMinutes(s.totalIntegrationSeconds).padding(toLength: 11, withPad: " ", startingAt: 0)
        let gross = showGross ? formatHoursMinutes(s.grossIntegrationSeconds).padding(toLength: 11, withPad: " ", startingAt: 0) + "  " : ""
        let sessions = String(s.sessionDates.count).padding(toLength: 8, withPad: " ", startingAt: 0)
        let last = (s.lastSessionDate ?? "-").padding(toLength: 11, withPad: " ", startingAt: 0)
        let wide = s.isWideField ? "wide" : ""
        print("\(name)  \(integration)  \(gross)\(sessions)  \(last)  \(wide)")
    }
}

private func printSingleTargetStats(_ s: TargetStats, showGross: Bool) {
    print("target: \(s.target)")
    print("integration: \(formatHoursMinutes(s.totalIntegrationSeconds))")
    if showGross {
        print("gross (undeduped): \(formatHoursMinutes(s.grossIntegrationSeconds))")
    }
    print("frames: \(s.usableFrameCount) usable, \(s.duplicateLinkCount) duplicate link(s), \(s.rejectedFrameCount) rejected, \(s.nonFrameFileCount) non-frame")
    if !s.excludedSessionDates.isEmpty {
        print("excluded sessions: \(s.excludedSessionDates.joined(separator: ", "))")
    }
    print("sessions: \(s.sessionDates.count)")
    print("last date: \(s.lastSessionDate ?? "-")")
    print("wide field: \(s.isWideField ? "yes" : "no")")
    print("cameras: \(s.cameras.joined(separator: ", "))")
    print("filters: \(s.filters.joined(separator: ", "))")
}

// MARK: - quality

/// `astrotool quality --target T [--date D] [--json]` -- absolute,
/// cross-setup-comparable session quality metrics (`SessionQuality`), as
/// opposed to `rate`'s per-frame RELATIVE z-scores.
func cmdQuality(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target") else {
        eprint("error: --target is required")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    var summaries = try SessionQuality.summaries(target: target, db: db, config: config)
    if let date = parsed.value("--date") {
        summaries = summaries.filter { $0.date == date }
    }

    if parsed.has("--json") {
        try printJSON(summaries)
    } else {
        printQualityTable(summaries)
    }
    return 0
}

private func printQualityTable(_ summaries: [SessionQualitySummary]) {
    guard !summaries.isEmpty else {
        print("no sessions")
        return
    }

    let dateWidth = max(summaries.map { $0.date.count }.max() ?? 10, 10)
    let header = "DATE".padding(toLength: dateWidth, withPad: " ", startingAt: 0)
    print("\(header)  FRAMES  FWHM(px)  FWHM(\")  BACKGROUND(e-/s/\"^2)  STARS  OUTLIER%  RANK")
    for s in summaries {
        let date = s.date.padding(toLength: dateWidth, withPad: " ", startingAt: 0)
        let fwhmPx = fmt(s.medianFWHMPixels, 2).padding(toLength: 8, withPad: " ", startingAt: 0)
        let fwhmArc = fmt(s.medianFWHMArcsec, 2).padding(toLength: 7, withPad: " ", startingAt: 0)
        let background = fmt(s.backgroundEPerSecPerArcsec2, 4).padding(toLength: 20, withPad: " ", startingAt: 0)
        let stars = (s.medianStarCount.map(String.init) ?? "-").padding(toLength: 5, withPad: " ", startingAt: 0)
        let outlier = (s.outlierFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0)
        let rank = s.rankAmongSessions.map { "\($0)/\(s.sessionCountForTarget ?? 0)" } ?? "-"
        print("\(date)  \(s.frameCount)       \(fwhmPx)  \(fwhmArc)  \(background)  \(stars)  \(outlier)  \(rank)")
    }
}

// MARK: - calib

func cmdCalib(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let needs = try CalibAnalyzer.coverage(db: db, config: config)
    if parsed.has("--json") {
        try printJSON(needs)
    } else {
        printCalibReport(needs)
    }
    return 0
}

private func printCalibReport(_ needs: [CalibNeed]) {
    let todos = needs.filter { $0.todo != nil }
    let covered = needs.filter { $0.todo == nil }

    if todos.isEmpty {
        print("no pending calibration todos")
    } else {
        print("todo:")
        for need in todos {
            print("  - \(need.todo ?? "")")
            if !need.mismatchReasons.isEmpty {
                print("    ⚠️ nem illeszkedő master: \(need.mismatchReasons.joined(separator: ", "))")
            }
        }
    }

    print("")
    print("covered combos: \(covered.count)")
    for need in covered {
        let tempStr = need.tempC.map { String(format: "%.1f°C", $0) } ?? "n/a"
        print("  \(formatted(need.exposureSeconds))s / \(tempStr) -> \(need.matchedMasterPath ?? "-")")
    }
}

private func formatted(_ value: Double) -> String {
    String(format: "%g", value)
}

// MARK: - match

func cmdMatch(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target"), let date = parsed.value("--date") else {
        eprint("error: --target and --date are required")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let result = try SessionMatcher.match(target: target, date: date, db: db, config: config)
    if parsed.has("--json") {
        try printJSON(result)
    } else {
        printSessionCalibration(result)
    }
    return 0
}

private func printSessionCalibration(_ sc: SessionCalibration) {
    print("target: \(sc.target)")
    print("date: \(sc.date)")
    print("lights: \(sc.lights)")
    print("flats: \(sc.flats.count)")
    print("darks: \(sc.darks.count)")
    print("biases: \(sc.biases.count)")
    if let libraryDark = sc.libraryDark {
        print("library dark: \(libraryDark)")
    }
    if sc.problems.isEmpty {
        print("no problems")
    } else {
        print("problems:")
        for problem in sc.problems {
            print("  [\(problem.severity.rawValue)] \(problem.category): \(problem.path)")
            print("    \(problem.message)")
        }
    }
}

// MARK: - link-calib

/// Hard-links matching calibration masters from `calibration_library/` into
/// one session's own `darks`/`biases` folders -- the sole additive write
/// this tool performs against files the user already has (spec section 11
/// point 4). Never runs without either an interactive `YES` confirmation or
/// an explicit `--yes`; `--dry-run` never writes at all, in any mode.
func cmdLinkCalib(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--dry-run", takesValue: false),
        FlagSpec("--yes", takesValue: false),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target"), let date = parsed.value("--date") else {
        eprint("error: --target and --date are required")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let plan = try CalibLinker.plan(target: target, date: date, db: db, config: config)
    let isJSON = parsed.has("--json")

    if parsed.has("--dry-run") {
        if isJSON {
            try printJSON(plan)
        } else {
            printLinkPlan(plan)
            print("(dry-run: nincs írás)")
        }
        return 0
    }

    if isJSON {
        // No stdin prompt makes sense for a --json caller -- require an
        // explicit --yes instead of ever blocking on a TTY read.
        guard parsed.has("--yes") else {
            eprint("error: --json without --dry-run requires --yes")
            return 1
        }
        let result = try applyLinkPlan(plan, config: config)
        try printJSON(result)
        return 0
    }

    printLinkPlan(plan)
    guard !plan.items.isEmpty else { return 0 }

    if !parsed.has("--yes") {
        print("Type YES to link:")
        guard let line = readLine(), line.trimmingCharacters(in: .whitespacesAndNewlines) == "YES" else {
            print("megszakítva, nem történt írás")
            return 0
        }
    }

    let result = try applyLinkPlan(plan, config: config)
    print("linked \(result.linked.count), skipped \(result.skipped.count)")
    return 0
}

private func applyLinkPlan(_ plan: CalibLinkPlan, config: AstroConfig) throws -> LinkResult {
    let writeGuard = makeWriteGuard(config: config)
    let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
    return try CalibLinker.apply(plan, root: root, using: writeGuard)
}

private func printLinkPlan(_ plan: CalibLinkPlan) {
    print("target: \(plan.target)")
    print("date: \(plan.date)")

    guard !plan.items.isEmpty else {
        if !plan.mismatchReasons.isEmpty {
            print("nem linkelhető: \(plan.mismatchReasons.joined(separator: ", "))")
        } else {
            print("nincs linkelhető kalibráció")
        }
        return
    }

    let grouped = Dictionary(grouping: plan.items, by: { $0.destDir })
    for destDir in grouped.keys.sorted() {
        print("\(destDir):")
        for item in (grouped[destDir] ?? []).sorted(by: { $0.sourcePath < $1.sourcePath }) {
            print("  \(item.sourcePath)  (\(item.reason))")
        }
    }
}

// MARK: - new-session

func cmdNewSession(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--catalog", takesValue: true),
        FlagSpec("--name", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let catalog = parsed.value("--catalog"),
          let name = parsed.value("--name"),
          let date = parsed.value("--date")
    else {
        eprint("error: --catalog, --name, and --date are required")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    try ensureRootAccessible(config)
    let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

    let result: SessionCreator.Result
    do {
        result = try SessionCreator.create(root: root, catalogRaw: catalog, nameRaw: name, date: date)
    } catch AstroError.invalidInput(let reason) {
        eprint("error: \(reason)")
        eprint(usageText)
        return 1
    }

    if parsed.has("--json") {
        try printJSON(["created": result.createdURLs.map { $0.path }])
    } else {
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(result.targetFolder, isDirectory: true)
            .appendingPathComponent(date, isDirectory: true)
        print("created: \(sessionDir.path)")
    }
    return 0
}

// MARK: - config

func cmdConfig(_ args: [String]) throws -> Int32 {
    guard let sub = args.first else {
        eprint("error: expected 'show' or 'path'")
        eprint(usageText)
        return 1
    }

    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(Array(args.dropFirst()), specs: specs)
    let config = try resolveConfig(rootFlag: parsed.value("--root"))

    switch sub {
    case "show":
        try printJSON(config)
        return 0
    case "path":
        let path = configPath(for: config)
        if parsed.has("--json") {
            try printJSON(["path": path])
        } else {
            print(path)
        }
        return 0
    default:
        eprint("error: expected 'show' or 'path', got '\(sub)'")
        eprint(usageText)
        return 1
    }
}

// MARK: - tag

/// `astrotool tag <add|remove|list>`. Unlike every other subcommand, `add`/
/// `remove` take a bare positional `<tag>` argument alongside their flags --
/// `ArgParser` itself has no notion of positionals (see its doc comment), so
/// `splitPositionalArgs` below separates recognized `--flag [value]` pairs
/// from anything else before handing the flag-only slice to `ArgParser`.
func cmdTag(_ args: [String]) throws -> Int32 {
    guard let sub = args.first else {
        eprint("error: expected 'add', 'remove', or 'list'")
        eprint(usageText)
        return 1
    }
    let rest = Array(args.dropFirst())

    let specs = [
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]

    switch sub {
    case "add", "remove":
        return try cmdTagAddOrRemove(rest, specs: specs, isAdd: sub == "add")
    case "list":
        return try cmdTagList(rest, specs: specs)
    default:
        eprint("error: expected 'add', 'remove', or 'list', got '\(sub)'")
        eprint(usageText)
        return 1
    }
}

private func cmdTagAddOrRemove(_ args: [String], specs: [FlagSpec], isAdd: Bool) throws -> Int32 {
    let (flagArgs, positionals) = splitPositionalArgs(args, specs: specs)
    let parsed = try ArgParser.parse(flagArgs, specs: specs)

    guard let target = parsed.value("--target") else {
        eprint("error: --target is required")
        eprint(usageText)
        return 1
    }
    guard positionals.count == 1 else {
        eprint("error: expected a single <tag> argument, got \(positionals.count)")
        eprint(usageText)
        return 1
    }
    let tagText = positionals[0]
    let date = parsed.value("--date")

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    let record = TagRecord(kind: date == nil ? "target" : "session", target: target, sessionDate: date, tag: tagText)

    if isAdd {
        try db.addTag(record)
    } else {
        try db.removeTag(record)
    }

    if parsed.has("--json") {
        try printJSON(record)
    } else {
        let scope = date.map { "\(target) [\($0)]" } ?? target
        print("\(isAdd ? "added" : "removed"): \(scope) -> \(record.tag.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return 0
}

private func cmdTagList(_ args: [String], specs: [FlagSpec]) throws -> Int32 {
    let (flagArgs, positionals) = splitPositionalArgs(args, specs: specs)
    guard positionals.isEmpty else {
        eprint("error: unexpected argument: \(positionals.joined(separator: " "))")
        eprint(usageText)
        return 1
    }
    let parsed = try ArgParser.parse(flagArgs, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)

    if let target = parsed.value("--target") {
        let date = parsed.value("--date")
        let tags = try db.tags(target: target, sessionDate: date)
        if parsed.has("--json") {
            try printJSON(tags)
        } else if tags.isEmpty {
            let scope = date.map { "\(target) [\($0)]" } ?? target
            print("no tags for \(scope)")
        } else {
            print(tags.joined(separator: ", "))
        }
        return 0
    }

    let all = try db.allTags()
    if parsed.has("--json") {
        try printJSON(all)
    } else {
        printTagsGrouped(all)
    }
    return 0
}

private func printTagsGrouped(_ records: [TagRecord]) {
    guard !records.isEmpty else {
        print("no tags")
        return
    }

    struct Key: Hashable {
        let target: String
        let date: String?
    }

    var tagsByKey: [Key: [String]] = [:]
    var order: [Key] = []
    for r in records {
        let key = Key(target: r.target, date: r.sessionDate)
        if tagsByKey[key] == nil { order.append(key) }
        tagsByKey[key, default: []].append(r.tag)
    }

    for key in order {
        let label = key.date.map { "\(key.target) [\($0)]" } ?? key.target
        print("\(label): \(tagsByKey[key]?.joined(separator: ", ") ?? "")")
    }
}

/// Splits `args` into recognized `--flag`/`--flag value` tokens (returned
/// verbatim, still to be handed to `ArgParser.parse`) and everything else
/// (the positional `<tag>` argument `tag add`/`tag remove` take). An
/// unrecognized `--flag` is left in the flag slice so `ArgParser.parse`
/// still reports it as `ArgParserError.unknownFlag` rather than silently
/// treating it as the positional.
private func splitPositionalArgs(_ args: [String], specs: [FlagSpec]) -> (flagArgs: [String], positionals: [String]) {
    let specByName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
    var flagArgs: [String] = []
    var positionals: [String] = []

    var index = 0
    while index < args.count {
        let arg = args[index]
        guard arg.hasPrefix("--") else {
            positionals.append(arg)
            index += 1
            continue
        }

        let name = arg.firstIndex(of: "=").map { String(arg[arg.startIndex..<$0]) } ?? arg
        guard let spec = specByName[name] else {
            // Unknown flag -- keep it so ArgParser.parse surfaces the error.
            flagArgs.append(arg)
            index += 1
            continue
        }

        if arg.contains("=") {
            flagArgs.append(arg)
            index += 1
        } else if spec.takesValue {
            flagArgs.append(arg)
            if index + 1 < args.count {
                flagArgs.append(args[index + 1])
            }
            index += 2
        } else {
            flagArgs.append(arg)
            index += 1
        }
    }

    return (flagArgs, positionals)
}

// MARK: - plan

/// `astrotool plan [--date YYYY-MM-DD] [--min-alt 30] [--json]` -- tonight's
/// observation plan for every target on record (see `Planner.plan`).
func cmdPlan(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--min-alt", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    var date: Date?
    if let raw = parsed.value("--date") {
        guard let parsedDate = parsePlanDate(raw) else {
            eprint("error: invalid --date (expected YYYY-MM-DD): \(raw)")
            return 1
        }
        date = parsedDate
    }

    var minAlt = 30.0
    if let raw = parsed.value("--min-alt") {
        guard let value = Double(raw) else {
            eprint("error: invalid --min-alt: \(raw)")
            return 1
        }
        minAlt = value
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let plans = try Planner.plan(date: date, minAltitudeDeg: minAlt, db: db, config: config)

    if parsed.has("--json") {
        try printJSON(plans)
    } else {
        try printPlanHeader(db: db, config: config, date: date)
        printPlanTable(plans)
    }
    return 0
}

/// Parses a bare `YYYY-MM-DD` date (UTC, offset to local noon so it safely
/// lands within the intended civil day regardless of the site's timezone
/// offset -- `Planner` only ever uses this to find "the night starting on
/// this calendar day", never the exact time of day).
private func parsePlanDate(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: raw) else { return nil }
    return date.addingTimeInterval(12 * 3600)
}

/// The header line above the plan table: tonight's dusk/dawn (site-LOCAL
/// time) and the Moon's phase. PRIVACY: never prints the site's actual
/// latitude/longitude -- only uses them to derive the times/phase shown
/// (`config show` is the one place those coordinates may appear).
private func printPlanHeader(db: Database, config: AstroConfig, date: Date?) throws {
    let site = try Planner.resolveSite(db: db, config: config)
    guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
        print("Ma este: helyszín ismeretlen (nincs SITELAT/SITELONG a könyvtárban, és a config sem ad meg helyszínt)")
        return
    }

    let timeZone = TimeZone.current
    let night = SunMoon.astronomicalTwilight(nightOf: date ?? Date(), latDeg: lat, lonDeg: lon, timeZone: timeZone)
    guard let dusk = night.duskUTC, let dawn = night.dawnUTC else {
        print("Ma este: nincs csillagászati (sem nautikai) éjszaka ezen a szélességen ma")
        return
    }

    let midNight = dusk.addingTimeInterval(dawn.timeIntervalSince(dusk) / 2)
    let moonIllum = SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(midNight))
    let fallbackNote = night.usedNauticalFallback ? " (nautikai szürkület, nincs valódi csillagászati sötét)" : ""

    print("Ma este: szürkület \(formatLocalTime(dusk, timeZone: timeZone)) -> hajnal \(formatLocalTime(dawn, timeZone: timeZone))\(fallbackNote), Hold: \(String(format: "%.0f%%", moonIllum))")
}

private func formatLocalTime(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func printPlanTable(_ plans: [TargetPlan]) {
    guard !plans.isEmpty else {
        print("no targets")
        return
    }

    let targetWidth = max(plans.map { $0.target.count }.max() ?? 7, 7)
    let header = "CÉLPONT".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    print("\(header)  MEGVAN   CÉL      KULMINÁCIÓ  MAX ALT  ABLAK          HOLD        VERDIKT")

    for plan in plans {
        let name = plan.target.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
        let have = formatHoursMinutes(plan.usableIntegrationSeconds).padding(toLength: 7, withPad: " ", startingAt: 0)
        let goal = (plan.goalSeconds.map(formatHoursMinutes) ?? "—").padding(toLength: 7, withPad: " ", startingAt: 0)
        let culmination = (plan.culminationLocal ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
        let maxAlt = (plan.maxAltitudeDeg.map { String(format: "%.0f°", $0) } ?? "-").padding(toLength: 7, withPad: " ", startingAt: 0)
        let window = (plan.visibleWindowLocal ?? "-").padding(toLength: 13, withPad: " ", startingAt: 0)
        let moon = moonColumnText(plan).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(name)  \(have)  \(goal)  \(culmination)  \(maxAlt)  \(window)  \(moon)  \(plan.verdict)")
    }
}

private func moonColumnText(_ plan: TargetPlan) -> String {
    guard let illum = plan.moonIlluminationPercent, let sep = plan.moonSeparationDeg else { return "-" }
    return String(format: "%.0f°/%.0f%%", sep, illum)
}
