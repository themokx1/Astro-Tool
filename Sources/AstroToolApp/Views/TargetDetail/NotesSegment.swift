import AppKit
import AstroCore
import SwiftUI

/// R9-T3/A.3's "Jegyzetek" segment: read-only per-session README notes
/// (editing arrives in T6/B4) plus a "Riportok" list of every generated
/// report HTML for this target under `.astro_tool/reports/`.
struct NotesSegment: View {
    @Environment(AppState.self) private var appState
    let target: String

    /// R9-T6/B4: every session now shown here, not just the ones with a
    /// note -- `SessionDetail.notes` merges README + the note-editor store
    /// (see `SessionStatsQueries.computeSessionDetail`), so a session with
    /// no notes YET is exactly where "Szerkesztés…" should be offered, not
    /// hidden until it already has something to show.
    private var allSessions: [SessionDetail] {
        (appState.sessionDetailsByTarget[target] ?? []).sorted { $0.dateRaw < $1.dateRaw }
    }

    /// The session currently shown in `SessionNoteSheet`, `nil` when closed.
    @State private var noteEditingSession: LinkingSession?

    /// R11-T13/F20: this session's conflicting keys (`NoteConflicts.detect`),
    /// computed straight off `AppState.storeNotes`/`readmeNotes` -- the two
    /// RAW sources, not `session.notes`, which already merged them (README
    /// winning) and so has thrown the disagreement away by the time it gets
    /// here.
    private func conflicts(forDate date: String) -> [String: NoteConflicts.Conflict] {
        NoteConflicts.detect(
            appNotes: appState.storeNotes(target: target, date: date),
            readmeNotes: appState.readmeNotes(target: target, date: date)
        )
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
        .sheet(item: $noteEditingSession) { session in
            SessionNoteSheet(target: session.target, date: session.date)
        }
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session-jegyzetek").font(.headline)
            if allSessions.isEmpty {
                Text("Nincs session ehhez a célponthoz.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(allSessions, id: \.dateRaw) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.dateRaw).font(.subheadline).bold()
                            Spacer()
                            Button("Szerkesztés…") {
                                noteEditingSession = LinkingSession(target: target, date: session.dateRaw)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        if session.notes.isEmpty {
                            Text("Nincs jegyzet.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            let sessionConflicts = conflicts(forDate: session.dateRaw)
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                                ForEach(session.notes.keys.sorted(), id: \.self) { key in
                                    GridRow {
                                        Text(key).foregroundStyle(.secondary)
                                        Text(session.notes[key] ?? "")
                                        // R11-T13/F20: this key's app-store
                                        // value and README value disagree --
                                        // a stronger signal than the merged
                                        // cell above alone shows (that cell
                                        // is always just the README's own
                                        // winning value).
                                        if let conflict = sessionConflicts[key] {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(.yellow)
                                                .help(
                                                    "app-jegyzet: \(conflict.appValue) · README: \(conflict.readmeValue)"
                                                )
                                        }
                                    }
                                    .font(.caption)
                                }
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
                            // R10 review (item 8): "Megnyitás Finderben"
                            // everywhere a Finder-reveal action exists --
                            // was a bare "Finderben".
                            Button("Megnyitás Finderben") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
