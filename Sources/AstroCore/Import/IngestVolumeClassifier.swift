import Foundation

/// V3 pre-stack program, section 5.1 (Ingest-figyelő), "kötet-osztályozás":
/// today nothing tells a memory card apart from an arbitrary USB key except
/// running the WHOLE card-import wizard and seeing `CaptureImportScanner
/// .scan` come back empty -- too slow/heavy to run silently on every volume
/// mount notification. This is the cheap pre-check the watcher runs BEFORE
/// deciding to kick off a real scan and show a Home banner: walk at most
/// `sampleLimit` entries (not the whole card) looking for a single `.fit`/
/// `.fits`/`.fz`/`.cr3` file, and stop the instant one turns up.
///
/// Deliberately reuses `LibraryScanner.fitsExtensions`/`.rawExtensions` --
/// the exact same two lists `CaptureImportScanner.scan` itself already
/// classifies against -- rather than a second, hand-picked extension list;
/// see that scanner's own doc comment for why a second list would be a
/// silent, confusing seam.
///
/// Read-only, like `CaptureImportScanner`: this only ever `stat()`s/lists
/// directories, never opens, moves, or deletes anything on the volume.
public enum IngestVolumeClassifier {
    /// `sampleLimit` bounds the walk at a small, fixed cost even for a card
    /// with thousands of irrelevant files (e.g. a plain USB key full of
    /// unrelated documents) -- once `sampleLimit` non-directory entries have
    /// been examined with no capture file found, this gives up and reports
    /// `false` rather than walking the entire volume.
    public static func isLikelyCaptureVolume(
        at url: URL,
        sampleLimit: Int = 40,
        fileManager: FileManager = .default
    ) -> Bool {
        var examined = 0
        return containsCaptureFile(in: url, fileManager: fileManager, examined: &examined, limit: sampleLimit)
    }

    private static func containsCaptureFile(
        in dirURL: URL,
        fileManager: FileManager,
        examined: inout Int,
        limit: Int
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return false }

        // Directories first, depth-first -- a card's actual frames are
        // almost always a folder or two down (e.g. `DCIM/100EOS_R/`), never
        // sitting loose at the volume root, so this gives the walk the best
        // chance of finding a real hit before `limit` is spent on
        // top-level clutter (`.Spotlight-V100`, a stray `readme.txt`, ...).
        let sorted = entries.sorted { lhs, rhs in
            let lhsIsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let rhsIsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if lhsIsDir != rhsIsDir { return lhsIsDir && !rhsIsDir }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }

        for entryURL in sorted {
            guard examined < limit else { return false }
            let name = entryURL.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            guard values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                if containsCaptureFile(in: entryURL, fileManager: fileManager, examined: &examined, limit: limit) {
                    return true
                }
                continue
            }

            examined += 1
            let ext = (name as NSString).pathExtension.lowercased()
            if LibraryScanner.fitsExtensions.contains(ext) || LibraryScanner.rawExtensions.contains(ext) {
                return true
            }
        }
        return false
    }
}
