import AstroCore
import SwiftUI

struct CalibrationView: View {
    @Environment(AppState.self) private var appState

    private struct Row: Identifiable {
        let id = UUID()
        let need: CalibNeed
    }

    private var todos: [CalibNeed] {
        appState.calibNeeds.filter { $0.todo != nil }
    }

    private var rows: [Row] {
        appState.calibNeeds.map(Row.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Frissítés") { appState.loadCalib() }
                    .disabled(appState.isBusy || appState.db == nil)
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                    Button("Mégse") { appState.cancelCurrentOperation() }
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Text("Teendők").font(.headline)
            if todos.isEmpty {
                Text("Nincs teendő — minden kombináció friss.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, need in
                        Text("• \(need.todo ?? "")")
                    }
                }
            }

            Text("Lefedettség").font(.headline)
            Table(rows) {
                TableColumn("Exp. (s)") { row in Text(formattedExposure(row.need.exposureSeconds)) }
                    .width(70)
                TableColumn("Hőm. (°C)") { row in Text(row.need.tempC.map { String(format: "%.1f", $0) } ?? "-") }
                    .width(80)
                TableColumn("Light-ok") { row in Text("\(row.need.lightCount)") }
                    .width(70)
                TableColumn("Master") { row in
                    Text(row.need.matchedMasterPath ?? "hiányzik")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.need.matchedMasterPath ?? "hiányzik")
                }
                .width(min: 180, ideal: 260)
                TableColumn("Kor (nap)") { row in Text(row.need.masterAgeDays.map(String.init) ?? "-") }
                    .width(80)
                TableColumn("Állapot") { row in
                    if row.need.isStale {
                        Text("⚠️ elavult").foregroundStyle(.orange)
                    } else if row.need.matchedMasterPath != nil {
                        Text("friss").foregroundStyle(.green)
                    } else {
                        Text("hiányzik").foregroundStyle(.red)
                    }
                }
                .width(90)
            }
        }
        .onAppear {
            if appState.calibNeeds.isEmpty { appState.loadCalib() }
        }
        .padding()
    }

    private func formattedExposure(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
