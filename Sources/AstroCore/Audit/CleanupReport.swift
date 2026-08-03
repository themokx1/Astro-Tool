import Foundation

/// One category of cleanup candidate — a residue sub-kind, or the single
/// aggregated `duplicate-content` bucket — with its files listed size-desc
/// and capped at `CleanupReport.build`'s `maxPathsPerGroup`.
public struct CleanupGroup: Codable, Equatable, Sendable {
    public var category: String
    public var fileCount: Int
    public var totalBytes: Int64
    /// Size-desc within the group, capped at `maxPathsPerGroup`; the
    /// remainder (if any) is only counted in `truncatedCount`, never listed.
    public var paths: [String]
    public var truncatedCount: Int

    public init(category: String, fileCount: Int, totalBytes: Int64, paths: [String], truncatedCount: Int) {
        self.category = category
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.paths = paths
        self.truncatedCount = truncatedCount
    }
}

/// The full cleanup summary: every non-empty category, sorted biggest-first.
public struct CleanupSummary: Codable, Equatable, Sendable {
    public var groups: [CleanupGroup]
    public var grandTotalBytes: Int64

    public init(groups: [CleanupGroup], grandTotalBytes: Int64) {
        self.groups = groups
        self.grandTotalBytes = grandTotalBytes
    }
}

/// Aggregates the library's known residue files/dirs and duplicate-content
/// groups into a single, size-ordered "what's worth cleaning up" report —
/// the answer to "mit érdemes kitakarítani és mennyit nyerek vele" that a
/// per-finding audit listing doesn't give directly.
///
/// Pure DB read: this never touches the filesystem and never runs content
/// hashing itself (that's `DuplicateFinder`'s job, invoked from
/// `AuditEngine.run`). `content_hash` is only populated once a duplicate-scan
/// audit has actually run — if the DB has no cached hashes yet, the
/// `duplicate-content` group is simply absent from the result (not present
/// with zero bytes), since this type has no way to tell "no duplicates
/// exist" apart from "duplicates were never looked for".
public enum CleanupReport {
    public static func build(db: Database, config: AstroConfig, maxPathsPerGroup: Int = 50) throws -> CleanupSummary {
        let files = try db.allFiles(includeMissing: false)

        var groups = residueGroups(files: files, config: config, maxPathsPerGroup: maxPathsPerGroup)
        if let dupGroup = duplicateGroup(files: files, maxPathsPerGroup: maxPathsPerGroup) {
            groups.append(dupGroup)
        }

        groups.sort { $0.totalBytes > $1.totalBytes }
        let grandTotal = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
        return CleanupSummary(groups: groups, grandTotalBytes: grandTotal)
    }

    // MARK: - Residue

    private static func residueGroups(files: [FileRecord], config: AstroConfig, maxPathsPerGroup: Int) -> [CleanupGroup] {
        var byCategory: [String: [FileRecord]] = [:]
        for file in files {
            guard let category = residueCategory(for: file.path, config: config) else { continue }
            byCategory[category, default: []].append(file)
        }
        return byCategory.map { category, entries in
            makeGroup(category: category, entries: entries, maxPathsPerGroup: maxPathsPerGroup)
        }
    }

    /// The cleanup-report sub-category a file falls into, or `nil` if it
    /// isn't residue at all. An ancestor directory named in
    /// `residueDirNames` (e.g. `process/`) takes precedence over filename
    /// pattern matching — everything under it is residue regardless of its
    /// own name, mirroring `ResidueRule`'s whole-directory finding — then
    /// filename-pattern matches split by extension (`.seq`/`.lst`/other). A
    /// file sitting anywhere under a `toolOutputDirNames` directory is never
    /// residue, however its name looks: those are known-intentional tool
    /// output (`ToolOutputRule`'s territory), not mess.
    private static func residueCategory(for path: String, config: AstroConfig) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { config.toolOutputDirNames.contains($0) }) else { return nil }

        let ancestors = components.dropLast()
        if ancestors.contains(where: { ResidueMatcher.isResidueDirName($0, config: config) }) {
            return "residue-process-dir"
        }

        let name = components.last ?? path
        guard ResidueMatcher.matchesFilePattern(name: name, config: config) else { return nil }

        switch (name as NSString).pathExtension.lowercased() {
        case "seq": return "residue-seq"
        case "lst": return "residue-lst"
        default: return "residue-other"
        }
    }

    // MARK: - Duplicates

    /// `nil` when no file in the DB has a cached `content_hash` yet, or none
    /// of the hashed files actually collide — see the type-level doc comment
    /// for why that's "absent" rather than an empty/zeroed group.
    private static func duplicateGroup(files: [FileRecord], maxPathsPerGroup: Int) -> CleanupGroup? {
        var byHash: [String: [FileRecord]] = [:]
        for file in files {
            guard let hash = file.contentHash else { continue }
            byHash[hash, default: []].append(file)
        }

        var wastedEntries: [FileRecord] = []
        for (_, group) in byHash where group.count >= 2 {
            let keeper = keeperPath(in: group)
            wastedEntries.append(contentsOf: group.filter { $0.path != keeper })
        }

        guard !wastedEntries.isEmpty else { return nil }
        return makeGroup(category: "duplicate-content", entries: wastedEntries, maxPathsPerGroup: maxPathsPerGroup)
    }

    /// The one path to keep (i.e. exclude from the reported "wasted bytes")
    /// out of a group of same-hash files: the `sessions/` copy if there is
    /// one — mirrors `DuplicateFinder`'s own reasoning that `sessions/` is
    /// the canonical RAW area and should never be the one implicitly counted
    /// as removable — the alphabetically-first path otherwise. If more than
    /// one copy sits under `sessions/`, the alphabetically-first one among
    /// those wins.
    private static func keeperPath(in group: [FileRecord]) -> String {
        let sessionsCopies = group.map(\.path).filter { $0 == "sessions" || $0.hasPrefix("sessions/") }
        if let first = sessionsCopies.sorted().first { return first }
        return group.map(\.path).sorted()[0]
    }

    // MARK: - Quarantine-move suggestion findings

    /// Turns every listed cleanup-candidate path across `summary.groups`
    /// into a `.suspicious` `cleanup-candidate` `Finding` whose suggestion
    /// is a `.move` into
    /// `.astro_tool/cleanup_quarantine/<timestamp>/<original-relative-path>`
    /// — never a delete. Shared by the CLI's `cleanup --suggest` and the
    /// app's "Takarítási script generálása" button so the two never drift
    /// on exactly what a cleanup script does. Feeding the result through
    /// `SuggestionScript` with `includeSuspicious: true, commentSuspicious:
    /// false` emits these as ACTIVE `mv` commands (still behind the
    /// script's own blocking `YES` confirmation gate and guarded-overwrite
    /// `mv`), so running the generated script only ever *moves* files into
    /// a quarantine folder the user can inspect and empty by hand later —
    /// nothing is ever `rm`'d.
    public static func quarantineFindings(for summary: CleanupSummary, timestamp: Date) -> [Finding] {
        let stamp = quarantineStampFormatter.string(from: timestamp)
        var findings: [Finding] = []
        for group in summary.groups {
            for path in group.paths {
                let quarantinePath = ".astro_tool/cleanup_quarantine/\(stamp)/\(path)"
                findings.append(Finding(
                    severity: .suspicious,
                    category: "cleanup-candidate",
                    path: path,
                    message: "\(group.category): cleanup candidate — moved to quarantine, not deleted; "
                        + "empty the quarantine folder by hand once you've confirmed you don't need it.",
                    suggestion: .move(from: path, to: quarantinePath)
                ))
            }
        }
        return findings
    }

    private static let quarantineStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Shared group builder

    private static func makeGroup(category: String, entries: [FileRecord], maxPathsPerGroup: Int) -> CleanupGroup {
        let sorted = entries.sorted { lhs, rhs in
            lhs.size != rhs.size ? lhs.size > rhs.size : lhs.path < rhs.path
        }
        let totalBytes = sorted.reduce(Int64(0)) { $0 + $1.size }
        let capped = sorted.prefix(maxPathsPerGroup)
        return CleanupGroup(
            category: category,
            fileCount: sorted.count,
            totalBytes: totalBytes,
            paths: capped.map(\.path),
            truncatedCount: sorted.count - capped.count
        )
    }
}
