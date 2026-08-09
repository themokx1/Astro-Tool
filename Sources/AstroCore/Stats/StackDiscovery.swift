import Foundation

/// One already-created stack/processed-output file found anywhere in the
/// library -- not necessarily under `stacks/<target>/` or
/// `processed/<target>/` at all; see `StackDiscovery`'s doc for why a
/// session or even the library root can hold one too.
public struct StackFile: Codable, Sendable, Equatable {
    public var path: String
    /// The target this file belongs to, resolved either from its path
    /// (`stacks/<T>/...`/`processed/<T>/...`) or, when the path itself
    /// carries no target, from its filename matching a known target's
    /// tokens/catalog designation. `nil` when neither source resolves --
    /// the "besorolatlan" (unclassified) group.
    public var target: String?
    /// Raw session date-dir name (e.g. `"2026-06-06"`, or an intentional
    /// variant like `"2026-06-06-2"`) when derivable from the path or the
    /// filename; `nil` otherwise.
    public var sessionDate: String?
    /// Canonical capture-group slug from mirrored stack/processed paths.
    public var captureSlug: String?
    public var sizeBytes: Int64
    /// ISO-8601 UTC timestamp derived from the file's `mtime`, `nil` only if
    /// `mtime` itself was `0` (never actually scanned).
    public var modifiedISO: String?
    /// `"stack"` (the common case), `"master-jelölt"` (a calibration master
    /// -- `MasterFlat`/`MasterDark`/`MasterBias`/`*_stacked` bias/dark/flat
    /// naming -- still listed, just flagged so it isn't mistaken for a light
    /// stack), or `"feldolgozott"` (a big TIF/FIT sitting under `processed/`).
    public var kind: String
    /// `"mappa"` (target resolved purely from the path), `"fájlnév"` (target
    /// resolved purely from filename token-matching -- the path itself gave
    /// no target), or `"mappa+fájlnév"` (the path gave the target AND the
    /// filename independently mentions it too).
    public var matchSource: String
    /// ASIAIR-style `"<Target>_<N>x<sub>sec_<total>s_..."` autosave naming,
    /// parsed via `parseStackName`: frame count. `nil` when the filename
    /// doesn't carry this pattern, or the parsed frame count was `0`.
    public var framesFromName: Int?
    /// As above: per-sub exposure length in seconds. `nil` when absent or
    /// parsed as `0` (ASIAIR's own placeholder for "no exposure info baked
    /// into this name", e.g. a mosaic panel-prep light).
    public var subSecondsFromName: Double?
    /// As above: total integration in seconds. Same `0` → `nil` rule.
    public var totalSecondsFromName: Double?
    /// `"6248×4176"` from the file's `fits_meta.naxis1`/`naxis2` when both
    /// are on record; `nil` otherwise.
    public var dimensions: String?

    public init(
        path: String,
        target: String? = nil,
        sessionDate: String? = nil,
        captureSlug: String? = nil,
        sizeBytes: Int64,
        modifiedISO: String? = nil,
        kind: String,
        matchSource: String,
        framesFromName: Int? = nil,
        subSecondsFromName: Double? = nil,
        totalSecondsFromName: Double? = nil,
        dimensions: String? = nil
    ) {
        self.path = path
        self.target = target
        self.sessionDate = sessionDate
        self.captureSlug = captureSlug
        self.sizeBytes = sizeBytes
        self.modifiedISO = modifiedISO
        self.kind = kind
        self.matchSource = matchSource
        self.framesFromName = framesFromName
        self.subSecondsFromName = subSecondsFromName
        self.totalSecondsFromName = totalSecondsFromName
        self.dimensions = dimensions
    }
}

/// One target's discovered stack files, sorted per `StackDiscovery.discover`'s
/// doc (`totalSecondsFromName` descending, then size descending).
public struct TargetStacks: Codable, Sendable, Equatable {
    /// `""` for the "besorolatlan" (unclassified) group -- every other entry
    /// has a real, non-empty target name.
    public var target: String
    public var displayName: String
    public var stacks: [StackFile]

    public init(target: String, displayName: String, stacks: [StackFile]) {
        self.target = target
        self.displayName = displayName
        self.stacks = stacks
    }
}

/// R8-3: which "flavor" of the same underlying stack a discovered file is --
/// the popover's dozens of flat rows (`NGC_2244_..._og.fit`,
/// `starless_..._og.fit`, `..._og_work_graxpert_result_HOO_Improved.fit`,
/// `..._seti_strech.jpg`, ...) are all THIS classification applied to one
/// filename, purely from the filename itself (no path, no database) -- same
/// "recognition is filename-driven" convention as `looksLikeStackOutput`.
public enum StackVariantKind: String, Codable, Sendable {
    /// Raw stacker output, no edit markers at all: `*_og.fit`, a plain
    /// `NxSUBsec_TOTALs` name, `result.fit`, `Autosave*.tif`.
    case original = "eredeti"
    /// Carries at least one recognized post-processing marker: `_work`,
    /// `_strech`/`_stretch`, `graxpert`, `denoise[d]`, `_seti`, `_spcc`,
    /// `parallax`, `prisim`, `resampled`, `alchemy`, a "copy" suffix,
    /// `Improved`, or an `_HOO`/`_HSO`/`_SHO`/`_OSH`-style channel-composite
    /// result token.
    case edited = "szerkesztett"
    /// Filename starts with `starless_` (star-removed variant).
    case starless = "starless"
    /// Filename starts with `starmask_` (extracted star-mask variant).
    case starmask = "starmask"
    /// `.jpg`/`.jpeg`/`.png` regardless of any other marker -- a rendered
    /// export always classifies as this, even when it also carries edit
    /// markers (e.g. `..._seti_strech.jpg`).
    case export_ = "export"
}

/// One "family" of stack variants sharing the same underlying capture --
/// R8-3's fix for the "dozens of flat unmanageable rows" complaint. `base` is
/// the primary/representative file (preferring a `.original`-kind member,
/// else the largest); `variants` is everything else in the group, sorted
/// `.original` (any extra copies) then `.edited`/`.starless`/`.starmask`/
/// `.export_`, then by name within each kind.
public struct StackGroup: Codable, Sendable {
    /// The grouping key derived by `StackDiscovery.stem(for:)` -- shared by
    /// every member's filename.
    public var stem: String
    public var base: StackFile
    public var variants: [StackFile]
    /// Best-known total integration seconds for this group -- `base`'s own
    /// `totalSecondsFromName` when present, else a `header_json` fallback
    /// (see `fromHeader`).
    public var totalSecondsBest: Double?
    /// Best-known frame count, same fallback rule as `totalSecondsBest`.
    public var framesBest: Int?
    /// Best-known per-sub exposure seconds, same fallback rule.
    public var subSecondsBest: Double?
    /// `true` when any of `framesBest`/`totalSecondsBest`/`subSecondsBest`
    /// came from `base`'s FITS header (`STACKCNT`/`LIVETIME`/`EXPTIME`)
    /// rather than being parsed from its filename -- lets the UI show a
    /// "headerből" ("from header") hint instead of implying the name itself
    /// carried the numbers.
    public var fromHeader: Bool

    public init(
        stem: String,
        base: StackFile,
        variants: [StackFile],
        totalSecondsBest: Double? = nil,
        framesBest: Int? = nil,
        subSecondsBest: Double? = nil,
        fromHeader: Bool = false
    ) {
        self.stem = stem
        self.base = base
        self.variants = variants
        self.totalSecondsBest = totalSecondsBest
        self.framesBest = framesBest
        self.subSecondsBest = subSecondsBest
        self.fromHeader = fromHeader
    }
}

/// `variantKind`, computed purely from the file's own basename -- see
/// `StackDiscovery.variantKind(fileName:)` for the recognition rules.
public extension StackFile {
    var variantKind: StackVariantKind {
        StackDiscovery.variantKind(fileName: (path as NSString).lastPathComponent)
    }
}

/// R8-1: finds every already-created stack/processed output for every
/// target, wherever it actually lives on disk -- NOT just the canonical
/// `stacks/<target>/<date>/` and `processed/<target>/<date>/` locations.
/// Real libraries routinely drop a finished stack straight into the
/// target's `stacks/` root (no date subfolder), or even leave one sitting
/// loose in a session's own folder -- this scans every tracked file in the
/// database (any area, any depth) and recognizes a "stack output" purely
/// from its own filename/extension/size, same "no filesystem access, read
/// only from `Database`" convention as every other `Stats` query type.
///
/// Recognition is filename-driven (`looksLikeStackOutput`) rather than
/// location-driven: being physically inside `stacks/<T>/` is neither
/// necessary (a stack can sit anywhere) nor sufficient (that same folder is
/// full of intermediate processing byproducts -- `starless_*`,
/// `*_graxdeconv_*`, Siril `.seq`/`cache/` scratch files -- that are NOT
/// finished stacks). The path IS still used, just for target/date
/// resolution: `PathClassifier` already parses `stacks/<T>/<date>/...` and
/// `processed/<T>/<date>/...` into `FileRecord.target`/`sessionDate`, so a
/// candidate under one of those trees gets its target for free; everything
/// else (root-level files, `area == .other`, a stray file sitting in
/// `calibration_library/` or even `sessions/`) falls back to matching its
/// filename's tokens against every target folder name/catalog designation
/// on record (`TargetNameResolver`).
public enum StackDiscovery {
    /// "Big enough that a TIF/FIT sitting under `processed/` is realistically
    /// a rendered result rather than a stray placeholder" -- real full-frame
    /// stacks/processed outputs in this library run tens to hundreds of MB;
    /// a handful of bytes (an aborted/placeholder write) never qualifies.
    private static let bigProcessedBytesThreshold: Int64 = 10_000_000
    private static let stackExtensions: Set<String> = ["fit", "fits", "fz", "tif", "tiff"]
    /// `(\d+)x([\d.]+)sec_(\d+(?:\.\d+)?)s` -- ASIAIR's own autosave-stack
    /// naming, e.g. `"NGC_7000_106x120sec_12720s_drizzle-1-0x_..."` ->
    /// 106 frames, 120 s subs, 12720 s total. Compiled once: this is
    /// evaluated against every tracked file in the library on every
    /// `discover` call, so a per-call `NSRegularExpression` construction
    /// would be wasteful.
    private static let stackNameRegex = try! NSRegularExpression(pattern: #"(\d+)x([0-9.]+)sec_([0-9.]+)s"#)
    private static let dateInNameRegex = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)

    // MARK: - Public API

    /// Every target's discovered stacks, plus a `target == ""` /
    /// `displayName == "Besorolatlan"` group last for stack-looking files
    /// that matched no known target at all. Targets are otherwise sorted by
    /// name.
    public static func discover(db: Database, config: AstroConfig) throws -> [TargetStacks] {
        let files = try db.allFiles(includeMissing: false)
        let knownTargets = Set(files.compactMap(\.target)).sorted()

        var candidates: [StackFile] = []
        // inode -> index into `candidates`, so a hardlinked file (the same
        // inode tracked at two different paths) is only ever listed once --
        // preferring whichever path sits under `stacks/`.
        var indexByInode: [Int64: Int] = [:]

        for file in files {
            guard let candidate = try classify(file: file, knownTargets: knownTargets, db: db) else { continue }

            guard let inode = file.inode else {
                candidates.append(candidate)
                continue
            }
            if let existingIndex = indexByInode[inode] {
                if isStacksLocated(candidate.path), !isStacksLocated(candidates[existingIndex].path) {
                    candidates[existingIndex] = candidate
                }
                continue
            }
            indexByInode[inode] = candidates.count
            candidates.append(candidate)
        }

        var byTarget: [String: [StackFile]] = [:]
        for candidate in candidates {
            byTarget[candidate.target ?? "", default: []].append(candidate)
        }

        var result: [TargetStacks] = []
        for (target, stacks) in byTarget {
            result.append(TargetStacks(target: target, displayName: try displayName(for: target, db: db), stacks: sortStacks(stacks)))
        }

        return result.sorted { a, b in
            if a.target.isEmpty != b.target.isEmpty { return b.target.isEmpty }
            return a.target < b.target
        }
    }

    /// The discovered stacks for one target, `[]` if it has none on record
    /// (including if `target` itself isn't known to the library at all).
    public static func stacks(target: String, db: Database, config: AstroConfig) throws -> [StackFile] {
        try discover(db: db, config: config).first { $0.target == target }?.stacks ?? []
    }

    /// R8-3: `stacks(target:...)`, collapsed into families sharing the same
    /// underlying capture (`stem(for:)`) -- the fix for the "dozens of flat
    /// unmanageable rows" complaint. Group order follows `stacks(target:...)`'s
    /// own sort (best-integration-first), one `StackGroup` per distinct stem.
    /// `[]` under the exact same conditions `stacks(target:...)` returns `[]`.
    public static func groupedStacks(target: String, db: Database, config: AstroConfig) throws -> [StackGroup] {
        let files = try stacks(target: target, db: db, config: config)
        guard !files.isEmpty else { return [] }

        var order: [String] = []
        var membersByStem: [String: [StackFile]] = [:]
        for file in files {
            let baseName = (file.path as NSString).lastPathComponent
            let key = stem(for: baseName)
            if membersByStem[key] == nil { order.append(key) }
            membersByStem[key, default: []].append(file)
        }

        return try order.map { key in
            let members = membersByStem[key] ?? []
            let base = chooseBase(members)
            let variants = members.filter { $0.path != base.path }.sorted(by: variantIsOrderedBeforeInGroup)

            var framesBest = base.framesFromName
            var subSecondsBest = base.subSecondsFromName
            var totalSecondsBest = base.totalSecondsFromName
            var fromHeader = false

            if framesBest == nil, let header = try headerExposure(path: base.path, db: db) {
                if let headerFrames = header.frames {
                    framesBest = headerFrames
                    fromHeader = true
                }
                if totalSecondsBest == nil, let headerTotal = header.totalSeconds {
                    totalSecondsBest = headerTotal
                    fromHeader = true
                }
                if subSecondsBest == nil, let frames = framesBest, frames > 0, let total = totalSecondsBest {
                    subSecondsBest = total / Double(frames)
                }
            }

            return StackGroup(
                stem: key,
                base: base,
                variants: variants,
                totalSecondsBest: totalSecondsBest,
                framesBest: framesBest,
                subSecondsBest: subSecondsBest,
                fromHeader: fromHeader
            )
        }
    }

    // MARK: - Recognition

    /// Whether `fileName` (bare, no path) looks like a finished stack/
    /// processed output, purely from its own name/extension/size -- no path,
    /// no database. `sizeBytes == 0` never qualifies (a placeholder/aborted
    /// write, not a real result). Residue (`r_*`, `*_pp_*`, `*_bkg*`, `.seq`/
    /// `.lst`, ...) is excluded even when it otherwise matches one of the
    /// patterns below -- reuses `ResidueMatcher` against the DEFAULT
    /// `AstroConfig().residuePatterns` (this is a pure, config-free helper by
    /// design) so a Siril-registered `r_merged_..._stacked.fit` is correctly
    /// rejected despite containing `"_stacked"`.
    ///
    /// Recognized patterns (tuned against this library's real on-disk
    /// names): the ASIAIR autosave-stack pattern (`parseStackName`, but only
    /// when it actually carries a nonzero sub/total exposure -- a
    /// `"...x0sec_0s..."` name with neither is ASIAIR's own placeholder for
    /// "no exposure info", the shape of a raw mosaic panel-prep light, not a
    /// finished stack); `*_stacked*` (any image extension) -- this alone
    /// also covers every calibration-master naming
    /// (`*_darks_stacked`/`*_flats_stacked`/`*_biases_stacked`/singular
    /// variants), which `kind(...)` below flags as `"master-jelölt"` rather
    /// than excluding; the ASIAIR live-stack numbered-capture naming
    /// (`Stacked112_...`, `Stacked141_...`); `result*` (any image
    /// extension); `Autosave*.tif`/`.tiff` (DeepSkyStacker); `MasterLight*`;
    /// and anything mentioning `"mosaic"` (`*_mosaic*`,
    /// `paneled_mosaic_final`, `paneled_mosaic_stacked`, ...).
    public static func looksLikeStackOutput(fileName: String, ext: String, sizeBytes: Int64) -> Bool {
        guard sizeBytes > 0 else { return false }
        guard !ResidueMatcher.matchesFilePattern(name: fileName, config: AstroConfig()) else { return false }

        let lower = fileName.lowercased()
        let extLower = ext.lowercased()

        if let parsed = parseStackName(fileName), (parsed.subSeconds ?? 0) > 0 || (parsed.totalSeconds ?? 0) > 0 {
            return true
        }
        if lower.contains("_stacked"), stackExtensions.contains(extLower) { return true }
        if hasASIAirStackedPrefix(lower) { return true }
        if lower.hasPrefix("result"), stackExtensions.contains(extLower) { return true }
        if lower.hasPrefix("autosave"), extLower == "tif" || extLower == "tiff" { return true }
        if lower.contains("masterlight") { return true }
        if lower.contains("mosaic") { return true }
        return false
    }

    /// ASIAIR's own live-stack numbered-capture naming: `"Stacked"` followed
    /// by one or more digits, then `"_"` -- e.g. `"Stacked112_NGC 7000_..."`.
    static func hasASIAirStackedPrefix(_ lower: String) -> Bool {
        guard lower.hasPrefix("stacked") else { return false }
        let rest = lower.dropFirst("stacked".count)
        guard let firstNonDigitIndex = rest.firstIndex(where: { !$0.isNumber }) else { return false }
        guard firstNonDigitIndex != rest.startIndex else { return false }
        return rest[firstNonDigitIndex] == "_"
    }

    /// Parses the ASIAIR autosave-stack naming
    /// `"...<N>x<sub>sec_<total>s..."` (e.g. `"106x120sec_12720s"` ->
    /// `(106, 120.0, 12720.0)`). Returns the parsed numbers AS-IS (`0`
    /// included) when the pattern matches at all; callers decide whether a
    /// `0` counts as "unknown" for their own purposes -- `looksLikeStackOutput`
    /// treats an all-zero sub/total match as ASIAIR's own placeholder (not a
    /// recognized stack by itself), while `StackFile`'s
    /// `subSecondsFromName`/`totalSecondsFromName`/`framesFromName` map a `0`
    /// to `nil`. `nil` when the name doesn't contain the pattern at all.
    static func parseStackName(_ name: String) -> (frames: Int?, subSeconds: Double?, totalSeconds: Double?)? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = stackNameRegex.firstMatch(in: name, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: name) else { return nil }
            return String(name[r])
        }

        let frames = group(1).flatMap(Int.init)
        let subSeconds = group(2).flatMap(Double.init)
        let totalSeconds = group(3).flatMap(Double.init)
        return (frames, subSeconds, totalSeconds)
    }

    // MARK: - Classification

    private static func classify(file: FileRecord, knownTargets: [String], db: Database) throws -> StackFile? {
        guard !file.missing else { return nil }
        let baseName = (file.path as NSString).lastPathComponent
        guard looksLikeStackOutput(fileName: baseName, ext: file.ext, sizeBytes: file.size) else { return nil }

        let parsed = parseStackName(baseName)
        let frames = parsed?.frames.flatMap { $0 == 0 ? nil : $0 }
        let subSeconds = parsed?.subSeconds.flatMap { $0 == 0 ? nil : $0 }
        let totalSeconds = parsed?.totalSeconds.flatMap { $0 == 0 ? nil : $0 }

        let target: String?
        let matchSource: String
        if let pathTarget = file.target {
            target = pathTarget
            matchSource = filenameMentionsTarget(baseName, target: pathTarget) ? "mappa+fájlnév" : "mappa"
        } else if let matched = knownTargets.first(where: { filenameMentionsTarget(baseName, target: $0) }) {
            target = matched
            matchSource = "fájlnév"
        } else {
            target = nil
            matchSource = "fájlnév"
        }

        let sessionDate = file.sessionDate ?? extractDate(fromName: baseName)

        var dimensions: String?
        if let fileID = file.id, let meta = try db.fitsMeta(fileID: fileID),
           let naxis1 = meta.naxis1, let naxis2 = meta.naxis2
        {
            dimensions = "\(naxis1)×\(naxis2)"
        }

        return StackFile(
            path: file.path,
            target: target,
            sessionDate: sessionDate,
            captureSlug: PathClassifier.classify(relativePath: file.path).captureSlug,
            sizeBytes: file.size,
            modifiedISO: file.mtime > 0 ? isoString(file.mtime) : nil,
            kind: kind(baseNameLower: baseName.lowercased(), area: file.area, ext: file.ext, sizeBytes: file.size),
            matchSource: matchSource,
            framesFromName: frames,
            subSecondsFromName: subSeconds,
            totalSecondsFromName: totalSeconds,
            dimensions: dimensions
        )
    }

    private static let masterMarkers = [
        "masterflat", "masterdark", "masterbias",
        "dark_stacked", "darks_stacked",
        "flat_stacked", "flats_stacked",
        "bias_stacked", "biases_stacked",
    ]

    private static func kind(baseNameLower: String, area: LibraryArea, ext: String, sizeBytes: Int64) -> String {
        if masterMarkers.contains(where: baseNameLower.contains) {
            return "master-jelölt"
        }
        if area == .processed, stackExtensions.contains(ext.lowercased()), sizeBytes >= bigProcessedBytesThreshold {
            return "feldolgozott"
        }
        return "stack"
    }

    private static func isStacksLocated(_ path: String) -> Bool {
        path.hasPrefix("stacks/")
    }

    // MARK: - Target token matching

    /// Whether `fileName`'s tokens contain `target`'s leading catalog tokens
    /// (or, when `TargetNameResolver` recognizes a catalog designation for
    /// it, that designation's own tokens) as a contiguous run --
    /// case-insensitive, `_`/space/hyphen-insensitive. E.g. target
    /// `"NGC_7000_North_American_Nebula"` (leading tokens `["ngc","7000"]`)
    /// matches filename `"NGC_7000_106x120sec_12720s_..."`.
    private static func filenameMentionsTarget(_ fileName: String, target: String) -> Bool {
        let fileTokens = tokenize(fileName)
        let targetTokens = tokenize(target)
        guard !targetTokens.isEmpty else { return false }

        let leading = Array(targetTokens.prefix(2))
        if containsContiguous(fileTokens, leading) { return true }

        if let designation = TargetNameResolver.resolve(folderName: target).designation {
            let designationTokens = tokenize(designation)
            if !designationTokens.isEmpty, containsContiguous(fileTokens, designationTokens) { return true }
        }
        return false
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    // MARK: - Date/size/time formatting

    private static func extractDate(fromName name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = dateInNameRegex.firstMatch(in: name, range: range), let r = Range(match.range, in: name) else {
            return nil
        }
        return String(name[r])
    }

    private static func isoString(_ epochSeconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    // MARK: - Sorting / display name

    private static func sortStacks(_ stacks: [StackFile]) -> [StackFile] {
        stacks.sorted { a, b in
            let ta = a.totalSecondsFromName ?? -1
            let tb = b.totalSecondsFromName ?? -1
            if ta != tb { return ta > tb }
            return a.sizeBytes > b.sizeBytes
        }
    }

    private static func displayName(for target: String, db: Database) throws -> String {
        guard !target.isEmpty else { return "Besorolatlan" }
        let tags = try db.tags(target: target, sessionDate: nil)
        return NameTag.apply(to: TargetNameResolver.resolve(folderName: target), tags: tags).displayName
    }

    // MARK: - Grouping (R8-3)

    /// The `NxSUBsec_TOTALs` core (reusing `stackNameRegex`'s own numbers),
    /// plus an optional immediately-following `_drizzle-A-Bx` token (one OR
    /// two underscores before it -- the real ASIAIR naming sometimes doubles
    /// up, e.g. `"12300s__drizzle-2-0x"`) and an optional
    /// `_YYYY-MM-DD_HHMM` autosave timestamp right after that. Matched
    /// against a name that's already lowercased/extension-stripped/
    /// starless-starmask-prefix-stripped; greedy optional groups mean the
    /// match extends through whichever of drizzle/timestamp are actually
    /// present, so `stem(for:)` only needs the single overall match range.
    private static let stemCoreRegex = try! NSRegularExpression(
        pattern: #"^.+?\d+x[0-9.]+sec_[0-9.]+s(?:_+drizzle-[0-9.]+-[0-9.]+x)?(?:_\d{4}-\d{2}-\d{2}_\d{4})?"#
    )

    /// Suffix markers stripped, left-to-right (leftmost occurrence across all
    /// of them wins, so one pass fully separates the "core" name from
    /// whatever post-processing chain follows) when a name has no
    /// `NxSUBsec_TOTALs` core to anchor on at all -- e.g. `"result_final.tif"`,
    /// `"Autosave001.tif"`. Applied to an already lowercased,
    /// extension-stripped, starless-/starmask-prefix-stripped name.
    private static let stemFallbackMarkers = [
        "_work", "_og", "_result", "_strech", "_stretch", "_graxpert", "_denoised",
        "_seti", "_spcc", "_parallax", "_prisim", "_improved", "_hoo", "_hso", "_sho", "_osh",
        " copy", "_workú", "_final", "_alchemy", "_resampled",
    ]

    /// R8-3's grouping key: the same for every variant of one underlying
    /// stack (`NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_
    /// 2026-03-17_1956` for the whole `_og`/`starless_`/`_work_graxpert_
    /// result_HOO_Improved` family). Lowercase, extension-stripped, with a
    /// leading `starless_`/`starmask_` prefix removed first (so a starless
    /// variant groups with its parent instead of forming its own singleton).
    static func stem(for fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension.lowercased()
        for prefix in ["starless_", "starmask_"] {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
                break
            }
        }

        let range = NSRange(name.startIndex..., in: name)
        if let match = stemCoreRegex.firstMatch(in: name, range: range), let matchRange = Range(match.range, in: name) {
            return String(name[matchRange])
        }
        return stripFallbackMarkerSuffix(name)
    }

    private static func stripFallbackMarkerSuffix(_ name: String) -> String {
        var cutIndex: String.Index?
        for marker in stemFallbackMarkers {
            guard let markerRange = name.range(of: marker) else { continue }
            if cutIndex == nil || markerRange.lowerBound < cutIndex! {
                cutIndex = markerRange.lowerBound
            }
        }
        var result = cutIndex.map { String(name[name.startIndex..<$0]) } ?? name
        while result.hasSuffix("_") { result.removeLast() }
        return result
    }

    /// Loose, order-independent substring markers for `.edited` -- any one
    /// hit is enough. `"denois"` catches both `denoise`/`denoised`; the
    /// `_hoo`/`_hso`/`_sho`/`_osh`-family channel-composite tokens are
    /// handled separately by `channelCompositeRegex` since a bare substring
    /// check on 3-letter tokens like `"sho"` risks false positives (e.g. an
    /// incidental `"shortcut"`).
    private static let editedMarkers = [
        "_work", "_strech", "_stretch", "graxpert", "denois", "_seti", "_spcc",
        "parallax", "prisim", "resampled", "alchemy", "copy", "improved",
    ]

    /// `_HOO_`/`_HSO_`/`_SHO_`/`_OSH_`/`_HOS_`/`_OHS_`/`_SOH_`-style
    /// channel-composite result tokens (every permutation of H/O/S is
    /// accepted, real on-disk names use several) -- underscore-anchored on
    /// both sides (or end-of-string/`.` on the trailing side) so a bare
    /// substring match never fires on unrelated text.
    private static let channelCompositeRegex = try! NSRegularExpression(
        pattern: "_(?:hoo|hso|sho|osh|hos|ohs|soh)(?:_|\\.|$)"
    )

    /// R8-3's per-file recognition: purely from `fileName` (bare, no path),
    /// same "no database" convention as `looksLikeStackOutput`. Order matters
    /// -- a `starless_`/`starmask_` prefix wins even over a `.jpg` extension
    /// or an edit marker (the star-removal/star-mask identity is the more
    /// important signal to surface), then export extension, then edit
    /// markers, else `.original`.
    static func variantKind(fileName: String) -> StackVariantKind {
        let lower = fileName.lowercased()
        if lower.hasPrefix("starless_") { return .starless }
        if lower.hasPrefix("starmask_") { return .starmask }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png"].contains(ext) { return .export_ }

        if editedMarkers.contains(where: lower.contains) { return .edited }
        let range = NSRange(lower.startIndex..., in: lower)
        if channelCompositeRegex.firstMatch(in: lower, range: range) != nil { return .edited }

        return .original
    }

    /// `groupedStacks`' base-selection: prefer a `.original`-kind member
    /// (there's usually exactly one -- the raw stacker output the whole
    /// family descends from), else the largest file in the group. `members`
    /// is always non-empty (built from a non-empty stem bucket).
    private static func chooseBase(_ members: [StackFile]) -> StackFile {
        if let original = members.first(where: { $0.variantKind == .original }) {
            return original
        }
        return members.max(by: { $0.sizeBytes < $1.sizeBytes }) ?? members[0]
    }

    /// Variant display order within one group: `.original` (any extra copies
    /// beyond the chosen `base`) first, then `.edited`/`.starless`/
    /// `.starmask`/`.export_` per R8-3's spec order, then alphabetically by
    /// filename within each kind.
    private static func variantRank(_ kind: StackVariantKind) -> Int {
        switch kind {
        case .original: return 0
        case .edited: return 1
        case .starless: return 2
        case .starmask: return 3
        case .export_: return 4
        }
    }

    private static func variantIsOrderedBeforeInGroup(_ a: StackFile, _ b: StackFile) -> Bool {
        let rankA = variantRank(a.variantKind)
        let rankB = variantRank(b.variantKind)
        if rankA != rankB { return rankA < rankB }
        return (a.path as NSString).lastPathComponent < (b.path as NSString).lastPathComponent
    }

    /// `groupedStacks`' header fallback for a group whose `base` filename
    /// carries no parsed frame count: reads `base`'s own `fits_meta.
    /// header_json` for `STACKCNT` (frames) and `LIVETIME`/`EXPTIME` (total
    /// seconds, `LIVETIME` preferred -- Siril writes both, `LIVETIME` is the
    /// true stacked integration while `EXPTIME` is only the per-sub length,
    /// but a per-sub number is still better than nothing when `LIVETIME`
    /// itself is absent). `nil` when `base` isn't tracked, has no
    /// `fits_meta` row, no `header_json`, or neither key parses.
    private static func headerExposure(path: String, db: Database) throws -> (frames: Int?, totalSeconds: Double?)? {
        guard let fileID = try db.fileID(path: path), let meta = try db.fitsMeta(fileID: fileID),
              let headerJSON = meta.headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }

        func numeric(_ key: String) -> Double? {
            guard let raw = cards[key] else { return nil }
            return Double(raw.trimmingCharacters(in: .whitespaces))
        }

        let frames = numeric("STACKCNT").map { Int($0) }
        let totalSeconds = numeric("LIVETIME") ?? numeric("EXPTIME")
        guard frames != nil || totalSeconds != nil else { return nil }
        return (frames, totalSeconds)
    }
}
