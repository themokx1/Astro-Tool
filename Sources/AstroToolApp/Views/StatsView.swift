import AstroCore
import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""

    private struct Row: Identifiable {
        let id = UUID()
        let stats: TargetStats
    }

    private var filtered: [TargetStats] {
        guard !searchText.isEmpty else { return appState.stats }
        return appState.stats.filter { $0.target.localizedCaseInsensitiveContains(searchText) }
    }

    private var rows: [Row] {
        filtered.map(Row.init)
    }

    private var totalIntegrationSeconds: Double {
        appState.stats.reduce(0) { $0 + $1.totalIntegrationSeconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Keresés célpont szerint", text: $searchText)
                    .frame(width: 260)
                Button("Frissítés") { appState.loadStats() }
                    .disabled(appState.isBusy || appState.db == nil)
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Table(rows) {
                TableColumn("Célpont") { row in Text(row.stats.target) }
                    .width(min: 160, ideal: 240)
                TableColumn("Össz. integráció") { row in Text(formatDuration(row.stats.totalIntegrationSeconds)) }
                    .width(120)
                TableColumn("Session-ök") { row in Text("\(row.stats.sessionDates.count)") }
                    .width(90)
                TableColumn("Utolsó dátum") { row in Text(row.stats.lastSessionDate ?? "-") }
                    .width(110)
                TableColumn("Wide-field") { row in Text(row.stats.isWideField ? "igen" : "") }
                    .width(80)
            }

            HStack {
                Text("Összes integráció:").bold()
                Text(formatDuration(totalIntegrationSeconds))
                Spacer()
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .padding()
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}
