import Foundation

/// The outcome of `StackList.select` for one session -- which frames were
/// kept, which were dropped and why, ready to hand to `StackList.export`
/// (or to print/inspect on its own via `--json`).
public struct StackSelection: Codable, Sendable {
    public var target: String
    public var date: String
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

    public init(
        target: String,
        date: String,
        totalFrames: Int,
        selectedFrames: Int,
        criteria: [String],
        selectedPaths: [String],
        rejectedPaths: [String],
        perFilter: [StackFilterSelection]? = nil,
        manifest: [StackManifestRow] = []
    ) {
        self.target = target
        self.date = date
        self.totalFrames = totalFrames
        self.selectedFrames = selectedFrames
        self.criteria = criteria
        self.selectedPaths = selectedPaths
        self.rejectedPaths = rejectedPaths
        self.perFilter = perFilter
        self.manifest = manifest
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
        keepFraction: Double = 0.8,
        keepFractionPerFilter: [String: Double] = [:],
        db: Database,
        config: AstroConfig
    ) throws -> StackSelection {
        let allFiles = try db.allFiles(includeMissing: false)
        let sessionLights = allFiles.filter {
            $0.area == .sessions && $0.role == .light && $0.target == target && $0.sessionDate == date
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)
        let usable = buckets.usable.sorted { $0.path < $1.path }
        let totalFrames = usable.count

        guard totalFrames > 0 else {
            return StackSelection(
                target: target,
                date: date,
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

        for filterKey in sortedFilterKeys {
            let groupFiles = filesByFilter[filterKey] ?? []
            let fraction = keepFractionPerFilter[filterKey] ?? keepFraction

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
            totalFrames: totalFrames,
            selectedFrames: selectedPaths.count,
            criteria: overallCriteria,
            selectedPaths: selectedPaths,
            rejectedPaths: rejectedPaths,
            perFilter: isSingleBucket ? nil : perFilterResults,
            manifest: manifestRows
        )
    }

    private static func formattedPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
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

    /// Materializes `selection` on disk: hardlinks the selected frames into
    /// `.astro_tool/stacklists/<target>-<date>/lights/` (via
    /// `WriteGuard.linkStackListFile` -- additive, never overwrites), then
    /// writes a `.dssfilelist`/`.ssf` pair alongside it (via
    /// `WriteGuard.writeToolFile` -- freely overwritable, it's the tool's
    /// own state, not the user's library), plus a `manifest.csv`. Returns
    /// the stacklist directory.
    ///
    /// R11-T11 (F15): when `selection.perFilter` is non-`nil` (more than one
    /// filter bucket), the hardlink tree becomes `lights/<FILTER>/` (one
    /// subfolder per filter, sanitized the same way session/target folder
    /// names are), and EACH filter gets its own `<slug>-<FILTER>.dssfilelist`
    /// / `<slug>-<FILTER>.ssf` pair instead of one shared `stack.*` pair --
    /// PixInsight's WBPP (and most other batch preprocessors) auto-detect
    /// filters from folder names, so this shape lets a WBPP project just
    /// point at `lights/`. `manifest.csv` is always written once at the
    /// stacklist root regardless of filter count.
    ///
    /// Idempotent: re-running `export` with the same (or an updated)
    /// selection never disturbs an already-linked frame -- `linkStackListFile`
    /// skips any destination that already exists -- and always rewrites the
    /// `.dssfilelist`/`.ssf`/`manifest.csv` text files to match the current
    /// selection.
    @discardableResult
    public static func export(_ selection: StackSelection, root: URL, using writeGuard: WriteGuard) throws -> URL {
        let slug = slug(target: selection.target, date: selection.date)
        let stacklistDir = root
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("stacklists/\(slug)", isDirectory: true)

        if let perFilter = selection.perFilter, !perFilter.isEmpty {
            for filterSelection in perFilter {
                let filterSlug = Sanitizer.sanitize(filterSelection.filter)
                let lightsDestDir = ".astro_tool/stacklists/\(slug)/lights/\(filterSlug)"

                var fileNames: [String] = []
                for path in filterSelection.selectedPaths {
                    let fileName = (path as NSString).lastPathComponent
                    _ = try writeGuard.linkStackListFile(sourceRelative: path, destDirRelative: lightsDestDir)
                    fileNames.append(fileName)
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

            var fileNames: [String] = []
            for path in selection.selectedPaths {
                let fileName = (path as NSString).lastPathComponent
                _ = try writeGuard.linkStackListFile(sourceRelative: path, destDirRelative: lightsDestDir)
                fileNames.append(fileName)
            }

            let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights")
            try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.dssfilelist", data: Data(dssContent.utf8))

            // R11-T17: cd's into the flat export's OWN lights/ subfolder, not
            // its parent stacklistDir -- Siril's `convert` reads only the
            // current working directory, and the hardlinked frames live in
            // lights/, exactly like the per-filter branch above already got
            // right. Before this fix the flat/single-filter script cd'd one
            // level too high and `convert` would find zero frames.
            let flatLightsDir = stacklistDir.appendingPathComponent("lights", isDirectory: true)
            let ssfContent = try renderSSF(framesDir: flatLightsDir, filterLabel: nil)
            try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.ssf", data: Data(ssfContent.utf8))
        }

        let manifestContent = renderManifestCSV(selection.manifest)
        try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/manifest.csv", data: Data(manifestContent.utf8))

        return stacklistDir
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
    @discardableResult
    public static func exportToDirectory(_ selection: StackSelection, destDir: URL, sourceRoot: URL) throws -> URL {
        let fm = FileManager.default

        if let perFilter = selection.perFilter, !perFilter.isEmpty {
            for filterSelection in perFilter {
                let filterSlug = Sanitizer.sanitize(filterSelection.filter)
                let lightsDir = destDir.appendingPathComponent("lights/\(filterSlug)", isDirectory: true)
                try fm.createDirectory(at: lightsDir, withIntermediateDirectories: true)

                var fileNames: [String] = []
                for path in filterSelection.selectedPaths {
                    let fileName = (path as NSString).lastPathComponent
                    fileNames.append(fileName)

                    let destFileURL = lightsDir.appendingPathComponent(fileName, isDirectory: false)
                    guard !fm.fileExists(atPath: destFileURL.path) else { continue }
                    let sourceURL = sourceRoot.appendingPathComponent(path)
                    try fm.linkItem(at: sourceURL, to: destFileURL)
                }

                let baseName = "\(slug(target: selection.target, date: selection.date))-\(filterSlug)"
                let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights/\(filterSlug)")
                try Data(dssContent.utf8).write(to: destDir.appendingPathComponent("\(baseName).dssfilelist"))

                let ssfContent = try renderSSF(framesDir: lightsDir, filterLabel: filterSelection.filter)
                try Data(ssfContent.utf8).write(to: destDir.appendingPathComponent("\(baseName).ssf"))
            }
        } else {
            let lightsDir = destDir.appendingPathComponent("lights", isDirectory: true)
            try fm.createDirectory(at: lightsDir, withIntermediateDirectories: true)

            var fileNames: [String] = []
            for path in selection.selectedPaths {
                let fileName = (path as NSString).lastPathComponent
                fileNames.append(fileName)

                let destFileURL = lightsDir.appendingPathComponent(fileName, isDirectory: false)
                guard !fm.fileExists(atPath: destFileURL.path) else { continue }
                let sourceURL = sourceRoot.appendingPathComponent(path)
                try fm.linkItem(at: sourceURL, to: destFileURL)
            }

            let dssContent = renderDSSFilelist(fileNames: fileNames, lightsRelativePath: "lights")
            try Data(dssContent.utf8).write(to: destDir.appendingPathComponent("stack.dssfilelist"))

            // R11-T17: same fix as `export` above -- cd into lights/ itself,
            // not destDir (its parent).
            let ssfContent = try renderSSF(framesDir: lightsDir, filterLabel: nil)
            try Data(ssfContent.utf8).write(to: destDir.appendingPathComponent("stack.ssf"))
        }

        let manifestContent = renderManifestCSV(selection.manifest)
        try Data(manifestContent.utf8).write(to: destDir.appendingPathComponent("manifest.csv"))

        return destDir
    }

    /// `<sanitized target>-<date>` -- the stacklist directory's own name
    /// under `.astro_tool/stacklists/`. Reuses `Sanitizer` (same convention
    /// `add_new_session.sh`/`SessionCreator` use for target folder names) so
    /// a target containing characters outside its allow-list still yields a
    /// safe path component; `WriteGuard.linkStackListFile`'s own component
    /// validation is the actual defense against a pathological result
    /// (e.g. a target that sanitizes down to `".."`), not this function.
    static func slug(target: String, date: String) -> String {
        "\(Sanitizer.sanitize(target))-\(date)"
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

    /// Renders `manifest.csv` -- see `StackManifestRow`'s own doc comment
    /// for what each row/column means. Header first, then one row per
    /// `rows` entry in its own order (grouped by filter, biggest bucket
    /// first, path-sorted within a filter -- `select()`'s own construction
    /// order).
    private static func renderManifestCSV(_ rows: [StackManifestRow]) -> String {
        var lines = ["file,filter,score,fwhm_px,session_date,verdict"]
        for row in rows {
            let fields = [
                row.file,
                row.filter,
                row.score.map { String(format: "%.2f", $0) } ?? "",
                row.fwhmPx.map { String(format: "%.2f", $0) } ?? "",
                row.sessionDate,
                row.verdict,
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
