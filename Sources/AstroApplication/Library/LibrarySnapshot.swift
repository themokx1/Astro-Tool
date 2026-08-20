public struct LibrarySnapshot: Equatable, Sendable {
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let projectCount: Int
    /// W6-E item 3: `Database.libraryIndexCounts`'s own
    /// `COUNT(DISTINCT session_date)` -- every distinct RAW `session_date`
    /// folder-name string under `sessions/`, no dedup by calendar date and
    /// no target/role filter. A run-suffix sibling folder (e.g.
    /// `2026-04-06` and `2026-04-06-2`) counts as two here. Deliberately
    /// NOT the same number as the deduplicated, calendar-date `NightRecord`
    /// count `NightsStore`/`HomeStore` show ("Éjszakák") -- the two measure
    /// different things (session-folder count vs. observed-night count),
    /// and `FirstScanSummaryView` labels this tile "Session Folders", not
    /// "Nights", so the two never claim to agree.
    public let nightCount: Int
    public let frameCount: Int

    public init(
        libraryID: LibraryIdentity,
        revision: UInt64,
        projectCount: Int,
        nightCount: Int,
        frameCount: Int
    ) {
        self.libraryID = libraryID
        self.revision = revision
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.frameCount = frameCount
    }
}
