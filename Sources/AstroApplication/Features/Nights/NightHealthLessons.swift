import AstroCore
import Foundation

/// One repeated hardware-health pattern across several recent sessions --
/// ideation #9 ("Éjszaka-tanulságok banner"). `NightHealth.report` (see that
/// type's own doc comment) only ever verdicts ONE night; this is the first
/// place anything looks across several nights for a pattern worth naming,
/// e.g. "the cooler missed set-point on 4 of your last 6 nights". Carries no
/// display string of its own -- the same "domain model, no UI string" split
/// `ClearNightProjection`/`HomeSnapshot.Highlight` already use; `HomeView`
/// builds the actual sentence (with its actionable hint) from `kind` plus
/// these two counts.
public struct NightHealthLesson: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case coolerNotHoldingSetpoint
        case focusDrift
    }
    public let kind: Kind
    /// How many of `sessionCount` sessions (that actually HAD the relevant
    /// reading) showed the problem -- always named alongside `sessionCount`,
    /// never summarized as a vague "often"/"usually" (this feature's own
    /// honesty rail; see `NightHealthLessons`' doc comment).
    public let failingCount: Int
    /// How many recent sessions actually carried the relevant reading at
    /// all -- NOT `NightHealthLessons.lookbackSessionCount` itself, since a
    /// DSLR night (no cooler data) or a night with too few rated frames (no
    /// focus trend) never counts toward this denominator.
    public let sessionCount: Int
    public var id: String {
        switch kind {
        case .coolerNotHoldingSetpoint: "coolerNotHoldingSetpoint|\(failingCount)|\(sessionCount)"
        case .focusDrift: "focusDrift|\(failingCount)|\(sessionCount)"
        }
    }

    public init(kind: Kind, failingCount: Int, sessionCount: Int) {
        self.kind = kind
        self.failingCount = failingCount
        self.sessionCount = sessionCount
    }
}

/// Aggregates `NightHealth.report`'s per-night cooler/focus verdicts across
/// the last `lookbackSessionCount` (~8) sessions with the relevant data, and
/// names a `NightHealthLesson` only when a real pattern repeats -- ideation
/// #9. Reads verdict STRINGS rather than `NightHealth`'s own private
/// thresholds (`coolerOutOfBandFractionThreshold` etc. are `internal` to
/// `AstroCore`, not visible from this module) -- the same "verdict string is
/// the public contract" convention `SharedComponents.VerdictChip.color(for:)`
/// already relies on (`verdict.hasPrefix("stabil")`), so this can never
/// silently drift from what `NightHealth` itself actually decided.
///
/// Honesty rails (the whole reason this is its own small type rather than a
/// string built inline at the call site):
///  - A lesson never fires from fewer than `minimumSessionsWithData` sessions
///    that actually HAVE the relevant reading -- absence of a lesson is the
///    GOOD state here, never a fabricated "stable" claim from thin data.
///  - The failing fraction must be STRICTLY over `failureFractionThreshold`
///    (50%) -- "3 of 8" (37.5%) stays silent, and so does an exact "4 of 8"
///    (50.0%, a bare plurality, not "more nights than not").
///  - Every lesson names its own numerator/denominator (`NightHealthLesson`'s
///    own two `Int`s) -- nothing is ever summarized as "often"/"usually".
///  - The focus-drift lesson counts ONLY sessions where `FocusHealth` found
///    an actual measurable trend (`verdict` not "n/a"), and only the
///    "fókuszcsúszás gyanú" (suspected drift) verdict counts as a failure --
///    a "javuló FWHM" (improving) night is real data, but never a problem.
public enum NightHealthLessons {
    /// How many of the most recent sessions (by `sessionDate`, most-recent
    /// first, across every target in the library) are pulled into the
    /// lookback window before filtering down to only the ones that actually
    /// carry cooler/focus data -- the spec's own "last N (~8) sessions".
    public static let lookbackSessionCount = 8
    /// Never fewer than this many sessions WITH the relevant reading before
    /// any lesson can fire -- see this type's own "honesty rails" above.
    public static let minimumSessionsWithData = 4
    /// A lesson fires only once the failing fraction is STRICTLY over half.
    public static let failureFractionThreshold = 0.5

    /// The pure decision: given already-built `NightHealthReport`s (any
    /// order, any mix of targets), which lessons -- if any -- are worth
    /// naming. Extracted from `production(rootURL:)` so tests can exercise
    /// the threshold/cap rules directly against plain fixtures, the same
    /// "extract the pure decision, test it directly" shape
    /// `HomeStore.composeHighlights`/`AnniversaryQuery`/`MilestoneQuery`
    /// already use elsewhere in this app.
    public static func evaluate(reports: [NightHealthReport]) -> [NightHealthLesson] {
        var lessons: [NightHealthLesson] = []

        let coolerSessions = reports.filter { !$0.cooler.verdict.hasPrefix("n/a") }
        if coolerSessions.count >= minimumSessionsWithData {
            let failing = coolerSessions.filter { !$0.cooler.verdict.hasPrefix("stabil") }.count
            if Double(failing) / Double(coolerSessions.count) > failureFractionThreshold {
                lessons.append(NightHealthLesson(
                    kind: .coolerNotHoldingSetpoint, failingCount: failing, sessionCount: coolerSessions.count
                ))
            }
        }

        // "n/a" covers both `FocusHealth`'s own "too few rated frames" case
        // AND the fact that `hasPrefix` never matches a `nil`-adjacent
        // string -- every non-"n/a" verdict here had a real regression
        // (`ratedFrameCount >= 5`, `slopePerHour != nil`).
        let focusSessions = reports.filter { !$0.focus.verdict.hasPrefix("n/a") }
        if focusSessions.count >= minimumSessionsWithData {
            // Only the suspected-drift verdict counts as a failure --
            // "javuló FWHM" (negative drift, i.e. IMPROVING focus) is real,
            // measurable data, but never something to warn about.
            let failing = focusSessions.filter { $0.focus.verdict.hasPrefix("fókuszcsúszás") }.count
            if Double(failing) / Double(focusSessions.count) > failureFractionThreshold {
                lessons.append(NightHealthLesson(
                    kind: .focusDrift, failingCount: failing, sessionCount: focusSessions.count
                ))
            }
        }

        return lessons
    }

    /// Resolves the last `lookbackSessionCount` (target, sessionDate)
    /// sessions on record for `rootURL` -- across every target, the same
    /// `(target, sessionDate)` session unit `RatingCoverageQuery`/
    /// `CoolerNotReachingSetpointRule` already key by -- builds each one's
    /// `NightHealth.report`, and hands the results to `evaluate`. A single
    /// session whose report fails to build (a transient DB read error) is
    /// dropped via `try?` rather than failing the whole call -- the same
    /// "one failure risks re-checking next time, not losing the whole
    /// dashboard" stance `HomeStore.productionHighlights`'s own milestone
    /// ledger write already takes.
    public static func production(rootURL: URL) async throws -> [NightHealthLesson] {
        let root = rootURL.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: root)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
            let db = try Database(path: paths.indexDatabase.path)
            let configURL = root.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = root.path

            struct SessionKey: Hashable { let target: String; let sessionDate: String }
            let lights = try db.allFiles(includeMissing: false).filter {
                $0.area == .sessions && $0.role == .light && $0.target != nil && $0.sessionDate != nil
            }
            var keys = Set<SessionKey>()
            for file in lights {
                guard let target = file.target, let sessionDate = file.sessionDate else { continue }
                keys.insert(SessionKey(target: target, sessionDate: sessionDate))
            }
            let recentSessions = keys.sorted { $0.sessionDate > $1.sessionDate }.prefix(lookbackSessionCount)

            let reports: [NightHealthReport] = recentSessions.compactMap { key in
                try? NightHealth.report(target: key.target, date: key.sessionDate, db: db, config: config)
            }
            return evaluate(reports: reports)
        }.value
    }
}
