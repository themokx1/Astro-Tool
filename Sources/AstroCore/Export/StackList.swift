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
    public var criteria: [String]
    /// Root-relative paths of every frame selected for stacking, sorted.
    public var selectedPaths: [String]
    /// Root-relative paths of every usable frame NOT selected (dropped by a
    /// hard rule, or cut by the keepFraction ranking), sorted.
    public var rejectedPaths: [String]

    public init(
        target: String,
        date: String,
        totalFrames: Int,
        selectedFrames: Int,
        criteria: [String],
        selectedPaths: [String],
        rejectedPaths: [String]
    ) {
        self.target = target
        self.date = date
        self.totalFrames = totalFrames
        self.selectedFrames = selectedFrames
        self.criteria = criteria
        self.selectedPaths = selectedPaths
        self.rejectedPaths = rejectedPaths
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
    public static func select(
        target: String,
        date: String,
        keepFraction: Double = 0.8,
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

        var criteria: [String] = ["használható (deduplikált, nem elvetett) light: \(totalFrames)"]

        struct Entry {
            let file: FileRecord
            let score: Double?
        }

        var entries: [Entry] = []
        var verdictDropped: [FileRecord] = []
        var outlierDropped: [FileRecord] = []

        for file in usable {
            guard let id = file.id else {
                entries.append(Entry(file: file, score: nil))
                continue
            }
            if let verdict = try db.userVerdict(fileID: id), verdict.accepted == false {
                verdictDropped.append(file)
                continue
            }
            let score = try db.rating(fileID: id)?.score
            if let score, score < -config.rating.outlierZScore {
                outlierDropped.append(file)
                continue
            }
            entries.append(Entry(file: file, score: score))
        }

        if !verdictDropped.isEmpty {
            criteria.append("DSS-ben elvetett: \(verdictDropped.count)")
        }
        if !outlierDropped.isEmpty {
            criteria.append("kiugróan gyenge: \(outlierDropped.count)")
        }

        let scoredEntries = entries.filter { $0.score != nil }.sorted { $0.score! > $1.score! }
        let unscoredEntries = entries.filter { $0.score == nil }

        if !unscoredEntries.isEmpty {
            criteria.append("nem pontozott: \(unscoredEntries.count) — megtartva")
        }

        let remainingCount = entries.count
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

        let selectedFiles = (unscoredEntries + selectedScored).map(\.file)
        let rejectedFiles = verdictDropped + outlierDropped + rejectedScored.map(\.file)

        let selectedPaths = selectedFiles.map(\.path).sorted()
        let rejectedPaths = rejectedFiles.map(\.path).sorted()

        return StackSelection(
            target: target,
            date: date,
            totalFrames: totalFrames,
            selectedFrames: selectedPaths.count,
            criteria: criteria,
            selectedPaths: selectedPaths,
            rejectedPaths: rejectedPaths
        )
    }

    private static func formattedPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Export

    /// Materializes `selection` on disk: hardlinks every `selectedPaths`
    /// frame into `.astro_tool/stacklists/<target>-<date>/lights/` (via
    /// `WriteGuard.linkStackListFile` -- additive, never overwrites), then
    /// writes a `.dssfilelist` and a `.ssf` Siril script alongside it (via
    /// `WriteGuard.writeToolFile` -- freely overwritable, it's the tool's
    /// own state, not the user's library). Returns the stacklist directory.
    ///
    /// Idempotent: re-running `export` with the same (or an updated)
    /// selection never disturbs an already-linked frame -- `linkStackListFile`
    /// skips any destination that already exists -- and always rewrites the
    /// `.dssfilelist`/`.ssf` text files to match the current selection.
    @discardableResult
    public static func export(_ selection: StackSelection, root: URL, using writeGuard: WriteGuard) throws -> URL {
        let slug = slug(target: selection.target, date: selection.date)
        let stacklistDir = root
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("stacklists/\(slug)", isDirectory: true)
        let lightsDestDir = ".astro_tool/stacklists/\(slug)/lights"

        var fileNames: [String] = []
        for path in selection.selectedPaths {
            let fileName = (path as NSString).lastPathComponent
            _ = try writeGuard.linkStackListFile(sourceRelative: path, destDirRelative: lightsDestDir)
            fileNames.append(fileName)
        }

        let dssContent = renderDSSFilelist(fileNames: fileNames)
        try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.dssfilelist", data: Data(dssContent.utf8))

        let ssfContent = try renderSSF(stacklistDir: stacklistDir)
        try writeGuard.writeToolFile(relativePath: "stacklists/\(slug)/stack.ssf", data: Data(ssfContent.utf8))

        return stacklistDir
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
    /// location (`lights/<name>`, resolving through the hardlinks this same
    /// export just created). Rejected frames are deliberately NOT listed as
    /// `CHECKED == 0` rows: unlike DSS's own native file list (which sits
    /// next to every frame it knows about, selected or not), this export
    /// only ever materializes the selected subset on disk -- a rejected
    /// frame has no path relative to this directory to write in the first
    /// place, and listing one that doesn't resolve would be worse than
    /// omitting it.
    ///
    /// Line endings: plain `\n`. The one real `.dssfilelist` sample this was
    /// verified against had no `\r`; there's no evidence DSS requires CRLF
    /// specifically (it's cross-platform, C++/wxWidgets), so this doesn't
    /// manufacture one.
    private static func renderDSSFilelist(fileNames: [String]) -> String {
        var lines = ["DSS file list", "CHECKED\tTYPE\tFILE"]
        for name in fileNames {
            lines.append("1\tlight\tlights/\(name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - .ssf

    /// A minimal, reviewable Siril script over the stacklist directory's own
    /// `lights/` folder: `convert` (raw -> Siril's working format),
    /// `register` (star alignment), then a single rejection-stack. This is
    /// deliberately NOT a "run everything end to end" pipeline -- it has no
    /// calibration step at all (Siril 1.4's `calibrate` needs master paths
    /// this type has no way to know are still valid/current), so the
    /// generated comment header tells the user to insert their own
    /// `calibrate`/`calibrate_single` line(s) first if this session needs
    /// them. Never contains a destructive command (no `rm`, no overwriting
    /// redirect) -- same "generated for a human to read before running"
    /// stance as `SuggestionScript`.
    ///
    /// `stacklistDir`'s path is interpolated into a quoted `cd "..."` line;
    /// same injection guard `SirilCLI.buildScript` uses (a path containing
    /// `"` or `\` is rejected outright rather than guessing at escaping
    /// rules Siril's script grammar may or may not support).
    private static func renderSSF(stacklistDir: URL) throws -> String {
        let path = stacklistDir.path
        guard !containsSirilScriptInjectionRisk(path) else {
            throw AstroError.invalidInput("stacklist dir path unsafe for a Siril script: \(path)")
        }

        let lines = [
            "# Generated by astrotool -- review before running (siril-cli -s stack.ssf,",
            "# or open in the Siril app and run manually).",
            "#",
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
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
