import Foundation

/// Decides what error a missing root/subpath should surface as. Split out
/// from `LibraryScanner.scan` so the decision (which never needs disk
/// access beyond one `volumeExists` check) can be unit-tested directly
/// without touching a real `/Volumes` mount point.
enum RootErrorClassifier {
    /// - `rootPath` starts with `/Volumes/` and its volume portion (the
    ///   first two path components, e.g. `/Volumes/images`) doesn't exist
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
    /// path components, e.g. `/Volumes/images/sessions` → `/Volumes/images`.
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

    public init(
        added: Int = 0,
        updated: Int = 0,
        unchanged: Int = 0,
        missing: Int = 0,
        inaccessiblePaths: [String] = [],
        reclassified: Int = 0,
        metaRefreshed: Int = 0
    ) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.missing = missing
        self.inaccessiblePaths = inaccessiblePaths
        self.reclassified = reclassified
        self.metaRefreshed = metaRefreshed
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
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> ScanSummary {
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

        try walk(
            dirURL: startURL,
            relPrefix: subpath ?? "",
            seen: &seen,
            processedCount: &processedCount,
            progress: progress,
            summary: &summary,
            refreshMeta: refreshMeta,
            isTopLevel: true
        )

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
        }

        try db.markMissing(pathsNotIn: seen, underSubpath: subpath, excludingPrefixes: summary.inaccessiblePaths)

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
        summary: inout ScanSummary,
        refreshMeta: Bool,
        isTopLevel: Bool = false
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
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
            let name = entryURL.lastPathComponent
            let relativePath = relPrefix.isEmpty ? name : relPrefix + "/" + name

            let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values.isDirectory ?? false

            if isDirectory {
                guard !isExcludedDir(name: name, relativePath: relativePath) else { continue }
                try walk(
                    dirURL: entryURL,
                    relPrefix: relativePath,
                    seen: &seen,
                    processedCount: &processedCount,
                    progress: progress,
                    summary: &summary,
                    refreshMeta: refreshMeta
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
                refreshMeta: refreshMeta
            )
        }
    }

    private func recordFile(
        relativePath: String,
        fileURL: URL,
        values: URLResourceValues,
        summary: inout ScanSummary,
        refreshMeta: Bool
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
        let specificFrameRoles: Set<FrameRole> = [.light, .flat, .dark, .bias]
        let effectiveRole: FrameRole
        if info.area == .sessions, info.role == .other, specificFrameRoles.contains(existing.role) {
            effectiveRole = existing.role
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

    private func refineLooseFrameRole(fileID: Int64, info: PathInfo, ext: String, baseRecord: FileRecord) throws {
        guard info.area == .sessions, info.role == .other else { return }
        guard ["fit", "fits", "fz"].contains(ext) else { return }
        guard let meta = try db.fitsMeta(fileID: fileID),
              let imagetyp = meta.imagetyp,
              let refined = Self.roleFromImagetyp(imagetyp)
        else { return }

        var refinedRecord = baseRecord
        refinedRecord.role = refined
        _ = try db.upsertFile(refinedRecord)
    }

    private static func roleFromImagetyp(_ imagetyp: String) -> FrameRole? {
        let lower = imagetyp.lowercased()
        if lower.contains("light") { return .light }
        if lower.contains("flat") { return .flat }
        if lower.contains("dark") { return .dark }
        if lower.contains("bias") { return .bias }
        return nil
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
            // without a `fits_meta` row. TODO: a later audit task should
            // flag fits-kind files with no fits_meta row as corrupt FITS,
            // since the parse error itself isn't surfaced anywhere today.
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

    private static func kind(for ext: String) -> String {
        switch ext {
        case "fit", "fits", "fz":
            return "fits"
        case "cr3":
            return "raw"
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
