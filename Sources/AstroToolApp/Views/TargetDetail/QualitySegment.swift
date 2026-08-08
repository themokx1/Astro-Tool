import AppKit
import AstroCore
import Charts
import SwiftUI

/// R9-T3/A.3's "Minőség" segment: the same frame `Table` `QualityView` used
/// to show (originally 10 columns, unchanged as of that task), but with the
/// control bar rebuilt per spec -- a single primary "Keretek pontozása"
/// button with a Menu-chevron for `--force`/`--no-siril`, a session-date
/// `Menu` instead of a free-text date field, and a 10-bucket score histogram
/// above the table. R10-B1 later added an 11th column ("Saját döntés") plus
/// the "Átnézés…" blink-review sheet -- see `frameTable`'s own doc comment
/// for how an 11th column fits `Table`'s 10-slot column-builder limit.
struct QualitySegment: View {
    @Environment(AppState.self) private var appState
    let target: String

    /// `nil` means "Minden session" (the Menu's own first item) -- mirrors
    /// the old free-text field's "empty means all sessions" convention.
    @State private var selectedDate: String?
    @State private var sortOrder = [KeyPathComparator(\Row.score, order: .reverse)]
    /// Drives the "Átnézés…" (blink review) sheet -- R10-B1. R11-T7 widened
    /// this from always-`rows.map(\.frameScore)` to a caller-chosen subset
    /// (`reviewFrames`) -- the whole table's "Átnézés…" button, the ⚠️
    /// popover's own "Átnézés" (this ONE frame), and the "Kiugrók átnézése
    /// (N)" control-bar button (every still-undecided outlier) all open the
    /// SAME sheet, just with a different `frames`/`subsetLabel` pair --
    /// see `openReview(for:label:)`.
    @State private var showingReview = false
    @State private var reviewFrames: [FrameScore] = []
    /// `nil` for the whole-table review (the sheet's header then shows a
    /// bare "3 / 7"); a Hungarian label like `"Kiugrók"` for a narrowed
    /// subset, so the sheet's header instead reads "Kiugrók: 3 / 7" -- F4
    /// spec's "látszódjon, hogy szűkített készletet nézel" requirement.
    @State private var reviewSubsetLabel: String?
    /// Drives the "Összes kiugró elvetésre jelölése… (N)" confirm sheet --
    /// R11-T7 (F4, item 4).
    @State private var showingBatchReject = false
    /// R10 review (item 5): row-scoped selection for `frameTable`'s
    /// `.contextMenu(forSelectionType:)` -- previously the context menu was
    /// attached to just the "Fájl" cell's own `HStack`, so right-clicking or
    /// double-clicking anywhere else in a row did nothing.
    @State private var selectedFrame: Row.ID?
    /// R12-U2 (point 5): the session currently shown in `StackListSheet` --
    /// `nil` when the sheet is closed. Set directly from the control bar's
    /// "Stackelés előkészítése…" button (using `selectedDate` when one's
    /// picked) or, for "Minden session", via its own session-picker `Menu`
    /// (`StacksSegment`'s own equivalent button, same pattern).
    @State private var stackListingSession: LinkingSession?

    /// R11-T1: Minőség-tábla oszlop-választó + szűkített alapkészlet. This
    /// app's deployment target (macOS 14) predates
    /// `.tableColumnCustomization(_:)`/`TableColumnCustomization` (macOS
    /// 15+), so this is the documented fallback: a plain `@AppStorage`-backed
    /// hidden-column `Set` (persisted as a comma-joined `String`, since
    /// `@AppStorage` has no direct `Set<String>` support) plus conditionally
    /// included `TableColumn`s below, with a control-bar "Oszlopok" `Menu`
    /// (toggle switches, see `columnsMenu`) as the ONE discoverability path
    /// -- there's no native right-click-header customization sheet to also
    /// offer here. Defaults to all six secondary columns hidden (spec:
    /// "alapból ennyi látszódjon: Fájl, Pontszám, FWHM, Kiugró, Saját
    /// döntés").
    private enum QualityColumn: String, CaseIterable {
        case folder, roundness, starCount, background, saturatedFraction, exptime

        var title: String {
            switch self {
            case .folder: return "Mappa"
            case .roundness: return "Kerekség"
            case .starCount: return "Csillagok"
            case .background: return "Háttér"
            case .saturatedFraction: return "Szat. %"
            case .exptime: return "Exp."
            }
        }
    }

    @AppStorage("qualityTable.hiddenColumns") private var hiddenColumnsRaw: String =
        QualityColumn.allCases.map(\.rawValue).joined(separator: ",")

    private var hiddenColumns: Set<String> {
        Set(hiddenColumnsRaw.split(separator: ",").map(String.init))
    }

    private func isVisible(_ column: QualityColumn) -> Bool { !hiddenColumns.contains(column.rawValue) }

    private func setVisible(_ column: QualityColumn, _ visible: Bool) {
        var set = hiddenColumns
        if visible { set.remove(column.rawValue) } else { set.insert(column.rawValue) }
        hiddenColumnsRaw = QualityColumn.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
    }

    /// Flattened, display-ready view of a `FrameScore` -- ported verbatim
    /// from the deleted `QualityView.Row`. `fileprivate` (not `private`) so
    /// the R11-T7 sibling views below (`OutlierCell`/`OutlierPopoverContent`/
    /// `BatchRejectOutliersConfirmSheet`), which live in this same file but
    /// aren't nested inside `QualitySegment` itself (they each need their
    /// OWN `@State`, which a plain cell-building function can't hold), can
    /// still read it.
    fileprivate struct Row: Identifiable {
        let id = UUID()
        /// Kept around (not just flattened into the fields below) so
        /// `FrameReviewSheet` can be handed the table's current sort/filter
        /// order by simply mapping `rows` back to `FrameScore` -- R10-B1.
        let frameScore: FrameScore
        let path: String
        let fileName: String
        let sessionSubdir: String?
        let score: Double
        let fwhm: Double?
        let roundness: Double?
        let starCount: Int?
        let background: Double?
        let saturatedFraction: Double?
        let exptime: Double?
        let isOutlier: Bool
        /// The user's own manual verdict for this frame (R10-B1) -- `nil`
        /// means no verdict recorded at all, from either this app or a past
        /// DSS import; `AppState.frameVerdicts` is the single source both
        /// this column and `FrameReviewSheet` read from.
        let verdict: Bool?
        /// R11-T7 (F4): per-metric z-score breakdown -- `Rater.score`/
        /// `Rater.cachedScores` (AstroCore) both populate `FrameScore
        /// .outlierBreakdown` directly, so this is just carried through
        /// unchanged, never recomputed in the app layer. `nil` for a frame
        /// with no metric values at all (extremely rare -- background alone
        /// is present for nearly every rated frame).
        let breakdown: OutlierBreakdown?

        init(_ frameScore: FrameScore, verdict: Bool?) {
            self.frameScore = frameScore
            path = frameScore.path
            fileName = frameScore.fileName
            sessionSubdir = frameScore.sessionSubdir
            score = frameScore.score
            fwhm = frameScore.metrics?.fwhm
            roundness = frameScore.metrics?.roundness
            starCount = frameScore.metrics?.starCount
            background = frameScore.background
            saturatedFraction = frameScore.saturatedFraction
            exptime = frameScore.exptime
            isOutlier = frameScore.isOutlier
            self.verdict = verdict
            breakdown = frameScore.outlierBreakdown
        }

        var sessionSubdirSortKey: String { sessionSubdir ?? "" }
        var fwhmSortKey: Double { fwhm ?? -.infinity }
        var roundnessSortKey: Double { roundness ?? -.infinity }
        var starCountSortKey: Int { starCount ?? .min }
        var backgroundSortKey: Double { background ?? -.infinity }
        var saturatedFractionSortKey: Double { saturatedFraction ?? -.infinity }
        var exptimeSortKey: Double { exptime ?? -.infinity }
    }

    private var sessionDates: [String] { appState.stats.first { $0.target == target }?.sessionDates ?? [] }
    private var rows: [Row] {
        filteredFrameScores
            .map { Row($0, verdict: appState.frameVerdicts[$0.path]) }
            .sorted(using: sortOrder)
    }
    private var sirilAvailable: Bool { FileManager.default.isExecutableFile(atPath: appState.config.rating.sirilPath) }

    /// R11-T7 (F4, items 3-4): outlier frames with NO manual verdict yet,
    /// in the table's current sort/filter order -- both the "Kiugrók
    /// átnézése (N)" review button and the "Összes kiugró elvetésre
    /// jelölése… (N)" batch action work over exactly this set, so their
    /// counts (and the batch sheet's own listing) can never disagree with
    /// each other. A frame already accepted OR rejected is excluded either
    /// way: reviewing/re-rejecting an already-judged frame isn't this
    /// feature's job.
    private var undecidedOutlierRows: [Row] {
        rows.filter { $0.isOutlier && $0.verdict == nil }
    }

    /// Opens the "Átnézés" (blink review) sheet over exactly `frames`, in
    /// the order given -- shared by the control bar's whole-table button,
    /// the "Kiugrók átnézése (N)" subset button, and the ⚠️ popover's own
    /// per-frame "Átnézés" (R11-T7).
    private func openReview(frames: [FrameScore], label: String?) {
        reviewFrames = frames
        reviewSubsetLabel = label
        showingReview = true
    }

    /// R10-A5: `selectedDate` used to only ever affect the NEXT "Keretek
    /// pontozása"/`loadFrameScores` call -- picking a date from the Menu
    /// visibly did nothing until the user re-ran one of those. `nil`
    /// ("Minden session") is a pass-through; otherwise every row whose
    /// path's date component doesn't match is dropped, client-side, with no
    /// extra DB round-trip -- `rows`/`histogram`/`summaryText` all read this
    /// instead of `appState.frameScores` directly, so the whole segment
    /// (table, histogram, and the "N frame · kiugró: …" line) reflects the
    /// filtered set.
    private var filteredFrameScores: [FrameScore] {
        guard let selectedDate else { return appState.frameScores }
        return appState.frameScores.filter { Self.sessionDate(ofPath: $0.path) == selectedDate }
    }

    /// The `<date>` component of a `sessions/<target>/<date>/…` path -- the
    /// same positional convention `Rater.sessionSubdir(path:)` (AstroCore,
    /// package-internal) reads ITS OWN result from, one component earlier.
    /// `FrameScore` doesn't carry a `sessionDate` field the way `TrackedFile`
    /// does, only the full `path`, so `filteredFrameScores` has to re-derive
    /// it the same positional way. Every row this table ever shows is
    /// `area == .sessions, role == .light` (`Rater.rate`'s own frame
    /// filter), so the layout is always `sessions/<target>/<date>/…` --
    /// never the differently-shaped `calibration_library/…`.
    private static func sessionDate(ofPath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return nil }
        return String(components[2])
    }

    private var summaryText: String? {
        guard !filteredFrameScores.isEmpty else { return nil }
        let total = filteredFrameScores.count
        let outliers = filteredFrameScores.count { $0.isOutlier }
        let withMetrics = filteredFrameScores.count { $0.metrics != nil }
        var text = "\(total) frame · kiugró: \(outliers) · Siril metrika: \(withMetrics)/\(total)"
        if withMetrics == 0 && sirilAvailable {
            text += " (a Siril nem adott metrikát — ellenőrizd a Siril útvonalat a Beállításokban)"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlBar

            if !sirilAvailable {
                HStack(spacing: 6) {
                    Text("Siril nem található — csak natív statisztika")
                        .font(.callout).foregroundStyle(.secondary)
                    // R11-T3/F11(c): same `SirilHelpSheet`, reached via the
                    // same notification `MetricInfoButton`'s "Fogalomtár…"
                    // footer link already posts (`RootView` owns the sheet).
                    Button("Mi ez?") {
                        NotificationCenter.default.post(name: .showSirilHelp, object: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline()
                }
            }
            if let summaryText {
                Text(summaryText).font(.callout).foregroundStyle(.secondary)
            }

            if filteredFrameScores.isEmpty {
                if appState.frameScores.isEmpty {
                    ContentUnavailableView(
                        "Nincsenek pontozott keretek",
                        systemImage: "star",
                        description: Text("Futtass pontozást a FWHM / kerekség / csillagszám metrikákhoz.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // R10-A5: OTHER sessions have rated frames, just not the
                    // one currently selected in the date Menu -- honest n/a
                    // per the project's own convention, rather than the
                    // blanket "nothing is rated at all" message above.
                    ContentUnavailableView(
                        "Nincs pontozott keret ehhez a sessionhöz",
                        systemImage: "star",
                        description: Text("Válassz másik sessiont a menüből, vagy futtasd a pontozást ehhez a sessionhöz.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                histogram
                if showsFWHMOverNightCard {
                    fwhmOverNightCard
                } else {
                    fwhmOverNightPlaceholderCard
                }
                frameTable
            }
        }
        .padding()
        .onAppear {
            // R9-D8/f: `AllTargetsPage`'s session row "Keretek pontozása"
            // preselects this segment's date filter before navigating here
            // -- consumed once, same "set, navigate, consume on appear"
            // pattern `SessionsSegment.consumePendingSelection` uses for
            // `pendingSessionSelection`.
            if let pendingDate = appState.pendingQualityDate {
                selectedDate = pendingDate
                appState.pendingQualityDate = nil
            }
            // R9-D6: `frameScores` previously only ever got populated as a
            // side effect of pressing "Keretek pontozása" -- opening this
            // segment for a target rated in a past session showed the false
            // "Nincsenek pontozott keretek" empty state until the user
            // re-rated. `loadFrameScores` rebuilds it from the persisted
            // `ratings` rows instead, without touching Siril/the filesystem.
            if appState.frameScores.isEmpty {
                appState.loadFrameScores(target: target, date: selectedDate)
            }
        }
        .sheet(isPresented: $showingReview) {
            // R11-T7: `reviewFrames`/`reviewSubsetLabel` are set by
            // `openReview(frames:label:)`, called from three places -- the
            // control bar's whole-table "Átnézés…" (the table's CURRENT
            // sort/filter order, same as before R11-T7), the "Kiugrók
            // átnézése (N)" subset button, and the ⚠️ popover's own
            // per-frame "Átnézés".
            FrameReviewSheet(frames: reviewFrames, subsetLabel: reviewSubsetLabel)
        }
        .sheet(isPresented: $showingBatchReject) {
            BatchRejectOutliersConfirmSheet(rows: undecidedOutlierRows)
        }
        // R12-U2 (point 5): same row-scoped `.sheet(item:)` pattern
        // `StacksSegment`/`AllTargetsPage`/`NightsPage` already use for
        // `StackListSheet`.
        .sheet(item: $stackListingSession) { session in
            StackListSheet(target: session.target, date: session.date)
        }
    }

    // MARK: - Control bar (rebuilt per A.3)

    private var controlBar: some View {
        HStack {
            Menu {
                // R9-D5: previously the only way to get here was already
                // being here -- once a specific date was picked, there was
                // no menu item to get back to "Minden session" short of
                // reopening the segment.
                //
                // R10-A5: `filteredFrameScores` (read by `rows`/`histogram`/
                // `summaryText`) client-side filters whatever's ALREADY in
                // `appState.frameScores` -- normally enough on its own, with
                // no extra DB round-trip. But if nothing's been loaded at
                // all yet (`frameScores.isEmpty`, e.g. the same session-was-
                // rated-in-a-past-run case `loadFrameScores`'s own doc
                // comment/R9-D6 describes, just triggered from here instead
                // of `onAppear`), there's nothing to filter -- so fall back
                // to the same on-demand load `onAppear` already does.
                Button("Minden session") {
                    selectedDate = nil
                    if appState.frameScores.isEmpty {
                        appState.loadFrameScores(target: target, date: nil)
                    }
                }
                Divider()
                ForEach(sessionDates, id: \.self) { date in
                    Button(date) {
                        selectedDate = date
                        if appState.frameScores.isEmpty {
                            appState.loadFrameScores(target: target, date: date)
                        }
                    }
                }
            } label: {
                Text(selectedDate ?? "Minden session")
            }
            .frame(width: 200)

            Menu {
                Button("Újra minden keret mérése (lassú)") {
                    appState.runRate(target: target, date: selectedDate, force: true)
                }
                Button("Siril nélkül (csak natív)") {
                    appState.runRate(target: target, date: selectedDate, noSiril: true)
                }
            } label: {
                Text("Keretek pontozása")
            } primaryAction: {
                appState.runRate(target: target, date: selectedDate)
            }
            .disabled(appState.isBusy)
            .fixedSize()

            // R10-B1: opens the "Átnézés" (blink review) sheet over exactly
            // the frames currently shown below (date filter + sort already
            // applied) -- disabled rather than hidden when there's nothing
            // to review, same convention every other conditionally-useless
            // control bar button in this app already follows.
            Button("Átnézés…") { openReview(frames: rows.map(\.frameScore), label: nil) }
                .disabled(filteredFrameScores.isEmpty)
                .help(
                    filteredFrameScores.isEmpty
                        ? "Nincs megjeleníthető keret"
                        : "Keretek egyenkénti átnézése, elfogadása/elvetése"
                )

            // R11-T7 (F4, item 3): scoped to exactly the still-undecided
            // outliers, in the table's current order -- hidden entirely
            // (not just disabled) when there are none, since "review 0
            // outliers" isn't a meaningful action to offer at all.
            if !undecidedOutlierRows.isEmpty {
                Button("Kiugrók átnézése (\(undecidedOutlierRows.count))") {
                    openReview(frames: undecidedOutlierRows.map(\.frameScore), label: "Kiugrók")
                }
                .help("A még el nem bírált kiugró keretek egyenkénti átnézése")

                // R11-T7 (F4, item 4): batch reject-marking, gated behind its
                // own confirm sheet -- never writes anything directly from
                // this button.
                Button("Összes kiugró elvetésre jelölése… (\(undecidedOutlierRows.count))") {
                    showingBatchReject = true
                }
            }

            stackPrepButton

            MetricInfoButton(metrics: Self.frameMetricInfo)

            columnsMenu

            Spacer()

            if appState.isBusy {
                ProgressView().controlSize(.small)
                Text(appState.progressText).foregroundStyle(.secondary)
                Button("Mégse") { appState.cancelCurrentOperation() }
            }
        }
    }

    /// R12-U2 (point 5): "Stackelés előkészítése…" -- opens `StackListSheet`
    /// straight for `selectedDate` when a specific session is picked in the
    /// date `Menu` above; when it's "Minden session" (`nil`), there's no
    /// single obvious session to default to, so this shows its OWN picker
    /// `Menu` instead, same pattern `StacksSegment.stackPrepButton` already
    /// uses for its own (count-based, not selection-based) version of this
    /// same choice. Hidden entirely when the target has no sessions at all.
    @ViewBuilder
    private var stackPrepButton: some View {
        if let date = selectedDate {
            Button("Stackelés előkészítése…") {
                stackListingSession = LinkingSession(target: target, date: date)
            }
        } else if sessionDates.count == 1, let onlyDate = sessionDates.first {
            Button("Stackelés előkészítése…") {
                stackListingSession = LinkingSession(target: target, date: onlyDate)
            }
        } else if !sessionDates.isEmpty {
            Menu("Stackelés előkészítése…") {
                ForEach(sessionDates, id: \.self) { date in
                    Button(date) { stackListingSession = LinkingSession(target: target, date: date) }
                }
            }
        }
    }

    /// R11-T1: the ONE discoverability path for `frameTable`'s hidden
    /// secondary columns -- see `QualityColumn`'s own doc comment for why
    /// this exists instead of (or alongside) a header right-click, given
    /// this app's deployment target.
    private var columnsMenu: some View {
        Menu("Oszlopok") {
            ForEach(QualityColumn.allCases, id: \.self) { column in
                Toggle(column.title, isOn: Binding(
                    get: { isVisible(column) },
                    set: { setVisible(column, $0) }
                ))
            }
        }
    }

    /// R9-T6/B16(a): the frame table's computed-metric columns, explained.
    private static let frameMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Pontszám",
            explanation: "A kerekség, FWHM, csillagszám és háttér súlyozott kombinációja (Beállítások ▸ Pontozás & expozíció ▸ súlyok). Nagyobb = jobb. Mikor hazudik: kevés csillagnál (szűk mezős vagy felhős keret) a bemenő metrikák zajosak, a pontszám megbízhatatlan."
        ),
        .init(
            title: "FWHM (px)",
            explanation: "Csillagok félértékszélessége pixelben -- a fókusz élességének mérőszáma, kisebb = élesebb. Mikor hazudik: „Siril nélkül” méréskor ez mindig „-”, natív statisztika nem ad FWHM-et.",
            glossaryTerm: "FWHM"
        ),
        .init(
            title: "Háttér",
            explanation: "Az égi háttér nyers ADU-szintje a keret medián pixelértékéből. Mikor hazudik: mért szenzor-profil nélkül (Szenzor-profilok oldal) ez csak nyers ADU, nem valódi e⁻/s/″² -- két különböző gain/setup között nem összehasonlítható.",
            glossaryTerm: "ADU"
        ),
        .init(
            title: "Szat. %",
            explanation: "A keret pixeleinek hány százaléka éri el a szenzor telítési szintjét (túlexponált csillagmagok, fényszennyezés). Mikor hazudik: a telítési küszöb becsült, nem a szenzor tényleges bit-mélységéből mért."
        ),
        .init(
            title: "Saját döntés",
            explanation: "A felhasználó saját elfogadás/elvetés döntése (Átnézés ablak, vagy a sor helyi menüje). Stackelésnél ELSŐBBSÉGET kap a pontszámmal szemben: egy elvetett keret a legjobb pontszám mellett is kimarad a stacklistből. A DeepSkyStacker .dssfilelist-jéből importált döntések (DSS-adatok beolvasása) is itt jelennek meg, forrástól függetlenül. Mikor hazudik: ez nem mérőszám, hanem az Ön saját szeme -- pontosságát semmi nem ellenőrzi."
        ),
    ]

    // MARK: - Score histogram

    /// 10 equal-width buckets spanning the currently loaded scores' own
    /// [min, max] range -- a quick "which frames are bad" visual without
    /// needing to sort the table by score first. Hidden (via the caller's
    /// `if filteredFrameScores.isEmpty` guard) rather than shown empty.
    private var histogram: some View {
        let scores = filteredFrameScores.map(\.score)
        let minScore = scores.min() ?? 0
        let maxScore = scores.max() ?? 1
        let span = max(maxScore - minScore, 0.0001)
        let bucketCount = 10
        var buckets = [Int](repeating: 0, count: bucketCount)
        for score in scores {
            let fraction = (score - minScore) / span
            let index = min(bucketCount - 1, max(0, Int(fraction * Double(bucketCount))))
            buckets[index] += 1
        }
        let maxCount = max(buckets.max() ?? 1, 1)

        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<bucketCount, id: \.self) { index in
                let count = buckets[index]
                let lowerBound = minScore + span * Double(index) / Double(bucketCount)
                let upperBound = minScore + span * Double(index + 1) / Double(bucketCount)
                VStack(spacing: 2) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(height: max(2, 40 * CGFloat(count) / CGFloat(maxCount)))
                }
                .frame(width: 20)
                .help("\(String(format: "%.2f", lowerBound))–\(String(format: "%.2f", upperBound)): \(count) keret")
            }
        }
        .frame(height: 44)
        .padding(.vertical, 4)
    }

    // MARK: - FWHM over the night (R10-B5)

    /// One rated frame's capture instant + FWHM, for the "when did the
    /// night go bad" trend card -- `Identifiable` so `ForEach` inside the
    /// `Chart` doesn't need `frame.path` (a `FrameScore` field this struct
    /// deliberately doesn't carry, keeping it a minimal plot-only value).
    private struct FWHMPoint: Identifiable {
        let id = UUID()
        let time: Date
        let fwhm: Double
        let isOutlier: Bool
    }

    /// `[]` whenever `selectedDate` is "Minden session" (`nil`) -- pooling
    /// frames from different nights on one time-of-night axis has nothing
    /// coherent to say, per the card's own gating rule. Otherwise, every
    /// frame in `filteredFrameScores` (already scoped to `selectedDate`)
    /// that has BOTH a Siril-measured FWHM and a parseable `DATE-OBS`,
    /// sorted ascending by capture time. `SessionTimeline.parseDateObs` is
    /// the exact same shared FITS/EXIF timestamp parser `NightHealth`'s own
    /// focus-drift regression parses `DATE-OBS` with -- promoted `public`
    /// (R10-B5) for this cross-module reuse rather than duplicated here.
    private var fwhmOverNightPoints: [FWHMPoint] {
        guard selectedDate != nil else { return [] }
        return filteredFrameScores
            .compactMap { score -> FWHMPoint? in
                guard let fwhm = score.metrics?.fwhm,
                      let rawDateObs = score.dateObs,
                      let time = SessionTimeline.parseDateObs(rawDateObs)
                else { return nil }
                return FWHMPoint(time: time, fwhm: fwhm, isOutlier: score.isOutlier)
            }
            .sorted { $0.time < $1.time }
    }

    /// Same "don't trust a handful of points" floor `NightHealth`'s own
    /// `minRatedFramesForFocus` uses for its regression (`NightHealth.swift`)
    /// -- reused here as the card's own show/hide gate rather than showing a
    /// noisy 2-3 point scatter with nothing to say.
    private static let minFWHMPointsForTrend = 5

    private var showsFWHMOverNightCard: Bool {
        selectedDate != nil && fwhmOverNightPoints.count >= Self.minFWHMPointsForTrend
    }

    /// R10 review (item 14): explains why `fwhmOverNightCard` isn't there
    /// instead of silently showing nothing -- same "honest n/a" stance
    /// `notAvailableReason` embodies elsewhere in this app. Two distinct
    /// reasons map to `showsFWHMOverNightCard`'s two ways of being `false`:
    /// "Minden session" pools frames across different nights, which has
    /// nothing coherent to trend on one time-of-night axis (see
    /// `fwhmOverNightPoints`'s own doc comment); a specific session just
    /// hasn't got `minFWHMPointsForTrend` scored frames yet.
    private var fwhmOverNightPlaceholderCard: some View {
        let text = selectedDate == nil
            ? "Válassz egy konkrét sessiont az éjszakán belüli FWHM-trendhez."
            : "Túl kevés pontozott keret a trendhez ennél a sessionnél."
        return Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// This session's `NightHealth` focus-drift report, if `AppState`
    /// loaded one for it (`AppState.loadTargetDetail` populates
    /// `targetNightHealthByDate` for every session date up front).
    private var focusHealth: FocusHealth? {
        guard let selectedDate else { return nil }
        return appState.targetNightHealthByDate[selectedDate]?.focus
    }

    /// The regression's slope, ONLY when its unit is already pixels.
    ///
    /// `FrameScore.metrics.fwhm` (this chart's Y axis) is always in pixels
    /// -- `SessionQuality` is what converts FWHM to arcseconds elsewhere in
    /// this app, using each frame's own pixel scale, and this chart
    /// deliberately doesn't: the point of "FWHM over the night" is
    /// consistency WITHIN one session's own frames, which pixels already
    /// give for free. `NightHealth.FocusHealth.slopeUnit` is `"arcsec/h"`
    /// whenever the session's frames carry a derivable pixel scale
    /// (`xpixsz`+`focallen` both present) and `"px/h"` otherwise -- drawing
    /// an arcsec/h slope against a pixel Y-axis would silently mix units,
    /// so the regression line is simply OMITTED in that case rather than
    /// drawn wrong. `FocusHealth` has no "always give me the px/h slope
    /// too" escape hatch (once converted, the pre-conversion pixel slope
    /// isn't retained), and re-deriving the session's own pixel scale here
    /// just to convert back would duplicate `NightHealth`'s internal logic
    /// for one trend line -- out of scope for this chart.
    private var focusSlopePxPerHour: Double? {
        guard let focusHealth, focusHealth.slopeUnit == "px/h" else { return nil }
        return focusHealth.slopePerHour
    }

    /// The regression line's two plot endpoints, `(time, fwhm-px)` each --
    /// `nil` whenever there's no unit-matching slope (`focusSlopePxPerHour`)
    /// or fewer than 2 plotted points to anchor a line between.
    ///
    /// `FocusHealth` stores the regression's SLOPE and total drift, but not
    /// its y-intercept. An ordinary-least-squares line always passes
    /// through its own sample's mean point `(t̄, ȳ)`, so `ȳ - slope·t̄`
    /// reconstructs that same line's intercept -- computed here from THIS
    /// card's own `fwhmOverNightPoints` (hours elapsed since the first
    /// plotted frame), which is the same "rated frame with both FWHM and a
    /// parseable DATE-OBS" universe `NightHealth.focusHealth` regresses
    /// over for this session, modulo that function's own dedup pass (a
    /// user's hand-triaged duplicate/derivative frame under a `Reject/`-like
    /// subfolder) -- close enough for a visual trend line, not claimed to
    /// be bit-exact. Keeping the SLOPE itself sourced from `FocusHealth`
    /// (rather than refitting it too from this card's possibly slightly
    /// different point set) is what keeps this line's rate-of-change
    /// consistent with the actual "fókuszcsúszás gyanú" verdict text shown
    /// elsewhere for this same session.
    private var focusRegressionEndpoints: (start: (time: Date, fwhm: Double), end: (time: Date, fwhm: Double))? {
        guard let slope = focusSlopePxPerHour,
              fwhmOverNightPoints.count >= 2,
              let t0 = fwhmOverNightPoints.first?.time,
              let tN = fwhmOverNightPoints.last?.time
        else { return nil }

        let hoursSinceStart = fwhmOverNightPoints.map { $0.time.timeIntervalSince(t0) / 3600.0 }
        let meanHours = hoursSinceStart.reduce(0, +) / Double(hoursSinceStart.count)
        let meanFWHM = fwhmOverNightPoints.reduce(0.0) { $0 + $1.fwhm } / Double(fwhmOverNightPoints.count)
        let intercept = meanFWHM - slope * meanHours

        let totalHours = tN.timeIntervalSince(t0) / 3600.0
        return ((t0, intercept), (tN, intercept + slope * totalHours))
    }

    private var fwhmOverNightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FWHM az éjszaka folyamán").font(.subheadline.bold())

            Chart {
                fwhmPointMarks
                focusRegressionLine
            }
            .chartLegend(.hidden)
            .chartYAxisLabel("FWHM (px)")
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.secondary)
                    AxisTick()
                    if let date = value.as(Date.self) {
                        AxisValueLabel(Self.timeOfNightFormatter.string(from: date))
                    }
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.secondary)
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .frame(height: 190)

            // Pixels, not arcsec (see `focusSlopePxPerHour`'s doc comment)
            // -- spelled out here since "FWHM (px)" alone on the axis is
            // easy to skim past.
            Text("Pixelben -- csak ezen a sessionön belül összevethető (nincs arcsec-konverzió).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    @ChartContentBuilder
    private var fwhmPointMarks: some ChartContent {
        ForEach(fwhmOverNightPoints) { point in
            PointMark(
                x: .value("Idő", point.time),
                y: .value("FWHM (px)", point.fwhm)
            )
            .foregroundStyle(point.isOutlier ? Color.red : Color.accentColor)
        }
    }

    @ChartContentBuilder
    private var focusRegressionLine: some ChartContent {
        if let endpoints = focusRegressionEndpoints {
            LineMark(
                x: .value("Idő", endpoints.start.time),
                y: .value("FWHM (px)", endpoints.start.fwhm)
            )
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))

            LineMark(
                x: .value("Idő", endpoints.end.time),
                y: .value("FWHM (px)", endpoints.end.fwhm)
            )
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
        }
    }

    /// `"20:15"` -- local time, same `en_US_POSIX`/`.current` convention as
    /// `SkyChartView.hourFormatter` (that one is `private` to that file).
    private static let timeOfNightFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Frame table (ported from the deleted QualityView; row-scoped
    // selection/context-menu added R10 review, item 5)

    private func tint(_ row: Row) -> Color { row.isOutlier ? .red : .primary }

    // MARK: - Secondary (hideable) column cells (R11-T1)

    @ViewBuilder
    private func folderCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.sessionSubdir)).lineLimit(1).foregroundColor(tint(row))
    }

    @ViewBuilder
    private func roundnessCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.roundness.map { String(format: "%.2f", $0) })).monospacedDigit().foregroundColor(tint(row))
    }

    @ViewBuilder
    private func starCountCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.starCount.map(String.init))).monospacedDigit().foregroundColor(tint(row))
    }

    @ViewBuilder
    private func backgroundCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.background.map { String(format: "%.0f", $0) })).monospacedDigit().foregroundColor(tint(row))
    }

    @ViewBuilder
    private func saturatedFractionCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.saturatedFraction.map { String(format: "%.2f", $0 * 100) })).monospacedDigit().foregroundColor(tint(row))
    }

    @ViewBuilder
    private func exptimeCell(_ row: Row) -> some View {
        Text(TDFormat.cell(row.exptime.map(Self.formatExptime))).monospacedDigit().foregroundColor(tint(row))
    }

    /// R11-T1: `TableColumnBuilder`'s conditional support (`buildIf`/
    /// `buildEither`, what `modernFrameTable`'s per-column `if isVisible(…)`
    /// below needs) is gated `@available(macOS 14.4, *)` in the SDK even
    /// though this package's own deployment target is macOS 14.0
    /// (`Package.swift`) -- routes to the column-picker-capable table when
    /// actually running 14.4+, else `legacyFrameTable`'s fixed, always-every-
    /// column layout (identical to this table before R11-T1) for the (by
    /// now vanishingly rare, macOS 14.4 shipped 2024-03) 14.0-14.3 window.
    @ViewBuilder
    private var frameTable: some View {
        if #available(macOS 14.4, *) {
            modernFrameTable
        } else {
            legacyFrameTable
        }
    }

    @available(macOS 14.4, *)
    private var modernFrameTable: some View {
        Table(rows, selection: $selectedFrame, sortOrder: $sortOrder) {
            // R9-T6/B7: the thumbnail rides along in the "Fájl" column
            // itself rather than as its own `TableColumn` -- `Table`'s
            // column-builder overloads top out at 10 top-level items.
            // R10-B1 added an 11th VISIBLE column ("Saját döntés") on top of
            // the 10 already here, and R11-T1 made "Mappa"/"Kerekség"/
            // "Csillagok"/"Háttér"/"Szat. %"/"Exp." individually hideable --
            // rather than costing one builder slot PER secondary column, all
            // six live inside ONE `Group { }` (a `TableColumnContent`
            // conformance meant exactly for this) with a per-column `if
            // isVisible(...)`, so the whole bundle costs the builder just 1
            // top-level slot no matter how many of the six are shown.
            TableColumn("Fájl", value: \.fileName) { row in
                HStack(spacing: 6) {
                    ThumbnailCell(url: fileURL(row), size: 22)
                    Text(row.fileName)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(tint(row))
                }
                .help(row.path)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Pontszám", value: \.score) { row in
                Text(String(format: "%.2f", row.score)).monospacedDigit().foregroundColor(tint(row))
            }
            .width(80)

            TableColumn("FWHM (px)", value: \.fwhmSortKey) { row in
                Text(TDFormat.cell(row.fwhm.map { String(format: "%.2f", $0) })).monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            // R11-T1: the six secondary/hideable columns -- see
            // `QualityColumn`'s own doc comment for the column-picker this
            // bundle is driven by. Default-hidden (spec: only Fájl/Pontszám/
            // FWHM/Kiugró/Saját döntés show out of the box). Each cell
            // routes through its own helper (`folderCell`/`roundnessCell`/…)
            // rather than inlining the `Text(...).modifier(...)` chain
            // directly in the column closure -- inlined, the type-checker
            // couldn't resolve six conditional columns in one `Group { }` in
            // reasonable time (same class of issue this table's other
            // `Group { }`s already worked around, per their own doc
            // comments); a plain function call is a cheap anchor either way.
            Group {
                if isVisible(.folder) {
                    TableColumn("Mappa", value: \Row.sessionSubdirSortKey) { row in folderCell(row) }
                        .width(min: 90, ideal: 140)
                }

                if isVisible(.roundness) {
                    TableColumn("Kerekség", value: \Row.roundnessSortKey) { row in roundnessCell(row) }
                        .width(70)
                }

                if isVisible(.starCount) {
                    TableColumn("Csillagok", value: \Row.starCountSortKey) { row in starCountCell(row) }
                        .width(70)
                }

                if isVisible(.background) {
                    TableColumn("Háttér", value: \Row.backgroundSortKey) { row in backgroundCell(row) }
                        .width(70)
                }

                if isVisible(.saturatedFraction) {
                    TableColumn("Szat. %", value: \Row.saturatedFractionSortKey) { row in saturatedFractionCell(row) }
                        .width(70)
                }

                if isVisible(.exptime) {
                    TableColumn("Exp.", value: \Row.exptimeSortKey) { row in exptimeCell(row) }
                        .width(60)
                }
            }

            outlierAndVerdictColumns
            actionColumn
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // R10 review (item 5): row-scoped context menu + double-click-to-
        // open, same pattern `TonightPage.planTable`/`AllTargetsPage
        // .statsTable`/`NightsPage.table`/`DiscoveryPage.table` all use --
        // replaces the old per-cell `.contextMenu` that only fired over the
        // "Fájl" cell's own `HStack`. The "⋯" column above stays as the
        // always-visible affordance hinting these actions exist at all.
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = row(withID: id) {
                frameContextMenuItems(row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = row(withID: id) {
                NSWorkspace.shared.open(fileURL(row))
            }
        }
    }

    /// R11-T1: pre-column-picker layout, unchanged from before it -- every
    /// column always shown, no toggle, `legacyFrameTable`'s own doc comment
    /// on `frameTable` explains why this still exists at all.
    private var legacyFrameTable: some View {
        Table(rows, selection: $selectedFrame, sortOrder: $sortOrder) {
            TableColumn("Fájl", value: \.fileName) { row in
                HStack(spacing: 6) {
                    ThumbnailCell(url: fileURL(row), size: 22)
                    Text(row.fileName)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(tint(row))
                }
                .help(row.path)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Mappa", value: \.sessionSubdirSortKey) { row in folderCell(row) }
                .width(min: 90, ideal: 140)

            TableColumn("Pontszám", value: \.score) { row in
                Text(String(format: "%.2f", row.score)).monospacedDigit().foregroundColor(tint(row))
            }
            .width(80)

            TableColumn("FWHM (px)", value: \.fwhmSortKey) { row in
                Text(TDFormat.cell(row.fwhm.map { String(format: "%.2f", $0) })).monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            TableColumn("Kerekség", value: \.roundnessSortKey) { row in roundnessCell(row) }
                .width(70)

            TableColumn("Csillagok", value: \.starCountSortKey) { row in starCountCell(row) }
                .width(70)

            TableColumn("Háttér", value: \.backgroundSortKey) { row in backgroundCell(row) }
                .width(70)

            Group {
                TableColumn("Szat. %", value: \.saturatedFractionSortKey) { row in saturatedFractionCell(row) }
                    .width(70)

                TableColumn("Exp.", value: \.exptimeSortKey) { row in exptimeCell(row) }
                    .width(60)
            }

            outlierAndVerdictColumns
            actionColumn
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // R10 review (item 5): row-scoped context menu + double-click-to-
        // open, same pattern `TonightPage.planTable`/`AllTargetsPage
        // .statsTable`/`NightsPage.table`/`DiscoveryPage.table` all use --
        // replaces the old per-cell `.contextMenu` that only fired over the
        // "Fájl" cell's own `HStack`. The "⋯" column above stays as the
        // always-visible affordance hinting these actions exist at all.
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = row(withID: id) {
                frameContextMenuItems(row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = row(withID: id) {
                NSWorkspace.shared.open(fileURL(row))
            }
        }
    }

    /// R10-B7: grouped so the table stays AT (not over) `Table`'s
    /// 10-top-level-column cap once the trailing "⋯" actions column below
    /// needs its own slot -- same `Group { }` workaround this table's own
    /// "Szat. %"/"Exp." pair above already established (R10-B1's own doc
    /// comment on this table's header). `outlierText(_:)` routes through a
    /// helper rather than inlining `row.isOutlier ? "⚠️" : ""` directly here
    /// -- learned from `CalibrationPage`/`TonightPage`/`NightsPage`'s own
    /// R10-B7 fixes, where an inline ternary/optional-coalesce directly
    /// inside a `Group { }` cell closure made the type-checker either fail
    /// to infer the closure parameter's type or time out outright; a plain
    /// function call is a cheap anchor either way. Shared by both
    /// `modernFrameTable`/`legacyFrameTable` (R11-T1) so the two variants'
    /// last two data columns can never drift apart.
    @TableColumnBuilder<Row, Never>
    private var outlierAndVerdictColumns: some TableColumnContent<Row, Never> {
        Group {
            // R11-T7 (F4): the ⚠️ is now a clickable button (`OutlierCell`)
            // opening a "why is this an outlier" popover, not just a static
            // glyph -- see `OutlierCell`'s own doc comment below.
            TableColumn("Kiugró") { (row: Row) in
                OutlierCell(
                    row: row,
                    onReview: { openReview(frames: [row.frameScore], label: nil) },
                    onReject: { appState.setFrameVerdict(path: row.path, accepted: false) }
                )
            }
            .width(50)

            // R10-B1: ✓/✗/— for the user's own manual verdict, PLUS (R11-T7)
            // a "javasolt: elvetés" hint for a still-undecided outlier -- see
            // `verdictCell(_:)` below. Not sortable (no `value:` binding),
            // same convention "Kiugró" right above already uses for a
            // glance-only signal column.
            TableColumn("Saját döntés") { (row: Row) in verdictCell(row) }
                .width(90)
        }
    }

    /// R10-B7: visible row-actions -- mirrors `frameContextMenuItems` exactly
    /// (same function, both call sites: this column's Menu AND the table's
    /// own row-scoped `.contextMenu`), so the right-click menu and this
    /// borderless "⋯" button can never drift apart. Shared by both
    /// `modernFrameTable`/`legacyFrameTable` (R11-T1).
    @TableColumnBuilder<Row, Never>
    private var actionColumn: some TableColumnContent<Row, Never> {
        TableColumn("") { (row: Row) in
            Menu {
                frameContextMenuItems(row)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .width(actionColumnWidth)
    }

    private func row(withID id: Row.ID) -> Row? {
        rows.first { $0.id == id }
    }

    @ViewBuilder
    private func frameContextMenuItems(_ row: Row) -> some View {
        Button("Megnyitás") { NSWorkspace.shared.open(fileURL(row)) }
        // R10 review (item 8): "Megnyitás Finderben" everywhere a Finder-
        // reveal action exists (`SearchResultsPage`/`AllTargetsPage`/
        // `NightsPage` already use this exact wording) -- was a bare
        // "Finderben", the only holdout.
        Button("Megnyitás Finderben") { NSWorkspace.shared.activateFileViewerSelecting([fileURL(row)]) }
        // R9-T6/B7: "Nagy előnézet (Space)" per spec -- the Space key itself
        // isn't wired (see `QuickLookController`'s doc comment for why),
        // this context-menu item is the documented fallback. R10 review
        // (item 7): renamed from "Quick Look" to "Nagy előnézet" --
        // `QuickLookController`'s own doc comment already documents that as
        // the convention every OTHER call site (`StacksSegment`) already
        // followed; this was the one holdout.
        Button("Nagy előnézet") { QuickLookController.shared.preview(fileURL(row)) }
        Divider()
        // R10-B1: shown CONTEXTUALLY -- whichever action would just repeat
        // the frame's current verdict is hidden rather than shown-but-inert,
        // and "Döntés törlése" only appears at all once there's something
        // to clear.
        if row.verdict != true {
            Button("Elfogadás") { appState.setFrameVerdict(path: row.path, accepted: true) }
        }
        if row.verdict != false {
            Button("Elvetés") { appState.setFrameVerdict(path: row.path, accepted: false) }
        }
        if row.verdict != nil {
            Button("Döntés törlése") { appState.setFrameVerdict(path: row.path, accepted: nil) }
        }
    }

    /// ✓ (green, accepted) / ✗ (red, rejected) / "-" (no verdict recorded,
    /// R11-T1: was the one em-dash holdout in a table cell -- see
    /// `TDFormat`'s own doc comment) -- the "Saját döntés" column's cell,
    /// and the same three states `FrameReviewSheet`'s verdict chip shows in
    /// its header (R10-B1). R11-T7 (F4, item 5): the no-verdict case now
    /// distinguishes a still-undecided OUTLIER (a halvány "javasolt:
    /// elvetés" hint, since the machine's own z-scores already lean toward
    /// rejecting it) from a genuinely neutral frame (the plain "-").
    @ViewBuilder
    private func verdictCell(_ row: Row) -> some View {
        switch row.verdict {
        case .some(true):
            Text("✓").bold().foregroundStyle(.green)
        case .some(false):
            Text("✗").bold().foregroundStyle(.red)
        case .none:
            if row.isOutlier {
                Text("javasolt: elvetés").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(TDFormat.missingCell).foregroundStyle(.secondary)
            }
        }
    }

    private func fileURL(_ row: Row) -> URL {
        URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).appendingPathComponent(row.path)
    }

    private static func formatExptime(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value)) s" }
        return String(format: "%.1f s", value)
    }
}

// MARK: - R11-T7 (F4): the ⚠️ "why is this an outlier" popover

/// The "Kiugró" column's cell -- a clickable ⚠️ button rather than a static
/// glyph. A dedicated `View` (not another `@ViewBuilder` cell function like
/// this table's other secondary-column cells) because it needs its OWN
/// per-row `showingPopover` state -- a plain `@State` on `QualitySegment`
/// itself couldn't tell which row's popover should be open.
fileprivate struct OutlierCell: View {
    let row: QualitySegment.Row
    let onReview: () -> Void
    let onReject: () -> Void

    @State private var showingPopover = false

    var body: some View {
        if row.isOutlier {
            Button {
                showingPopover = true
            } label: {
                Text("⚠️")
            }
            .buttonStyle(.plain)
            .help("Miért kiugró? -- kattints a részletekért")
            .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
                OutlierPopoverContent(
                    row: row,
                    onReview: { showingPopover = false; onReview() },
                    onReject: { showingPopover = false; onReject() }
                )
            }
        } else {
            Text("")
        }
    }
}

/// The ⚠️ popover's content (F4 spec): a per-metric z-score breakdown
/// (dominant metric highlighted in red/bold), a hedged "valószínű ok"
/// sentence, and the two F4 actions -- "Átnézés" opens `FrameReviewSheet` on
/// just this one frame, "Elvetés" records the reject verdict directly
/// without opening anything.
fileprivate struct OutlierPopoverContent: View {
    let row: QualitySegment.Row
    let onReview: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("⚠️ Kiugró").font(.headline)
                if row.verdict == nil {
                    Text("javasolt: elvetés").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let breakdown = row.breakdown, !breakdown.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(breakdown.entries, id: \.metric) { entry in
                        Text(Self.lineText(entry))
                            .font(.callout)
                            .fontWeight(entry.metric == breakdown.dominantMetric ? .bold : .regular)
                            .foregroundStyle(entry.metric == breakdown.dominantMetric ? .red : .primary)
                    }
                }

                if let cause = breakdown.likelyCauseText {
                    Text(cause)
                        .font(.callout.bold())
                        .padding(.top, 2)
                }
            } else {
                Text("Nincs metrika-bontás ehhez a kerethez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Átnézés") { onReview() }
                Button("Elvetés") { onReject() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// `"FWHM 4.20 px — session-medián 2.90 px · z = -2.4"` -- F4 spec's
    /// exact wording, one line per metric the frame actually has a value
    /// for.
    private static func lineText(_ entry: OutlierBreakdown.MetricEntry) -> String {
        let (valueText, medianText): (String, String)
        switch entry.metric {
        case .fwhm:
            valueText = String(format: "%.2f px", entry.value)
            medianText = String(format: "%.2f px", entry.groupMedian)
        case .roundness:
            valueText = String(format: "%.2f", entry.value)
            medianText = String(format: "%.2f", entry.groupMedian)
        case .starCount:
            valueText = String(Int(entry.value.rounded()))
            medianText = String(Int(entry.groupMedian.rounded()))
        case .background:
            valueText = String(format: "%.0f", entry.value)
            medianText = String(format: "%.0f", entry.groupMedian)
        }
        let zText = String(format: "%.1f", entry.zScore)
        return "\(entry.metric.displayName) \(valueText) — session-medián \(medianText) · z = \(zText)"
    }
}

// MARK: - R11-T7 (F4, item 4): batch reject-marking confirm sheet

/// "Összes kiugró elvetésre jelölése… (N)" -- lists every still-undecided
/// outlier (filename + its dominant metric/z, the "fő ok") before writing
/// anything, with an explicit "this is a marking, not a file operation"
/// disclaimer (same trust-philosophy wording this app uses everywhere a
/// batch action could otherwise look scarier than it is). Confirming writes
/// a plain `reject` `user_verdict` for each row through the SAME
/// `AppState.setFrameVerdict` path the single-frame "Elvetés" actions
/// already use (`source == "app"`), then toasts and dismisses -- the table
/// behind it updates on its own since `frameVerdicts` is patched in place.
fileprivate struct BatchRejectOutliersConfirmSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let rows: [QualitySegment.Row]

    private func causeSummary(_ row: QualitySegment.Row) -> String {
        guard let breakdown = row.breakdown,
              let dominant = breakdown.dominantMetric,
              let entry = breakdown.entries.first(where: { $0.metric == dominant })
        else { return TDFormat.missingTile }
        return "\(dominant.displayName) (z = \(String(format: "%.1f", entry.zScore)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Összes kiugró elvetésre jelölése").font(.headline)

            Text("Ez csak jelölés a stack-válogatáshoz — fájlt nem érint.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("\(rows.count) keret kerül elvetésre jelölésre:")
                .font(.callout)

            if rows.isEmpty {
                Text("Nincs még el nem bírált kiugró keret.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            HStack {
                                Text(row.fileName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(causeSummary(row)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Elvetés (\(rows.count))") {
                    for row in rows {
                        appState.setFrameVerdict(path: row.path, accepted: false)
                    }
                    appState.pushToast(.success, "\(rows.count) kiugró keret elvetésre jelölve")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }
}
