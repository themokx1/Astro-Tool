import Foundation

/// The outcome of running `FrameSet.lightBuckets` over one scope's raw
/// session light-role files: how many are real, deduped, usable frames vs.
/// noise the naive "everything under lights/ is a light" count used to
/// silently fold in.
public struct FrameBuckets: Sendable {
    /// Deduped, non-rejected real light frames -- one entry per physically
    /// distinct exposure, the canonical copy of each (see
    /// `FrameSet.lightBuckets`'s doc for how "canonical" is chosen).
    public var usable: [FileRecord]
    /// Deduped real light frames that live under a `Reject/` triage
    /// subdirectory -- the user explicitly threw these out, so they count
    /// as "have" data but never as usable integration.
    public var rejected: [FileRecord]
    /// Extra copies collapsed away during dedup: hardlinked triage copies
    /// (`Stack`/`Review`/`Reject` siblings of the same inode) plus
    /// cross-extension pairs (a `.cr3` and its converted `.tif`). Does NOT
    /// include `nonFrameFileCount` -- that's counted separately.
    public var duplicateLinkCount: Int
    /// Files under `lights/` that were never real frames at all: wrong
    /// extensions (sidecars, reports, logs, ...) and processed-derivative
    /// names (`starless_*`, `starmask_*`, ...) that happen to sit in a
    /// `lights/` folder next to the real frames.
    public var nonFrameFileCount: Int

    public init(usable: [FileRecord], rejected: [FileRecord], duplicateLinkCount: Int, nonFrameFileCount: Int) {
        self.usable = usable
        self.rejected = rejected
        self.duplicateLinkCount = duplicateLinkCount
        self.nonFrameFileCount = nonFrameFileCount
    }
}

/// The single source of truth for "which files under a `lights/` folder are
/// real, usable light frames" -- see the R4-1 review this implements:
/// `PathClassifier` marks EVERY file under `lights/` as role `.light`
/// (sidecars, triage-tool reports, processed derivatives, hardlinked triage
/// copies, ...), which inflates naive counts/integration sums by roughly
/// 30% on a real library. `FrameSet` cleans that up without touching
/// `PathClassifier` itself (which stays a pure, cheap path classifier).
public enum FrameSet {
    /// Extensions a real light frame can have. Anything else under
    /// `lights/` (`.xmp`, `.png`, `.txt`, `.html`, `.csv`, `.ssf`, `.json`,
    /// ...) is tool noise, not a frame.
    public static let frameExtensions: Set<String> = ["fit", "fits", "fz", "cr3", "tif"]

    /// Filename substrings (checked case-insensitively against just the
    /// last path component) that mark a processed DERIVATIVE of a real
    /// frame rather than the frame itself -- e.g. Siril's `starless_*.fit`/
    /// `starmask_*.fit` byproducts sitting in the same `lights/` folder.
    private static let derivativeMarkers = ["starless_", "starmask_", "_stacked", "autosave", "result"]

    /// Splits `files` (expected to already be scoped to one target/session's
    /// `area == .sessions && role == .light` rows) into usable vs. rejected
    /// real frames, after dropping non-frame noise and collapsing duplicate
    /// copies of the same physical exposure down to one canonical copy.
    ///
    /// Dedup runs in three passes:
    /// 1. Group by `inode` where known -- catches hardlinked triage copies
    ///    (`Stack`/`Review`/`Reject` siblings LightFrameRater creates).
    /// 2. For files with no `inode` (pre-v3 scan, or a stat failure), fall
    ///    back to grouping by `(target, sessionDate, normalized DATE-OBS,
    ///    exptime)`.
    /// 3. Merge cross-extension pairs among the resulting representatives:
    ///    a `.cr3` and a `.tif` with a matching normalized DATE-OBS (or the
    ///    same filename stem) are the same DSLR frame captured twice --
    ///    keep the raw `.cr3`.
    ///
    /// Within a dedup group, the kept "canonical" copy is the one whose
    /// immediate parent directory is literally `lights` (case-insensitive)
    /// -- i.e. NOT a `Stack`/`Review`/`Reject` triage subdirectory. If no
    /// group member sits directly in `lights/` (the file's only copy is
    /// itself inside a triage subdirectory), the shortest path is kept.
    public static func lightBuckets(
        files: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        config: AstroConfig
    ) -> FrameBuckets {
        var nonFrameCount = 0
        var frameFiles: [FileRecord] = []

        for file in files {
            guard isFrameCandidate(file) else {
                nonFrameCount += 1
                continue
            }
            frameFiles.append(file)
        }

        var byInode: [Int64: [FileRecord]] = [:]
        var inodeOrder: [Int64] = []
        var byFallbackKey: [String: [FileRecord]] = [:]
        var fallbackOrder: [String] = []

        for file in frameFiles {
            if let inode = file.inode {
                if byInode[inode] == nil { inodeOrder.append(inode) }
                byInode[inode, default: []].append(file)
            } else {
                let key = fallbackKey(for: file, meta: meta)
                if byFallbackKey[key] == nil { fallbackOrder.append(key) }
                byFallbackKey[key, default: []].append(file)
            }
        }

        var representatives: [FileRecord] = []
        var duplicateCount = 0

        for inode in inodeOrder {
            let group = byInode[inode] ?? []
            representatives.append(pickCanonical(group))
            duplicateCount += group.count - 1
        }
        for key in fallbackOrder {
            let group = byFallbackKey[key] ?? []
            representatives.append(pickCanonical(group))
            duplicateCount += group.count - 1
        }

        let (merged, crossExtDuplicates) = mergeCrossExtension(representatives, meta: meta)
        duplicateCount += crossExtDuplicates

        var usable: [FileRecord] = []
        var rejected: [FileRecord] = []
        for file in merged {
            if isUnderReject(file.path, config: config) {
                rejected.append(file)
            } else {
                usable.append(file)
            }
        }

        return FrameBuckets(usable: usable, rejected: rejected, duplicateLinkCount: duplicateCount, nonFrameFileCount: nonFrameCount)
    }

    // MARK: - Non-frame / derivative detection

    static func isFrameCandidate(_ file: FileRecord) -> Bool {
        frameExtensions.contains(file.ext.lowercased()) && !isDerivativeName(file.path)
    }

    static func isDerivativeName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return StackDiscovery.hasASIAirStackedPrefix(name)
            || derivativeMarkers.contains { name.contains($0) }
    }

    // MARK: - Dedup keys

    private static func fallbackKey(for file: FileRecord, meta: [Int64: FITSMetaRecord]) -> String {
        let m = file.id.flatMap { meta[$0] }
        let dateObs = m?.dateObs.map(normalizeDateObs) ?? ""
        let exptime = m?.exptime.map(\.description) ?? ""
        return "\(file.target ?? "")|\(file.sessionDate ?? "")|\(dateObs)|\(exptime)"
    }

    /// Digits-only comparison so an EXIF-style `"2026:04:18 04:36:24"` and a
    /// FITS-style `"2026-04-18T04:36:24"` for the same instant compare equal.
    private static func normalizeDateObs(_ raw: String) -> String {
        String(raw.filter(\.isNumber))
    }

    // MARK: - Canonical-copy selection

    private static func pickCanonical(_ group: [FileRecord]) -> FileRecord {
        guard group.count > 1 else { return group[0] }
        if let direct = group.first(where: isDirectLightsChild) {
            return direct
        }
        return group.sorted { a, b in
            let ac = a.path.split(separator: "/").count
            let bc = b.path.split(separator: "/").count
            if ac != bc { return ac < bc }
            return a.path < b.path
        }.first ?? group[0]
    }

    /// Whether `path`'s immediate parent directory is literally `lights`
    /// (case-insensitive) -- i.e. not a `Stack`/`Review`/`Reject` triage
    /// subdirectory underneath it.
    private static func isDirectLightsChild(_ file: FileRecord) -> Bool {
        let comps = file.path.split(separator: "/")
        guard comps.count >= 2 else { return false }
        return comps[comps.count - 2].lowercased() == "lights"
    }

    // MARK: - Cross-extension (CR3 + TIF) merge

    private static func mergeCrossExtension(
        _ files: [FileRecord],
        meta: [Int64: FITSMetaRecord]
    ) -> (merged: [FileRecord], duplicates: Int) {
        var cr3s: [FileRecord] = []
        var tifs: [(offset: Int, file: FileRecord)] = []
        var others: [FileRecord] = []

        for file in files {
            switch file.ext.lowercased() {
            case "cr3": cr3s.append(file)
            case "tif": tifs.append((tifs.count, file))
            default: others.append(file)
            }
        }

        guard !cr3s.isEmpty, !tifs.isEmpty else { return (files, 0) }

        var matchedTifOffsets = Set<Int>()
        var duplicates = 0

        for cr3 in cr3s {
            let cr3Meta = cr3.id.flatMap { meta[$0] }
            let cr3DateObs = cr3Meta?.dateObs.map(normalizeDateObs)
            let cr3Stem = stem(of: cr3.path)

            if let match = tifs.first(where: { entry in
                guard !matchedTifOffsets.contains(entry.offset) else { return false }
                guard entry.file.target == cr3.target, entry.file.sessionDate == cr3.sessionDate else { return false }
                if let cr3DateObs, !cr3DateObs.isEmpty {
                    let tifMeta = entry.file.id.flatMap { meta[$0] }
                    if let tifDateObs = tifMeta?.dateObs.map(normalizeDateObs), tifDateObs == cr3DateObs {
                        return true
                    }
                }
                return stem(of: entry.file.path) == cr3Stem
            }) {
                matchedTifOffsets.insert(match.offset)
                duplicates += 1
            }
        }

        let remainingTifs = tifs.filter { !matchedTifOffsets.contains($0.offset) }.map(\.file)
        return (others + cr3s + remainingTifs, duplicates)
    }

    private static func stem(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Reject bucket

    private static func isUnderReject(_ path: String, config: AstroConfig) -> Bool {
        guard config.toolOutputDirNames.contains("Reject") else { return false }
        return path.split(separator: "/").map(String.init).contains("Reject")
    }
}
