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
  rate          [--root R] --target T [--date D] [--json] [--no-siril] [--force]
  stats         [--root R] [--target T] [--json] [--gross] [--sessions (requires --target)] [--tag TAG]
                [--timeline (requires --target) [--date D]]
  quality       --target T [--date D] [--root R] [--json]
  calib         [--root R] [--json] [--health]
  match         [--root R] --target T --date D [--json]
  link-calib    --target T --date D [--dry-run] [--yes] [--root R] [--json]
  new-session   --catalog CAT --name NAME --date D [--root R] [--json]
  config        (show|path) [--root R] [--json]
  tag add       --target T [--date D] <tag> [--root R] [--json]
  tag remove    --target T [--date D] <tag> [--root R] [--json]
  tag list      [--target T] [--date D] [--root R] [--json]
  plan          [--date YYYY-MM-DD] [--min-alt 30] [--root R] [--json]
                [--month [--nights 30]]
                Without --month: tonight's per-target observation plan.
                With --month: a month-at-a-glance planning calendar (dark
                hours, Moon%, top-3 targets per night) instead.
  projects      [--root R] [--json]
  export        --target T --format astrobin|csv|md [--out PATH] [--root R]
  health        --target T [--date D] [--root R] [--json]
  panels        --target T [--root R] [--json]
  search        <query> [--root R] [--json]
  solve         --target T|--all [--frames N] [--force] [--root R] [--json]
  sensor        [--measure] [--json] [--root R]
  ingest-dss    [--root R] [--json]
                Harvests DeepSkyStacker <frame>.info.txt star metrics and
                .dssfilelist accept/reject decisions already in the library.
                Not run automatically by `scan --refresh-meta` -- DSS trees
                can be large, so this stays an explicit, predictable step.
  expose        [--target T] [--json] [--root R]
                Sub-exposure-length optimizer + relative-SNR advisor, built
                from measured sensor-profile + per-Bayer background data.
                Without --target: one row per target. With --target: full
                advice for that target.
  stacklist     --target T --date D [--keep 0.8] [--json] [--root R]
                Best-frame stack-list export: hardlinks the selected lights
                into .astro_tool/stacklists/<target>-<date>/lights/ and
                writes a .dssfilelist (DeepSkyStacker/Sirilic) and a .ssf
                Siril script alongside it. Additive and idempotent -- never
                touches your original files.
  stacks        [--target T] [--json] [--root R]
                Stack-file felderítés: minden már létrejött stack/feldolgozott
                kimenet célpontonként, bárhol is legyen a lemezen -- nem csak
                a kanonikus stacks/<cél>/<dátum>/ helyen. Ismeretlen célponthoz
                sorolt találatok "Besorolatlan" alatt.
  report        --target T --date D [--out -] [--root R]
                Self-contained HTML night-report card: frame/exposure
                summary, timeline, quality, altitude/airmass + achieved Moon
                geometry, hardware health, calibration status, DSS verdicts,
                README notes, and to-dos. Written to
                .astro_tool/reports/<target>-<date>.html; --out - prints
                the HTML to stdout instead.
  target-report --target T [--out -] [--root R]
                Self-contained HTML target-report: everything on record for
                one target across every session -- coordinates, setup,
                sessions table, quality/exposure advice, discovered stacks
                (R8-1), calibration status, mosaic panels, tonight's plan,
                README notes, and pipeline to-dos. Written to
                .astro_tool/reports/target-<target>.html; --out - prints
                the HTML to stdout instead.

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
        FlagSpec("--force", takesValue: false),
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
    let results = try rater.rate(target: target, date: parsed.value("--date"), force: parsed.has("--force"))

    if Rater.shouldWarnNoMetrics(results, providerWasUsed: provider != nil) {
        eprint("a Siril nem adott metrikát egyetlen keretre sem — ellenőrizd a telepítést")
    }

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

/// `displayName` when it differs from the raw folder `target`, with the
/// folder name kept alongside in parentheses (truncated to a sane overall
/// width for the table); just `target` when they're the same (an
/// unresolved/junk folder name, where `displayName` is only `target` with
/// underscores turned into spaces -- printing it twice would be noise).
private func statsNameColumnText(_ s: TargetStats, maxWidth: Int = 40) -> String {
    guard s.displayName != s.target else { return s.target }
    let full = "\(s.displayName) (\(s.target))"
    guard full.count > maxWidth else { return full }
    let truncatedDisplay = String(s.displayName.prefix(max(1, maxWidth - s.target.count - 4))) + "…"
    return "\(truncatedDisplay) (\(s.target))"
}

private func printStatsTable(_ stats: [TargetStats], showGross: Bool) {
    guard !stats.isEmpty else {
        print("no targets")
        return
    }

    let names = stats.map { statsNameColumnText($0) }
    let targetWidth = max(names.map(\.count).max() ?? 6, 6)
    let header = "TARGET".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    let grossHeader = showGross ? "  GROSS      " : ""
    print("\(header)  INTEGRATION  \(grossHeader)SESSIONS  LAST DATE   WIDE")
    for (s, nameText) in zip(stats, names) {
        let name = nameText.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
        let integration = formatHoursMinutes(s.totalIntegrationSeconds).padding(toLength: 11, withPad: " ", startingAt: 0)
        let gross = showGross ? formatHoursMinutes(s.grossIntegrationSeconds).padding(toLength: 11, withPad: " ", startingAt: 0) + "  " : ""
        let sessions = String(s.sessionDates.count).padding(toLength: 8, withPad: " ", startingAt: 0)
        let last = (s.lastSessionDate ?? "-").padding(toLength: 11, withPad: " ", startingAt: 0)
        let wide = s.isWideField ? "wide" : ""
        print("\(name)  \(integration)  \(gross)\(sessions)  \(last)  \(wide)")
    }
}

private func printSingleTargetStats(_ s: TargetStats, showGross: Bool) {
    if s.displayName != s.target {
        print("target: \(s.displayName) (\(s.target))")
    } else {
        print("target: \(s.target)")
    }
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
        FlagSpec("--health", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    if parsed.has("--health") {
        let report = try CalibHealth.report(db: db, config: config)
        if parsed.has("--json") {
            try printJSON(report)
        } else {
            printCalibHealthReport(report)
        }
        return 0
    }

    let needs = try CalibAnalyzer.coverage(db: db, config: config)
    if parsed.has("--json") {
        try printJSON(needs)
    } else {
        printCalibReport(needs)
    }
    return 0
}

private func printCalibHealthReport(_ report: CalibHealthReport) {
    print("Flat-fegyelem:")
    let problemFlats = report.flats.filter { $0.status != "rendben" }
    let okFlats = report.flats.filter { $0.status == "rendben" }
    if report.flats.isEmpty {
        print("  nincs session usable lighttal")
    }
    for flat in problemFlats + okFlats {
        print("  \(flat.target)/\(flat.date): \(flat.status)")
        if !flat.reasons.isEmpty {
            print("    - \(flat.reasons.joined(separator: ", "))")
        }
    }

    print("")
    print("Bias-készlet:")
    if report.biasGroups.isEmpty {
        print("  nincs bias frame")
    }
    for group in report.biasGroups {
        let gainStr = group.gain.map(formatted) ?? "-"
        let offsetStr = group.offset.map(formatted) ?? "-"
        let cameraStr = group.camera ?? "-"
        print("  gain\(gainStr)/offset\(offsetStr)/\(cameraStr): \(group.frameCount) frame (\(group.locations.joined(separator: ", ")))")
    }
    if !report.missingBiasCombos.isEmpty {
        print("  hiányzó kombók:")
        for combo in report.missingBiasCombos {
            print("    - \(combo)")
        }
    }

    print("")
    print("Dark-készlet egészség:")
    if report.darkMasters.isEmpty {
        print("  nincs master dark")
    }
    for master in report.darkMasters {
        let ageStr = master.ageDays.map(String.init) ?? "-"
        var line = "  \(master.path): \(master.frameCount) frame, \(ageStr) napos"
        if master.isStale { line += " ⚠️ elavult" }
        print(line)
        if !master.warnings.isEmpty {
            print("    - \(master.warnings.joined(separator: ", "))")
        }
    }
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

// MARK: - search

/// `astrotool search <query> [--root R] [--json]` -- R6-4's searchable
/// night log: a plain `LIKE` lookup over `session_notes` (Bortle, SQM,
/// seeing, dew, free-form notes -- everything the user typed into a
/// session's `README.txt` that a FITS header could never carry). Takes a
/// bare positional `<query>` alongside its flags, same
/// `splitPositionalArgs` split as `tag add`/`tag remove` use.
func cmdSearch(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let (flagArgs, positionals) = splitPositionalArgs(args, specs: specs)
    guard positionals.count == 1 else {
        eprint("error: expected a single <query> argument, got \(positionals.count)")
        eprint(usageText)
        return 1
    }
    let query = positionals[0]
    let parsed = try ArgParser.parse(flagArgs, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let results = try db.searchNotes(query: query)

    if parsed.has("--json") {
        try printJSON(results.map {
            SessionNoteSearchResult(target: $0.target, date: $0.date, key: $0.key, value: $0.value)
        })
    } else if results.isEmpty {
        print("no matches for \"\(query)\"")
    } else {
        printSearchResultsGrouped(results)
    }
    return 0
}

/// `db.searchNotes` returns plain tuples (not `Encodable`) -- this thin
/// wrapper is the only thing `--json` needs to serialize them.
private struct SessionNoteSearchResult: Encodable {
    let target: String
    let date: String
    let key: String
    let value: String
}

private func printSearchResultsGrouped(_ results: [(target: String, date: String, key: String, value: String)]) {
    struct Key: Hashable {
        let target: String
        let date: String
    }

    var rowsByKey: [Key: [(key: String, value: String)]] = [:]
    var order: [Key] = []
    for r in results {
        let key = Key(target: r.target, date: r.date)
        if rowsByKey[key] == nil { order.append(key) }
        rowsByKey[key, default: []].append((r.key, r.value))
    }

    for key in order {
        print("\(key.target) [\(key.date)]")
        for row in rowsByKey[key] ?? [] {
            print("  \(row.key): \(row.value)")
        }
    }
}

// MARK: - plan

/// `astrotool plan [--date YYYY-MM-DD] [--min-alt 30] [--json]` -- tonight's
/// observation plan for every target on record (see `Planner.plan`).
/// `astrotool plan --month [--nights 30] [--json]` -- a month-at-a-glance
/// planning calendar instead (see `Planner.month`, R7-B5).
func cmdPlan(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--min-alt", takesValue: true),
        FlagSpec("--json", takesValue: false),
        FlagSpec("--month", takesValue: false),
        FlagSpec("--nights", takesValue: true),
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

    if parsed.has("--month") {
        var nights = 30
        if let raw = parsed.value("--nights") {
            guard let value = Int(raw), value > 0 else {
                eprint("error: invalid --nights: \(raw)")
                return 1
            }
            nights = value
        }

        let summaries = try Planner.month(from: date, nights: nights, minAltitudeDeg: minAlt, db: db, config: config)
        if parsed.has("--json") {
            try printJSON(summaries)
        } else {
            printMonthTable(summaries)
        }
        return 0
    }

    let plans = try Planner.plan(date: date, minAltitudeDeg: minAlt, db: db, config: config)

    if parsed.has("--json") {
        try printJSON(plans)
    } else {
        try printPlanHeader(db: db, config: config, date: date)
        printPlanTable(plans)
    }
    return 0
}

/// The nights ≥ this dark-hour count AND < this Moon illumination get a `▲`
/// prefix in `printMonthTable` -- "worth circling on the calendar" nights.
private let monthHighlightMinDarkHours = 4.0
private let monthHighlightMaxMoonPercent = 30.0

private func printMonthTable(_ summaries: [NightSummary]) {
    guard !summaries.isEmpty else {
        print("no nights")
        return
    }

    print("   DÁTUM       SÖTÉT ÓRA  HOLD%   LEGJOBB CÉLPONTOK")
    for summary in summaries {
        let isHighlight = (summary.astroDarkHours ?? 0) >= monthHighlightMinDarkHours
            && summary.moonIlluminationPercent < monthHighlightMaxMoonPercent
        let prefix = isHighlight ? "▲ " : "  "
        let darkText = (summary.astroDarkHours.map { String(format: "%.1f", $0) } ?? "n/a").padding(toLength: 9, withPad: " ", startingAt: 0)
        let moonText = String(format: "%3.0f%%", summary.moonIlluminationPercent)
        let bestText = summary.bestTargets.map { "\($0.target) (\(String(format: "%.1f", $0.usableHours))h)" }.joined(separator: ", ")
        print("\(prefix)\(summary.date)  \(darkText)  \(moonText)   \(bestText.isEmpty ? "-" : bestText)")
        if let note = summary.note {
            print("      \(note)")
        }
    }
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

/// `displayName` when it differs from the raw folder `target` (folder name
/// kept alongside in parentheses), just `target` otherwise -- same
/// convention as `statsNameColumnText`.
private func planNameColumnText(_ plan: TargetPlan) -> String {
    guard plan.displayName != plan.target else { return plan.target }
    return "\(plan.displayName) (\(plan.target))"
}

private func printPlanTable(_ plans: [TargetPlan]) {
    guard !plans.isEmpty else {
        print("no targets")
        return
    }

    let names = plans.map(planNameColumnText)
    let targetWidth = max(names.map(\.count).max() ?? 7, 7)
    let header = "CÉLPONT".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    print("\(header)  MEGVAN   CÉL      KULMINÁCIÓ  MAX ALT  ABLAK          HOLD        VERDIKT")

    for (plan, nameText) in zip(plans, names) {
        let name = nameText.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
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

// MARK: - projects

/// `astrotool projects [--root R] [--json]` -- per-target pipeline status
/// (collect/stack/process/done) with a concrete Hungarian to-do list, the
/// answer to "cloudy tonight, what should I work on?" (see
/// `ProjectStatusQueries.projects`).
func cmdProjects(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let projects = try ProjectStatusQueries.projects(db: db, config: config)

    if parsed.has("--json") {
        try printJSON(projects)
    } else {
        printProjectsGrouped(projects)
    }
    return 0
}

private func printProjectsGrouped(_ projects: [ProjectState]) {
    guard !projects.isEmpty else {
        print("no targets")
        return
    }

    let groups: [(ProjectPhase, String)] = [
        (.collecting, "Gyűjtés alatt"),
        (.readyToStack, "Stackelhető"),
        (.stacked, "Feldolgozásra vár"),
        (.done, "Kész"),
    ]

    for (phase, header) in groups {
        let items = projects.filter { $0.phase == phase }
        guard !items.isEmpty else { continue }
        print("\(header) (\(items.count)):")
        for p in items {
            let have = formatHoursMinutes(p.usableIntegrationSeconds)
            let goal = p.goalSeconds.map(formatHoursMinutes) ?? "—"
            let name = p.displayName != p.target ? "\(p.displayName) (\(p.target))" : p.target
            print("  \(name)  \(have) / \(goal)")
            for todo in p.todos.prefix(2) {
                print("    - \(todo)")
            }
        }
    }
}

// MARK: - export

/// `astrotool export --target T --format astrobin|csv|md [--out PATH]` --
/// publish-ready acquisition report for one target (see
/// `AcquisitionExport`). Default behavior writes under
/// `.astro_tool/exports/` via `WriteGuard` and prints the resulting path.
/// `--out -` prints the rendered content to stdout instead of writing any
/// file. `--out PATH` writes to an arbitrary path OUTSIDE the library root
/// via plain `FileManager` (allowed since it's the user's own destination,
/// e.g. a Desktop folder to hand off to AstroBin) -- a `--out` path that
/// resolves INSIDE the library root is rejected, since inside the library
/// only `WriteGuard`'s own `.astro_tool/` paths are legal writes.
func cmdExport(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--format", takesValue: true),
        FlagSpec("--out", takesValue: true),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target"), let formatRaw = parsed.value("--format") else {
        eprint("error: --target and --format are required")
        eprint(usageText)
        return 1
    }
    guard let format = ExportFormat(rawValue: formatRaw) else {
        eprint("error: invalid --format (expected astrobin, csv, or md): \(formatRaw)")
        eprint(usageText)
        return 1
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    if let out = parsed.value("--out") {
        if out == "-" {
            let content = try AcquisitionExport.render(target: target, format: format, db: db, config: config)
            print(content, terminator: "")
            return 0
        }

        let rootURL = URL(fileURLWithPath: config.rootPath, isDirectory: true).standardizedFileURL
        let resolvedOut = URL(fileURLWithPath: out).standardizedFileURL
        guard resolvedOut.path != rootURL.path, !resolvedOut.path.hasPrefix(rootURL.path + "/") else {
            eprint("error: --out path is inside the library root; only .astro_tool/exports (the default, omit --out) may be written there")
            return 1
        }

        let content = try AcquisitionExport.render(target: target, format: format, db: db, config: config)
        try FileManager.default.createDirectory(at: resolvedOut.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: resolvedOut)
        print(resolvedOut.path)
        return 0
    }

    let writeGuard = makeWriteGuard(config: config)
    let url = try AcquisitionExport.write(target: target, format: format, timestamp: Date(), db: db, config: config, using: writeGuard)
    print(url.path)
    return 0
}

// MARK: - health

/// `astrotool health --target T [--date D] [--json]` -- R6-2's per-night
/// hardware health (cooler stability + focus drift). Without `--date`,
/// iterates every session date-dir on record for `target` (same enumeration
/// `SessionStatsQueries.sessions` uses), printing all of them -- unlike
/// `quality`/`stats --timeline`, there's no separate "gross" flag here to
/// filter n/a-only nights, so a target with mostly DSLR/unrated nights still
/// shows every session's verdicts (including the n/a ones) rather than
/// silently hiding them.
func cmdHealth(_ args: [String]) throws -> Int32 {
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

    let dates: [String]
    if let date = parsed.value("--date") {
        dates = [date]
    } else {
        dates = try SessionStatsQueries.sessions(target: target, db: db, config: config).map(\.dateRaw)
    }

    let reports = try dates.map { try NightHealth.report(target: target, date: $0, db: db, config: config) }

    if parsed.has("--json") {
        try printJSON(reports)
    } else {
        printHealthReports(reports)
    }
    return 0
}

private func printHealthReports(_ reports: [NightHealthReport]) {
    guard !reports.isEmpty else {
        print("no sessions")
        return
    }
    for r in reports {
        print("session: \(r.target) / \(r.date)")
        print("  Hűtés: \(r.cooler.verdict)")
        print("  Fókusz: \(r.focus.verdict)")
    }
}

// MARK: - panels

/// `astrotool panels --target T [--json]` -- R6-3's mosaic-panel breakdown
/// (WCS field-center clustering of the target's usable lights, across every
/// session on record).
func cmdPanels(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
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

    let report = try FieldGeometry.panels(target: target, db: db, config: config)

    if parsed.has("--json") {
        try printJSON(report)
    } else {
        printPanelReport(report)
    }
    return 0
}

private func printPanelReport(_ report: PanelReport) {
    guard !report.panels.isEmpty else {
        print("no WCS-solved frames for \(report.target)")
        return
    }

    print("PANEL  KÖZÉP RA/DEC          KERET  INTEGRÁCIÓ  ROT      SCALE")
    for panel in report.panels {
        let center = String(format: "%9.4f / %+8.4f", panel.centerRaDeg, panel.centerDecDeg)
        let integration = formatHoursMinutes(panel.integrationSeconds)
        let rotation = panel.rotationDeg.map { String(format: "%.1f°", $0) } ?? "-"
        let scale = panel.pixelScaleArcsec.map { String(format: "%.2f\"/px", $0) } ?? "-"
        print("\(panel.label.padding(toLength: 5, withPad: " ", startingAt: 0))  \(center)  \(String(panel.frameCount).padding(toLength: 5, withPad: " ", startingAt: 0))  \(integration.padding(toLength: 10, withPad: " ", startingAt: 0))  \(rotation.padding(toLength: 7, withPad: " ", startingAt: 0))  \(scale)")
    }

    if report.isUnbalanced {
        print("⚠️  kiegyenlítetlen mozaik: a panelek integrációja jelentősen eltér egymástól")
    }
}

// MARK: - solve

/// `astrotool solve --target T|--all [--frames N] [--force] [--root R]
/// [--json]` -- R7-1's plate-solve backfill: blind-solves usable lights that
/// have no WCS solution at all (typically wide-field Canon CR3 frames) via
/// Siril, persisting the result into `fits_meta.solved_*` columns only --
/// see `PlateSolver`'s doc for why the library itself is never touched.
/// `--all` iterates every target with at least one session light on record
/// that currently has no resolvable coordinate at all (median over
/// `TargetCoordinates`), instead of a single `--target`. Always exits `0`
/// once solving actually runs, even with per-frame failures or zero frames
/// solved -- only a missing Siril binary or bad input (`--target` not on
/// record, invalid `--frames`) is an error (exit 1).
func cmdSolve(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--all", takesValue: false),
        FlagSpec("--frames", takesValue: true),
        FlagSpec("--force", takesValue: false),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let targetFlag = parsed.value("--target")
    let solveAll = parsed.has("--all")
    guard targetFlag != nil || solveAll else {
        eprint("error: --target or --all is required")
        eprint(usageText)
        return 1
    }

    var maxFrames = 1
    if let raw = parsed.value("--frames") {
        guard let value = Int(raw), value > 0 else {
            eprint("error: invalid --frames: \(raw)")
            return 1
        }
        maxFrames = value
    }
    let force = parsed.has("--force")
    let isJSON = parsed.has("--json")

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let allFiles = try db.allFiles(includeMissing: false)
    let lights = allFiles.filter { $0.area == .sessions && $0.role == .light }

    let targets: [String]
    if solveAll {
        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }
        let targetsWithFrames = Set(lights.compactMap(\.target)).sorted()
        targets = targetsWithFrames.filter { t in
            let targetLights = lights.filter { $0.target == t }
            return TargetCoordinates.medianCoordinates(files: targetLights, meta: metaByFileID) == nil
        }
    } else {
        guard let target = targetFlag, lights.contains(where: { $0.target == target }) else {
            eprint("error: target not found: \(targetFlag ?? "")")
            return 1
        }
        targets = [target]
    }

    guard !targets.isEmpty else {
        if isJSON {
            try printJSON([String: SolveSummary]())
        } else {
            print("nincs koordináta nélküli célpont")
        }
        return 0
    }

    let solver: PlateSolver
    do {
        solver = try PlateSolver(sirilPath: config.rating.sirilPath)
    } catch {
        eprint("siril not found at \(config.rating.sirilPath)")
        return 1
    }

    var summaries: [String: SolveSummary] = [:]
    for t in targets {
        if !isJSON { eprint("solving \(t)…") }
        let summary = try solver.solveTarget(
            t, db: db, config: config, maxFramesPerSession: maxFrames, force: force
        ) { done, total in
            eprint("  \(t): \(done)/\(total)")
        }
        summaries[t] = summary
    }

    if isJSON {
        try printJSON(summaries)
    } else {
        for t in targets {
            guard let summary = summaries[t] else { continue }
            print("\(t): attempted \(summary.attempted), solved \(summary.solved), failed \(summary.failed), skipped \(summary.skipped)")
        }
    }
    return 0
}

// MARK: - sensor (R7-B1 item C)

/// `astrotool sensor [--measure] [--json]` -- measured per-`(camera, gain,
/// offset)` sensor characterization: bias pedestal, read noise (from a bias
/// pair), dark rate, EGAIN. Without `--measure`, prints whatever's already
/// persisted in `sensor_profile` (`db.allSensorProfiles()`) -- this never
/// runs a measurement itself, so a bare `astrotool sensor` is cheap and
/// read-only. With `--measure`, re-derives every combo's profile from
/// tracked BIAS/DARK frames first (`SensorProfiler.measure`, which upserts
/// as it goes) and prints the freshly measured set.
///
/// Either way, also warns (stderr, never stdout -- so `--json` output stays
/// parseable) about every `(camera, gain, offset)` combo actually used by
/// tracked LIGHT frames that has no USABLE profile on record yet
/// (`SensorProfiler.combosMissingProfile` -- a row with a `nil` bias level
/// counts as missing too). This is the mechanism that catches "offset
/// changed between sessions, the old master bias/profile silently stopped
/// matching" before `SessionQuality`'s electron-domain numbers quietly go
/// `nil` on the user.
func cmdSensor(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--measure", takesValue: false),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)
    let isJSON = parsed.has("--json")

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let profiles: [SensorProfileRecord]
    if parsed.has("--measure") {
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        profiles = try SensorProfiler.measure(db: db, config: config, root: root) { message in
            if !isJSON { eprint(message) }
        }
    } else {
        profiles = try db.allSensorProfiles()
    }

    let allFiles = try db.allFiles(includeMissing: false)
    let lights = allFiles.filter { $0.area == .sessions && $0.role == .light }
    var metaByFileID: [Int64: FITSMetaRecord] = [:]
    for file in lights {
        guard let id = file.id else { continue }
        if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
    }
    let missingCombos = SensorProfiler.combosMissingProfile(lights: lights, meta: metaByFileID, profiles: profiles)
    for combo in missingCombos {
        eprint("nincs mérés ehhez: \(sensorComboDescription(camera: combo.camera, gain: combo.gain, offset: combo.offset)) (készíts legalább 2 bias frame-et)")
    }

    if isJSON {
        try printJSON(profiles)
    } else {
        printSensorProfiles(profiles)
    }
    return 0
}

private func sensorComboDescription(camera: String, gain: Double?, offset: Double?) -> String {
    let gainText = gain.map(formatted) ?? "-"
    let offsetText = offset.map(formatted) ?? "-"
    return "\(camera) · gain \(gainText) · offset \(offsetText)"
}

private func printSensorProfiles(_ profiles: [SensorProfileRecord]) {
    guard !profiles.isEmpty else {
        print("nincs mért szenzor-profil (astrotool sensor --measure)")
        return
    }
    for p in profiles {
        let biasText = p.biasLevelADU.map { String(format: "%.0f ADU", $0) } ?? "n/a"
        let readNoiseText = p.readNoiseE.map { String(format: "%.2f e⁻ (mérve)", $0) } ?? "n/a (kell 2. bias frame)"
        let darkText: String
        if let darkRate = p.darkRateEPerS {
            let tempText = p.darkTempC.map { String(format: "%.1f °C", $0) } ?? "?"
            darkText = "dark \(tempText): \(String(format: "%.4f", darkRate)) e⁻/s"
        } else {
            darkText = "dark n/a (nincs dark ehhez a kombóhoz)"
        }
        let egainText = p.egain.map { String(format: "%.3f", $0) } ?? "n/a"
        print("\(sensorComboDescription(camera: p.camera, gain: p.gain, offset: p.offset)): bias \(biasText), leolvasási zaj \(readNoiseText), \(darkText), EGAIN \(egainText)")
    }
}

// MARK: - ingest-dss (R7-B2)

/// `astrotool ingest-dss [--root R] [--json]` -- harvests star metrics from
/// every tracked `<frame>.info.txt` (DeepSkyStacker's own per-light
/// measurement sidecar) into `ratings` (`source == "dss"`, never clobbering
/// an existing astrotool/Siril rating), and the user's own accept/reject
/// decisions from every tracked `.dssfilelist`'s `CHECKED` column into
/// `user_verdicts`. Deliberately NOT run automatically by `scan
/// --refresh-meta` -- a DSS project tree can be large, and this way running
/// it is always an explicit, predictable choice rather than a surprise cost
/// tacked onto an ordinary rescan.
func cmdIngestDSS(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)
    let isJSON = parsed.has("--json")

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
    let summary = try DSSIngest.ingest(db: db, config: config, root: root) { message in
        if !isJSON { eprint(message) }
    }

    if isJSON {
        try printJSON(summary)
    } else {
        print(
            "info.txt feldolgozva: \(summary.infoFilesParsed), rating beszúrva/frissítve: \(summary.ratingsUpserted), "
                + ".dssfilelist feldolgozva: \(summary.filelistsParsed), döntés rögzítve: \(summary.verdictsRecorded), "
                + "kihagyva: \(summary.skipped)"
        )
    }
    return 0
}

// MARK: - expose (R7-B3)

/// `astrotool expose [--target T] [--json] [--root R]` -- the sub-exposure
/// optimizer + relative-SNR advisor (`ExposureAdvisor`). Without `--target`,
/// reports one compact row per target that has usable light frames
/// (`ExposureAdvisor.adviseAll`); with `--target`, the full advice block for
/// that one target, every `advice` sentence printed in full.
func cmdExpose(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)
    let isJSON = parsed.has("--json")

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    if let target = parsed.value("--target") {
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        if isJSON {
            try printJSON(advice)
        } else {
            printExposeDetail(advice)
        }
    } else {
        let all = try ExposureAdvisor.adviseAll(db: db, config: config)
        if isJSON {
            try printJSON(all)
        } else {
            printExposeTable(all)
        }
    }
    return 0
}

private func printExposeDetail(_ advice: ExposureAdvice) {
    print("Célpont: \(advice.target)")
    if let sessionDate = advice.sessionDate {
        print("Session: \(sessionDate)")
    }
    if let camera = advice.camera {
        let gainText = advice.gain.map { String(format: "%g", $0) } ?? "-"
        print("Kamera: \(camera) · gain \(gainText)")
    }
    if let descriptor = advice.setupDescriptor {
        print("Setup: \(descriptor)")
    }

    if let reason = advice.notAvailableReason {
        print("n/a: \(reason)")
    } else {
        if let current = advice.currentSubSeconds {
            print("Jelenlegi sub: \(String(format: "%.1f", current)) s")
        }
        if let channel = advice.weakestChannel, let skyRate = advice.skyRateEPerSPx {
            print("Leggyengébb csatorna: \(channel) (\(String(format: "%.4f", skyRate)) e⁻/s/px)")
        }
        if let optimal = advice.optimalSubSeconds {
            print("Ideális sub (elméleti): \(String(format: "%.1f", optimal)) s")
        }
        if let recommended = advice.recommendedSubSeconds {
            let capText = advice.capReason.map { " (\($0) miatt korlátozva)" } ?? ""
            print("Ajánlott sub: \(String(format: "%.1f", recommended)) s\(capText)")
        }
        if let c10 = advice.recommendedSubSecondsC10 {
            print("Rövidebb alternatíva (C=10%): \(String(format: "%.1f", c10)) s")
        }
    }

    print("Összes használható integráció: \(String(format: "%.2f", advice.totalUsableSeconds / 3600)) óra")

    if !advice.advice.isEmpty {
        print("Tanács:")
        for line in advice.advice {
            print("  - \(line)")
        }
    }
}

private func printExposeTable(_ all: [ExposureAdvice]) {
    guard !all.isEmpty else {
        print("nincs adat egyetlen célponthoz sem")
        return
    }

    let targetWidth = max(all.map(\.target.count).max() ?? 10, 10)
    let header = "CÉLPONT".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    print("\(header)  MOST      AJÁNLOTT  LEOLV.ZAJ  TANÁCS")
    for advice in all {
        let target = advice.target.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
        let current = (advice.currentSubSeconds.map { String(format: "%.0f s", $0) } ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0)
        let recommended = (advice.recommendedSubSeconds.map { String(format: "%.0f s", $0) } ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0)
        let share = (advice.currentReadNoiseSharePercent.map { String(format: "%.0f%%", $0) } ?? "-").padding(toLength: 9, withPad: " ", startingAt: 0)
        let tip = advice.notAvailableReason ?? advice.advice.first ?? "-"
        print("\(target)  \(current)  \(recommended)  \(share)  \(tip)")
    }
}

// MARK: - stacklist (R7-B4)

/// Selects the best frames of one session and exports the artifacts the
/// user's real stacking tools consume: a `.astro_tool/stacklists/<slug>/
/// lights/` hardlink folder, a `.dssfilelist`, and a `.ssf` Siril script.
/// Unlike `link-calib`, there's no `--dry-run`/`--yes` gate -- both the
/// selection and the export are read-only against the user's actual light
/// frames (hardlink-only, additive, idempotent), so this always runs both
/// steps and reports what it did.
func cmdStackList(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--keep", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    guard let target = parsed.value("--target"), let date = parsed.value("--date") else {
        eprint("error: --target and --date are required")
        eprint(usageText)
        return 1
    }

    var keepFraction = 0.8
    if let keepText = parsed.value("--keep") {
        guard let parsedKeep = Double(keepText), parsedKeep > 0, parsedKeep <= 1 else {
            eprint("error: --keep must be a number in (0, 1]")
            return 1
        }
        keepFraction = parsedKeep
    }

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let selection = try StackList.select(target: target, date: date, keepFraction: keepFraction, db: db, config: config)
    let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
    let writeGuard = makeWriteGuard(config: config)
    let stacklistDir = try StackList.export(selection, root: root, using: writeGuard)

    if parsed.has("--json") {
        struct Output: Encodable {
            var selection: StackSelection
            var stackListDir: String
        }
        try printJSON(Output(selection: selection, stackListDir: stacklistDir.path))
    } else {
        printStackSelection(selection)
        print("exportálva: \(stacklistDir.path)")
    }
    return 0
}

private func printStackSelection(_ selection: StackSelection) {
    print("target: \(selection.target)")
    print("date: \(selection.date)")
    print("összes használható: \(selection.totalFrames)")
    print("kiválasztva: \(selection.selectedFrames)")
    if !selection.criteria.isEmpty {
        print("szempontok:")
        for line in selection.criteria {
            print("  - \(line)")
        }
    }
}

// MARK: - stacks (R8-1)

/// `astrotool stacks [--target T] [--json] [--root R]` -- R8-1's stack-file
/// discovery (`StackDiscovery.discover`): every already-created stack/
/// processed output on record for every target, wherever it actually lives
/// -- not just the canonical `stacks/<target>/<date>/` location. Without
/// `--target`, every target with at least one discovered stack (plus a
/// trailing "Besorolatlan" group for stack-looking files matched to no known
/// target at all); with `--target`, only that one target's group.
func cmdStacks(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    let reports = try StackDiscovery.discover(db: db, config: config)
    let selected: [TargetStacks]
    if let target = parsed.value("--target") {
        selected = reports.filter { $0.target == target }
    } else {
        selected = reports
    }

    if parsed.has("--json") {
        try printJSON(selected)
    } else {
        printStackReports(selected)
    }
    return 0
}

private func printStackReports(_ reports: [TargetStacks]) {
    let nonEmpty = reports.filter { !$0.stacks.isEmpty }
    guard !nonEmpty.isEmpty else {
        print("nincs felfedezett stack")
        return
    }

    for report in nonEmpty {
        print("\(report.displayName)  (\(report.stacks.count) stack)")
        print("  FÁJL                                              HELY        KERET×SUB      ÖSSZIDŐ  MÉRET      DÁTUM")
        for stack in report.stacks {
            let name = (stack.path as NSString).lastPathComponent
            let location = locationLabel(for: stack.path)
            let framesSub = stack.framesFromName.map { frames in
                "\(frames)×\(stack.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?")s"
            } ?? "-"
            let total = stack.totalSecondsFromName.map(formatHoursMinutes) ?? "-"
            let size = formatBytes(stack.sizeBytes)
            let date = stack.sessionDate ?? "-"
            var line = "  \(name.padding(toLength: 50, withPad: " ", startingAt: 0)) \(location.padding(toLength: 10, withPad: " ", startingAt: 0))  \(framesSub.padding(toLength: 13, withPad: " ", startingAt: 0))  \(total.padding(toLength: 7, withPad: " ", startingAt: 0))  \(size.padding(toLength: 9, withPad: " ", startingAt: 0))  \(date)"
            if stack.kind != "stack" {
                line += "  [\(stack.kind)]"
            }
            print(line)
        }
        if let best = report.stacks.first(where: { $0.totalSecondsFromName != nil }) {
            let framesText = best.framesFromName.map(String.init) ?? "?"
            let subText = best.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?"
            print("  legjobb: \(framesText)×\(subText) s (\(formatHoursMinutes(best.totalSecondsFromName ?? 0)))")
        }
        print("")
    }
}

/// `"stacks"`/`"processed"`/`"sessions"`/`"gyökér"` (a top-level file with no
/// area subfolder at all -- practically never happens, but keeps every path
/// labeled) from the path's own first component, purely for the human table
/// -- the JSON output carries the full `path` instead.
private func locationLabel(for path: String) -> String {
    let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    switch top {
    case "stacks": return "stacks"
    case "processed": return "processed"
    case "sessions": return "sessions"
    default: return "gyökér"
    }
}

// MARK: - report (R7-B5)

/// `astrotool report --target T --date D [--out -] [--root R]` -- one
/// night's self-contained HTML report card (see `NightReport`). Default
/// behavior writes under `.astro_tool/reports/` via `WriteGuard` and prints
/// the resulting path; `--out -` prints the rendered HTML to stdout instead
/// (same convention as `export --out -`).
func cmdReport(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--date", takesValue: true),
        FlagSpec("--out", takesValue: true),
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

    if parsed.value("--out") == "-" {
        let html = try NightReport.render(target: target, date: date, db: db, config: config)
        print(html, terminator: "")
        return 0
    }

    let writeGuard = makeWriteGuard(config: config)
    let url = try NightReport.write(target: target, date: date, timestamp: Date(), db: db, config: config, using: writeGuard)
    print(url.path)
    return 0
}

// MARK: - target-report (R8-2)

/// `astrotool target-report --target T [--out -] [--root R]` -- the full
/// "everything about one target" self-contained HTML report (see
/// `TargetReport`). Default behavior writes under `.astro_tool/reports/`
/// via `WriteGuard` and prints the resulting path; `--out -` prints the
/// rendered HTML to stdout instead (same convention as `report --out -`/
/// `export --out -`). An unknown target surfaces as `AstroError.pathNotFound`,
/// caught by `main.swift`'s generic handler (exit code 1), same as every
/// other command that resolves a target this way.
func cmdTargetReport(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--out", takesValue: true),
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

    if parsed.value("--out") == "-" {
        let html = try TargetReport.render(target: target, db: db, config: config)
        print(html, terminator: "")
        return 0
    }

    let writeGuard = makeWriteGuard(config: config)
    let url = try TargetReport.write(target: target, db: db, config: config, using: writeGuard)
    print(url.path)
    return 0
}
