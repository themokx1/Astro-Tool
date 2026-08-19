import AstroCore
import Foundation

/// One event on a project's own "Célpont-történet" (target history) timeline
/// -- expert ideation #4. Every event is a plain fact already known to one of
/// three existing, independently-tested engines (see `TargetHistoryTimeline
/// .build(sessions:stackGroups:)`'s own doc comment for exactly which one);
/// nothing here invents a new metric or a new scoring rule.
public struct TargetHistoryEvent: Equatable, Sendable {
    /// `firstLight` and `session` are mutually exclusive for the SAME
    /// session -- see `build(sessions:stackGroups:)`'s doc comment for why
    /// the project's earliest session becomes exactly one `firstLight`
    /// event, never a `firstLight` PLUS a duplicate `session` event for that
    /// same day.
    public enum Kind: Equatable, Sendable {
        /// This project's earliest recorded session -- the same "earliest
        /// `NightRecord.localDate` wins" rule `AnniversaryQuery.anniversaries`
        /// already uses for its own "first light" concept, just without that
        /// query's "at least a year ago" anniversary gate (a target history
        /// entry marks the day itself, not a return to it).
        case firstLight
        /// One ordinary session: this session's own usable integration, plus
        /// its best-measured FWHM when the session was ever rated at all
        /// (`fwhmArcsec` wins over `fwhmPixels` when both are present, same
        /// precedence `TrendPoint.fwhmValue` itself already establishes) --
        /// `nil`/`nil` for a captured-but-never-rated session, never a
        /// fabricated placeholder number.
        case session(integrationSeconds: Double, fwhmArcsec: Double?, fwhmPixels: Double?)
        /// One or more stack FAMILIES (`StackGroup`, the same "collapse
        /// every `_og`/`_work`/`starless_` variant of one underlying capture
        /// into one family" grouping the Results tab renders) whose base
        /// file's own `sessionDate` folds onto this event's `date`. Carries
        /// each family's base file NAME only (never a full path -- this is a
        /// display fact, not a file reference), in `StackDiscovery
        /// .groupedStacks`'s own best-integration-first order.
        case stacksProduced(fileNames: [String])
    }

    /// The event's own calendar day, `YYYY-MM-DD` when derivable (a
    /// session's own canonical `sessionStartDate`, or a stack family's own
    /// `StackFile.sessionDate`) -- the same "canonical when parseable, raw
    /// text otherwise" convention `TrendPoint.date`/`.sessionStartDate`
    /// already establish, since a `.session` event's `date` is taken
    /// straight from there.
    public let date: String
    public let kind: Kind

    public init(date: String, kind: Kind) {
        self.date = date
        self.kind = kind
    }
}

/// Pure library-storytelling compose for one project/target -- expert
/// ideation #4 ("Célpont-történet idővonal"). Reads no database and touches
/// no filesystem itself: every input is already the exact output of one of
/// three existing, independently-tested `AstroCore`/`AstroApplication`
/// engines --
///
/// - first light: the same "earliest session wins" rule `AnniversaryQuery
///   .anniversaries` already applies, computed here from `sessions`' own
///   dates rather than re-reading `ProjectSnapshot.nights` a second way --
///   `sessions` (see below) already IS one row per session with a
///   comparable date, so a second "walk the nights" pass would be the same
///   fact fetched twice.
/// - every session: `TrendQueries.points`, scoped to one target (by whatever
///   folder name the caller resolved) -- the one engine that already
///   resolves "one entry per session, oldest first, with usable integration
///   AND best-measured FWHM in a single row" (`TrendPoint.fwhmValue`), so
///   this reuses it rather than re-joining `SessionStatsQueries`/
///   `SessionQuality` a second time the way `ProjectReportQuery.Result`
///   itself does for its own, differently-shaped Sessions/Quality report
///   sections.
/// - every produced stack family: `StackDiscovery.groupedStacks(target:db:
///   config:)` -- the exact same engine the Results tab and `ResultsQuery`
///   already use, so this timeline and Results can never disagree about
///   what a "family" is or how many exist.
///
/// No new persistence and no new scoring: this type only INTERLEAVES three
/// already-existing reads into one chronological list.
public enum TargetHistoryTimeline {
    /// Builds one target's chronological history from its own sessions and
    /// stack families.
    ///
    /// `sessions` need not already be sorted -- this sorts them itself
    /// (chronologically ascending, by `sessionStartDate` when parseable,
    /// else the raw dir name, same fallback `TrendQueries.points` itself
    /// uses) rather than trusting caller order, so a caller that hands this
    /// an unsorted slice (a test fixture, say) still gets a correct
    /// timeline.
    ///
    /// The EARLIEST session becomes exactly one `.firstLight` event -- never
    /// a `.firstLight` event PLUS a second, duplicate `.session` event for
    /// that same day (a project with exactly one recorded session must
    /// therefore produce exactly one event total, not two describing the
    /// same night twice). Every OTHER session becomes its own `.session`
    /// event.
    ///
    /// Stack families fold onto whichever date their own base file's
    /// `sessionDate` names -- a family produced from a session already in
    /// the list lands right alongside it; a family whose date matches no
    /// session in `sessions` at all (a stray capture the target-history
    /// scope never saw as a session, or one dropped after the stack was
    /// made) still gets its own entry on its own real date, never
    /// re-dated to fit an existing row. Multiple families sharing the same
    /// date fold into ONE `.stacksProduced` event carrying every one of
    /// their names, in `groupedStacks`' own best-integration-first order --
    /// never one row per family on a busy processing day. A family whose
    /// base file carries no `sessionDate` at all is skipped rather than
    /// invented a date (`StackFile.sessionDate`'s own doc comment: this can
    /// genuinely be `nil`).
    ///
    /// `nil` -- not `[]` -- when `sessions` is empty: a target with no
    /// recorded session at all has no story to tell yet, and this
    /// distinguishes "nothing happened" from "the caller asked for a target
    /// with literally zero data", the same "distinguish absence from an
    /// empty list" contract `ProjectReportQuery.run` marks by throwing
    /// instead of returning an empty `Result`. A target with sessions but no
    /// stack families at all still returns the session/first-light events
    /// (never an all-or-nothing `nil` just because ONE of the three reads
    /// came back empty).
    public static func build(sessions: [TrendPoint], stackGroups: [StackGroup]) -> [TargetHistoryEvent]? {
        guard !sessions.isEmpty else { return nil }

        let ordered = sessions.sorted { lhs, rhs in
            eventDate(lhs) < eventDate(rhs)
        }

        var events: [TargetHistoryEvent] = [
            TargetHistoryEvent(date: eventDate(ordered[0]), kind: .firstLight),
        ]
        for point in ordered.dropFirst() {
            let fwhm = point.fwhmValue
            events.append(TargetHistoryEvent(
                date: eventDate(point),
                kind: .session(
                    integrationSeconds: point.integrationSeconds,
                    fwhmArcsec: fwhm.flatMap { $0.isPixelFallback ? nil : $0.value },
                    fwhmPixels: fwhm.flatMap { $0.isPixelFallback ? $0.value : nil }
                )
            ))
        }

        var stackNamesByDate: [String: [String]] = [:]
        var stackDateOrder: [String] = []
        for group in stackGroups {
            guard let date = group.base.sessionDate else { continue }
            if stackNamesByDate[date] == nil { stackDateOrder.append(date) }
            stackNamesByDate[date, default: []].append((group.base.path as NSString).lastPathComponent)
        }
        for date in stackDateOrder {
            events.append(TargetHistoryEvent(date: date, kind: .stacksProduced(fileNames: stackNamesByDate[date] ?? [])))
        }

        return events.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return rank(lhs.kind) < rank(rhs.kind)
        }
    }

    /// One target's history, straight from the production database -- opens
    /// the exact same `TrendQueries.points`/`StackDiscovery.groupedStacks`
    /// reads `ProjectReportQuery.run`/`ResultsQuery.stackResults` already
    /// call, scoped to `target`. `ResultsQuery.libraryFolder(matching:
    /// among:)` resolves the same on-disk folder-name drift (e.g. NGC 7000's
    /// catalog name vs. its real, differently-spelled `stacks/` folder) that
    /// query itself already corrects for -- see its own doc comment for the
    /// measured real-library incident this fixes.
    public static func events(target: String, db: Database, config: AstroConfig) throws -> [TargetHistoryEvent]? {
        let knownFolders = Array(Set(try db.allFiles(includeMissing: false).compactMap(\.target)))
        let folder = ResultsQuery.libraryFolder(matching: target, among: knownFolders) ?? target
        let sessions = try TrendQueries.points(db: db, config: config).filter { $0.target == folder }
        let stackGroups = try StackDiscovery.groupedStacks(target: folder, db: db, config: config)
        return build(sessions: sessions, stackGroups: stackGroups)
    }

    /// Opens the V2 index (`AppStoragePaths.production` -> `index.sqlite`)
    /// for `rootURL` and hands it to `events(target:db:config:)` -- same
    /// shape as `ProjectReportQuery.production(rootURL:)`/`ResultsQuery
    /// .production(rootURL:)`.
    public static func production(rootURL: URL, target: String) throws -> [TargetHistoryEvent]? {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return try events(target: target, db: database, config: config)
    }

    /// `TrendPoint`'s own canonical-when-parseable, raw-dir-name-otherwise
    /// date -- same fallback `TrendQueries.points`' own sort already uses.
    private static func eventDate(_ point: TrendPoint) -> String {
        point.sessionStartDate ?? point.date
    }

    private static func rank(_ kind: TargetHistoryEvent.Kind) -> Int {
        switch kind {
        case .firstLight: return 0
        case .session: return 1
        case .stacksProduced: return 2
        }
    }
}
