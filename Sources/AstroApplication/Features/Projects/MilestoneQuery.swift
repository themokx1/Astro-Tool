import Foundation

/// One project that just crossed an integration-hour milestone -- expert
/// ideation spec #5 ("honest milestones"). `thresholdHours` is the LARGEST
/// threshold this observation newly crosses (a project that jumped from,
/// say, 8h to 110h in one scan crossed 10/25/50/100 all at once; only the
/// biggest one is worth a card -- see `MilestoneQuery.evaluate`).
public struct MilestoneHit: Equatable, Sendable, Identifiable {
    public let projectID: UUID
    public let catalogID: String
    public let displayName: String
    public let thresholdHours: Int
    public var id: String { "\(projectID.uuidString)|\(thresholdHours)" }

    public init(projectID: UUID, catalogID: String, displayName: String, thresholdHours: Int) {
        self.projectID = projectID
        self.catalogID = catalogID
        self.displayName = displayName
        self.thresholdHours = thresholdHours
    }
}

/// Pure "did any project's integration total just cross a real hour
/// threshold" decision, expert ideation spec #5. Reads no database and
/// touches no filesystem itself -- `evaluate` is a plain, exhaustively
/// testable comparison over `ProjectSnapshot.integrationSeconds` (already
/// computed from real usable-frame decisions, see that property's own doc
/// comment) against a small ledger of previously observed totals, the same
/// "extract the pure decision, test it directly" shape `AnniversaryQuery`/
/// `CompletionForecast`/`HomeStore.cloudOutlook` already use elsewhere in
/// this app. `MilestoneLedger` below is the one piece that actually touches
/// disk -- reading/writing that small per-project ledger is `HomeStore
/// .productionHighlights`'s job, never this type's own.
public enum MilestoneQuery {
    /// Real, round integration-hour thresholds only -- no invented scoring,
    /// per the spec's own "zero invented scoring" ground rule.
    public static let thresholdHours: [Int] = [10, 25, 50, 100, 250]

    /// For each project: compares its CURRENT `integrationSeconds` against
    /// `previousTotals[project.id]`, the last total this same project was
    /// ever observed at. A threshold fires only when the previous total was
    /// strictly below it and the current one has reached or passed it --
    /// so a total that was already past 100h the very first time this
    /// project was ever observed does NOT fire (there is no `previousTotals`
    /// entry for it yet; see the "fresh install" branch below), and a total
    /// that stays flat between two observations never re-fires the same
    /// threshold twice.
    ///
    /// A project with NO entry in `previousTotals` at all is new to this
    /// ledger -- either a fresh install that has never recorded totals
    /// before, or a project created since the last observation. Its current
    /// total is seeded into `updatedTotals` SILENTLY: nothing fires for it
    /// this round, exactly the spec's "a fresh install with an
    /// already-100h project does NOT fire everything retroactively" rule.
    ///
    /// Returns both the hits to show today AND the full totals ledger the
    /// caller must persist afterward (`MilestoneLedger.save`) -- every
    /// project's current total is folded in, fired or not, so the NEXT call
    /// only ever compares against what was actually seen this time.
    public static func evaluate(
        projects: [ProjectSnapshot],
        previousTotals: [UUID: Double]
    ) -> (hits: [MilestoneHit], updatedTotals: [UUID: Double]) {
        var hits: [MilestoneHit] = []
        var updatedTotals = previousTotals
        for snapshot in projects {
            let projectID = snapshot.project.id
            let currentTotal = snapshot.integrationSeconds
            defer { updatedTotals[projectID] = currentTotal }

            guard let previousTotal = previousTotals[projectID] else { continue }
            let crossed = thresholdHours.filter { hours in
                let thresholdSeconds = Double(hours) * 3600
                return previousTotal < thresholdSeconds && currentTotal >= thresholdSeconds
            }
            guard let largest = crossed.max() else { continue }
            hits.append(MilestoneHit(
                projectID: projectID,
                catalogID: snapshot.project.catalogID,
                displayName: snapshot.project.displayName,
                thresholdHours: largest
            ))
        }
        return (
            hits.sorted { lhs, rhs in
                if lhs.thresholdHours != rhs.thresholdHours { return lhs.thresholdHours > rhs.thresholdHours }
                return lhs.catalogID < rhs.catalogID
            },
            updatedTotals
        )
    }
}

/// The small on-disk ledger `MilestoneQuery.evaluate` needs to tell "already
/// crossed" from "crossing right now" across app launches -- one JSON file,
/// project id to last-observed `integrationSeconds`, living next to this
/// library's own `metadata.sqlite` under Application Support
/// (`AppStoragePaths.production`'s own per-library directory), NEVER inside
/// the photo library itself (that store's own safety checks already forbid
/// it; this reuses its already-validated directory rather than inventing a
/// second path convention). Same "plain `Codable` blob at a computed URL"
/// shape `SettingsStore`/`AppModel`'s `RecentLibraryEntry` already use for
/// their own lightweight persistence, adapted from `UserDefaults` to a
/// dedicated file because this data is per-LIBRARY, not per-user -- a
/// `UserDefaults.standard` key would bleed one library's milestone history
/// into every other library the same app ever opens.
public struct MilestoneLedger: Sendable {
    private let fileURL: URL

    /// `FileManager` is deliberately NOT a stored property (it isn't
    /// `Sendable`, and this type otherwise is) -- `.default` is looked up
    /// fresh inside each method instead, exactly the way `MetadataStore
    /// .init(databaseURL:)` already does for its own directory-creation call.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `[:]` for a brand-new library (no ledger file yet) or a corrupt/
    /// unreadable one -- both are treated as "nothing observed before",
    /// which is exactly the seed-silently case `MilestoneQuery.evaluate`
    /// already handles for any project missing from the result.
    public func load() -> [UUID: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        var totals: [UUID: Double] = [:]
        for (key, value) in raw {
            guard let projectID = UUID(uuidString: key) else { continue }
            totals[projectID] = value
        }
        return totals
    }

    /// Keys must be `String` for `JSONEncoder`/a JSON object at all -- `UUID
    /// .uuidString`, decoded back the same way in `load()`.
    public func save(_ totals: [UUID: Double]) throws {
        let raw = Dictionary(uniqueKeysWithValues: totals.map { ($0.key.uuidString, $0.value) })
        let data = try JSONEncoder().encode(raw)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    /// `paths.metadataDatabase`'s own parent directory -- the exact
    /// per-library Application Support folder `AppStoragePaths.production`
    /// already resolved and validated (never inside the library root; see
    /// that type's own `storageDestinationInsideLibrary` guard) -- rather
    /// than a new top-level path this type would have to re-validate itself.
    public static func production(rootURL: URL) throws -> MilestoneLedger {
        let identity = LibraryIdentity(rootURL: rootURL)
        let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let fileURL = paths.metadataDatabase.deletingLastPathComponent()
            .appendingPathComponent("milestones.json")
        return MilestoneLedger(fileURL: fileURL)
    }
}
