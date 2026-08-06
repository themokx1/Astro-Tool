import AppKit
import AstroCore
import SwiftUI

/// R9-T3/A.3's "Minőség" segment: the same 10-column frame `Table`
/// `QualityView` used to show (unchanged), but with the control bar rebuilt
/// per spec -- a single primary "Keretek pontozása" button with a
/// Menu-chevron for `--force`/`--no-siril`, a session-date `Menu` instead of
/// a free-text date field, and a 10-bucket score histogram above the table.
struct QualitySegment: View {
    @Environment(AppState.self) private var appState
    let target: String

    /// `nil` means "Minden session" (the Menu's own first item) -- mirrors
    /// the old free-text field's "empty means all sessions" convention.
    @State private var selectedDate: String?
    @State private var sortOrder = [KeyPathComparator(\Row.score, order: .reverse)]

    /// Flattened, display-ready view of a `FrameScore` -- ported verbatim
    /// from the deleted `QualityView.Row`.
    private struct Row: Identifiable {
        let id = UUID()
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

        init(_ frameScore: FrameScore) {
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
    private var rows: [Row] { appState.frameScores.map(Row.init).sorted(using: sortOrder) }
    private var sirilAvailable: Bool { FileManager.default.isExecutableFile(atPath: appState.config.rating.sirilPath) }

    private var summaryText: String? {
        guard !appState.frameScores.isEmpty else { return nil }
        let total = appState.frameScores.count
        let outliers = appState.frameScores.count { $0.isOutlier }
        let withMetrics = appState.frameScores.count { $0.metrics != nil }
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

            if appState.frameScores.isEmpty {
                ContentUnavailableView(
                    "Nincsenek pontozott keretek",
                    systemImage: "star",
                    description: Text("Futtass pontozást a FWHM / kerekség / csillagszám metrikákhoz.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                histogram
                frameTable
            }
        }
        .padding()
    }

    // MARK: - Control bar (rebuilt per A.3)

    private var controlBar: some View {
        HStack {
            Menu {
                ForEach(sessionDates, id: \.self) { date in
                    Button(date) { selectedDate = date }
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
    ]

    // MARK: - Score histogram

    /// 10 equal-width buckets spanning the currently loaded scores' own
    /// [min, max] range -- a quick "which frames are bad" visual without
    /// needing to sort the table by score first. Hidden (via the caller's
    /// `if appState.frameScores.isEmpty` guard) rather than shown empty.
    private var histogram: some View {
        let scores = appState.frameScores.map(\.score)
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

    // MARK: - Frame table (unchanged from the deleted QualityView)

    private func tint(_ row: Row) -> Color { row.isOutlier ? .red : .primary }

    private var frameTable: some View {
        Table(rows, sortOrder: $sortOrder) {
            // R9-T6/B7: the thumbnail rides along in the "Fájl" column
            // itself rather than as its own `TableColumn` -- `Table`'s
            // column-builder overloads top out at 10, and this table
            // already has exactly 10 without one more.
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

            TableColumn("Szat. %", value: \.saturatedFractionSortKey) { row in
                Text(row.saturatedFraction.map { String(format: "%.2f", $0 * 100) } ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(70)

            TableColumn("Exp.", value: \.exptimeSortKey) { row in
                Text(row.exptime.map(Self.formatExptime) ?? "-").monospacedDigit().foregroundColor(tint(row))
            }
            .width(60)

            TableColumn("Kiugró") { row in Text(row.isOutlier ? "⚠️" : "") }
                .width(50)
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
    }

    private func fileURL(_ row: Row) -> URL {
        URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).appendingPathComponent(row.path)
    }

    private static func formatExptime(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value)) s" }
        return String(format: "%.1f s", value)
    }
}
