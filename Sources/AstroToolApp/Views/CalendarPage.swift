import AstroCore
import SwiftUI

/// "Naptár" sidebar page (R9-T1): the 30-night planning calendar
/// (`Planner.month`, R7-B5) that used to live behind Áttekintés's "Hónap…"
/// sheet button, now a page of its own (spec's `Page.calendar`) -- same
/// `AppState.monthPlan`/`loadMonthPlan()` underneath, only the surrounding
/// chrome changed from a sheet's `NavigationStack` to a plain page header.
/// T4 rebuilds this page's content in full; for now it's the same list,
/// relocated.
struct CalendarPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Naptár").font(.largeTitle).bold()
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Frissítés") { appState.loadMonthPlan() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Group {
                if let month = appState.monthPlan {
                    if month.isEmpty {
                        ContentUnavailableView("Nincs adat", systemImage: "moon.stars")
                    } else {
                        List(month, id: \.date) { night in
                            monthRow(night)
                        }
                    }
                } else if appState.isBusy {
                    ProgressView("Havi terv számítása…")
                } else {
                    ContentUnavailableView("Még nincs számolva", systemImage: "calendar")
                }
            }
        }
        .onAppear {
            if appState.monthPlan == nil { appState.loadMonthPlan() }
        }
        .padding()
    }

    private func monthRow(_ night: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isHighlighted(night) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Text(night.date).font(.callout.bold())
                Spacer()
                Text(night.astroDarkHours.map { String(format: "%.1f óra sötét", $0) } ?? "n/a sötét")
                    .foregroundStyle(.secondary)
                Text(String(format: "Hold: %.0f%%", night.moonIlluminationPercent))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            if let note = night.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }

            if night.bestTargets.isEmpty {
                Text("—").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(night.bestTargets.map { "\($0.target) (\(String(format: "%.1f", $0.usableHours))h)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func isHighlighted(_ night: NightSummary) -> Bool {
        (night.astroDarkHours ?? 0) >= 4 && night.moonIlluminationPercent < 30
    }
}
