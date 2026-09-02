import Foundation

/// Decides what error a missing root/subpath should surface as. Split out
/// from `LibraryScanner.scan` so the decision can be unit-tested directly
/// without touching a real `/Volumes` mount point or iCloud Drive — the only
/// filesystem access it needs comes through the injected `probe`.
/// `public` since 2026-09-02: the onboarding store (`AstroUI`) needs the very
/// same missing-root diagnosis the scanner already had, so an unplugged
/// external drive reads as "reconnect the drive" there too instead of being
/// misreported as "that is not a folder".
public enum RootErrorClassifier {
    /// The real filesystem/volume facts this classifier needs beyond plain
    /// path existence, injected so its decision logic can be unit-tested
    /// deterministically. `LibraryScanner.scan`'s call site backs these with
    /// `FileManager`/`URLResourceKey` reads; a test injects a fake table
    /// instead of requiring a real removable drive or iCloud container.
    public struct VolumeProbe: Sendable {
        /// Same semantics as `FileManager.fileExists`.
        public var pathExists: @Sendable (String) -> Bool
        /// Whether `path` (already known to exist) looks like a volume
        /// mount point rather than an ordinary directory on the same
        /// filesystem as its parent -- `URLResourceKey.volumeIsRemovableKey
        /// == true`, `.volumeIsInternalKey == false`, or (the fallback for a
        /// boundary neither of those reliably flags, e.g. a firmlink-style
        /// mount like `/System/Volumes/Data`) its `.volumeIdentifierKey`
        /// differing from its own parent directory's.
        public var isVolumeBoundary: @Sendable (String) -> Bool

        public init(
            pathExists: @escaping @Sendable (String) -> Bool,
            isVolumeBoundary: @escaping @Sendable (String) -> Bool
        ) {
            self.pathExists = pathExists
            self.isVolumeBoundary = isVolumeBoundary
        }
    }

    /// - `rootPath` starts with `/Volumes/`: its volume portion (the first
    ///   two path components, e.g. `/Volumes/AstroDrive`) missing per
    ///   `probe.pathExists` → `.volumeNotMounted(path: rootPath)`; present →
    ///   `.pathNotFound` straight away (a real missing subpath on a properly
    ///   mounted drive, not an unmount) without falling through to the
    ///   generic boundary check below, which would otherwise flag the mount
    ///   point itself as "a volume" every time.
    /// - `rootPath` has a path component literally named `Mobile Documents`
    ///   (iCloud Drive's on-disk container, `~/Library/Mobile
    ///   Documents/...`) → `.volumeNotMounted`: content that hasn't been
    ///   downloaded locally yet reads as "missing" exactly like an unmounted
    ///   network share, and "wait/retry" is the right recovery, not
    ///   "re-pick the folder".
    /// - Otherwise, walk up from `rootPath` to its nearest existing
    ///   ancestor (per `probe.pathExists`); if that ancestor looks like a
    ///   volume boundary per `probe.isVolumeBoundary` → `.volumeNotMounted`
    ///   -- covers a root that sits on a since-detached external/network
    ///   volume mounted somewhere other than `/Volumes/` (e.g. a
    ///   `/System/Volumes/Data`-relative path).
    /// - Otherwise the missing root/subpath itself doesn't exist (but its
    ///   parent does, on the SAME ordinary volume) → `.pathNotFound(path:)`,
    ///   using `subpath` when one was given (a scoped scan under an
    ///   existing root) or `rootPath` when the root itself is what's
    ///   missing.
    public static func classify(
        rootPath: String,
        subpath: String?,
        probe: VolumeProbe
    ) -> AstroError {
        if rootPath.hasPrefix("/Volumes/") {
            let volume = volumePortion(of: rootPath)
            return probe.pathExists(volume)
                ? .pathNotFound(path: subpath ?? rootPath)
                : .volumeNotMounted(path: rootPath)
        }

        if hasMobileDocumentsComponent(rootPath) {
            return .volumeNotMounted(path: rootPath)
        }

        if let ancestor = nearestExistingAncestor(of: rootPath, pathExists: probe.pathExists),
           ancestor != "/", probe.isVolumeBoundary(ancestor)
        {
            return .volumeNotMounted(path: rootPath)
        }

        return .pathNotFound(path: subpath ?? rootPath)
    }

    /// The volume mount point portion of an absolute path — its first two
    /// path components, e.g. `/Volumes/AstroDrive/sessions` → `/Volumes/AstroDrive`.
    public static func volumePortion(of path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return path }
        return "/" + comps[0] + "/" + comps[1]
    }

    /// Whether `path` has a path component literally named `Mobile
    /// Documents` — iCloud Drive's real on-disk container directory under
    /// `~/Library/`.
    static func hasMobileDocumentsComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains("Mobile Documents")
    }

    /// Walks up `path` one path component at a time until `pathExists`
    /// reports true, or there's nowhere left to go. `nil` only if not even
    /// `"/"` exists per `pathExists` — never happens against the real
    /// filesystem, but a fake in a test might omit it, so this doesn't loop
    /// forever in that case.
    static func nearestExistingAncestor(of path: String, pathExists: (String) -> Bool) -> String? {
        var current = path
        while true {
            if pathExists(current) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return nil }
            current = parent
        }
    }
}

/// Counts of what an incremental scan did, broken down by outcome per file.
public struct ScanSummary: Codable, Sendable {
    public var added: Int
    public var updated: Int
    public var unchanged: Int
    public var missing: Int
    /// Root-relative paths of directories the scan couldn't read (EPERM/
    /// EACCES) partway through the walk and skipped -- the walk continued
    /// past them rather than aborting the whole scan. Empty on a normal
    /// scan. Files already tracked under one of these paths are left alone
    /// (not marked missing) since the scan simply couldn't see them this
    /// time, not because they're actually gone.
    public var inaccessiblePaths: [String]
    /// Count of files whose size/mtime matched the stored row (so they're
    /// also counted in `unchanged`) but whose `PathClassifier` output
    /// (area/target/sessionDate/role) or `kind` bucket had drifted from what
    /// was on record -- a classifier fix landed after these rows were last
    /// scanned, and the rescan healed the stale values in place. 0 on a
    /// normal scan where nothing had drifted. Additive field, defaults to 0
    /// so existing JSON callers/decoders are unaffected.
    public var reclassified: Int
    /// Count of UNCHANGED, meta-bearing files (fit/fits/fz/cr3/tif) whose
    /// `fits_meta` was re-captured because a `--refresh-meta` backfill scan
    /// found either no `fits_meta` row at all, or (for a raw/image kind) a
    /// stored `exptime` of NULL. 0 on a normal scan, since this check never
    /// runs unless `refreshMeta` was requested. This counts recapture
    /// ATTEMPTS, not confirmed successes -- a still-corrupt file can be
    /// attempted again and again without ever producing a row, same as a
    /// brand-new scan of that file would. Additive field, defaults to 0 so
    /// existing JSON callers/decoders are unaffected.
    public var metaRefreshed: Int
    /// R11-T4: sorted, deduplicated list of every target that had at least
    /// one added, updated, or missing file THIS run -- the set a pipeline
    /// should re-rate/re-audit next, without having to diff two full `scan
    /// --json` snapshots itself. A target that only had `unchanged` files
    /// (including ones merely `reclassified` by a healed `PathClassifier`
    /// rule) never appears here. Empty on a scan that changed nothing.
    public var changedTargets: [String]
    /// R11-T9/F5: sorted, deduplicated list of every `(target, session date)`
    /// pair that had at least one ADDED or UPDATED **light** frame this run
    /// -- what the "Előző éjszaka" morning-triage page (`AppState
    /// .freshSessions`) considers "fresh material worth a look", a
    /// deliberately narrower notion than `changedTargets` above:
    /// - Only `.sessions`-area frames classified `role == .light` count --
    ///   a flat/dark/bias/master change, or a `stacks`/`processed`-area
    ///   file, never adds an entry (those have no "session date" a triage
    ///   card could show).
    /// - Only `added`/`updated` frames count, never `missing` ones -- a
    ///   light that vanished isn't "new material to review".
    /// - A frame merely `reclassified` (unchanged bytes, healed
    ///   classification) doesn't count either, same "nothing actually
    ///   arrived" reasoning.
    /// Empty on a scan that added/updated no light frame at all (including
    /// every fully-`unchanged` rescan).
    public var changedSessions: [SessionKey]

    /// One `(target, session date)` pair -- `changedSessions`' element type.
    /// A small `Codable`/`Hashable` value type rather than a bare tuple so it
    /// can live in a `Set` while walking and round-trip through `--json`
    /// (a Swift tuple is neither `Hashable` nor `Codable`).
    public struct SessionKey: Codable, Sendable, Equatable, Hashable, Comparable {
        public var target: String
        public var date: String

        public init(target: String, date: String) {
            self.target = target
            self.date = date
        }

        /// Sorts by target first, then date -- same tie-break order
        /// `changedTargets.sorted()` already uses for its own flat list, so
        /// `changedSessions` reads in the same deterministic, humanly
        /// sensible order.
        public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
            (lhs.target, lhs.date) < (rhs.target, rhs.date)
        }
    }

    public init(
        added: Int = 0,
        updated: Int = 0,
        unchanged: Int = 0,
        missing: Int = 0,
        inaccessiblePaths: [String] = [],
        reclassified: Int = 0,
        metaRefreshed: Int = 0,
        changedTargets: [String] = [],
        changedSessions: [SessionKey] = []
    ) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.missing = missing
        self.inaccessiblePaths = inaccessiblePaths
        self.reclassified = reclassified
        self.metaRefreshed = metaRefreshed
        self.changedTargets = changedTargets
        self.changedSessions = changedSessions
    }
}

public struct ScanProgress: Equatable, Sendable {
    public let scanned: Int
    public let total: Int?

    public var fraction: Double? {
        guard let total else { return nil }
        guard total > 0 else { return 1 }
        return Double(scanned) / Double(total)
    }

    public init(scanned: Int, total: Int?) {
        let safeTotal = total.map { max(0, $0) }
        self.total = safeTotal
        self.scanned = safeTotal.map { min(max(0, scanned), $0) } ?? max(0, scanned)
    }
}

/// Walks the library tree and incrementally syncs `Database.files` with
/// what's actually on disk. Never writes, deletes, or moves anything in the
/// library itself — the only filesystem access here is read-only directory
/// listing and file metadata (size/mtime).
public final class LibraryScanner {
    private let config: AstroConfig
    private let db: Database

    public init(config: AstroConfig, db: Database) {
        self.config = config
        self.db = db
    }

    /// The real-filesystem backing for `RootErrorClassifier.classify` --
    /// `RootErrorClassifierTests` injects a fake `VolumeProbe` instead so
    /// the boundary-detection logic doesn't need a real removable drive or
    /// iCloud container to test.
    public static let realVolumeProbe = RootErrorClassifier.VolumeProbe(
        pathExists: { FileManager.default.fileExists(atPath: $0) },
        isVolumeBoundary: { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: [
                .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIdentifierKey,
            ]) else { return false }
            if values.volumeIsRemovable == true { return true }
            if values.volumeIsInternal == false { return true }

            // Neither resource value flagged it -- fall back to comparing
            // this path's volume identifier against its own parent's. A
            // mismatch means this path sits at a filesystem boundary
            // (e.g. a firmlink-style mount like `/System/Volumes/Data`)
            // that the two booleans above don't reliably describe.
            guard let ownIdentifier = values.volumeIdentifier as? NSObject else { return false }
            let parentURL = url.deletingLastPathComponent()
            guard parentURL.path != url.path,
                  let parentValues = try? parentURL.resourceValues(forKeys: [.volumeIdentifierKey]),
                  let parentIdentifier = parentValues.volumeIdentifier as? NSObject
            else { return false }
            return !ownIdentifier.isEqual(parentIdentifier)
        }
    )

    /// Scans `config.rootPath`, or just the `subpath` subtree of it when
    /// given. `progress` is called every 100 files with the running count
    /// of files processed so far in this scan.
    ///
    /// `refreshMeta` opts an otherwise-normal incremental scan into also
    /// backfilling `fits_meta` for UNCHANGED meta-bearing files (fit/fits/
    /// fz/cr3/tif) that are missing metadata a feature added after they
    /// were first scanned would have captured -- see `refreshMetaIfNeeded`.
    /// Existing callers that don't pass it get the exact same behavior as
    /// before this parameter existed.
    ///
    /// Directory listing is done manually (not `FileManager.enumerator`) so
    /// exclusions are decided before descending into a directory, and a
    /// permission failure on any one directory can be caught and reported
    /// with that directory's path rather than aborting with no context.
    public func scan(
        subpath: String? = nil,
        refreshMeta: Bool = false,
        progress: (@Sendable (Int) -> Void)? = nil,
        progressUpdate: (@Sendable (ScanProgress) -> Void)? = nil,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ScanSummary {
        try Self.checkCancellation(shouldCancel)
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let startURL = subpath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root

        guard FileManager.default.fileExists(atPath: startURL.path) else {
            throw RootErrorClassifier.classify(
                rootPath: config.rootPath,
                subpath: subpath,
                probe: Self.realVolumeProbe
            )
        }

        var seen = Set<String>()
        var summary = ScanSummary()
        var processedCount = 0
        var changedTargets = Set<String>()
        var changedSessions = Set<ScanSummary.SessionKey>()

        // Only bothered with `progressUpdate` at all is a caller that wants
        // a progress UI -- `estimatedFileCount` walks the same tree the
        // scan is about to, so it's wasted work behind a caller (e.g. the
        // CLI) that never asked for progress updates in the first place.
        let total = progressUpdate == nil ? nil : estimatedFileCount(
            startURL: startURL,
            relPrefix: subpath ?? "",
            shouldCancel: shouldCancel,
            deadline: Date().addingTimeInterval(2.0)
        )
        progressUpdate?(ScanProgress(scanned: 0, total: total))

        // Every write below (`walk`'s per-file upserts, then `markMissing`)
        // runs inside ONE explicit transaction -- `walk` itself commits and
        // reopens it every ~2000 files (see `Self.transactionBatchSize`) so
        // a 100k+-file scan pays for one fsync per BATCH instead of one per
        // statement, which used to dominate wall-clock time on a spinning
        // disk or network share. On any error (including cancellation),
        // everything fully written so far this run is still a valid
        // incremental result and must survive -- committed here rather than
        // left open (and so invisible to every other reader) forever.
        try db.beginTransaction()
        do {
            try walk(
                dirURL: startURL,
                relPrefix: subpath ?? "",
                seen: &seen,
                processedCount: &processedCount,
                progress: progress,
                progressUpdate: progressUpdate,
                total: total,
                shouldCancel: shouldCancel,
                summary: &summary,
                refreshMeta: refreshMeta,
                changedTargets: &changedTargets,
                changedSessions: &changedSessions,
                isTopLevel: true
            )
            try Self.checkCancellation(shouldCancel)

            // `path`/`target` only -- see `trackedPathsAndTargets`'s own doc
            // comment on why this is lighter than `allFiles` for a caller
            // that never touches any of the other twelve columns.
            let tracked = try db.trackedPathsAndTargets(includeMissing: false)
            let scoped: [(path: String, target: String?)]
            if let subpath {
                scoped = tracked.filter { $0.path == subpath || $0.path.hasPrefix(subpath + "/") }
            } else {
                scoped = tracked
            }
            // Byte-wise (not `Set<String>`'s Unicode-canonical) membership
            // check against `seen` -- see `PathNormalization`'s doc comment.
            // Without this, a STALE differently-normalized row already in
            // the DB (from before every relative path was normalized at
            // scan time below) would compare as "still present" here even
            // though its bytes never matched anything actually seen this
            // scan, undercounting `missing` relative to what
            // `db.markMissing` below actually retires.
            let seenBytes = PathNormalization.byteSet(seen)
            summary.missing = scoped.reduce(into: 0) { count, record in
                guard !PathNormalization.containsByteWise(record.path, in: seenBytes) else { return }
                guard !Self.isUnder(record.path, anyOf: summary.inaccessiblePaths) else { return }
                count += 1
                if let target = record.target { changedTargets.insert(target) }
            }

            try db.markMissing(pathsNotIn: seen, underSubpath: subpath, excludingPrefixes: summary.inaccessiblePaths)
            try Self.checkCancellation(shouldCancel)
            try db.commitTransaction()
        } catch {
            try? db.commitTransaction()
            throw error
        }

        summary.changedTargets = changedTargets.sorted()
        summary.changedSessions = changedSessions.sorted()
        progressUpdate?(ScanProgress(scanned: processedCount, total: processedCount))
        return summary
    }

    /// How many files `walk` fully records before committing the open
    /// transaction and opening a fresh one -- bounds how much work a crash
    /// or a killed process partway through an enormous scan could lose to
    /// an uncommitted transaction, while still amortizing the fsync cost
    /// over a large batch. ~2000 is arbitrary but conservative: at typical
    /// FITS/RAW frame-file sizes this is a few seconds of scanning even on
    /// a slow disk, not minutes.
    static let transactionBatchSize = 2000

    private static func isUnder(_ path: String, anyOf prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Walk

    /// `isTopLevel` distinguishes the very first directory of this scan
    /// invocation (the configured root, or the requested `subpath`) from
    /// every directory found underneath it during the recursive walk. An
    /// EPERM/EACCES reading the top-level directory itself still aborts the
    /// whole scan with `.accessDenied` -- that contract (CLI exit 2, etc.)
    /// is unchanged. The SAME error reading a deeper directory instead skips
    /// just that directory's subtree (recorded in `summary.inaccessiblePaths`)
    /// and lets the rest of the tree keep scanning -- one locked-down folder
    /// partway through a large real-world library shouldn't blow up the
    /// entire scan.
    private func walk(
        dirURL: URL,
        relPrefix: String,
        seen: inout Set<String>,
        processedCount: inout Int,
        progress: (@Sendable (Int) -> Void)?,
        progressUpdate: (@Sendable (ScanProgress) -> Void)?,
        total: Int?,
        shouldCancel: @Sendable () -> Bool,
        summary: inout ScanSummary,
        refreshMeta: Bool,
        changedTargets: inout Set<String>,
        changedSessions: inout Set<ScanSummary.SessionKey>,
        isTopLevel: Bool = false
    ) throws {
        try Self.checkCancellation(shouldCancel)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            )
        } catch {
            guard isPermissionError(error) else { throw error }
            guard isTopLevel else {
                summary.inaccessiblePaths.append(relPrefix)
                return
            }
            throw AstroError.accessDenied(path: relPrefix)
        }

        for entryURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Self.checkCancellation(shouldCancel)
            let name = entryURL.lastPathComponent
            // Normalized to NFC at the exact point a filesystem-derived
            // relative path becomes part of this file's DB identity -- see
            // `PathNormalization`'s doc comment for why (a library that's
            // moved between HFS+/NFD and APFS-or-SMB/NFC naming would
            // otherwise get a duplicate row per accented path).
            let relativePath = PathNormalization.canonical(relPrefix.isEmpty ? name : relPrefix + "/" + name)

            // A file can vanish between `contentsOfDirectory` above and this
            // `resourceValues` call -- a capture session still writing to
            // this directory, Siril temp files, an SMB share reconnecting
            // mid-scan. That used to throw (NSFileReadNoSuchFileError) and
            // fail the WHOLE scan over one file that simply isn't there
            // anymore; skipping just this entry is consistent with how a
            // deeper directory's own read failure is handled just above.
            guard let values = try? entryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]) else { continue }
            // A Siril/processing work tree can leave dangling sequence
            // symlinks behind. They are references, not library frames;
            // indexing the link's own byte length makes the planner's DB
            // fingerprint disagree with the executor's regular-file-only
            // filesystem fingerprint. Skip all symbolic links consistently
            // (hard links remain ordinary files and are still indexed).
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory ?? false

            if isDirectory {
                guard !isExcludedDir(name: name, relativePath: relativePath) else { continue }
                try walk(
                    dirURL: entryURL,
                    relPrefix: relativePath,
                    seen: &seen,
                    processedCount: &processedCount,
                    progress: progress,
                    progressUpdate: progressUpdate,
                    total: total,
                    shouldCancel: shouldCancel,
                    summary: &summary,
                    refreshMeta: refreshMeta,
                    changedTargets: &changedTargets,
                    changedSessions: &changedSessions
                )
                continue
            }

            guard !isExcludedFile(name: name, relativePath: relativePath) else { continue }

            seen.insert(relativePath)
            processedCount += 1
            if processedCount % 100 == 0 {
                progress?(processedCount)
            }

            try recordFile(
                relativePath: relativePath,
                fileURL: entryURL,
                values: values,
                summary: &summary,
                refreshMeta: refreshMeta,
                changedTargets: &changedTargets,
                changedSessions: &changedSessions
            )
            // Checked only AFTER `recordFile` fully returns, never between
            // its own writes -- a commit boundary always lands between two
            // whole files, so the transaction `scan()` commits on an error
            // right after this never contains a half-written file.
            if processedCount % LibraryScanner.transactionBatchSize == 0 {
                try db.commitTransaction()
                try db.beginTransaction()
            }
            if processedCount % 64 == 0 {
                progressUpdate?(ScanProgress(scanned: processedCount, total: total))
            }
        }
    }

    private static func checkCancellation(
        _ shouldCancel: @Sendable () -> Bool
    ) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    /// A cheap upper-bound file count for `ScanProgress.total`, computed by
    /// walking the same tree `walk` is about to (respecting the same
    /// directory/file exclusions) but touching only `isDirectoryKey`/
    /// `isSymbolicLinkKey` per entry -- none of the size/mtime/FITS-header
    /// work the real scan does per file. Without this, the FIRST scan of a
    /// library shows an indeterminate spinner the entire time, since
    /// `walk` alone has no way to know how many files are left until it's
    /// already seen all of them.
    ///
    /// Bails out to `nil` (never partially reports a total) if it's still
    /// running past `deadline` or the caller cancels -- an honest
    /// indeterminate progress bar beats stalling the real scan behind a
    /// slow pre-count on an enormous library or a network/spinning-disk
    /// root, where directory enumeration itself can be the expensive part.
    private func estimatedFileCount(
        startURL: URL,
        relPrefix: String,
        shouldCancel: @Sendable () -> Bool,
        deadline: Date
    ) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: startURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }

        let startComponents = startURL.standardizedFileURL.pathComponents
        var count = 0
        var visited = 0

        for case let entryURL as URL in enumerator {
            visited += 1
            // Checked periodically, not per-entry -- `shouldCancel`/`Date()`
            // aren't free, and this loop can run over hundreds of thousands
            // of entries on a real library.
            if visited % 256 == 0, shouldCancel() || Date() >= deadline {
                return nil
            }

            guard let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true
            else { continue }

            let entryComponents = entryURL.standardizedFileURL.pathComponents
            let suffix = entryComponents.count > startComponents.count
                ? entryComponents[startComponents.count...].joined(separator: "/")
                : entryURL.lastPathComponent
            let relativePath = PathNormalization.canonical(relPrefix.isEmpty ? suffix : relPrefix + "/" + suffix)
            let name = entryURL.lastPathComponent

            if values.isDirectory == true {
                if isExcludedDir(name: name, relativePath: relativePath) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard !isExcludedFile(name: name, relativePath: relativePath) else { continue }
            count += 1
        }
        return count
    }

    private func recordFile(
        relativePath: String,
        fileURL: URL,
        values: URLResourceValues,
        summary: inout ScanSummary,
        refreshMeta: Bool,
        changedTargets: inout Set<String>,
        changedSessions: inout Set<ScanSummary.SessionKey>
    ) throws {
        let size = Int64(values.fileSize ?? 0)
        let mtime = (values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let info = PathClassifier.classify(relativePath: relativePath)
        let kind = Self.kind(for: ext)

        let existing = try db.file(path: relativePath)
        if let existing, !existing.missing, existing.size == size, abs(existing.mtime - mtime) <= 1.0 {
            summary.unchanged += 1
            try healStaleClassification(existing: existing, info: info, kind: kind, summary: &summary)
            // Cheap, targeted backfill for rows scanned before schema v3 (or
            // whose earlier stat call simply failed) -- only when missing,
            // to avoid a stat() on every unchanged file every scan.
            if existing.inode == nil, let fileID = existing.id {
                let (inode, nlink) = Self.inodeAndNlink(atPath: fileURL.path)
                if inode != nil {
                    try db.backfillInode(id: fileID, inode: inode, nlink: nlink)
                }
            }
            if refreshMeta, let fileID = existing.id {
                try refreshMetaIfNeeded(
                    fileID: fileID, kind: kind, ext: ext, url: fileURL,
                    relativePath: relativePath, info: info, summary: &summary
                )
            }
            return
        }

        // Reaching this point means either the file is brand new (`existing`
        // is nil) or something about it changed (size/mtime/missing-flag
        // differs from what's on record) — the only case that keeps a prior
        // `contentHash` is the fast `unchanged` path above, which returns
        // before ever building a record. So any hash cached from a previous
        // scan is stale here and must be dropped, not carried forward.
        let (inode, nlink) = Self.inodeAndNlink(atPath: fileURL.path)
        let record = FileRecord(
            id: existing?.id,
            path: relativePath,
            size: size,
            mtime: mtime,
            ext: ext,
            kind: kind,
            area: info.area,
            target: info.target,
            sessionDate: info.dateRaw,
            role: info.role,
            contentHash: nil,
            scannedAt: Date().timeIntervalSince1970,
            missing: false,
            inode: inode,
            nlink: nlink
        )
        let fileID = try db.upsertFile(record)

        if existing == nil {
            summary.added += 1
        } else {
            summary.updated += 1
        }
        if let target = info.target { changedTargets.insert(target) }
        // R11-T9/F5: only a `.sessions`-area LIGHT frame counts as "fresh
        // material" for the morning-triage page -- see `changedSessions`'
        // own doc comment for the full reasoning (missing frames, non-light
        // roles, and stacks/processed files are deliberately excluded).
        if info.area == .sessions, info.role == .light, let target = info.target, let date = info.dateRaw {
            changedSessions.insert(ScanSummary.SessionKey(target: target, date: date))
        }

        // Metadata capture only runs for NEW/CHANGED files (never for the
        // `unchanged` early-return above) — that's what keeps incremental
        // rescans of a large library fast.
        try captureMeta(fileID: fileID, ext: ext, url: fileURL, relativePath: relativePath, info: info)

        // A loose frame sitting directly in a session date dir (no lights/
        // flats/darks/biases subdir under it -- real libraries have these)
        // classifies from the path alone as role `.other`. Now that its FITS
        // header has just been read above, refine the role from IMAGETYP so
        // it still counts correctly in stats/calibration coverage. Only
        // reachable for new/changed files, same as the meta capture itself.
        try refineLooseFrameRole(fileID: fileID, info: info, ext: ext, baseRecord: record)
    }

    /// Files whose size/mtime match the stored row (the `unchanged` fast
    /// path in `recordFile`) still skip metadata re-capture, but their
    /// classification is pure string work over `relativePath` -- cheap
    /// enough to recompute on every scan. When `PathClassifier` logic
    /// changes between releases (or gains a new area/role it didn't
    /// previously recognize), already-scanned rows would otherwise keep
    /// their OLD classification forever, since an unchanged file never
    /// reaches the upsert in `recordFile`. This recomputes `info`/`kind`
    /// (already done by the caller) and heals the stored row in place when
    /// they've drifted -- no FITS/ImageIO re-read, since file content
    /// (and therefore any content-derived meta) hasn't changed.
    private func healStaleClassification(
        existing: FileRecord,
        info: PathInfo,
        kind: String,
        summary: inout ScanSummary
    ) throws {
        // Loose-frame guard: `refineLooseFrameRole` can upgrade a path-only
        // `.other` role to a specific frame role (light/flat/dark/bias)
        // using the FITS IMAGETYP header -- content the pure path
        // classifier never sees. A rescan of that same (unchanged) file
        // must not undo that upgrade just because the path alone still
        // resolves to `.other`; keep the stored role in that case.
        //
        // EXCEPT when the path is non-promotable session residue (see
        // `isNonPromotableSessionResidue`): a specific frame role there can
        // only be a leftover wrong promotion from BEFORE `refineLooseFrameRole`
        // grew its residue guards above (residue is never promoted going
        // forward, so no legitimate upgrade could have produced this
        // combination post-fix). Demote it back to the path-derived `.other`
        // so a plain rescan is self-healing, without needing a dedicated
        // migration.
        let specificFrameRoles: Set<FrameRole> = [.light, .flat, .dark, .bias]
        let effectiveRole: FrameRole
        if info.area == .sessions, info.role == .other, specificFrameRoles.contains(existing.role) {
            effectiveRole = isNonPromotableSessionResidue(path: existing.path) ? .other : existing.role
        } else {
            effectiveRole = info.role
        }

        guard existing.area != info.area
            || existing.target != info.target
            || existing.sessionDate != info.dateRaw
            || existing.role != effectiveRole
            || existing.kind != kind
        else {
            return
        }

        var healed = existing
        healed.area = info.area
        healed.target = info.target
        healed.sessionDate = info.dateRaw
        healed.role = effectiveRole
        healed.kind = kind
        healed.scannedAt = Date().timeIntervalSince1970
        _ = try db.upsertFile(healed)
        summary.reclassified += 1
    }

    /// Whether a file at `path`, sitting loose in a session date dir (path
    /// role `.other`), must never be promoted to a specific frame role via
    /// its FITS IMAGETYP header -- `true` when EITHER of two independent
    /// engines says so, neither one copied:
    ///  1. `ResidueMatcher.isResidue` -- config-driven, from
    ///     `AstroConfig.residuePatterns`/`residueDirNames` (universal) plus
    ///     `AstroConfig.sessionResiduePatterns` (applied by `ResidueMatcher`
    ///     itself to `.sessions`-area paths only -- the vocabulary that is
    ///     junk here but WANTED StackDiscovery output in `stacks/`/
    ///     `processed/`, e.g. `result_*` integrations). The same predicate
    ///     `CleanupReport`'s cleanup summary uses.
    ///  2. `StackDiscovery.classifiesAsStackProduct` -- code-driven, the
    ///     same starless/starmask/edited/export recognition `stacks/`/
    ///     `processed`-area variant grouping already applies to filenames.
    /// The second check overlaps the session-pattern defaults on purpose: a
    /// Siril byproduct named `starless_*` sitting loose in `sessions/` must
    /// still never be promoted even when a library's `config.json` empties
    /// the pattern lists, since this recognition is code, not config. The
    /// session-pattern layer in turn reaches names `variantKind` can't
    /// (`result_Ha_12720s.fit` classifies `.original`) and is what
    /// `CleanupReport` surfaces to the user.
    private func isNonPromotableSessionResidue(path: String) -> Bool {
        if ResidueMatcher.isResidue(path: path, config: config) { return true }
        let fileName = (path as NSString).lastPathComponent
        return StackDiscovery.classifiesAsStackProduct(fileName: fileName)
    }

    private func refineLooseFrameRole(fileID: Int64, info: PathInfo, ext: String, baseRecord: FileRecord) throws {
        guard info.area == .sessions, info.role == .other else { return }
        guard ["fit", "fits", "fz"].contains(ext) else { return }
        // Siril stack products (starless/starmask/registered sequences)
        // inherit IMAGETYP='Light Frame' from the subs they were stacked
        // from -- a residue file sitting loose in a session date dir hits
        // the exact same "role .other, FITS header says Light" shape as a
        // genuine loose light frame. Never promote it via IMAGETYP -- see
        // `isNonPromotableSessionResidue`'s doc comment for the two
        // independent engines this consults.
        guard !isNonPromotableSessionResidue(path: baseRecord.path) else { return }
        guard let meta = try db.fitsMeta(fileID: fileID),
              let imagetyp = meta.imagetyp,
              let refined = Self.roleFromImagetyp(imagetyp)
        else { return }

        var refinedRecord = baseRecord
        refinedRecord.role = refined
        _ = try db.upsertFile(refinedRecord)
    }

    /// Delegates to `FrameRoleFromHeader` -- see that type's doc comment for
    /// why this is no longer its own copy of the predicate.
    private static func roleFromImagetyp(_ imagetyp: String) -> FrameRole? {
        FrameRoleFromHeader.role(fromImagetyp: imagetyp)
    }

    // MARK: - Metadata capture

    /// Reads FITS header / CR3-or-TIFF image metadata for a just-recorded
    /// file and upserts it into `fits_meta` (or, for a session `README.txt`,
    /// parses its "Fill in metadata" notes into `session_notes` -- see
    /// `captureReadmeNotes`). Extensions this scanner doesn't know how to
    /// introspect (jpg, png, xmp, ...) are a silent no-op.
    private func captureMeta(fileID: Int64, ext: String, url: URL, relativePath: String, info: PathInfo) throws {
        switch ext {
        case _ where Self.fitsExtensions.contains(ext):
            // A corrupt/unreadable FITS header is swallowed by design here:
            // the file itself is still recorded in `files` above, just
            // without a `fits_meta` row. R11-T4's `CorruptFITSRule` (audit)
            // is what surfaces this to the user -- a light/flat/dark/bias/
            // master-role file at a FITS-kind extension with no `fits_meta`
            // row at all gets flagged `sure_error` there, since the parse
            // failure itself isn't surfaced anywhere else.
            guard let header = try? FITSReader.readHeader(url: url) else { return }
            try db.upsertFITSMeta(Self.fitsMetaRecord(fileID: fileID, header: header))
        case _ where Self.imageMetaExtensions.contains(ext):
            guard let meta = ImageMetaReader.read(url: url) else { return }
            // DSLR frames have no FITS EXPTIME/GAIN header -- their Exif
            // ExposureTime and ISOSpeedRatings are the equivalent values, so
            // they're stored in the same `exptime`/`gain` columns FITS
            // frames use. This is what lets StatsQueries' integration-time
            // and exposure-breakdown queries (which only ever look at
            // `fits_meta.exptime`) count CR3/RAW/TIFF/JPEG lights the same
            // way as FITS lights, instead of all landing in the "unknown"
            // bucket. ISO is unitless (not a real e-/ADU gain), but reusing
            // the column keeps every frame kind on one schema.
            //
            // Exif `DateTimeOriginal` is camera-LOCAL wall-clock time, not
            // UTC, but `date_obs` is read back everywhere (SessionTimeline,
            // AstroBin export, ...) as a UTC instant -- so this converts
            // using the frame's own `OffsetTimeOriginal` when the body wrote
            // one, else the Mac's current time zone (documented assumption:
            // the machine doing the scan usually sits where the camera was).
            // The raw Exif string itself isn't retained anywhere for
            // provenance -- `headerJSON` below is deliberately left nil for
            // non-FITS frames (see `fitsMetaRecord`'s own doc comment: it's
            // the ORIGINAL FITS header, never repurposed for Exif data).
            let dateObs = meta.dateTaken.flatMap {
                ExifDateConversion.utcDateObsString(dateTaken: $0, offsetTimeOriginal: meta.dateTakenOffset)
            } ?? meta.dateTaken
            try db.upsertFITSMeta(
                FITSMetaRecord(
                    fileID: fileID,
                    exptime: meta.exposureSeconds,
                    gain: meta.iso.map(Double.init),
                    instrume: meta.cameraModel,
                    focallen: meta.focalLengthMM,
                    dateObs: dateObs
                )
            )
        case "txt":
            try captureReadmeNotes(relativePath: relativePath, info: info, url: url)
        default:
            return
        }
    }

    /// R6-4: sky conditions (Bortle, SQM, seeing, dew, notes) can't come
    /// from a FITS header -- but the user's own workflow already writes them
    /// into each session's `README.txt` (`SessionCreator`'s "Fill in
    /// metadata" template). Parsing that text is what makes a night
    /// searchable and feeds Bortle/SQM into the AstroBin export. Only a
    /// session-level `README.txt` counts: `sessions/<target>/<date>/
    /// README.txt` directly (never a stray text file elsewhere in the
    /// library, and never one nested inside a role subdir -- `info.role`
    /// is `.other` for exactly the direct-under-date-dir case, since a role
    /// subdir needs one path component more than `PathClassifier` requires
    /// to resolve `target`/`dateRaw` at all). READ ONLY: the file itself is
    /// never written back to. A non-UTF8 or oversized (>64 KiB) file, or a
    /// read failure, is silently skipped -- same "swallow and move on"
    /// convention the FITS branch above uses for a corrupt header.
    private func captureReadmeNotes(relativePath: String, info: PathInfo, url: URL) throws {
        guard info.area == .sessions, info.role == .other,
              let target = info.target, let date = info.dateRaw,
              (relativePath as NSString).lastPathComponent == "README.txt"
        else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let notes = ReadmeNotesParser.parse(data: data) else { return }
        try db.upsertSessionNotes(target: target, date: date, notes: notes)
    }

    /// Backfill hook for `--refresh-meta` scans. Only ever called for
    /// UNCHANGED files, and only when the caller asked for a refresh: a
    /// normal incremental scan never reaches this, so its extra `fits_meta`/
    /// `session_notes` lookup stays off the hot path. Re-captures metadata
    /// when a feature added after the file was first scanned would have
    /// captured more than what's on record: either the file has no
    /// `fits_meta` row at all (e.g. an earlier parse failure), or it's a
    /// raw/image kind whose stored `exptime` is NULL (scanned before Exif
    /// ExposureTime capture existed) -- or, for a session `README.txt`, no
    /// `session_notes` row exists yet at all (a README scanned before R6-4
    /// existed, or a template README that was entirely blank on first scan
    /// and has since been filled in by hand without the file's size/mtime
    /// otherwise triggering a normal rescan). Files/sessions with complete
    /// data are left untouched.
    private func refreshMetaIfNeeded(
        fileID: Int64,
        kind: String,
        ext: String,
        url: URL,
        relativePath: String,
        info: PathInfo,
        summary: inout ScanSummary
    ) throws {
        switch ext {
        case _ where Self.fitsExtensions.contains(ext) || Self.imageMetaExtensions.contains(ext):
            let existingMeta = try db.fitsMeta(fileID: fileID)
            let needsRefresh: Bool
            if existingMeta == nil {
                needsRefresh = true
            } else if kind == "raw" || kind == "image" {
                needsRefresh = existingMeta?.exptime == nil
            } else {
                needsRefresh = false
            }
            guard needsRefresh else { return }
            summary.metaRefreshed += 1
            try captureMeta(fileID: fileID, ext: ext, url: url, relativePath: relativePath, info: info)
        case "txt":
            guard info.area == .sessions, info.role == .other,
                  let target = info.target, let date = info.dateRaw,
                  (relativePath as NSString).lastPathComponent == "README.txt"
            else { return }
            guard try db.sessionNotes(target: target, date: date).isEmpty else { return }
            summary.metaRefreshed += 1
            try captureMeta(fileID: fileID, ext: ext, url: url, relativePath: relativePath, info: info)
        default:
            return
        }
    }

    private static func fitsMetaRecord(fileID: Int64, header: FITSHeader) -> FITSMetaRecord {
        let headerJSON = (try? JSONEncoder().encode(header.allCards)).flatMap { String(data: $0, encoding: .utf8) }
        return FITSMetaRecord(
            fileID: fileID,
            // `EXPTIME` is the standard keyword, but some capture tools
            // (e.g. certain PixInsight/SGP exports) only write `EXPOSURE`
            // instead -- without this fallback, those frames' exposure time
            // was silently lost even though it's right there in the header.
            exptime: header.double("EXPTIME") ?? header.double("EXPOSURE"),
            gain: header.double("GAIN"),
            offset: header.double("OFFSET"),
            setTemp: header.double("SET-TEMP"),
            ccdTemp: header.double("CCD-TEMP"),
            instrume: header.string("INSTRUME"),
            focallen: header.double("FOCALLEN"),
            filter: header.string("FILTER"),
            // `DATE-OBS` is the standard keyword; `DATE-LOC` (local-time
            // variant some tools write instead/alongside) and plain `DATE`
            // (the generic FITS "file written" keyword, used as a last
            // resort when neither observation-specific keyword is present)
            // are the two real-world fallbacks -- same "don't lose data a
            // less-common but valid tool already wrote" reasoning as the
            // EXPTIME/EXPOSURE fallback above.
            dateObs: header.string("DATE-OBS") ?? header.string("DATE-LOC") ?? header.string("DATE"),
            imagetyp: header.string("IMAGETYP"),
            naxis1: header.int("NAXIS1"),
            naxis2: header.int("NAXIS2"),
            xpixsz: header.double("XPIXSZ"),
            egain: header.double("EGAIN"),
            headerJSON: headerJSON
        )
    }

    // MARK: - Exclusions

    private var exclusion: ExclusionRules { ExclusionRules(config: config) }

    private func isExcludedDir(name: String, relativePath: String) -> Bool {
        exclusion.isExcludedDir(name: name, relativePath: relativePath)
    }

    private func isExcludedFile(name: String, relativePath: String) -> Bool {
        // Dotfiles are noise from the tool's point of view, except
        // `.DS_Store`: that one is residue the audit engine reports on, so
        // it must be recorded like any other file.
        if name.hasPrefix(".") && name != ".DS_Store" { return true }
        return exclusion.isExcludedPath(relativePath)
    }

    // MARK: - Inode / link count

    /// The filesystem inode number and hardlink count for the file at
    /// `path`, via `FileManager.attributesOfItem` (`.systemFileNumber` /
    /// `.referenceCount`). `(nil, nil)` if the stat call fails -- callers
    /// treat that the same as "not known yet", same as a pre-v3 row.
    private static func inodeAndNlink(atPath path: String) -> (inode: Int64?, nlink: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (nil, nil)
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
        let nlink = (attributes[.referenceCount] as? NSNumber)?.int64Value
        return (inode, nlink)
    }

    // MARK: - Kind bucket

    /// Extensions this scanner records as `kind == "fits"` -- FITS proper
    /// (`.fit`/`.fits`/`.fts`, all in real-world use by different tools) plus
    /// its gzip'd `.fz` sibling. `public` (card-import wizard): the
    /// source-card scan step needs the exact same "does this file count as
    /// a capture frame at all" list the library scanner already uses,
    /// rather than a second, hand-picked one that could silently drift from
    /// it (e.g. missing `.fz`, or adding an extension this scanner would
    /// never index).
    public static let fitsExtensions: Set<String> = ["fit", "fits", "fts", "fz"]
    /// Extensions this scanner records as `kind == "raw"` -- every camera
    /// RAW format actually seen in a library, not just Canon's CR3: CR2
    /// (older Canon), NEF (Nikon), ARW (Sony), DNG (Adobe/generic, also
    /// what some phones and non-Canon bodies write directly), RAF (Fuji),
    /// ORF (Olympus/OM System), RW2 (Panasonic), PEF (Pentax), SRW
    /// (Samsung). Before this list only had `cr3`, so every other vendor's
    /// DSLR/mirrorless lights silently fell through `FrameSet`'s
    /// `frameExtensions` as "non-frame files" -- counted as zero usable
    /// integration time. `public` for the same cross-module reuse reason as
    /// `fitsExtensions` above.
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw",
    ]
    /// PixInsight's native format -- a common `lights/` frame for a
    /// PixInsight-first workflow (WBPP output, or lights converted from FITS
    /// early to keep 32-bit float precision). No reader exists anywhere in
    /// this codebase for XISF's own binary structure (it isn't FITS), so
    /// `captureMeta` never attempts one -- these frames are recorded and
    /// counted like any other frame, just without a `fits_meta` row, exactly
    /// like a CR3/RAW frame with no ImageIO-readable Exif. `public` for the
    /// same cross-module reuse reason as `fitsExtensions` above.
    public static let xisfExtensions: Set<String> = ["xisf"]
    /// Extensions `ImageMetaReader` (ImageIO/Exif) can introspect: every
    /// `rawExtensions` member (ImageIO's built-in RAW codecs handle NEF/ARW/
    /// DNG/... the same way they already handled CR3) plus the non-RAW image
    /// kinds a DSLR/phone/finished-export frame can show up as -- `tif`/
    /// `tiff` (both spellings are common) and `jpg`/`jpeg`. Before this only
    /// `cr3`/`tif` were introspected, so e.g. a NEF or JPEG light's Exif
    /// ExposureTime/ISO/capture-date never made it into `fits_meta` even
    /// though ImageIO can read all of these the same way.
    private static let imageMetaExtensions: Set<String> = rawExtensions.union(["tif", "tiff", "jpg", "jpeg"])

    private static func kind(for ext: String) -> String {
        if fitsExtensions.contains(ext) { return "fits" }
        if rawExtensions.contains(ext) { return "raw" }
        if xisfExtensions.contains(ext) { return "xisf" }
        switch ext {
        case "tif", "tiff", "png", "jpg", "jpeg":
            return "image"
        case "xmp":
            return "sidecar"
        case "seq", "lst":
            return "residue"
        case "txt":
            return "text"
        default:
            return "other"
        }
    }

}
