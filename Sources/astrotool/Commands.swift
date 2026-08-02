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
  rate          [--root R] --target T [--date D] [--json] [--no-siril]
  stats         [--root R] [--target T] [--json]
  calib         [--root R] [--json]
  match         [--root R] --target T --date D [--json]
  new-session   --catalog CAT --name NAME --date D [--root R] [--json]
  config        (show|path) [--root R] [--json]

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
        printAuditFindings(findings)
        if let suggestMessage { print(suggestMessage) }
    }
    return 0
}

private func printAuditFindings(_ findings: [Finding]) {
    guard !findings.isEmpty else {
        print("no findings")
        return
    }

    let order: [Severity] = [.sureError, .suspicious, .probablyIntentional]
    for severity in order {
        let group = findings.filter { $0.severity == severity }
        guard !group.isEmpty else { continue }

        print("\(severity.rawValue) (\(group.count))")
        for finding in group {
            print("\(finding.severity.rawValue)  \(finding.category)  \(finding.path)")
            for line in finding.message.components(separatedBy: "\n") {
                print("    \(line)")
            }
        }
    }
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

private func printRateTable(_ results: [FrameScore]) {
    guard !results.isEmpty else {
        print("no frames rated")
        return
    }

    let pathWidth = results.map { $0.path.count }.max() ?? 4
    let header = "PATH".padding(toLength: pathWidth, withPad: " ", startingAt: 0)
    print("\(header)  SCORE      OUTLIER")
    for r in results {
        let path = r.path.padding(toLength: pathWidth, withPad: " ", startingAt: 0)
        let score = String(format: "%9.4f", r.score)
        let marker = r.isOutlier ? "*" : ""
        print("\(path)  \(score)  \(marker)")
    }
}

// MARK: - stats

func cmdStats(_ args: [String]) throws -> Int32 {
    let specs = [
        FlagSpec("--root", takesValue: true),
        FlagSpec("--target", takesValue: true),
        FlagSpec("--json", takesValue: false),
    ]
    let parsed = try ArgParser.parse(args, specs: specs)

    let config = try resolveConfig(rootFlag: parsed.value("--root"))
    let db = try makeDatabase(config: config)
    try hintIfEmpty(db)

    if let target = parsed.value("--target") {
        guard let stats = try StatsQueries.target(target, db: db, config: config) else {
            eprint("error: target not found: \(target)")
            return 1
        }
        if parsed.has("--json") {
            try printJSON(stats)
        } else {
            printSingleTargetStats(stats)
        }
    } else {
        let all = try StatsQueries.perTarget(db: db, config: config)
        if parsed.has("--json") {
            try printJSON(all)
        } else {
            printStatsTable(all)
        }
    }
    return 0
}

private func formatHoursMinutes(_ seconds: Double) -> String {
    let totalMinutes = Int((seconds / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return String(format: "%d:%02d", hours, minutes)
}

private func printStatsTable(_ stats: [TargetStats]) {
    guard !stats.isEmpty else {
        print("no targets")
        return
    }

    let targetWidth = max(stats.map { $0.target.count }.max() ?? 6, 6)
    let header = "TARGET".padding(toLength: targetWidth, withPad: " ", startingAt: 0)
    print("\(header)  INTEGRATION  SESSIONS  LAST DATE   WIDE")
    for s in stats {
        let name = s.target.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
        let integration = formatHoursMinutes(s.totalIntegrationSeconds).padding(toLength: 11, withPad: " ", startingAt: 0)
        let sessions = String(s.sessionDates.count).padding(toLength: 8, withPad: " ", startingAt: 0)
        let last = (s.lastSessionDate ?? "-").padding(toLength: 11, withPad: " ", startingAt: 0)
        let wide = s.isWideField ? "wide" : ""
        print("\(name)  \(integration)  \(sessions)  \(last)  \(wide)")
    }
}

private func printSingleTargetStats(_ s: TargetStats) {
    print("target: \(s.target)")
    print("integration: \(formatHoursMinutes(s.totalIntegrationSeconds))")
    print("sessions: \(s.sessionDates.count)")
    print("last date: \(s.lastSessionDate ?? "-")")
    print("wide field: \(s.isWideField ? "yes" : "no")")
    print("cameras: \(s.cameras.joined(separator: ", "))")
    print("filters: \(s.filters.joined(separator: ", "))")
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
