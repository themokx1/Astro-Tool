import AstroCore
import Foundation
import SwiftUI

struct QualityView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTarget: String?
    @State private var dateText: String = ""
    @State private var sortOrder = [KeyPathComparator(\Row.score, order: .reverse)]

    /// Flattened, display-ready view of a `FrameScore` -- every optional
    /// metric stays optional here too (rather than substituting a sentinel)
    /// so `KeyPathComparator` sorts absent values consistently (`nil` sorts
    /// lowest) and each cell can independently render "-" for its own
    /// missing value.
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

        // `Table`'s sortable `TableColumn(_:value:content:)` overload only
        // resolves against a *non-optional* `Comparable` keypath (Optional
        // doesn't itself conform to `Comparable`) -- these give every
        // optional metric a non-optional sort surrogate (nil sorts lowest)
        // so its column can still be sortable, while the cell content still
        // renders "-" for the real `nil`.
        var sessionSubdirSortKey: String { sessionSubdir ?? "" }
        var fwhmSortKey: Double { fwhm ?? -.infinity }
        var roundnessSortKey: Double { roundness ?? -.infinity }
        var starCountSortKey: Int { starCount ?? .min }
        var backgroundSortKey: Double { background ?? -.infinity }
        var saturatedFractionSortKey: Double { saturatedFraction ?? -.infinity }
        var exptimeSortKey: Double { exptime ?? -.infinity }
    }

    private var targets: [String] {
        appState.stats.map(\.target).sorted()
    }

    private var rows: [Row] {
        appState.frameScores.map(Row.init).sorted(using: sortOrder)
    }

    private var sirilAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: appState.config.rating.sirilPath)
    }

    /// "N frame · kiugró: K · Siril metrika: M/N", with an extra hint
    /// appended when Siril was available to try (so the user would expect
    /// star metrics) but not a single frame actually got any -- most likely
    /// because the configured Siril path doesn't work, not because Siril
    /// itself found nothing on every single frame.
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

    private static func formatExptime(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value)) s"
        }
        return String(format: "%.1f s", value)
    }

    private func tint(_ row: Row) -> Color {
        row.isOutlier ? .red : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Célpont", selection: $selectedTarget) {
                    Text("Válassz célpontot…").tag(String?.none)
                    ForEach(targets, id: \.self) { target in
                        Text(target).tag(Optional(target))
                    }
                }
                .frame(width: 260)

                TextField("Dátum (opcionális, YYYY-MM-DD)", text: $dateText)
                    .frame(width: 220)

                Button("Pontozás") {
                    guard let selectedTarget else { return }
                    appState.runRate(target: selectedTarget, date: dateText.isEmpty ? nil : dateText)
                }
                .disabled(selectedTarget == nil || appState.isBusy)

                Spacer()

                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                    Button("Mégse") { appState.cancelCurrentOperation() }
                }
            }

            if !sirilAvailable {
                Text("Siril nem található — csak natív statisztika")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let summaryText {
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Fájl", value: \.fileName) { row in
                    Text(row.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(tint(row))
                        .help(row.path)
                }
                .width(min: 140, ideal: 220)

                TableColumn("Mappa", value: \.sessionSubdirSortKey) { row in
                    Text(row.sessionSubdir ?? "-")
                        .lineLimit(1)
                        .foregroundColor(tint(row))
                }
                .width(min: 90, ideal: 140)

                TableColumn("Pontszám", value: \.score) { row in
                    Text(String(format: "%.2f", row.score))
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(80)

                TableColumn("FWHM", value: \.fwhmSortKey) { row in
                    Text(row.fwhm.map { String(format: "%.2f", $0) } ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(60)

                TableColumn("Kerekség", value: \.roundnessSortKey) { row in
                    Text(row.roundness.map { String(format: "%.2f", $0) } ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(70)

                TableColumn("Csillagok", value: \.starCountSortKey) { row in
                    Text(row.starCount.map(String.init) ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(70)

                TableColumn("Háttér", value: \.backgroundSortKey) { row in
                    Text(row.background.map { String(format: "%.0f", $0) } ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(70)

                TableColumn("Szat. %", value: \.saturatedFractionSortKey) { row in
                    Text(row.saturatedFraction.map { String(format: "%.2f", $0 * 100) } ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(70)

                TableColumn("Exp.", value: \.exptimeSortKey) { row in
                    Text(row.exptime.map(Self.formatExptime) ?? "-")
                        .monospacedDigit()
                        .foregroundColor(tint(row))
                }
                .width(60)

                TableColumn("Kiugró") { row in
                    Text(row.isOutlier ? "⚠️" : "")
                }
                .width(50)
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .padding()
    }
}
