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
    /// Drives the "Átnézés…" (blink review) sheet -- R10-B1.
    @State private var showingReview = false

    /// Flattened, display-ready view of a `FrameScore` -- ported verbatim
    /// from the deleted `QualityView.Row`.
    private struct Row: Identifiable {
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
                Text("Siril nem található — csak natív statisztika")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let summaryText {
                Text(summaryText).font(.callout).foregroundStyle(.secondary)
            }
            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
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
            // R10-B1: hands the sheet the table's CURRENT sort/filter order
            // (`rows` already applies both `filteredFrameScores`'s date
            // filter and the user's own column sort) -- blinking through
            // frames must never silently show them in a different order
            // than what's on screen behind the sheet.
            FrameReviewSheet(frames: rows.map(\.frameScore))
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
            Button("Átnézés…") { showingReview = true }
                .disabled(filteredFrameScores.isEmpty)
                .help(
                    filteredFrameScores.isEmpty
                        ? "Nincs megjeleníthető keret"
                        : "Keretek egyenkénti átnézése, elfogadása/elvetése"
                )

            MetricInfoButton(metrics: Self.frameMetricInfo)

            Spacer()

            if appState.isBusy {
                ProgressView().controlSize(.small)
                Text(appState.progressText).foregroundStyle(.secondary)
                Button("Mégse") { appState.cancelCurrentOperation() }
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
            title: "FWHM",
            explanation: "Csillagok félértékszélessége -- a fókusz élességének mérőszáma, kisebb = élesebb. Mikor hazudik: \"Siril nélkül\" méréskor ez mindig „-”, natív statisztika nem ad FWHM-et."
        ),
        .init(
            title: "Háttér",
            explanation: "Az égi háttér nyers ADU-szintje a keret medián pixelértékéből. Mikor hazudik: mért szenzor-profil nélkül (Szenzor-profilok oldal) ez csak nyers ADU, nem valódi e⁻/s/″² -- két különböző gain/setup között nem összehasonlítható."
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

    // MARK: - Frame table (unchanged from the deleted QualityView)

    private func tint(_ row: Row) -> Color { row.isOutlier ? .red : .primary }

    private var frameTable: some View {
        Table(rows, sortOrder: $sortOrder) {
            // R9-T6/B7: the thumbnail rides along in the "Fájl" column
            // itself rather than as its own `TableColumn` -- `Table`'s
            // column-builder overloads top out at 10 top-level items.
            // R10-B1 added an 11th VISIBLE column ("Saját döntés") on top of
            // the 10 already here -- rather than embedding it into an
            // existing cell the way the thumbnail was, "Szat. %"/"Exp."
            // below are grouped into one `Group { }` (a `TableColumnContent`
            // conformance meant exactly for this): that's still 2 real
            // columns, it just costs the builder only 1 top-level slot, and
            // frees the slot "Saját döntés" needs.
            TableColumn("Fájl", value: \.fileName) { row in
                HStack(spacing: 6) {
                    ThumbnailCell(url: fileURL(row), size: 22)
                    Text(row.fileName)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(tint(row))
                }
                .help(row.path)
                .contextMenu { frameContextMenuItems(row) }
            }
            .width(min: 160, ideal: 240)

            TableColumn("Mappa", value: \.sessionSubdirSortKey) { row in
                Text(row.sessionSubdir ?? "-").lineLimit(1).foregroundColor(tint(row))
            }
            .width(min: 90, ideal: 140)

            TableColumn("Pontszám", value: \.score) { row in
                Text(String(format: "%.2f", row.score)).monospacedDigit().foregroundColor(tint(row))
            }
            .width(80)

            TableColumn("FWHM", value: \.fwhmSortKey) { row in
                Text(row.fwhm.map { String(format: "%.2f", $0) } ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(60)

            TableColumn("Kerekség", value: \.roundnessSortKey) { row in
                Text(row.roundness.map { String(format: "%.2f", $0) } ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            TableColumn("Csillagok", value: \.starCountSortKey) { row in
                Text(row.starCount.map(String.init) ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            TableColumn("Háttér", value: \.backgroundSortKey) { row in
                Text(row.background.map { String(format: "%.0f", $0) } ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            Group {
                TableColumn("Szat. %", value: \.saturatedFractionSortKey) { row in
                    Text(row.saturatedFraction.map { String(format: "%.2f", $0 * 100) } ?? "-").monospacedDigit().foregroundColor(tint(row))
                }
                .width(70)

                TableColumn("Exp.", value: \.exptimeSortKey) { row in
                    Text(row.exptime.map(Self.formatExptime) ?? "-").monospacedDigit().foregroundColor(tint(row))
                }
                .width(60)
            }

            TableColumn("Kiugró") { row in Text(row.isOutlier ? "⚠️" : "") }
                .width(50)

            // R10-B1: ✓/✗/— for the user's own manual verdict -- see
            // `verdictCell(_:)` below. Not sortable (no `value:` binding),
            // same convention "Kiugró" right above already uses for a
            // glance-only signal column.
            TableColumn("Saját döntés") { row in verdictCell(row.verdict) }
                .width(90)
        }
    }

    @ViewBuilder
    private func frameContextMenuItems(_ row: Row) -> some View {
        Button("Megnyitás") { NSWorkspace.shared.open(fileURL(row)) }
        Button("Finderben") { NSWorkspace.shared.activateFileViewerSelecting([fileURL(row)]) }
        // R9-T6/B7: "Quick Look (Space)" per spec -- the Space key itself
        // isn't wired (see `QuickLookController`'s doc comment for why),
        // this context-menu item is the documented fallback.
        Button("Quick Look") { QuickLookController.shared.preview(fileURL(row)) }
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

    /// ✓ (green, accepted) / ✗ (red, rejected) / — (no verdict recorded) --
    /// the "Saját döntés" column's cell, and the same three states
    /// `FrameReviewSheet`'s verdict chip shows in its header (R10-B1).
    @ViewBuilder
    private func verdictCell(_ verdict: Bool?) -> some View {
        switch verdict {
        case .some(true):
            Text("✓").bold().foregroundStyle(.green)
        case .some(false):
            Text("✗").bold().foregroundStyle(.red)
        case .none:
            Text("—").foregroundStyle(.secondary)
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
