import Foundation

/// Per-target on-disk size, broken down by library area -- the answer to
/// "how much space does this target actually use, and where" (R11-T8/F19).
/// Purely a map: unlike `CleanupReport`, this never classifies anything as
/// worth removing and never produces a quarantine suggestion, so it's safe
/// to show unconditionally (no "iron rule" concerns -- it's read-only by
/// construction, unrelated to whether a size is "residue").
///
/// Wide-field/deep-sky classification (`WideFieldHeuristic`) deliberately
/// plays no part here -- a target's storage footprint doesn't depend on
/// which lens/scope it was shot with.
public struct TargetStorage: Codable, Equatable, Sendable {
    public var target: String
    /// Same resolution `StatsQueries.TargetStats.displayName` uses
    /// (`TargetNameResolver` + `NameTag`) -- so a target reads the same
    /// name here as everywhere else in the app/CLI.
    public var displayName: String
    /// Bytes under `sessions/<target>/...`.
    public var sessionsBytes: Int64
    /// Bytes under `stacks/<target>/...`.
    public var stacksBytes: Int64
    /// Bytes under `processed/<target>/...`.
    public var processedBytes: Int64
    /// Bytes under any other area that still happens to carry this
    /// target's name (`PathClassifier` never actually assigns a `target`
    /// outside `sessions`/`stacks`/`processed` today, so this is normally
    /// `0` -- kept as its own bucket instead of silently folding into one of
    /// the other three so a future classifier change surfaces here rather
    /// than skewing an existing area's total).
    public var otherBytes: Int64
    public var totalBytes: Int64

    public init(
        target: String,
        displayName: String,
        sessionsBytes: Int64,
        stacksBytes: Int64,
        processedBytes: Int64,
        otherBytes: Int64,
        totalBytes: Int64
    ) {
        self.target = target
        self.displayName = displayName
        self.sessionsBytes = sessionsBytes
        self.stacksBytes = stacksBytes
        self.processedBytes = processedBytes
        self.otherBytes = otherBytes
        self.totalBytes = totalBytes
    }
}

/// The full per-target storage map: every target with at least one
/// non-missing session/stack/processed file, size-descending.
public struct StorageSummary: Codable, Equatable, Sendable {
    public var targets: [TargetStorage]
    public var grandTotalBytes: Int64

    public init(targets: [TargetStorage], grandTotalBytes: Int64) {
        self.targets = targets
        self.grandTotalBytes = grandTotalBytes
    }
}

/// Builds `StorageSummary` from the scanned library. Pure DB read (`Database
/// .allFiles(includeMissing: false)`, same convention as `CleanupReport`/
/// `StatsQueries`) -- never touches the filesystem itself.
public enum StorageQueries {
    /// One entry per distinct target among session/stacks/processed files
    /// (same universe `StatsQueries.perTarget` covers), sorted by total size
    /// descending, ties broken by target name for a stable order.
    public static func perTarget(db: Database, config: AstroConfig) throws -> StorageSummary {
        let files = try db.allFiles(includeMissing: false)

        var byTarget: [String: [FileRecord]] = [:]
        for file in files {
            guard let target = file.target, isRelevant(file.area) else { continue }
            byTarget[target, default: []].append(file)
        }

        let targets = try byTarget.map { name, entries -> TargetStorage in
            var sessionsBytes: Int64 = 0
            var stacksBytes: Int64 = 0
            var processedBytes: Int64 = 0
            var otherBytes: Int64 = 0
            for file in entries {
                switch file.area {
                case .sessions: sessionsBytes += file.size
                case .stacks: stacksBytes += file.size
                case .processed: processedBytes += file.size
                case .calibration, .other: otherBytes += file.size
                }
            }
            let total = sessionsBytes + stacksBytes + processedBytes + otherBytes

            let tags = try db.tags(target: name, sessionDate: nil)
            let resolvedName = NameTag.apply(to: TargetNameResolver.resolve(folderName: name), tags: tags)

            return TargetStorage(
                target: name,
                displayName: resolvedName.displayName,
                sessionsBytes: sessionsBytes,
                stacksBytes: stacksBytes,
                processedBytes: processedBytes,
                otherBytes: otherBytes,
                totalBytes: total
            )
        }.sorted { lhs, rhs in
            lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.target < rhs.target
        }

        let grandTotal = targets.reduce(Int64(0)) { $0 + $1.totalBytes }
        return StorageSummary(targets: targets, grandTotalBytes: grandTotal)
    }

    /// Same universe `StatsQueries.isStatsRelevant` uses -- only areas that
    /// `PathClassifier` ever assigns a `target` to are meaningful here;
    /// `calibration`/bare `other` files never carry a target at all, so this
    /// only matters as a defensive guard against a future classifier change.
    private static func isRelevant(_ area: LibraryArea) -> Bool {
        area == .sessions || area == .stacks || area == .processed
    }
}
