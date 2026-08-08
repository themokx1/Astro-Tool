import Foundation

/// Compares two audit runs' findings, grouped the same way the CLI/app
/// already group them (`FindingGrouper`), to answer "what changed since the
/// last audit" (R11-T8/F6). Pure function of two `Finding` arrays plus the
/// config `FindingGrouper.groupKey(for:config:)` needs -- no DB access of
/// its own, so it's trivially testable; the caller (`AppState.runAudit`/
/// `Commands.cmdAudit`) is responsible for fetching the previous run's
/// findings (`Database.previousRunID(before:kind:)` + `Database.findings(runID:)`)
/// before calling `compute`.
///
/// Comparison happens at `FindingGrouper.Key` granularity -- same severity,
/// same category, same `groupKey` -- exactly the unit the Hibák/Gyanús/
/// Szándékos lists already show one row per. A group's ack state
/// (`Database.ackedKeys`) is a completely separate dimension this type never
/// looks at: an acked group that's still present in both runs is
/// "unchanged" here regardless of its ack state, and a newly-acked group
/// doesn't stop being "new" just because the user acked it in the same
/// session -- ack only ever affects whether the Hibák/Gyanús list HIDES a
/// row, never what this diff reports.
public enum AuditDiff {
    /// One comparison's result: which groups are brand new since the
    /// previous run, which disappeared (fixed, or no longer triggering),
    /// and which are present in both. Each side keeps its own full
    /// `FindingGrouper.Group` (not just the key) so callers can show counts,
    /// example paths, or messages without re-grouping.
    public struct Result: Sendable {
        /// Present in `current`, absent from `previous` -- keyed by
        /// `(severity, category, groupKey)`.
        public let newGroups: [FindingGrouper.Group]
        /// Present in `previous`, absent from `current` -- the group no
        /// longer fires at all (fixed, or the offending files/dirs are gone).
        public let resolvedGroups: [FindingGrouper.Group]
        /// Present in both runs.
        public let unchangedGroups: [FindingGrouper.Group]

        public init(newGroups: [FindingGrouper.Group], resolvedGroups: [FindingGrouper.Group], unchangedGroups: [FindingGrouper.Group]) {
            self.newGroups = newGroups
            self.resolvedGroups = resolvedGroups
            self.unchangedGroups = unchangedGroups
        }

        public var newCount: Int { newGroups.count }
        public var resolvedCount: Int { resolvedGroups.count }
        public var unchangedCount: Int { unchangedGroups.count }
    }

    /// Groups `previous` and `current` (via `FindingGrouper.group`, so
    /// severity-first/size-desc ordering is preserved within each bucket)
    /// and buckets every group's key into new/resolved/unchanged by set
    /// membership.
    public static func compute(previous: [Finding], current: [Finding], config: AstroConfig) -> Result {
        let previousGroups = FindingGrouper.group(previous, config: config)
        let currentGroups = FindingGrouper.group(current, config: config)

        let previousKeys = Set(previousGroups.map(\.key))
        let currentKeys = Set(currentGroups.map(\.key))

        return Result(
            newGroups: currentGroups.filter { !previousKeys.contains($0.key) },
            resolvedGroups: previousGroups.filter { !currentKeys.contains($0.key) },
            unchangedGroups: currentGroups.filter { previousKeys.contains($0.key) }
        )
    }
}
