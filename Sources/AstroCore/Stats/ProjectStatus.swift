import Foundation

/// Where a target sits in the collect -> stack -> process pipeline. See
/// `ProjectStatusQueries.projects` for exactly how each phase is derived.
public enum ProjectPhase: String, Codable, Sendable, Equatable {
    /// Usable integration is below the explicit or automatic goal -- still
    /// out shooting this target.
    case collecting = "gyujtes"
    /// Has session data whose date isn't covered by any stack yet, and data
    /// collection looks done for now (no goal, or the goal is already met).
    case readyToStack = "stackelheto"
    /// The latest session data has a stack, but that stack (or a later one)
    /// has no processed output yet.
    case stacked = "feldolgozasra_var"
    /// Processed output covers the latest stack, which covers the latest
    /// session -- nothing outstanding.
    case done = "kesz"
}

/// One target's place in the pipeline, plus a concrete Hungarian to-do list
/// -- the answer to "cloudy tonight, what should I work on?".
public struct ProjectState: Codable, Sendable, Equatable {
    public var target: String
    /// Resolved catalog designation/Hungarian common name for `target` --
    /// same `TargetStats.displayName` this comes straight from (via
    /// `StatsQueries.perTarget`), so it's already override-aware
    /// (`name:<text>` tag).
    public var displayName: String
    public var phase: ProjectPhase
    public var usableIntegrationSeconds: Double
    public var goalSeconds: Double?
    /// Provenance for `goalSeconds`; `nil` only in older decoded payloads.
    public var goalSource: IntegrationGoalSource?
    /// `max(goal - usable, 0)`; `nil` only in older decoded payloads.
    public var missingSeconds: Double?
    /// Per-filter usable/goal/missing rows from `FilterGoalQueries.merge`.
    /// Older serialized states decode this additive field as an empty list.
    public var filterGoals: [FilterIntegration]
    /// Effective overall goal (explicit tag or automatic reference).
    /// Older decoded payloads without one fall back to the sum of their
    /// independently configured filter goals.
    public var effectiveGoalSeconds: Double? {
        if let goalSeconds { return goalSeconds }
        let values = filterGoals.compactMap(\.goalSeconds)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    /// Largest currently outstanding per-filter deficit, if any.
    public var largestFilterDeficitSeconds: Double? {
        filterGoals.compactMap(\.missingSeconds).filter { $0 > 0 }.max()
    }
    /// The latest (`SessionDate.start`) session date-dir on record for this
    /// target, across ALL session dates including excluded (`_hibas`) ones
    /// -- same convention as `TargetStats.lastSessionDate`.
    public var latestSessionDate: String?
    /// The latest stack date-dir on record (`stacks/<target>/<date>`).
    public var latestStackDate: String?
    /// The latest processed-output date-dir on record
    /// (`processed/<target>/<date>`).
    public var latestProcessedDate: String?
    /// Concrete, Hungarian, actionable to-do lines -- see
    /// `ProjectStatusQueries.projects`'s doc for the exact rules and order.
    public var todos: [String]

    public init(
        target: String,
        displayName: String? = nil,
        phase: ProjectPhase,
        usableIntegrationSeconds: Double,
        goalSeconds: Double? = nil,
        goalSource: IntegrationGoalSource? = nil,
        missingSeconds: Double? = nil,
        filterGoals: [FilterIntegration] = [],
        latestSessionDate: String? = nil,
        latestStackDate: String? = nil,
        latestProcessedDate: String? = nil,
        todos: [String] = []
    ) {
        self.target = target
        self.displayName = displayName ?? target.replacingOccurrences(of: "_", with: " ")
        self.phase = phase
        self.usableIntegrationSeconds = usableIntegrationSeconds
        self.goalSeconds = goalSeconds
        self.goalSource = goalSource
        self.missingSeconds = missingSeconds
        self.filterGoals = filterGoals
        self.latestSessionDate = latestSessionDate
        self.latestStackDate = latestStackDate
        self.latestProcessedDate = latestProcessedDate
        self.todos = todos
    }

    private enum CodingKeys: String, CodingKey {
        case target, displayName, phase, usableIntegrationSeconds, goalSeconds, goalSource, missingSeconds, filterGoals,
             latestSessionDate, latestStackDate, latestProcessedDate, todos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        // Absent in JSON produced before this field existed -- fall back to
        // the cleaned target name, same default the memberwise `init` uses.
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? target.replacingOccurrences(of: "_", with: " ")
        phase = try c.decode(ProjectPhase.self, forKey: .phase)
        usableIntegrationSeconds = try c.decode(Double.self, forKey: .usableIntegrationSeconds)
        goalSeconds = try c.decodeIfPresent(Double.self, forKey: .goalSeconds)
        goalSource = try c.decodeIfPresent(IntegrationGoalSource.self, forKey: .goalSource)
        missingSeconds = try c.decodeIfPresent(Double.self, forKey: .missingSeconds)
        filterGoals = try c.decodeIfPresent([FilterIntegration].self, forKey: .filterGoals) ?? []
        latestSessionDate = try c.decodeIfPresent(String.self, forKey: .latestSessionDate)
        latestStackDate = try c.decodeIfPresent(String.self, forKey: .latestStackDate)
        latestProcessedDate = try c.decodeIfPresent(String.self, forKey: .latestProcessedDate)
        todos = try c.decodeIfPresent([String].self, forKey: .todos) ?? []
    }
}

/// Builds each target's `ProjectState` from the scanned library. Reads only
/// from `Database` (via `StatsQueries`/`SessionStatsQueries`/`allFiles`) --
/// never touches the filesystem.
public enum ProjectStatusQueries {
    /// One entry per target `StatsQueries.perTarget` knows about (same
    /// target universe), sorted so the most actionable target comes first:
    /// every non-`.done` target before every `.done` one, then by
    /// `missingSeconds` descending (targets with no goal sort after ones
    /// that have outstanding hours, within the same phase group), then by
    /// target name ascending.
    public static func projects(db: Database, config: AstroConfig) throws -> [ProjectState] {
        let stats = try StatsQueries.perTarget(db: db, config: config)
        let files = try db.allFiles(includeMissing: false)
        // R8-1: `StackDiscovery` finds stack files that a plain `area ==
        // .stacks` scan would miss (a finished stack sitting loose in the
        // session folder, or at the target's `stacks/` root with no date
        // subfolder) -- computed once here, up front, rather than per
        // target inside `buildState` (which would re-run the same
        // whole-library `discover` scan once per target).
        let discoveredByTarget = Dictionary(
            uniqueKeysWithValues: try StackDiscovery.discover(db: db, config: config).map { ($0.target, $0.stacks) }
        )

        let states = try stats.map { stat -> ProjectState in
            let sessions = try SessionStatsQueries.sessions(target: stat.target, db: db, config: config)
            let discoveredStacks = discoveredByTarget[stat.target] ?? []
            let breakdown = try FilterBreakdownQueries.breakdown(db: db, config: config, target: stat.target)
            let filterGoals = FilterGoalQueries.merge(breakdown: breakdown, tags: stat.tags)
            return buildState(
                stat: stat,
                sessions: sessions,
                files: files,
                discoveredStacks: discoveredStacks,
                filterGoals: filterGoals,
                config: config
            )
        }

        return states.sorted { a, b in
            let groupA = a.phase == .done ? 1 : 0
            let groupB = b.phase == .done ? 1 : 0
            if groupA != groupB { return groupA < groupB }
            let missingA = max(a.missingSeconds ?? -Double.infinity, a.largestFilterDeficitSeconds ?? -Double.infinity)
            let missingB = max(b.missingSeconds ?? -Double.infinity, b.largestFilterDeficitSeconds ?? -Double.infinity)
            if missingA != missingB { return missingA > missingB }
            return a.target < b.target
        }
    }

    // MARK: - Per-target date span

    private struct DatedSpan {
        let raw: String
        let start: String
        let end: String
    }

    private static func spans(
        area: LibraryArea,
        target: String,
        files: [FileRecord],
        config: AstroConfig
    ) -> [DatedSpan] {
        let dates = Set(files.filter { $0.target == target && $0.area == area }.compactMap(\.sessionDate))
        return dates.compactMap { date in
            guard let parsed = SessionDateParser.parse(date, patterns: config.intentional) else { return nil }
            return DatedSpan(raw: date, start: parsed.start, end: parsed.end)
        }
    }

    private static func overlaps(_ a: DatedSpan, _ b: DatedSpan) -> Bool {
        a.start <= b.end && b.start <= a.end
    }

    // MARK: - Per-target assembly

    private static func buildState(
        stat: TargetStats,
        sessions: [SessionDetail],
        files: [FileRecord],
        discoveredStacks: [StackFile],
        filterGoals: [FilterIntegration],
        config: AstroConfig
    ) -> ProjectState {
        let target = stat.target
        let excludedSet = Set(stat.excludedSessionDates)

        let allSessionSpans = spans(area: .sessions, target: target, files: files, config: config)
        let actionableSessionSpans = allSessionSpans
            .filter { !excludedSet.contains($0.raw) }
            .sorted { $0.raw < $1.raw }
        // R8-1: union `StackDiscovery`'s own (target, date) evidence into
        // the plain `area == .stacks` spans -- a discovered stack sitting
        // outside the canonical `stacks/<target>/<date>/` tree (e.g. loose
        // in the session folder, or the target's `stacks/` root with no
        // date subfolder at all) still counts as "this date is stacked".
        // Deduped by raw date-dir name (`Dictionary(uniqueKeysWithValues:)`
        // over `raw` -- the same span computed both ways is kept once).
        let areaStackSpans = spans(area: .stacks, target: target, files: files, config: config)
        let discoveredStackSpans = discoveredStacks.compactMap { stack -> DatedSpan? in
            guard let date = stack.sessionDate, let parsed = SessionDateParser.parse(date, patterns: config.intentional) else { return nil }
            return DatedSpan(raw: date, start: parsed.start, end: parsed.end)
        }
        let stackSpans = Array(
            Dictionary((areaStackSpans + discoveredStackSpans).map { ($0.raw, $0) }, uniquingKeysWith: { first, _ in first }).values
        )
        let processedSpans = spans(area: .processed, target: target, files: files, config: config)

        // Deliberately from the ACTIONABLE (non-excluded) spans only -- an
        // excluded (`_hibas`) night dated after the real work is done must
        // not drag the target back out of `.done`/`.stacked` into
        // `.readyToStack`, matching "`_hibas` ignored in phase" below.
        let latestSessionDate = actionableSessionSpans.map(\.start).max()
        let latestStackDate = stackSpans.map(\.start).max()
        let latestProcessedDate = processedSpans.map(\.start).max()

        let effectiveGoal = IntegrationGoalCalculator.effectiveGoal(
            tags: stat.tags,
            rule: config.integrationReference,
            setup: ImagingSetupProfile.defaultSetup(in: config.imagingSetups),
            target: TargetCatalog.target(matchingFolderName: stat.target)
        )
        let goalSeconds = effectiveGoal.seconds
        let missingSeconds = max(0, goalSeconds - stat.usableIntegrationSeconds)

        let sessionsNeedingStack = actionableSessionSpans
            .filter { session in !stackSpans.contains { overlaps($0, session) } }
        let stacksNeedingProcess = stackSpans
            .filter { stack in !processedSpans.contains { overlaps($0, stack) } }
            .sorted { $0.raw < $1.raw }

        // MARK: Phase
        let hasAnyStack = !stackSpans.isEmpty
        let underGoal = stat.usableIntegrationSeconds < goalSeconds
        let underFilterGoal = filterGoals.contains { ($0.missingSeconds ?? 0) > 0 }
        let noStackAndLow = !hasAnyStack && stat.usableIntegrationSeconds < config.stats.collectingThresholdSeconds

        let phase: ProjectPhase
        if underGoal || underFilterGoal || noStackAndLow {
            phase = .collecting
        } else if !sessionsNeedingStack.isEmpty {
            phase = .readyToStack
        } else if let latestProcessedDate, let latestStackDate, let latestSessionDate,
                  latestProcessedDate >= latestStackDate, latestStackDate >= latestSessionDate {
            phase = .done
        } else {
            phase = .stacked
        }

        // MARK: Todos
        var todos: [String] = []

        for session in sessionsNeedingStack {
            todos.append("készíts stacket: \(target)/\(session.raw)")
        }
        for stack in stacksNeedingProcess {
            todos.append("dolgozd fel: stacks/\(target)/\(stack.raw)")
        }
        if missingSeconds > 0 {
            let sourceText = effectiveGoal.source == .explicitTag
                ? "goal:\(formatGoalHours(goalSeconds))h"
                : "automatikus célpontfényesség + APS-C f/5 referencia"
            todos.append("hiányzik még \(formatHours(missingSeconds)) óra a célhoz (\(sourceText))")
        }
        for entry in filterGoals
            .filter({ ($0.missingSeconds ?? 0) > 0 })
            .sorted(by: { $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending }) {
            guard let missing = entry.missingSeconds, let goal = entry.goalSeconds else { continue }
            todos.append(
                "hiányzik még \(formatHours(missing)) óra \(entry.filter) szűrőből (goal:\(entry.filter)=\(formatGoalHours(goal))h)"
            )
        }

        let sessionDetailByDate = Dictionary(uniqueKeysWithValues: sessions.map { ($0.dateRaw, $0) })
        for session in actionableSessionSpans {
            if let detail = sessionDetailByDate[session.raw], !detail.hasReadme {
                todos.append("nincs README: \(target)/\(session.raw)")
            }
        }
        for date in stat.excludedSessionDates.sorted() {
            let label = SessionDateParser.parse(date, patterns: config.intentional)?.label ?? "hibas"
            todos.append("kizárt session: \(date) (\(label))")
        }

        return ProjectState(
            target: target,
            displayName: stat.displayName,
            phase: phase,
            usableIntegrationSeconds: stat.usableIntegrationSeconds,
            goalSeconds: goalSeconds,
            goalSource: effectiveGoal.source,
            missingSeconds: missingSeconds,
            filterGoals: filterGoals,
            latestSessionDate: latestSessionDate,
            latestStackDate: latestStackDate,
            latestProcessedDate: latestProcessedDate,
            todos: todos
        )
    }

    // MARK: - Formatting

    private static func formatHours(_ seconds: Double) -> String {
        String(format: "%.1f", seconds / 3600.0)
    }

    /// Same value the user wrote in the `goal:Xh` tag -- an integral number
    /// of hours prints without a decimal point (`"goal:6h"`, not
    /// `"goal:6.0h"`).
    private static func formatGoalHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        if hours.rounded() == hours {
            return String(Int(hours))
        }
        return String(format: "%.1f", hours)
    }
}
