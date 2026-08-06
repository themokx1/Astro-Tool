import AstroCore
import SwiftUI

/// R9-T6/B14's "Minden célpont pontozása…" confirm sheet: shows the target
/// (and usable-frame) count before anything runs, then hands off to
/// `AppState.runRateAll()` -- the same serial-loop-with-aggregate-progress
/// shape `runRate`/`runPlateSolveAll` already use for a single/all-target
/// operation, just looped over every target instead of one. No fake ETA
/// number is shown (this app avoids invented precision elsewhere -- see
/// e.g. `ExposureAdvice.notAvailableReason`'s "honest, not a guess" stance);
/// instead this states the actual frame count and an honest caveat about
/// per-frame cost.
struct RateAllConfirmSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    private var targetCount: Int { appState.stats.count }
    private var totalUsableFrames: Int { appState.stats.reduce(0) { $0 + $1.usableFrameCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Minden célpont pontozása").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(targetCount) célpont, összesen \(totalUsableFrames) használható keret.")
                Text("Sorosan futtatja minden célpontra a szokásos keret-pontozást (FWHM/kerekség/csillagszám, Siril ha elérhető). Az időigény kereten és Siril-elérhetőségen múlik -- nem tudunk pontos becslést adni.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if started {
                HStack(spacing: 8) {
                    if appState.isBusy {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                    } else {
                        Text(appState.progressText).foregroundStyle(.green)
                    }
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(started && !appState.isBusy ? "Bezárás" : "Mégse") { dismiss() }
                if !started {
                    Button("Pontozás indítása") {
                        started = true
                        appState.runRateAll()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetCount == 0)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 200)
    }
}

/// R9-T6/B14's "Expozíció-tanácsadó minden célpontra…" results sheet: one
/// row per target from `ExposureAdvisor.adviseAll`, the batch counterpart
/// of the per-target advisor panel already shown on `OverviewSegment`. No
/// confirm-first step -- this is a read-only computation over already-
/// scanned data, same "just runs" stance `runIngestDSS`/`runPlateSolveAll`
/// take for their own non-destructive batch operations.
struct ExposureAdviceAllSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id: String
        let advice: ExposureAdvice
    }

    private var rows: [Row] {
        (appState.exposureAdviceAll ?? [])
            .sorted { $0.target < $1.target }
            .map { Row(id: $0.target + "|" + ($0.sessionDate ?? ""), advice: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Expozíció-tanácsadó — minden célpont").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "Nincs adat",
                    systemImage: "sparkles",
                    description: Text("Nincs olyan célpont, amelyhez elég adat lenne a tanácsadáshoz.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("Célpont") { row in Text(row.advice.target) }
                        .width(min: 140, ideal: 200)
                    TableColumn("Jelenlegi sub") { row in Text(row.advice.currentSubSeconds.map { "\(Int($0)) s" } ?? "-") }
                        .width(90)
                    TableColumn("Javasolt sub") { row in Text(row.advice.recommendedSubSeconds.map { "\(Int($0)) s" } ?? "-") }
                        .width(90)
                    TableColumn("Olvasási zaj-részesedés") { row in
                        Text(row.advice.currentReadNoiseSharePercent.map { String(format: "%.0f%%", $0) } ?? "-")
                    }
                    .width(140)
                    TableColumn("Tanács") { row in
                        Text(row.advice.advice.first ?? row.advice.notAvailableReason ?? "-")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(row.advice.advice.isEmpty ? .secondary : .primary)
                    }
                    .width(min: 200, ideal: 320)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }
}
