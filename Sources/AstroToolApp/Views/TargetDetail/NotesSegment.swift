import AppKit
import AstroCore
import SwiftUI

/// R9-T3/A.3's "Jegyzetek" segment: read-only per-session README notes
/// (editing arrives in T6/B4) plus a "Riportok" list of every generated
/// report HTML for this target under `.astro_tool/reports/`.
struct NotesSegment: View {
    @Environment(AppState.self) private var appState
    let target: String

    private var sessionsWithNotes: [SessionDetail] {
        (appState.sessionDetailsByTarget[target] ?? [])
            .filter { !$0.notes.isEmpty }
            .sorted { $0.dateRaw < $1.dateRaw }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                notesBlock
                reportsBlock
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session-jegyzetek").font(.headline)
            if sessionsWithNotes.isEmpty {
                Text("Nincs README-jegyzet ehhez a célponthoz.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessionsWithNotes, id: \.dateRaw) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.dateRaw).font(.subheadline).bold()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                            ForEach(session.notes.keys.sorted(), id: \.self) { key in
                                GridRow {
                                    Text(key).foregroundStyle(.secondary)
                                    Text(session.notes[key] ?? "")
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var reportsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Riportok").font(.headline)
            let files = appState.reportFiles(for: target)
            if files.isEmpty {
                Text("Nincs generált riport ehhez a célponthoz. (`Riport…` menü a fejlécben.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files, id: \.path) { url in
                        HStack(spacing: 10) {
                            Text(url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Megnyitás") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link).font(.caption)
                            Button("Finderben") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(.link).font(.caption)
                            Button("Újragenerálás") { appState.regenerateReport(url, target: target) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }
}
