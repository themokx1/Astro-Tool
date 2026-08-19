import Foundation

/// Decides what error a missing root/subpath should surface as. Split out
/// from `LibraryScanner.scan` so the decision (which never needs disk
/// access beyond one `volumeExists` check) can be unit-tested directly
/// without touching a real `/Volumes` mount point.
enum RootErrorClassifier {
    /// - `rootPath` starts with `/Volumes/` and its volume portion (the
    ///   first two path components, e.g. `/Volumes/AstroDrive`) doesn't exist
    ///   per `volumeExists` → `.volumeNotMounted(path: rootPath)`.
    /// - Otherwise the missing root/subpath itself doesn't exist (but its
    ///   parent does) → `.pathNotFound(path:)`, using `subpath` when one was
    ///   given (a scoped scan under an existing root) or `rootPath` when the
    ///   root itself is what's missing.
    static func classify(
        rootPath: String,
        subpath: String?,
        volumeExists: (String) -> Bool
    ) -> AstroError {
        if rootPath.hasPrefix("/Volumes/") {
            let volume = volumePortion(of: rootPath)
            if !volumeExists(volume) {
                return .volumeNotMounted(path: rootPath)
            }
        }
        return .pathNotFound(path: subpath ?? rootPath)
    }

    /// The volume mount point portion of an absolute path — its first two
    /// path components, e.g. `/Volumes/AstroDrive/sessions` → `/Volumes/AstroDrive`.
    static func volumePortion(of path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return path }
        return "/" + comps[0] + "/" + comps[1]
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
                volumeExists: { FileManager.default.fileExists(atPath: $0) }
            )
        }

        var seen = Set<String>()
        var summary = ScanSummary()
        var processedCount = 0
        var changedTargets = Set<String>()
        var changedSessions = Set<ScanSummary.SessionKey>()
        progressUpdate?(ScanProgress(scanned: 0, total: nil))

        try walk(
            dirURL: startURL,
            relPrefix: subpath ?? "",
            seen: &seen,
            processedCount: &processedCount,
            progress: progress,
            progressUpdate: progressUpdate,
            shouldCancel: shouldCancel,
            summary: &summary,
            refreshMeta: refreshMeta,
            changedTargets: &changedTargets,
            changedSessions: &changedSessions,
            isTopLevel: true
        )
        try Self.checkCancellation(shouldCancel)

        let tracked = try db.allFiles(includeMissing: false)
        let scoped: [FileRecord]
        if let subpath {
            scoped = tracked.filter { $0.path == subpath || $0.path.hasPrefix(subpath + "/") }
        } else {
            scoped = tracked
        }
        summary.missing = scoped.reduce(into: 0) { count, record in
            guard !seen.contains(record.path) else { return }
            guard !Self.isUnder(record.path, anyOf: summary.inaccessiblePaths) else { return }
            count += 1
            if let target = record.target { changedTargets.insert(target) }
        }

        try db.markMissing(pathsNotIn: seen, underSubpath: subpath, excludingPrefixes: summary.inaccessiblePaths)
        try Self.checkCancellation(shouldCancel)

        summary.changedTargets = changedTargets.sorted()
        summary.changedSessions = changedSessions.sorted()
        progressUpdate?(ScanProgress(scanned: processedCount, total: processedCount))
        return summary
    }

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
            let relativePath = relPrefix.isEmpty ? name : relPrefix + "/" + name

            let values = try entryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
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
            if processedCount % 64 == 0 {
                progressUpdate?(ScanProgress(scanned: processedCount, total: nil))
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
    ///     `AstroConfig.residuePatterns`/`residueDirNames`, the same
    ///     predicate `CleanupReport`'s cleanup summary uses.
    ///  2. `StackDiscovery.classifiesAsStackProduct` -- code-driven, the
    ///     same starless/starmask/edited/export recognition `stacks/`/
    ///     `processed`-area variant grouping already applies to filenames.
    /// The second check exists because `starless`/`starmask`/`graxpert`
    /// tokens can't safely live in `residuePatterns`'s defaults (see that
    /// property's own doc comment -- they're first-class, WANTED variant
    /// output there, not residue), but a Siril byproduct using those exact
    /// names sitting loose in `sessions/` must still never be promoted,
    /// REGARDLESS of what a given library's `config.json` says, since this
    /// recognition is code, not config.
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
        case "fit", "fits", "fz":
            // A corrupt/unreadable FITS header is swallowed by design here:
            // the file itself is still recorded in `files` above, just
            // without a `fits_meta` row. R11-T4's `CorruptFITSRule` (audit)
            // is what surfaces this to the user -- a light/flat/dark/bias/
            // master-role file at a FITS-kind extension with no `fits_meta`
            // row at all gets flagged `sure_error` there, since the parse
            // failure itself isn't surfaced anywhere else.
            guard let header = try? FITSReader.readHeader(url: url) else { return }
            try db.upsertFITSMeta(Self.fitsMetaRecord(fileID: fileID, header: header))
        case "cr3", "tif":
            guard let meta = ImageMetaReader.read(url: url) else { return }
            // DSLR frames have no FITS EXPTIME/GAIN header -- their Exif
            // ExposureTime and ISOSpeedRatings are the equivalent values, so
            // they're stored in the same `exptime`/`gain` columns FITS
            // frames use. This is what lets StatsQueries' integration-time
            // and exposure-breakdown queries (which only ever look at
            // `fits_meta.exptime`) count CR3/TIFF lights the same way as
            // FITS lights, instead of all landing in the "unknown" bucket.
            // ISO is unitless (not a real e-/ADU gain), but reusing the
            // column keeps every frame kind on one schema.
            try db.upsertFITSMeta(
                FITSMetaRecord(
                    fileID: fileID,
                    exptime: meta.exposureSeconds,
                    gain: meta.iso.map(Double.init),
                    instrume: meta.cameraModel,
                    focallen: meta.focalLengthMM,
                    dateObs: meta.dateTaken
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
        case "fit", "fits", "fz", "cr3", "tif":
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
            exptime: header.double("EXPTIME"),
            gain: header.double("GAIN"),
            offset: header.double("OFFSET"),
            setTemp: header.double("SET-TEMP"),
            ccdTemp: header.double("CCD-TEMP"),
            instrume: header.string("INSTRUME"),
            focallen: header.double("FOCALLEN"),
            filter: header.string("FILTER"),
            dateObs: header.string("DATE-OBS"),
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
    /// plus its gzip'd `.fz` sibling. `public` (card-import wizard): the
    /// source-card scan step needs the exact same "does this file count as
    /// a capture frame at all" list the library scanner already uses,
    /// rather than a second, hand-picked one that could silently drift from
    /// it (e.g. missing `.fz`, or adding an extension this scanner would
    /// never index).
    public static let fitsExtensions: Set<String> = ["fit", "fits", "fz"]
    /// Extensions this scanner records as `kind == "raw"` -- camera RAW
    /// (Canon CR3 today). `public` for the same cross-module reuse reason
    /// as `fitsExtensions` above.
    public static let rawExtensions: Set<String> = ["cr3"]

    private static func kind(for ext: String) -> String {
        if fitsExtensions.contains(ext) { return "fits" }
        if rawExtensions.contains(ext) { return "raw" }
        switch ext {
        case "tif", "png", "jpg", "jpeg":
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
