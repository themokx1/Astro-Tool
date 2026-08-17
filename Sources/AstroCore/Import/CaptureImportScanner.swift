import Foundation

/// Walks an EXTERNAL source (an SD card, an ASI Air's storage, any folder the
/// user picked) looking for capture files -- the card-import wizard's Source/
/// Classify steps. Read-only in every sense: this never writes to, moves, or
/// deletes anything under `sourceRoot`, and it never touches the library
/// itself either (that is `CaptureImportCommand`'s job, once a destination is
/// chosen).
///
/// Deliberately reuses `LibraryScanner`'s own `fitsExtensions`/
/// `rawExtensions` (the extensions the library scanner would treat as
/// `kind == "fits"`/`"raw"`) rather than a second, hand-picked list -- a file
/// this wizard would import but the scanner would never later see as a
/// tracked file (or vice versa) would be a silent, confusing seam.
public enum CaptureImportScanner {
    /// Scans `sourceRoot` shallowly-but-recursively (every subdirectory,
    /// however deep a card's own folder structure goes) for `.fit`/`.fits`/
    /// `.fz`/`.cr3` files. Hidden entries (dotfiles, `.Spotlight-V100`,
    /// `.Trashes`, ...) and symbolic links are skipped, mirroring
    /// `LibraryScanner.walk`'s own conventions for the same reasons: a
    /// card's own OS-written housekeeping is never a capture frame, and a
    /// symlink's target could point anywhere.
    ///
    /// A single file this can't `stat()` (permission revoked mid-scan, an
    /// ejected card) is skipped rather than aborting the whole scan --
    /// consistent with `LibraryScanner`'s own per-directory (not
    /// per-scan) failure handling, since a source card is exactly the kind
    /// of external, less-trustworthy medium that's more likely to hiccup
    /// mid-read.
    public static func scan(sourceRoot: URL) throws -> [DiscoveredCaptureFile] {
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            throw AstroError.pathNotFound(path: sourceRoot.path)
        }
        var results: [DiscoveredCaptureFile] = []
        try walk(sourceRoot, relPrefix: "", into: &results)
        return results.sorted { $0.relativeSourcePath < $1.relativeSourcePath }
    }

    private static func walk(_ dirURL: URL, relPrefix: String, into results: inout [DiscoveredCaptureFile]) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        } catch {
            // A locked-down subfolder on the card shouldn't abort the whole
            // scan -- same "skip and keep going" stance `LibraryScanner`
            // takes for a deeper directory (see `Scanner.walk`'s own doc
            // comment). The top-level `sourceRoot` itself is checked for
            // existence above, before this recursion starts, so a failure
            // here is always a DEEPER directory.
            return
        }

        for entryURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entryURL.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let relativePath = relPrefix.isEmpty ? name : relPrefix + "/" + name

            guard let values = try? entryURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ]) else { continue }
            guard values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                try walk(entryURL, relPrefix: relativePath, into: &results)
                continue
            }

            let ext = (name as NSString).pathExtension.lowercased()
            let kind: String
            if LibraryScanner.fitsExtensions.contains(ext) {
                kind = "fits"
            } else if LibraryScanner.rawExtensions.contains(ext) {
                kind = "raw"
            } else {
                continue
            }

            let sizeBytes = Int64(values.fileSize ?? 0)
            let (role, date, dateSource) = classify(fileURL: entryURL, ext: ext, kind: kind)

            results.append(DiscoveredCaptureFile(
                sourceURL: entryURL,
                relativeSourcePath: relativePath,
                fileName: name,
                ext: ext,
                kind: kind,
                sizeBytes: sizeBytes,
                proposedRole: role,
                captureDate: date,
                captureDateSource: dateSource
            ))
        }
    }

    /// Content-based classification for one file, using the SAME predicate
    /// the library scanner already relies on (`FrameRoleFromHeader`) --
    /// never a second, hand-copied one. FITS files get a role whenever their
    /// `IMAGETYP` names one of the four recognized kinds; `.cr3` files have
    /// no such header anywhere in this codebase (Canon doesn't write one),
    /// so they always come back `nil` here -- explicitly unclassified,
    /// exactly as the owner's brief requires ("never silently guessed").
    private static func classify(
        fileURL: URL, ext: String, kind: String
    ) -> (role: FrameRole?, date: String?, source: CaptureDateSource?) {
        if kind == "fits" {
            if let header = try? FITSReader.readHeader(url: fileURL) {
                let role = header.string("IMAGETYP").flatMap(FrameRoleFromHeader.role(fromImagetyp:))
                if let rawDateObs = header.string("DATE-OBS"),
                   let parsed = SessionTimeline.parseDateObs(rawDateObs)
                {
                    return (role, Self.yyyyMMdd(parsed), .fitsDateObs)
                }
                return (role, fileModificationDate(fileURL), .fileModificationDate)
            }
            return (nil, fileModificationDate(fileURL), .fileModificationDate)
        }

        // `.cr3` (or any other `rawExtensions` member): no IMAGETYP
        // equivalent exists, so the role is always unclassified. The date
        // still comes from Exif when available.
        if let meta = ImageMetaReader.read(url: fileURL),
           let rawDateTaken = meta.dateTaken,
           let parsed = SessionTimeline.parseDateObs(rawDateTaken)
        {
            return (nil, Self.yyyyMMdd(parsed), .exifDateTaken)
        }
        return (nil, fileModificationDate(fileURL), .fileModificationDate)
    }

    private static func fileModificationDate(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate
        else { return nil }
        return yyyyMMdd(date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func yyyyMMdd(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
