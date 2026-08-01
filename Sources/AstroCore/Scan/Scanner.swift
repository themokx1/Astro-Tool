import Foundation

/// Counts of what an incremental scan did, broken down by outcome per file.
public struct ScanSummary: Codable, Sendable {
    public var added: Int
    public var updated: Int
    public var unchanged: Int
    public var missing: Int

    public init(added: Int = 0, updated: Int = 0, unchanged: Int = 0, missing: Int = 0) {
        self.added = added
        self.updated = updated
        self.unchanged = unchanged
        self.missing = missing
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
    /// Directory listing is done manually (not `FileManager.enumerator`) so
    /// exclusions are decided before descending into a directory, and a
    /// permission failure on any one directory can be caught and reported
    /// with that directory's path rather than aborting with no context.
    public func scan(
        subpath: String? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> ScanSummary {
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let startURL = subpath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root

        guard FileManager.default.fileExists(atPath: startURL.path) else {
            if config.rootPath.hasPrefix("/Volumes/") {
                throw AstroError.volumeNotMounted(path: config.rootPath)
            } else {
                throw AstroError.accessDenied(path: subpath ?? "")
            }
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
            summary: &summary
        )

        let tracked = try db.allFiles(includeMissing: false)
        let scoped: [FileRecord]
        if let subpath {
            scoped = tracked.filter { $0.path == subpath || $0.path.hasPrefix(subpath + "/") }
        } else {
            scoped = tracked
        }
        summary.missing = scoped.reduce(into: 0) { count, record in
            if !seen.contains(record.path) { count += 1 }
        }

        try db.markMissing(pathsNotIn: seen, underSubpath: subpath)

        return summary
    }

    // MARK: - Walk

    private func walk(
        dirURL: URL,
        relPrefix: String,
        seen: inout Set<String>,
        processedCount: inout Int,
        progress: (@Sendable (Int) -> Void)?,
        summary: inout ScanSummary
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: []
            )
        } catch {
            if isPermissionError(error) {
                throw AstroError.accessDenied(path: relPrefix)
            }
            throw error
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
                    summary: &summary
                )
                continue
            }

            guard !isExcludedFile(name: name, relativePath: relativePath) else { continue }

            seen.insert(relativePath)
            processedCount += 1
            if processedCount % 100 == 0 {
                progress?(processedCount)
            }

            try recordFile(relativePath: relativePath, fileURL: entryURL, values: values, summary: &summary)
        }
    }

    private func recordFile(
        relativePath: String,
        fileURL: URL,
        values: URLResourceValues,
        summary: inout ScanSummary
    ) throws {
        let size = Int64(values.fileSize ?? 0)
        let mtime = (values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let info = PathClassifier.classify(relativePath: relativePath)

        let existing = try db.file(path: relativePath)
        if let existing, !existing.missing, existing.size == size, abs(existing.mtime - mtime) <= 1.0 {
            summary.unchanged += 1
            return
        }

        let record = FileRecord(
            id: existing?.id,
            path: relativePath,
            size: size,
            mtime: mtime,
            ext: ext,
            kind: Self.kind(for: ext),
            area: info.area,
            target: info.target,
            sessionDate: info.dateRaw,
            role: info.role,
            contentHash: existing?.contentHash,
            scannedAt: Date().timeIntervalSince1970,
            missing: false
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
        try captureMeta(fileID: fileID, ext: ext, url: fileURL)
    }

    // MARK: - Metadata capture

    /// Reads FITS header / CR3-or-TIFF image metadata for a just-recorded
    /// file and upserts it into `fits_meta`. Extensions this scanner doesn't
    /// know how to introspect (jpg, png, xmp, ...) are a silent no-op.
    private func captureMeta(fileID: Int64, ext: String, url: URL) throws {
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
            try db.upsertFITSMeta(
                FITSMetaRecord(
                    fileID: fileID,
                    instrume: meta.cameraModel,
                    focallen: meta.focalLengthMM,
                    dateObs: meta.dateTaken
                )
            )
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
