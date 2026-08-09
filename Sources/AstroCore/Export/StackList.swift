import Foundation

/// The outcome of `StackList.select` for one session -- which frames were
/// kept, which were dropped and why, ready to hand to `StackList.export`
/// (or to print/inspect on its own via `--json`).
public struct StackSelection: Codable, Sendable {
    public var target: String
    public var date: String
    /// Optional first-class capture scope. `nil` keeps the historic whole-session behavior.
    public var captureSlug: String?
    /// Usable lights in this session before any drop -- `FrameSet`'s deduped,
    /// non-`Reject/` bucket. NOT the raw file count under `lights/` (that
    /// would double-count triage hardlinks and non-frame noise -- see
    /// `FrameSet.lightBuckets`'s own doc for why).
    public var totalFrames: Int
    public var selectedFrames: Int
    /// Hungarian, human-facing record of what filtered what -- one line per
    /// rule that actually fired, in the order the rules ran, plus a final
    /// summary line. Empty only when `totalFrames == 0`.
    ///
    /// R11-T11 (F15): when `perFilter` is non-`nil` (more than one filter
    /// bucket among this session's usable lights), every per-filter line
    /// after the leading "használható" summary is prefixed `"[<filter>] "`
    /// so the flat list still reads top-to-bottom without needing
    /// `perFilter` at all. When there's only one bucket, this array is
    /// byte-identical to what this type produced before per-filter grouping
    /// existed -- no prefix, same wording, same order.
    public var criteria: [String]
    /// Root-relative paths of every frame selected for stacking, sorted.
    public var selectedPaths: [String]
    /// Root-relative paths of every usable frame NOT selected (dropped by a
    /// hard rule, or cut by the keepFraction ranking), sorted.
    public var rejectedPaths: [String]
    /// R11-T11 (F15): per-filter breakdown, present iff `select()` found
    /// MORE THAN ONE distinct filter bucket among this session's usable
    /// lights (a raw FITS `FILTER` header value, or
    /// `FilterBreakdownQueries.noFilterSentinel` for frames with none).
    /// `nil` for the common single-bucket case -- one mono filter shot all
    /// session, or an unfiltered OSC/DSLR session -- so existing callers
    /// (CLI `--json` scripts, `StackListSheet` before this ticket) see
    /// exactly the same shape they always did. `StackList.export`/
    /// `exportToDirectory` key off this field to decide flat vs.
    /// `lights/<FILTER>/` export-tree shape.
    public var perFilter: [StackFilterSelection]?
    /// R11-T11 (F15): every usable light this selection considered --
    /// selected or not -- ready to render as `manifest.csv`. Always
    /// populated (empty only when `totalFrames == 0`), regardless of
    /// `perFilter`, so `export`/`exportToDirectory` can render the manifest
    /// with no further DB access.
    public var manifest: [StackManifestRow]
    /// R12-U2 (point 3): every distinct filter-bucket key `select()` found
    /// among this session's usable lights -- a raw FITS `FILTER` value, or
    /// `FilterBreakdownQueries.noFilterSentinel` -- regardless of whether
    /// there was only ONE (in which case `perFilter` itself stays `nil` for
    /// full backward compatibility, see that field's own doc). Lets a caller
    /// (the CLI's `--keep-filter` unknown-name warning) know which filter
    /// names actually exist in this session without needing `perFilter`
    /// populated. Empty only when `totalFrames == 0`.
    public var filterKeysPresent: [String]

    public init(
        target: String,
        date: String,
        captureSlug: String? = nil,
        totalFrames: Int,
        selectedFrames: Int,
        criteria: [String],
        selectedPaths: [String],
        rejectedPaths: [String],
        perFilter: [StackFilterSelection]? = nil,
        manifest: [StackManifestRow] = [],
        filterKeysPresent: [String] = []
    ) {
        self.target = target
        self.date = date
        self.captureSlug = captureSlug
        self.totalFrames = totalFrames
        self.selectedFrames = selectedFrames
        self.criteria = criteria
        self.selectedPaths = selectedPaths
        self.rejectedPaths = rejectedPaths
        self.perFilter = perFilter
        self.manifest = manifest
        self.filterKeysPresent = filterKeysPresent
    }
}

/// One filter's own best-frame selection within a multi-filter session --
/// `StackSelection.perFilter`'s per-bucket breakdown (R11-T11, F15). Only
/// ever appears when the whole session has more than one filter bucket; see
/// `StackSelection.perFilter`'s own doc for the single-bucket (`nil`) case.
public struct StackFilterSelection: Codable, Sendable, Equatable {
    /// Raw FITS `FILTER` header value (e.g. `"Ha"`, `"OIII"`), or
    /// `FilterBreakdownQueries.noFilterSentinel` for the bucket of usable
    /// lights with no filter recorded at all -- same convention the
    /// "Szűrők" card / `stats --filters` already use, so this bucket always
    /// means the same thing everywhere in the app.
    public var filter: String
    /// This filter's own usable frame count (before any drop) -- the
    /// per-filter denominator for a "45/52" style preview.
    public var totalFrames: Int
    public var selectedFrames: Int
    /// Root-relative paths of this filter's selected frames, sorted.
    public var selectedPaths: [String]
    /// Root-relative paths of this filter's usable-but-dropped frames,
    /// sorted.
    public var rejectedPaths: [String]

    public init(
        filter: String,
        totalFrames: Int,
        selectedFrames: Int,
        selectedPaths: [String],
        rejectedPaths: [String]
    ) {
        self.filter = filter
        self.totalFrames = totalFrames
        self.selectedFrames = selectedFrames
        self.selectedPaths = selectedPaths
        self.rejectedPaths = rejectedPaths
    }
}

/// One row of `manifest.csv` -- `StackList.export`/`exportToDirectory` write
/// this alongside every stacklist export (R11-T11, F15): a flat, per-frame
/// inventory a WBPP/other post-processing script can read without touching
/// astrotool's own DB. Lists every usable light `select()` considered,
/// selected AND rejected, with just enough measured data to make sense of
/// the pick.
public struct StackManifestRow: Codable, Sendable, Equatable {
    /// Root-relative path into the LIBRARY (`sessions/<target>/<date>/
    /// lights/<name>`) -- NOT relative to the export tree. Traceable back to
    /// the original file regardless of `verdict`: only `"selected"` rows are
    /// actually hardlinked anywhere under this export, but every row's
    /// `file` still resolves against the library root.
    public var file: String
    /// Raw FITS `FILTER` header value, or
    /// `FilterBreakdownQueries.noFilterSentinel` for a frame with none.
    public var filter: String
    public var score: Double?
    public var fwhmPx: Double?
    public var sessionDate: String
    /// `"selected"`, or one of the three drop reasons `select()` itself
    /// distinguishes: `"rejected_verdict"` (DSS-rejected via
    /// `user_verdicts`), `"rejected_outlier"` (session-outlier score), or
    /// `"rejected_keepfraction"` (cut by the keepFraction ranking). English
    /// values, not Hungarian -- this file is written for an external
    /// tool/script to parse, the same register as the `.dssfilelist`/`.ssf`
    /// this export already writes, not the app's own Hungarian UI.
    public var verdict: String

    public init(file: String, filter: String, score: Double?, fwhmPx: Double?, sessionDate: String, verdict: String) {
        self.file = file
        self.filter = filter
        self.score = score
        self.fwhmPx = fwhmPx
        self.sessionDate = sessionDate
        self.verdict = verdict
    }
}

/// Bridges frame scoring (`Rater`) and the user's own accept/reject calls
/// (`DSSIngest`'s `user_verdicts`) to the tools that actually stack: picks
/// the best frames of one session (`select`), then materializes that pick
/// as artifacts DeepSkyStacker and Siril/Sirilic can consume directly
/// (`export`) -- hardlinked copies under `.astro_tool/stacklists/`, a
/// `.dssfilelist`, and a minimal `.ssf` script.
///
/// Siril 1.4 has no "stack this exact list of files" command, and its
/// sequence-index select/unselect grammar is fragile against reordering --
/// so rather than generate either of those, `export` hardlinks only the
/// SELECTED frames into their own folder and hands Siril a plain
/// `convert`/`register`/`stack` script over that folder's contents. The
/// `.dssfilelist` is for DeepSkyStacker/Sirilic, which do understand that
/// format directly.
///
/// R11-T11 (F15): a session shot through more than one filter gets a
/// SEPARATE `lights/<FILTER>/` hardlink folder, `.dssfilelist`, and `.ssf`
/// per filter -- PixInsight's WBPP (and Siril's own multi-filter workflows)
/// auto-detect filters from folder names, so this tree shape lets a WBPP
/// project just point at the export root. A `manifest.csv` is written at the
/// export root either way (flat or per-filter) -- see `StackManifestRow`.
public enum StackList {
    // MARK: - Selection

    /// Computes the best-frame selection for `target`/`date`. Read-only --
    /// never touches the filesystem or `db` beyond queries.
    ///
    /// Priority order (every rule that drops or specially treats a frame
    /// contributes a line to `criteria`):
    /// 1. Start from `FrameSet.lightBuckets`'s `usable` bucket -- deduped,
    ///    non-`Reject/` real light frames of this session.
    /// 2. HARD drops, in order: a frame with a recorded `user_verdicts` row
    ///    where `accepted == false` (the user rejected it in DeepSkyStacker)
    ///    is dropped regardless of any score; a frame whose persisted rating
    ///    `score` is more than `config.rating.outlierZScore` below zero
    ///    (same threshold `Rater.rate` itself uses for `FrameScore.isOutlier`
    ///    -- recomputed here from the stored `score` rather than duplicating
    ///    `Rater`'s z-score machinery) is dropped as a session outlier.
    /// 3. Whatever's left is ranked by `score` descending for the
    ///    keepFraction cut below -- but a frame with NO persisted rating (or
    ///    a rating with a `nil` score, e.g. `rate` was never run for it) is
    ///    never subjected to that cut at all: it's always kept. Missing data
    ///    is not evidence of a bad frame.
    /// 4. Among the SCORED remainder, keep the top
    ///    `max(ceil(keepFraction * remaining), 3)` (capped at however many
    ///    scored frames actually exist) -- `remaining` is the full
    ///    post-hard-drop population (scored + unscored), so the "never
    ///    fewer than 3 when available" floor still applies to a session
    ///    that's mostly unrated.
    ///
    /// R11-T11 (F15): steps 2-4 run PER FILTER BUCKET, not once over the
    /// whole session -- usable lights are first grouped by their raw FITS
    /// `FILTER` header (`FilterBreakdownQueries.noFilterSentinel` for frames
    /// with none), and each bucket gets its own hard-drop pass and its own
    /// keepFraction cut (so a rarer filter's weaker frames never get
    /// squeezed out just because a bigger filter's frames score higher in a
    /// combined ranking, and the "never fewer than 3" floor applies
    /// per-filter too). `keepFractionPerFilter` overrides `keepFraction` for
    /// one specific bucket's key; buckets not mentioned there fall back to
    /// `keepFraction`. A session with only one bucket (a single mono filter,
    /// or an unfiltered OSC/DSLR session) runs through the exact same
    /// per-bucket logic but produces `criteria`/`selectedPaths`/
    /// `rejectedPaths` byte-identical to what this function produced before
    /// per-filter grouping existed, and `StackSelection.perFilter` stays
    /// `nil` -- fully backward compatible.
    public static func select(
        target: String,
        date: String,
        captureSlug: String? = nil,
        keepFraction: Double = 0.8,
        keepFractionPerFilter: [String: Double] = [:],
        db: Database,
        config: AstroConfig
    ) throws -> StackSelection {
        let allFiles = try db.allFiles(includeMissing: false)
        var sessionLights = allFiles.filter {
            $0.area == .sessions && $0.role == .light && $0.target == target && $0.sessionDate == date
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        if let captureSlug {
            let resolver = try CaptureResolver.load(db: db)
            sessionLights = sessionLights.filter { file in
                resolver.resolve(file: file, meta: file.id.flatMap { metaByFileID[$0] }).slug == captureSlug
            }
        }

        let buckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)
        let usable = buckets.usable.sorted { $0.path < $1.path }
        let totalFrames = usable.count

        guard totalFrames > 0 else {
            return StackSelection(
                target: target,
                date: date,
                captureSlug: captureSlug,
                totalFrames: 0,
                selectedFrames: 0,
                criteria: ["nincs használható light frame ehhez a session-höz"],
                selectedPaths: [],
                rejectedPaths: []
            )
        }

        // Bucket by raw FITS FILTER header -- same convention
        // `FilterBreakdownQueries` uses for the "Szűrők" card, so a
        // "Ha"/"(nincs szűrő-adat)" bucket here always means the same thing
        // it does everywhere else in the app.
        var filesByFilter: [String: [FileRecord]] = [:]
        var filterOrder: [String] = []
        for file in usable {
            let meta = file.id.flatMap { metaByFileID[$0] }
            let rawFilter = meta?.filter?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (rawFilter?.isEmpty == false) ? rawFilter! : FilterBreakdownQueries.noFilterSentinel
            if filesByFilter[key] == nil { filterOrder.append(key) }
            filesByFilter[key, default: []].append(file)
        }

        let isSingleBucket = filterOrder.count <= 1
        // Biggest bucket first (ties by filter name) -- the same "what have
        // I got the most of" instinct `FilterBreakdownQueries.breakdown`
        // already sorts by, and a stable order for `perFilter`/the export
        // tree either way.
        let sortedFilterKeys = filterOrder.sorted { a, b in
            let countA = filesByFilter[a]?.count ?? 0
            let countB = filesByFilter[b]?.count ?? 0
            if countA != countB { return countA > countB }
            return a < b
        }

        var overallCriteria: [String] = ["használható (deduplikált, nem elvetett) light: \(totalFrames)"]
        var selectedFiles: [FileRecord] = []
        var rejectedFiles: [FileRecord] = []
        var manifestRows: [StackManifestRow] = []
        var perFilterResults: [StackFilterSelection] = []

        // R12-U2 (point 3): case-insensitive matching between
        // `keepFractionPerFilter`'s own keys and this session's bucket keys
        // -- a caller typing "ha" instead of "Ha" (or vice versa) should
        // still hit the override, the same case-folding
        // `CalibAnalyzer.normalizedFilterKey`/`FilterGoalQueries.merge`
        // already apply to a raw FITS FILTER value elsewhere in this
        // codebase. The CLI's own "none" alias for the no-filter sentinel is
        // resolved BEFORE this dictionary is built (`parseKeepFilterPerFilter`),
        // so this is a plain case-fold, nothing more.
        var normalizedOverrides: [String: Double] = [:]
        for (key, value) in keepFractionPerFilter {
            normalizedOverrides[normalizedFilterOverrideKey(key)] = value
        }

        for filterKey in sortedFilterKeys {
            let groupFiles = filesByFilter[filterKey] ?? []
            let fraction = normalizedOverrides[normalizedFilterOverrideKey(filterKey)] ?? keepFraction

            let result = try selectWithinGroup(
                files: groupFiles, filterKey: filterKey, keepFraction: fraction, db: db, config: config
            )

            if isSingleBucket {
                overallCriteria.append(contentsOf: result.criteria)
            } else {
                overallCriteria.append("[\(filterKey)] használható: \(groupFiles.count)")
                overallCriteria.append(contentsOf: result.criteria.map { "[\(filterKey)] \($0)" })
            }

            selectedFiles.append(contentsOf: result.selected)
            rejectedFiles.append(contentsOf: result.rejected)
            manifestRows.append(contentsOf: result.manifestRows)

            if !isSingleBucket {
                perFilterResults.append(
                    StackFilterSelection(
                        filter: filterKey,
                        totalFrames: groupFiles.count,
                        selectedFrames: result.selected.count,
                        selectedPaths: result.selected.map(\.path).sorted(),
                        rejectedPaths: result.rejected.map(\.path).sorted()
                    )
                )
            }
        }

        let selectedPaths = selectedFiles.map(\.path).sorted()
        let rejectedPaths = rejectedFiles.map(\.path).sorted()

        return StackSelection(
            target: target,
            date: date,
            captureSlug: captureSlug,
            totalFrames: totalFrames,
            selectedFrames: selectedPaths.count,
            criteria: overallCriteria,
            selectedPaths: selectedPaths,
            rejectedPaths: rejectedPaths,
            perFilter: isSingleBucket ? nil : perFilterResults,
            manifest: manifestRows,
            filterKeysPresent: sortedFilterKeys
        )
    }

    private static func formattedPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Trimmed + lower-cased, for matching a `keepFractionPerFilter` key
    /// against an actual bucket key case-insensitively (R12-U2, point 3) --
    /// same normalization shape `CalibAnalyzer.normalizedFilterKey` already
    /// uses for a raw FITS FILTER value, just without that function's
    /// `nil`-for-blank behavior (an override key is never legitimately
    /// blank -- `parseKeepFilterPerFilter` already rejects an empty filter
    /// name outright).
    private static func normalizedFilterOverrideKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Per-filter selection (R11-T11)

    private struct GroupSelectionResult {
        var criteria: [String]
        var selected: [FileRecord]
        var rejected: [FileRecord]
        var manifestRows: [StackManifestRow]
    }

    /// Runs the hard-drop + keepFraction pipeline (see `select`'s own doc)
    /// over exactly ONE filter bucket's usable files. Also fetches each
    /// file's rating unconditionally (even a DSS-rejected one) so
    /// `manifest.csv` can show its score/FWHM regardless of `verdict` --
    /// this is strictly additive over the pre-R11-T11 logic: a
    /// `user_verdicts`-rejected frame still short-circuits BEFORE the
    /// outlier/keepFraction checks exactly as before, the rating fetch
    /// itself just no longer gates on that.
    private static func selectWithinGroup(
        files: [FileRecord],
        filterKey: String,
        keepFraction: Double,
        db: Database,
        config: AstroConfig
    ) throws -> GroupSelectionResult {
        struct Entry {
            let file: FileRecord
            let score: Double?
            let fwhmPx: Double?
            let userRejected: Bool
        }

        var allEntries: [Entry] = []
        for file in files {
            var score: Double?
            var fwhmPx: Double?
            var userRejected = false
            if let id = file.id {
                if let verdict = try db.userVerdict(fileID: id), verdict.accepted == false {
                    userRejected = true
                }
                if let rating = try db.rating(fileID: id) {
                    score = rating.score
                    fwhmPx = rating.fwhm
                }
            }
            allEntries.append(Entry(file: file, score: score, fwhmPx: fwhmPx, userRejected: userRejected))
        }

        let verdictDropped = allEntries.filter(\.userRejected)
        let afterVerdict = allEntries.filter { !$0.userRejected }
        func isOutlier(_ entry: Entry) -> Bool {
            guard let score = entry.score else { return false }
            return score < -config.rating.outlierZScore
        }
        let outlierDropped = afterVerdict.filter(isOutlier)
        let remaining = afterVerdict.filter { !isOutlier($0) }

        var criteria: [String] = []
        if !verdictDropped.isEmpty { criteria.append("DSS-ben elvetett: \(verdictDropped.count)") }
        if !outlierDropped.isEmpty { criteria.append("kiugróan gyenge: \(outlierDropped.count)") }

        let scoredEntries = remaining.filter { $0.score != nil }.sorted { $0.score! > $1.score! }
        let unscoredEntries = remaining.filter { $0.score == nil }
        if !unscoredEntries.isEmpty { criteria.append("nem pontozott: \(unscoredEntries.count) — megtartva") }

        let remainingCount = remaining.count
        let keepCount: Int
        if remainingCount <= 3 {
            keepCount = remainingCount
        } else {
            let raw = Int((keepFraction * Double(remainingCount)).rounded(.up))
            keepCount = min(max(raw, 3), remainingCount)
        }

        let selectedScoredCount = max(min(keepCount - unscoredEntries.count, scoredEntries.count), 0)
        let selectedScored = Array(scoredEntries.prefix(selectedScoredCount))
        let rejectedScored = Array(scoredEntries.dropFirst(selectedScoredCount))

        criteria.append(
            "megtartva: \(unscoredEntries.count + selectedScored.count) / \(remainingCount) (keepFraction \(formattedPercent(keepFraction)))"
        )

        let selectedEntries = unscoredEntries + selectedScored
        let selectedPathSet = Set(selectedEntries.map(\.file.path))
        let verdictDroppedPathSet = Set(verdictDropped.map(\.file.path))
        let outlierDroppedPathSet = Set(outlierDropped.map(\.file.path))

        var manifestRows: [StackManifestRow] = []
        for entry in allEntries {
            let verdict: String
            if selectedPathSet.contains(entry.file.path) {
                verdict = "selected"
            } else if verdictDroppedPathSet.contains(entry.file.path) {
                verdict = "rejected_verdict"
            } else if outlierDroppedPathSet.contains(entry.file.path) {
                verdict = "rejected_outlier"
            } else {
                verdict = "rejected_keepfraction"
            }
            manifestRows.append(
                StackManifestRow(
                    file: entry.file.path,
                    filter: filterKey,
                    score: entry.score,
                    fwhmPx: entry.fwhmPx,
                    sessionDate: entry.file.sessionDate ?? "",
                    verdict: verdict
                )
            )
        }

        return GroupSelectionResult(
            criteria: criteria,
            selected: selectedEntries.map(\.file),
            rejected: verdictDropped.map(\.file) + outlierDropped.map(\.file) + rejectedScored.map(\.file),
            manifestRows: manifestRows
        )
    }

    // MARK: - Export

    /// Outcome of one `export`/`exportToDirectory` call (R12-U2) -- beyond
    /// just "where did it write", both callers (CLI, `StackListSheet`) need
    /// to know whether this run's own re-export SYNC removed anything left
    /// over from a previous export with a different selection (point 2), and
    /// whether a cross-device `--out` destination fell back to a plain copy
    /// instead of a hardlink (point 1). `export` itself never crosses a
    /// volume boundary (its destination is always under the SAME root as
    /// its source), so `copyFallbackUsed` is always `false` there --
    /// `exportToDirectory` is the only caller that can ever set it `true`.
    public struct StackExportResult: Sendable, Equatable {
        public var directory: URL
        /// Regular files removed from the destination `lights/` tree because
        /// they belonged to an EARLIER export's selection but not this one
        /// (R12-U2, point 2) -- `0` for a fresh export or a re-export whose
        /// tree already matches the current selection exactly.
        public var removedStaleCount: Int
        /// `true` iff at least one selected frame had to be plain-copied
        /// instead of hardlinked because `destDir` sits on a different
        /// volume than the source library (R12-U2, point 1).
        public var copyFallbackUsed: Bool

        public init(directory: URL, removedStaleCount: Int = 0, copyFallbackUsed: Bool = false) {
            self.directory = directory
            self.removedStaleCount = removedStaleCount
            self.copyFallbackUsed = copyFallbackUsed
        }
    }

    /// Materializes `selection` on disk: hardlinks the selected frames into
    /// `.astro_tool/stacklists/<target>-<date>/lights/` (via
    /// `WriteGuard.linkStackListFile` -- additive, never overwrites), then
    /// writes a `.dssfilelist`/`.ssf` pair alongside it (via
    /// `WriteGuard.writeToolFile` -- freely overwritable, it's the tool's
    /// own state, not the user's library), plus a `manifest.csv`.
    ///
    /// R11-T11 (F15): when `selection.perFilter` is non-`nil` (more than one
    /// filter bucket), the hardlink tree becomes `lights/<FILTER>/` (one
    /// subfolder per filter, sanitized the same way session/target folder
    /// names are -- R12-U2, point 4: with a collision-safe fallback slug, see
    /// `resolvedFilterSlugs`), and EACH filter gets its own
    /// `<slug>-<FILTER>.dssfilelist`/`<slug>-<FILTER>.ssf` pair instead of one
    /// shared `stack.*` pair -- PixInsight's WBPP (and most other batch
    /// preprocessors) auto-detect filters from folder names, so this shape
    /// lets a WBPP project just point at `lights/`. `manifest.csv` is always
    /// written once at the stacklist root regardless of filter count.
    ///
    /// R12-U2 (point 2): after linking, the destination `lights/` tree is
    /// SYNCED to the current selection -- any regular file directly under
    /// `lights/` or one level under one of its own subfolders that ISN'T
    /// part of THIS selection (left over from an earlier export with a
    /// different keep-fraction, or from a flat->per-filter shape change) is
    /// removed. Strictly scoped to this stacklist's own `lights/` tree (see
    /// `syncLightsTree`'s own doc) -- the user's library is never touched.
    ///
    /// Idempotent: re-running `export` with the same (or an updated)
    /// selection never disturbs an already-linked frame -- `linkStackListFile`
    /// skips any destination that already exists -- and always rewrites the
    /// `.dssfilelist`/`.ssf`/`manifest.csv` text files to match the current
    /// selection.
    @discardableResult
    public static func export(_ selection: StackSelection, root: URL, using writeGuard: WriteGuard) throws -> StackExportResult {
        let slug = exportSlug(for: selection)
        let stacklistDir = root
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("stacklists/\(slug)", isDirectory: true)
        let lightsDir = stacklistDir.appendingPathComponent("lights", isDirectory: true)

        var expectedRelativePaths = Set<String>()
        var linkedNameByPath: [String: String] = [:]

        if let perFilter = selection.perFilter, !perFilter.isEmpty {
            let filterSlugs = resolvedFilterSlugs(for: perFilter)
            for (index, filterSelection) in perFilter.enumerated() {
                let filterSlug = filterSlugs[index]
                let lightsDestDir = ".astro_tool/stacklists/\(slug)/lights/\(filterSlug)"
                let nameByPath = disambiguatedFileNames(forPaths: filterSelection.selectedPaths)

                var fileNames: [String] = []
                for path in filterSelection.selectedPaths {
                    let fileName = nameByPath[path] ?? (path as NSString).lastPathComponent
                    _ = try writeGuard.linkStackListFile(
                        sourceRelative: path, destDirRelative: lightsDestDir, destFileName: fileName
                    )
                    fileNames.append(fileName)
                    expectedRelativePaths.insert("\(filterSlug)/\(fileName)")
                    linkedNameByPath[path] = fileName
                }

                let baseName = "\(slug)-\(filterSlug)"
                let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights/\(filterSlug)")
                try writeGuard.writeToolFile(
                    relativePath: "stacklists/\(slug)/\(baseName).dssfilelist", data: Data(dssContent.utf8)
                )

                // R11-T11: cwd is the filter's OWN frame folder directly
                // (Siril's `convert` reads only the current working
                // directory, never a subfolder -- verified against Siril's
                // own docs), so this per-filter script is self-contained.
                let filterLightsDir = stacklistDir.appendingPathComponent("lights/\(filterSlug)", isDirectory: true)
                let ssfContent = try renderSSF(framesDir: filterLightsDir, filterLabel: filterSelection.filter)
                try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/\(baseName).ssf", data: Data(ssfContent.utf8))
            }
        } else {
            let lightsDestDir = ".astro_tool/stacklists/\(slug)/lights"
            let nameByPath = disambiguatedFileNames(forPaths: selection.selectedPaths)

            var fileNames: [String] = []
            for path in selection.selectedPaths {
                let fileName = nameByPath[path] ?? (path as NSString).lastPathComponent
                _ = try writeGuard.linkStackListFile(
                    sourceRelative: path, destDirRelative: lightsDestDir, destFileName: fileName
                )
                fileNames.append(fileName)
                expectedRelativePaths.insert(fileName)
                linkedNameByPath[path] = fileName
            }

            let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights")
            try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.dssfilelist", data: Data(dssContent.utf8))

            // R11-T17: cd's into the flat export's OWN lights/ subfolder, not
            // its parent stacklistDir -- Siril's `convert` reads only the
            // current working directory, and the hardlinked frames live in
            // lights/, exactly like the per-filter branch above already got
            // right. Before this fix the flat/single-filter script cd'd one
            // level too high and `convert` would find zero frames.
            let ssfContent = try renderSSF(framesDir: lightsDir, filterLabel: nil)
            try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.ssf", data: Data(ssfContent.utf8))
        }

        // R12-U2 (point 2): sync AFTER every filter's own frames have been
        // linked, over the whole `lights/` tree at once -- a stale filter
        // subfolder's leftover files (e.g. an old per-filter export where
        // one filter has since disappeared entirely) are caught by this same
        // pass, not just a stale file within a still-present bucket.
        let removedStaleCount = try syncLightsTree(
            lightsDir: lightsDir, expectedRelativePaths: expectedRelativePaths, guardBase: writeGuard.toolDir
        )

        let manifestContent = renderManifestCSV(selection.manifest, libraryRoot: root, linkedNameByPath: linkedNameByPath)
        try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/manifest.csv", data: Data(manifestContent.utf8))

        return StackExportResult(directory: stacklistDir, removedStaleCount: removedStaleCount)
    }

    /// R11-T4 (`astrotool stacklist --out PATH`): the same materialization as
    /// `export`, but directly into a caller-chosen `destDir` -- typically
    /// OUTSIDE the library root, e.g. a WBPP project folder on another
    /// volume -- instead of the default `.astro_tool/stacklists/<slug>/`
    /// location. Deliberately bypasses `WriteGuard` entirely: `WriteGuard`'s
    /// whole contract is "only ever writes to these specific known-safe
    /// spots under the root", which is the opposite of what an explicit
    /// `--out` is for. Same guard the CLI's `export --out PATH` already
    /// applies (destDir must not resolve inside the library root) is the
    /// caller's responsibility, not this function's -- this only performs
    /// the write once that's already been checked.
    ///
    /// `destDir` becomes the stacklist directory directly (no extra
    /// `<target>-<date>` slug subfolder, since the caller already chose the
    /// exact destination): `destDir/lights/`, `destDir/stack.dssfilelist`,
    /// `destDir/stack.ssf`, `destDir/manifest.csv` -- or, per R11-T11's
    /// multi-filter tree (see `export`'s own doc), `destDir/lights/<FILTER>/`
    /// plus one `<target>-<date>-<FILTER>.dssfilelist`/`.ssf` pair per
    /// filter. Same idempotent, additive, hardlink-only behavior as
    /// `export` -- never overwrites a destination file that's already there.
    ///
    /// R12-U2 (point 1): `destDir` can legitimately sit on a DIFFERENT
    /// volume than `sourceRoot` -- the one hardlink destination in this whole
    /// package where that's possible -- so a per-frame link that fails with
    /// `EXDEV` (cross-device) falls back to a plain copy instead of
    /// propagating the error; `result.copyFallbackUsed` tells the caller this
    /// happened, so the CLI/app can say "hardlink helyett másolat készült"
    /// rather than silently behaving differently.
    @discardableResult
    public static func exportToDirectory(
        _ selection: StackSelection, destDir: URL, sourceRoot: URL
    ) throws -> StackExportResult {
        let fm = FileManager.default
        let lightsDir = destDir.appendingPathComponent("lights", isDirectory: true)

        var expectedRelativePaths = Set<String>()
        var linkedNameByPath: [String: String] = [:]
        var copyFallbackUsed = false

        if let perFilter = selection.perFilter, !perFilter.isEmpty {
            let filterSlugs = resolvedFilterSlugs(for: perFilter)
            for (index, filterSelection) in perFilter.enumerated() {
                let filterSlug = filterSlugs[index]
                let filterLightsDir = destDir.appendingPathComponent("lights/\(filterSlug)", isDirectory: true)
                try fm.createDirectory(at: filterLightsDir, withIntermediateDirectories: true)
                let nameByPath = disambiguatedFileNames(forPaths: filterSelection.selectedPaths)

                var fileNames: [String] = []
                for path in filterSelection.selectedPaths {
                    let fileName = nameByPath[path] ?? (path as NSString).lastPathComponent
                    fileNames.append(fileName)
                    expectedRelativePaths.insert("\(filterSlug)/\(fileName)")
                    linkedNameByPath[path] = fileName

                    let destFileURL = filterLightsDir.appendingPathComponent(fileName, isDirectory: false)
                    let sourceURL = sourceRoot.appendingPathComponent(path)
                    if try linkOrCopyForExport(
                        sourceURL: sourceURL, destFileURL: destFileURL,
                        link: { try fm.linkItem(at: $0, to: $1) }, copy: { try fm.copyItem(at: $0, to: $1) }
                    ) {
                        copyFallbackUsed = true
                    }
                }

                let baseName = "\(exportSlug(for: selection))-\(filterSlug)"
                let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights/\(filterSlug)")
                try Data(dssContent.utf8).write(to: destDir.appendingPathComponent("\(baseName).dssfilelist"))

                let ssfContent = try renderSSF(framesDir: filterLightsDir, filterLabel: filterSelection.filter)
                try Data(ssfContent.utf8).write(to: destDir.appendingPathComponent("\(baseName).ssf"))
            }
        } else {
            try fm.createDirectory(at: lightsDir, withIntermediateDirectories: true)
            let nameByPath = disambiguatedFileNames(forPaths: selection.selectedPaths)

            var fileNames: [String] = []
            for path in selection.selectedPaths {
                let fileName = nameByPath[path] ?? (path as NSString).lastPathComponent
                fileNames.append(fileName)
                expectedRelativePaths.insert(fileName)
                linkedNameByPath[path] = fileName

                let destFileURL = lightsDir.appendingPathComponent(fileName, isDirectory: false)
                let sourceURL = sourceRoot.appendingPathComponent(path)
                if try linkOrCopyForExport(
                    sourceURL: sourceURL, destFileURL: destFileURL,
                    link: { try fm.linkItem(at: $0, to: $1) }, copy: { try fm.copyItem(at: $0, to: $1) }
                ) {
                    copyFallbackUsed = true
                }
            }

            let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights")
            try Data(dssContent.utf8).write(to: destDir.appendingPathComponent("stack.dssfilelist"))

            // R11-T17: same fix as `export` above -- cd into lights/ itself,
            // not destDir (its parent).
            let ssfContent = try renderSSF(framesDir: lightsDir, filterLabel: nil)
            try Data(ssfContent.utf8).write(to: destDir.appendingPathComponent("stack.ssf"))
        }

        // R12-U2 (point 2): same re-export sync as `export`, scoped to
        // `destDir`'s own `lights/` tree this time (the guard base for an
        // external `--out` destination).
        let removedStaleCount = try syncLightsTree(
            lightsDir: lightsDir, expectedRelativePaths: expectedRelativePaths, guardBase: destDir
        )

        let manifestContent = renderManifestCSV(selection.manifest, libraryRoot: sourceRoot, linkedNameByPath: linkedNameByPath)
        try Data(manifestContent.utf8).write(to: destDir.appendingPathComponent("manifest.csv"))

        return StackExportResult(directory: destDir, removedStaleCount: removedStaleCount, copyFallbackUsed: copyFallbackUsed)
    }

    /// Links `sourceURL` to `destFileURL`, falling back to a plain COPY when
    /// `link` itself reports a cross-device (`EXDEV`) failure (R12-U2, point
    /// 1) -- `exportToDirectory`'s `destDir` is the one hardlink destination
    /// in this package that can legitimately sit on a different volume than
    /// the library root, and a hard link (a second directory entry for the
    /// SAME inode) simply cannot cross a filesystem boundary by definition.
    /// Skips entirely (returns `false`, touches nothing) when `destFileURL`
    /// already exists -- same idempotent "never overwrite" rule every other
    /// hardlink call site in this package follows.
    ///
    /// `link`/`copy` are injected rather than calling `FileManager` directly
    /// so a test can simulate the `EXDEV` failure with a fake `link` closure
    /// without needing a REAL second volume -- both production call sites
    /// pass `FileManager.default.linkItem`/`copyItem`.
    ///
    /// Returns `true` iff the copy fallback actually fired.
    @discardableResult
    static func linkOrCopyForExport(
        sourceURL: URL,
        destFileURL: URL,
        fileManager: FileManager = .default,
        link: (URL, URL) throws -> Void,
        copy: (URL, URL) throws -> Void
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: destFileURL.path) else { return false }
        do {
            try link(sourceURL, destFileURL)
            return false
        } catch {
            guard isCrossDeviceLinkError(error) else { throw error }
            try copy(sourceURL, destFileURL)
            return true
        }
    }

    /// Classifies a filesystem error as a cross-device link failure
    /// (`EXDEV`) -- the OS's own answer to "hard-link a file onto a
    /// different volume", impossible by definition (a hard link is a second
    /// directory entry for the SAME inode, and an inode belongs to exactly
    /// one filesystem). Mirrors `isPermissionError`'s own recursive "check
    /// `NSUnderlyingErrorKey` too" shape (`ExclusionRules.swift`) -- Foundation
    /// sometimes wraps the real POSIX error one level down rather than
    /// surfacing it directly.
    static func isCrossDeviceLinkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EXDEV) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isCrossDeviceLinkError(underlying)
        }
        return false
    }

    /// Resolves a stable, collision-free folder/basename SLUG for every one
    /// of `perFilter`'s own filter buckets, in that array's order (R12-U2,
    /// point 4) -- `export`/`exportToDirectory`'s per-filter tree
    /// (`lights/<slug>/`, `<target>-<date>-<slug>.dssfilelist`/`.ssf`) used
    /// to call `Sanitizer.sanitize(filterSelection.filter)` directly and let
    /// two different filters collide silently: a filter name made ENTIRELY
    /// of characters `Sanitizer` strips (e.g. `"###"`) sanitizes to an EMPTY
    /// string, and two distinctly-named filters can sanitize to the very
    /// SAME non-empty slug (e.g. `"Ha!"` and `"Ha?"` both -> `"Ha"`) --
    /// either way, the second bucket's own `linkStackListFile`/`linkItem`
    /// calls would silently no-op against the first bucket's already-linked
    /// files (or empty-string path component would outright fail).
    ///
    /// Assigns, in encounter order:
    /// - `"filter_1"`, `"filter_2"`, … to every EMPTY-slug bucket;
    /// - a `"_2"`, `"_3"`, … numeric suffix to every non-empty slug that's
    ///   ALREADY been used by an earlier bucket in this same export.
    ///
    /// A session with no collision at all resolves to exactly the plain
    /// `Sanitizer.sanitize` output every existing bucket already used --
    /// fully backward compatible.
    static func resolvedFilterSlugs(for perFilter: [StackFilterSelection]) -> [String] {
        var usedSlugs = Set<String>()
        var emptySlugCounter = 0
        var result: [String] = []
        for filterSelection in perFilter {
            var candidate = Sanitizer.sanitize(filterSelection.filter)
            if candidate.isEmpty {
                emptySlugCounter += 1
                candidate = "filter_\(emptySlugCounter)"
            } else if usedSlugs.contains(candidate) {
                var suffix = 2
                var attempt = "\(candidate)_\(suffix)"
                while usedSlugs.contains(attempt) {
                    suffix += 1
                    attempt = "\(candidate)_\(suffix)"
                }
                candidate = attempt
            }
            usedSlugs.insert(candidate)
            result.append(candidate)
        }
        return result
    }

    /// Builds a collision-safe hardlink FILENAME for every one of `paths`
    /// (one filter bucket's already-selected, path-sorted frames) -- R12-U2,
    /// point 4. `export`/`exportToDirectory` used to just take
    /// `(path as NSString).lastPathComponent` and rely on the destination
    /// write's own "already there, skip" idempotence to protect against a
    /// re-run -- but that same idempotence silently swallows a SECOND,
    /// DIFFERENT source file that happens to share a first file's basename
    /// (e.g. two sub-folders' own `img_0001.fit`): the second frame would
    /// just never get linked at all, with nothing in the output to say so.
    ///
    /// The FIRST path with a given basename keeps it unchanged. Every
    /// subsequent path with the SAME basename gets a `<parent-dir>__<name>`
    /// disambiguated name instead (e.g. `part2/img_0001.fit` ->
    /// `"part2__img_0001.fit"`), falling back to a bare numeric `_2`/`_3`…
    /// suffix on top of that if the parent-prefixed name is STILL taken (a
    /// rarer, second-order collision). A bucket with no colliding basename
    /// at all resolves every path to its own plain basename -- byte-for-byte
    /// what this export produced before this fix.
    static func disambiguatedFileNames(forPaths paths: [String]) -> [String: String] {
        var usedNames = Set<String>()
        var result: [String: String] = [:]
        for path in paths {
            let baseName = (path as NSString).lastPathComponent
            var candidate = baseName
            if usedNames.contains(candidate) {
                let parentDir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let prefixedBase = parentDir.isEmpty ? baseName : "\(parentDir)__\(baseName)"
                candidate = prefixedBase
                var suffix = 2
                while usedNames.contains(candidate) {
                    candidate = "\(prefixedBase)_\(suffix)"
                    suffix += 1
                }
            }
            usedNames.insert(candidate)
            result[path] = candidate
        }
        return result
    }

    /// Removes every regular file (symlinks and directories left alone)
    /// directly under `lightsDir`, or one level under any of `lightsDir`'s
    /// OWN immediate subfolders (the flat vs. per-filter shapes `export`/
    /// `exportToDirectory` produce), that ISN'T among `expectedRelativePaths`
    /// (each relative to `lightsDir` itself -- a bare name like `"l1.fit"`
    /// for the flat shape, `"Ha/ha1.fit"` for a per-filter one) -- R12-U2,
    /// point 2's re-export sync. Never recurses past that one level, so a
    /// stray deeper subfolder under `lights/` is left untouched either way.
    ///
    /// `guardBase` must be an ancestor of `lightsDir` (the tool's own
    /// `toolDir` for `export`'s internal `.astro_tool/stacklists/...`
    /// location, `destDir` for `exportToDirectory`'s external `--out` tree)
    /// -- every candidate-for-deletion path is re-verified against it via
    /// `standardizedFileURL` containment right before `removeItem` ever
    /// runs, on top of already only ever walking `lightsDir`'s own two
    /// levels: the same defense-in-depth `WriteGuard`'s own writes already
    /// apply, so this can never reach outside the export's own tree, let
    /// alone into the user's actual library.
    ///
    /// Returns the number of files actually removed.
    static func syncLightsTree(lightsDir: URL, expectedRelativePaths: Set<String>, guardBase: URL) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lightsDir.path) else { return 0 }
        let guardBasePath = guardBase.standardizedFileURL.path

        func isRegularFile(_ url: URL) -> Bool {
            let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            return type == .typeRegular
        }

        var removed = 0
        func maybeRemove(_ url: URL, relativePath: String) throws {
            guard !expectedRelativePaths.contains(relativePath) else { return }
            guard isRegularFile(url) else { return }
            let standardized = url.standardizedFileURL
            guard standardized.path == guardBasePath || standardized.path.hasPrefix(guardBasePath + "/") else { return }
            try fm.removeItem(at: standardized)
            removed += 1
        }

        let topLevelNames = (try? fm.contentsOfDirectory(atPath: lightsDir.path)) ?? []
        for name in topLevelNames {
            let itemURL = lightsDir.appendingPathComponent(name, isDirectory: false)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let subDirURL = lightsDir.appendingPathComponent(name, isDirectory: true)
                let subNames = (try? fm.contentsOfDirectory(atPath: subDirURL.path)) ?? []
                for subName in subNames {
                    let fileURL = subDirURL.appendingPathComponent(subName, isDirectory: false)
                    try maybeRemove(fileURL, relativePath: "\(name)/\(subName)")
                }
            } else {
                try maybeRemove(itemURL, relativePath: name)
            }
        }
        return removed
    }

    /// `<sanitized target>-<date>` -- the stacklist directory's own name
    /// under `.astro_tool/stacklists/`. Reuses `Sanitizer` (same convention
    /// `add_new_session.sh`/`SessionCreator` use for target folder names) so
    /// a target containing characters outside its allow-list still yields a
    /// safe path component; `WriteGuard.linkStackListFile`'s own component
    /// validation is the actual defense against a pathological result
    /// (e.g. a target that sanitizes down to `".."`), not this function.
    /// `public` (R12-U2, point 5) so the app layer (`StackListSheet`'s own
    /// `exportDestinationCaption`) can show the REAL, slugged export path
    /// instead of a raw `"\(target)-\(date)"` literal that silently diverges
    /// from the actual on-disk folder name whenever `target` contains a
    /// character `Sanitizer` strips.
    public static func slug(target: String, date: String) -> String {
        "\(Sanitizer.sanitize(target))-\(date)"
    }

    /// Capture-scoped exports cannot overwrite the whole-session export.
    public static func exportSlug(for selection: StackSelection) -> String {
        let session = slug(target: selection.target, date: selection.date)
        guard let captureSlug = selection.captureSlug else { return session }
        return "\(session)-\(Sanitizer.sanitize(captureSlug))"
    }

    // MARK: - .dssfilelist

    /// DeepSkyStacker's own file-list format (verified against a real
    /// sample, see `DSSFilelistParser`'s doc comment): line 1 literally
    /// `"DSS file list"`, line 2 the tab-separated `CHECKED\tTYPE\tFILE`
    /// header, then one tab-separated row per tracked file.
    ///
    /// Only the SELECTED (hardlinked) frames are listed here, each
    /// `CHECKED == 1`, with `FILE` relative to this `.dssfilelist`'s own
    /// location (`<lightsRelativePath>/<name>`, resolving through the
    /// hardlinks this same export just created -- `"lights"` for the flat/
    /// single-filter case, `"lights/<FILTER>"` for a per-filter one, R11-T11).
    /// Rejected frames are deliberately NOT listed as `CHECKED == 0` rows:
    /// unlike DSS's own native file list (which sits next to every frame it
    /// knows about, selected or not), this export only ever materializes the
    /// selected subset on disk -- a rejected frame has no path relative to
    /// this directory to write in the first place, and listing one that
    /// doesn't resolve would be worse than omitting it.
    ///
    /// Line endings: plain `\n`. The one real `.dssfilelist` sample this was
    /// verified against had no `\r`; there's no evidence DSS requires CRLF
    /// specifically (it's cross-platform, C++/wxWidgets), so this doesn't
    /// manufacture one.
    private static func renderDSSFilelist(fileNames: [String], lightsRelativePath: String) -> String {
        var lines = ["DSS file list", "CHECKED\tTYPE\tFILE"]
        for name in fileNames {
            lines.append("1\tlight\t\(lightsRelativePath)/\(name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - .ssf

    /// A minimal, reviewable Siril script over `framesDir`'s own contents:
    /// `convert` (raw -> Siril's working format), `register` (star
    /// alignment), then a single rejection-stack. This is deliberately NOT a
    /// "run everything end to end" pipeline -- it has no calibration step at
    /// all (Siril 1.4's `calibrate` needs master paths this type has no way
    /// to know are still valid/current), so the generated comment header
    /// tells the user to insert their own `calibrate`/`calibrate_single`
    /// line(s) first if this session needs them. Never contains a
    /// destructive command (no `rm`, no overwriting redirect) -- same
    /// "generated for a human to read before running" stance as
    /// `SuggestionScript`.
    ///
    /// `framesDir`'s path is interpolated into a quoted `cd "..."` line; same
    /// injection guard `SirilCLI.buildScript` uses (a path containing `"` or
    /// `\` is rejected outright rather than guessing at escaping rules
    /// Siril's script grammar may or may not support). `framesDir` MUST be
    /// the folder that directly contains the hardlinked light frames --
    /// Siril's `convert` only ever reads the current working directory, not
    /// a subfolder of it -- so every caller passes the actual `lights/` (or
    /// `lights/<FILTER>/`) directory itself, never its parent. (R11-T17: the
    /// flat/single-filter export used to pass its parent -- the stacklist
    /// root -- here, so `convert` would find zero frames; see `export`'s own
    /// doc comment.)
    ///
    /// `filterLabel` (R11-T11): when non-`nil`, adds a `# Filter: <name>`
    /// comment line -- used for a per-filter script, where `framesDir` is
    /// that filter's OWN `lights/<FILTER>` folder. `nil` for the flat/
    /// single-filter export.
    private static func renderSSF(framesDir: URL, filterLabel: String?) throws -> String {
        let path = framesDir.path
        guard !containsSirilScriptInjectionRisk(path) else {
            throw AstroError.invalidInput("stacklist dir path unsafe for a Siril script: \(path)")
        }

        var lines = [
            "# Generated by astrotool -- review before running (siril-cli -s stack.ssf,",
            "# or open in the Siril app and run manually).",
            "#",
        ]
        if let filterLabel {
            lines.append("# Filter: \(filterLabel)")
            lines.append("#")
        }
        lines.append(contentsOf: [
            "# Converts, registers, and stacks the SELECTED lights hardlinked into",
            "# this folder's own lights/ subdirectory -- your library originals are",
            "# never modified by astrotool.",
            "#",
            "# astrotool does not calibrate frames. If this session needs bias/dark/",
            "# flat calibration, insert your own calibrate/calibrate_single command(s)",
            "# (pointing at your own current masters) between convert and register",
            "# below before running this script.",
            "requires 1.2.0",
            "cd \"\(path)\"",
            "convert light -out=.",
            "register light",
            "stack r_light rej 3 3 -norm=addscale -out=result",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - manifest.csv (R11-T11)

    /// Renders `manifest.csv` -- see `StackManifestRow`'s own doc comment for
    /// what each data column means. R12-U2 (point 6): line 1 is now a `#`
    /// comment carrying the LIBRARY root's absolute path (`# library_root:
    /// /path/to/library`) -- every `file` column below is root-RELATIVE, so
    /// without this a script reading `manifest.csv` in isolation (e.g. after
    /// copying it off onto another machine) has no way to resolve those
    /// paths back to real files; a leading `#` line is universally ignored
    /// by CSV readers that don't know to look for it, so this doesn't break
    /// any existing consumer. R12-U2 (point 4): the trailing `linked_name`
    /// column is this row's ACTUAL on-disk hardlink filename under `lights/`
    /// (post collision-disambiguation, see `disambiguatedFileNames`) --
    /// blank for a row that was never linked at all (any `verdict` other
    /// than `"selected"`).
    private static func renderManifestCSV(
        _ rows: [StackManifestRow], libraryRoot: URL, linkedNameByPath: [String: String] = [:]
    ) -> String {
        var lines = ["# library_root: \(libraryRoot.standardizedFileURL.path)"]
        lines.append("file,filter,score,fwhm_px,session_date,verdict,linked_name")
        for row in rows {
            let fields = [
                row.file,
                row.filter,
                row.score.map { String(format: "%.2f", $0) } ?? "",
                row.fwhmPx.map { String(format: "%.2f", $0) } ?? "",
                row.sessionDate,
                row.verdict,
                linkedNameByPath[row.file] ?? "",
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Standard CSV field escaping: wrap in quotes (doubling any embedded
    /// quote) only when the field actually needs it -- same convention
    /// `PlanExport`/`AcquisitionExport` each already duplicate their own
    /// copy of (there's no shared CSV-writing type yet in AstroCore).
    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
