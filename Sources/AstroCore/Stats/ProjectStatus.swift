import Foundation

/// Where a target sits in the collect -> stack -> process pipeline. See
/// `ProjectStatusQueries.projects` for exactly how each phase is derived.
public enum ProjectPhase: String, Codable, Sendable, Equatable {
    /// Usable integration is below the goal (or, with no goal set, below
    /// `config.stats.collectingThresholdSeconds` and there's no stack at
    /// all yet) -- still out shooting this target.
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
    /// `max(goal - usable, 0)`; `nil` if there's no goal tag.
    public var missingSeconds: Double?
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
        missingSeconds: Double? = nil,
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
        self.missingSeconds = missingSeconds
        self.latestSessionDate = latestSessionDate
        self.latestStackDate = latestStackDate
        self.latestProcessedDate = latestProcessedDate
        self.todos = todos
    }

    private enum CodingKeys: String, CodingKey {
        case target, displayName, phase, usableIntegrationSeconds, goalSeconds, missingSeconds,
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
        missingSeconds = try c.decodeIfPresent(Double.self, forKey: .missingSeconds)
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

        let states = try stats.map { stat -> ProjectState in
            let sessions = try SessionStatsQueries.sessions(target: stat.target, db: db, config: config)
            return buildState(stat: stat, sessions: sessions, files: files, config: config)
        }

        return states.sorted { a, b in
            let groupA = a.phase == .done ? 1 : 0
            let groupB = b.phase == .done ? 1 : 0
            if groupA != groupB { return groupA < groupB }
            let missingA = a.missingSeconds ?? -Double.infinity
            let missingB = b.missingSeconds ?? -Double.infinity
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
        config: AstroConfig
    ) -> ProjectState {
        let target = stat.target
        let excludedSet = Set(stat.excludedSessionDates)

        let allSessionSpans = spans(area: .sessions, target: target, files: files, config: config)
        let actionableSessionSpans = allSessionSpans
            .filter { !excludedSet.contains($0.raw) }
            .sorted { $0.raw < $1.raw }
        let stackSpans = spans(area: .stacks, target: target, files: files, config: config)
        let processedSpans = spans(area: .processed, target: target, files: files, config: config)

        // Deliberately from the ACTIONABLE (non-excluded) spans only -- an
        // excluded (`_hibas`) night dated after the real work is done must
        // not drag the target back out of `.done`/`.stacked` into
        // `.readyToStack`, matching "`_hibas` ignored in phase" below.
        let latestSessionDate = actionableSessionSpans.map(\.start).max()
        let latestStackDate = stackSpans.map(\.start).max()
        let latestProcessedDate = processedSpans.map(\.start).max()

        let goalSeconds = GoalTag.parse(tags: stat.tags)
        let missingSeconds = goalSeconds.map { max(0, $0 - stat.usableIntegrationSeconds) }

        let sessionsNeedingStack = actionableSessionSpans
            .filter { session in !stackSpans.contains { overlaps($0, session) } }
        let stacksNeedingProcess = stackSpans
            .filter { stack in !processedSpans.contains { overlaps($0, stack) } }
            .sorted { $0.raw < $1.raw }

        // MARK: Phase
        let hasAnyStack = !stackSpans.isEmpty
        let underGoal = goalSeconds.map { stat.usableIntegrationSeconds < $0 } ?? false
        let noStackAndLow = !hasAnyStack && stat.usableIntegrationSeconds < config.stats.collectingThresholdSeconds

        let phase: ProjectPhase
        if underGoal || noStackAndLow {
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
        if let goalSeconds, let missingSeconds, missingSeconds > 0 {
            todos.append("hiányzik még \(formatHours(missingSeconds)) óra a célhoz (goal:\(formatGoalHours(goalSeconds))h)")
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
            missingSeconds: missingSeconds,
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
