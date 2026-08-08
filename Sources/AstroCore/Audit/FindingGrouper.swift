import Foundation

/// Aggregates a flat list of findings into "one row per repeated cause"
/// groups, shared by the CLI's human-readable `audit` output and the app's
/// `AuditView` so the two never drift on what counts as one group. Exists
/// because a single root cause (a nested session tree, a `.DS_Store` left in
/// every date folder, ...) otherwise floods a per-finding listing with
/// dozens or hundreds of near-identical rows.
public enum FindingGrouper {
    /// Identifies one group: same severity, same category, same
    /// `groupKey` (see `groupKey(for:config:)`). `Codable` (R11-T8) so
    /// `AuditDiff`'s new-group keys can be serialized straight into
    /// `audit --json`'s `diff` block without a separate DTO.
    public struct Key: Hashable, Codable, Sendable {
        public let severity: Severity
        public let category: String
        public let groupKey: String

        public init(severity: Severity, category: String, groupKey: String) {
            self.severity = severity
            self.category = category
            self.groupKey = groupKey
        }
    }

    /// One aggregated group: its key, plus every finding that fell into it
    /// (path-sorted).
    public struct Group: Sendable {
        public let key: Key
        public let findings: [Finding]

        public init(key: Key, findings: [Finding]) {
            self.key = key
            self.findings = findings
        }

        public var count: Int { findings.count }
        public var firstMessage: String { findings.first?.message ?? "" }
    }

    /// The key a finding falls under within its own category:
    /// - `residue`: the matched file-name *pattern class* — the exact name
    ///   for a literal match (`.DS_Store`, or a `residueDirNames` directory
    ///   name), else `*.<ext>` for an extension-pattern match (`*.seq`), so
    ///   every `.DS_Store` in the tree groups into one row and every `.seq`
    ///   file into another, regardless of which directory they're in.
    /// - `duplicate-content` / `calib-in-wrong-dir` / `misplaced-file`: the
    ///   finding's parent directory — these fire once per *file*, so the
    ///   directory is the natural "one root cause" unit (a whole nested tree
    ///   misclassified the same way, a whole duplicated folder, ...).
    /// - everything else (dir-level findings — `nested-session-tree`,
    ///   `placeholder-name`, `tool-output`, `intentional-date`,
    ///   `missing-counterpart`, `similar-target-names`, ... — plus
    ///   `FixityVerifier`'s per-file `content-changed`/`modified`/
    ///   `verify-read-error`, R11-T14): the finding's own path. These rules
    ///   already fire at most once (or a handful of times) per offending
    ///   directory, so grouping by path is a no-op that still lets the
    ///   shared `group(_:config:)` machinery treat every category
    ///   uniformly. For the verify categories specifically, per-file (i.e.
    ///   effectively "no grouping") IS the right shape: unlike a residue
    ///   pattern or a misclassified directory, bitrot has no single root
    ///   cause spanning multiple files, so each corrupt/modified/unreadable
    ///   file is its own story and deserves its own row.
    public static func groupKey(for finding: Finding, config: AstroConfig) -> String {
        switch finding.category {
        case "residue":
            return residueGroupKey(for: finding, config: config)
        case "duplicate-content", "calib-in-wrong-dir", "misplaced-file":
            return (finding.path as NSString).deletingLastPathComponent
        default:
            return finding.path
        }
    }

    private static func residueGroupKey(for finding: Finding, config: AstroConfig) -> String {
        let name = (finding.path as NSString).lastPathComponent

        // A whole residue *directory* (e.g. `process/`) groups under its own
        // name -- there's no meaningful "extension class" for a directory.
        if ResidueMatcher.isResidueDirName(name, config: config) {
            return name
        }

        // A literal (no-wildcard) pattern match, e.g. `.DS_Store`, groups
        // under the exact name -- there's nothing more general to say.
        let literalMatch = config.residuePatterns.contains { pattern in
            !pattern.contains("*") && pattern.caseInsensitiveCompare(name) == .orderedSame
        }
        if literalMatch {
            return name
        }

        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? name : "*.\(ext.lowercased())"
    }

    /// Groups `findings` by `(severity, category, groupKey)`, sorted
    /// severity-first (sure error, then suspicious, then probably
    /// intentional), then by descending group size, ties broken by
    /// `groupKey`. Each group's own findings are path-sorted.
    public static func group(_ findings: [Finding], config: AstroConfig) -> [Group] {
        var order: [Key] = []
        var buckets: [Key: [Finding]] = [:]

        for finding in findings {
            let key = Key(severity: finding.severity, category: finding.category, groupKey: groupKey(for: finding, config: config))
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(finding)
        }

        let groups = order.map { key -> Group in
            let sortedFindings = (buckets[key] ?? []).sorted { $0.path < $1.path }
            return Group(key: key, findings: sortedFindings)
        }

        return groups.sorted { lhs, rhs in
            let leftRank = severityRank(lhs.key.severity)
            let rightRank = severityRank(rhs.key.severity)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.key.groupKey < rhs.key.groupKey
        }
    }

    private static func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .sureError: return 0
        case .suspicious: return 1
        case .probablyIntentional: return 2
        }
    }
}
