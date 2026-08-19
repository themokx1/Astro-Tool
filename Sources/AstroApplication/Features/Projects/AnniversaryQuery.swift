import Foundation

/// One project whose EARLIEST recorded session lands on today's exact
/// month+day, at least one full year ago -- expert ideation spec #5
/// ("First-Light Anniversaries"). `yearsAgo` is always `>= 1`: a project
/// first shot earlier this same calendar year never fires (there is no
/// anniversary to mark yet), and neither does one whose first session
/// simply happens to share today's month but not its day.
public struct AnniversaryHit: Equatable, Sendable, Identifiable {
    public let projectID: UUID
    public let catalogID: String
    public let displayName: String
    public let yearsAgo: Int
    /// The project's own first-light date, verbatim as `NightRecord
    /// .localDate` stores it (`yyyy-MM-dd`, canonical -- see that type's own
    /// doc comment) -- kept around for callers that want to show the exact
    /// date, though `HomeView`'s card only ever needs `yearsAgo`.
    public let firstLightDate: String
    public var id: UUID { projectID }

    public init(projectID: UUID, catalogID: String, displayName: String, yearsAgo: Int, firstLightDate: String) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.displayName = displayName
        self.yearsAgo = yearsAgo
        self.firstLightDate = firstLightDate
    }
}

/// Pure "did any project's first light land on this exact calendar date N
/// years ago" query, expert ideation spec #5. Reads no database and touches
/// no filesystem -- every input already lives in the `ProjectSnapshot`s
/// `ProjectsQuery.project(id:)` already builds (`nights`, each carrying its
/// own `NightRecord.localDate`), so this is a plain, exhaustively testable
/// date-comparison function, the same "extract the pure decision, test it
/// directly" shape `CompletionForecast`/`HomeStore.cloudOutlook` already
/// use elsewhere in this app.
///
/// Real dates and real thresholds only, zero invented scoring -- an
/// anniversary either fires on the EXACT month+day match or it doesn't;
/// there is no partial-credit "close enough" case.
public enum AnniversaryQuery {
    /// `HomeStore`'s own composition caps the COMBINED anniversary +
    /// milestone list at this many cards (see `HomeStore.composeHighlights`)
    /// -- exposed here too so a caller that only cares about anniversaries
    /// (a future digest, a test) can apply the identical cap without
    /// duplicating the literal `2`.
    public static let maximumHits = 2

    /// Every project whose first-light date matches today's month+day, at
    /// least one year ago, sorted with the LARGEST anniversary first (a
    /// 5-year anniversary beats a 1-year one when several targets fire the
    /// same day), ties broken by `catalogID` for a deterministic order.
    /// `projects` is expected to be every project's own snapshot (whatever
    /// phase) -- this makes no phase judgment of its own, an anniversary is
    /// a fact about a date, not about whether the project is still active.
    public static func anniversaries(
        projects: [ProjectSnapshot],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [AnniversaryHit] {
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: today)
        guard let todayYear = todayComponents.year,
              let todayMonth = todayComponents.month,
              let todayDay = todayComponents.day
        else { return [] }

        var hits: [AnniversaryHit] = []
        for snapshot in projects {
            guard let firstLight = snapshot.nights.map(\.night.localDate).min(),
                  let parsed = parse(firstLight),
                  parsed.month == todayMonth, parsed.day == todayDay
            else { continue }
            let years = todayYear - parsed.year
            guard years >= 1 else { continue }
            hits.append(AnniversaryHit(
                projectID: snapshot.project.id,
                catalogID: snapshot.project.catalogID,
                displayName: snapshot.project.displayName,
                yearsAgo: years,
                firstLightDate: firstLight
            ))
        }
        return hits.sorted { lhs, rhs in
            if lhs.yearsAgo != rhs.yearsAgo { return lhs.yearsAgo > rhs.yearsAgo }
            return lhs.catalogID < rhs.catalogID
        }
    }

    /// `NightRecord.localDate` is the canonical `"yyyy-MM-dd"` string
    /// `SessionDateParser` produces (never a `Date`, see that type's own doc
    /// comment) -- parsed as plain integers rather than through a
    /// `DateFormatter`/`Calendar` round trip, so this can never misfire from
    /// a timezone or DST edge the session's own calendar day never had.
    private static func parse(_ localDate: String) -> (year: Int, month: Int, day: Int)? {
        let parts = localDate.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }
}
