import AstroCore
import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var selection: Row.ID?

    private struct Row: Identifiable {
        var id: String { stats.target }
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

            Table(rows, selection: $selection) {
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

            if let selection {
                Divider()
                SessionDetailPanel(target: selection, sessions: appState.sessionDetails, isBusy: appState.isBusy)
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .onChange(of: selection) { _, newValue in
            if let newValue {
                appState.loadSessionDetails(target: newValue)
            }
        }
        .padding()
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

/// Detail area shown under the target table once a row is selected: one
/// block per session date-dir with the equipment signals `TargetStats`
/// doesn't carry (focal length, camera, gain/ISO, sensor temp, filter).
private struct SessionDetailPanel: View {
    let target: String
    let sessions: [SessionDetail]
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session-ök — \(target)").font(.headline)

            if isBusy && sessions.isEmpty {
                ProgressView().controlSize(.small)
            } else if sessions.isEmpty {
                Text("Nincs session ehhez a célponthoz.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sessions, id: \.dateRaw) { session in
                            sessionRow(session)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func sessionRow(_ session: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.dateRaw).bold()
                Text("(\(session.lightCount) light, \(session.flatCount) flat, \(session.darkCount) dark, \(session.biasCount) bias)")
                    .foregroundStyle(.secondary)
                if session.hasReadme {
                    Text("README").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("Integráció:").foregroundStyle(.secondary)
                    Text(formatDuration(session.integrationSeconds))
                }
                GridRow {
                    Text("Expozíciók:").foregroundStyle(.secondary)
                    Text(exposureSummary(session.exposureBreakdown))
                }
                GridRow {
                    Text("Kamera:").foregroundStyle(.secondary)
                    Text(session.cameras.isEmpty ? "-" : session.cameras.joined(separator: ", "))
                }
                GridRow {
                    Text("Gyújtótávolság:").foregroundStyle(.secondary)
                    Text(session.focalLengthsMM.isEmpty ? "-" : session.focalLengthsMM.map { "\(Self.formatNumber($0)) mm" }.joined(separator: ", "))
                }
                GridRow {
                    Text("Gain/ISO:").foregroundStyle(.secondary)
                    Text(session.gains.isEmpty ? "-" : session.gains.map { Self.formatNumber($0) }.joined(separator: ", "))
                }
                GridRow {
                    Text("Szenzor hőm.:").foregroundStyle(.secondary)
                    Text(session.sensorTempsC.isEmpty ? "-" : session.sensorTempsC.map { "\(Self.formatNumber($0))°C" }.joined(separator: ", "))
                }
                GridRow {
                    Text("Szűrő:").foregroundStyle(.secondary)
                    Text(session.filters.isEmpty ? "-" : session.filters.joined(separator: ", "))
                }
            }
            .font(.callout)
        }
    }

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { "\($0.key)s×\($0.value)" }
            .joined(separator: ", ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
