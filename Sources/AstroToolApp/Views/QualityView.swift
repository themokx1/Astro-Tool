import AstroCore
import Foundation
import SwiftUI

struct QualityView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTarget: String?
    @State private var dateText: String = ""

    private struct Row: Identifiable {
        let id = UUID()
        let score: FrameScore
    }

    private var targets: [String] {
        appState.stats.map(\.target).sorted()
    }

    private var rows: [Row] {
        appState.frameScores.map(Row.init)
    }

    private var sirilAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: appState.config.rating.sirilPath)
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

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Table(rows) {
                TableColumn("Útvonal") { row in
                    Text(row.score.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.score.isOutlier ? Color.orange : Color.primary)
                }
                .width(min: 220, ideal: 340)

                TableColumn("Pontszám") { row in
                    Text(String(format: "%.2f", row.score.score))
                        .foregroundStyle(row.score.isOutlier ? Color.orange : Color.primary)
                }
                .width(90)

                TableColumn("Kiugró") { row in
                    Text(row.score.isOutlier ? "⚠️" : "")
                }
                .width(60)
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .padding()
    }
}
