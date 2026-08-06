import AppKit
import AstroCore
import SwiftUI

/// R9-T6/B3's global search results page: four sections
/// (Célpontok/Sessionök/Fájlok/Jegyzetek) over `AppState.searchResults`,
/// populated by `AppState.runSearch(query:)` from the sidebar's ⌘F/Enter.
/// Every row navigates somewhere concrete -- a target row opens
/// `Page.target`, a session row opens the same target page and preselects
/// that session, a file row offers a Finder action plus a link to its
/// parent target, a note row opens the target page (the Jegyzetek segment
/// is where that note actually lives).
struct SearchResultsPage: View {
    @Environment(AppState.self) private var appState

    private var results: SearchResults? { appState.searchResults }

    private var totalHitCount: Int {
        guard let results else { return 0 }
        return results.targets.count + results.sessions.count + results.files.count + results.notes.count
    }

    var body: some View {
        Group {
            if appState.searchQuery.isEmpty {
                ContentUnavailableView(
                    "Kereső",
                    systemImage: "magnifyingglass",
                    description: Text("Írj be egy célpont-, session-, fájl- vagy jegyzet-keresést a bal oldali mezőbe.")
                )
            } else if let results, !results.isEmpty {
                resultsList(results)
            } else {
                ContentUnavailableView.search(text: appState.searchQuery)
            }
        }
        .navigationTitle("Kereső")
    }

    @ViewBuilder
    private func resultsList(_ results: SearchResults) -> some View {
        List {
            Section {
                Text("\(totalHitCount) találat erre: \u{201E}\(appState.searchQuery)\u{201D}")
                    .font(.headline)
                    .listRowSeparator(.hidden)
            }

            if !results.targets.isEmpty {
                Section("Célpontok") {
                    ForEach(results.targets, id: \.target) { hit in
                        targetRow(hit)
                    }
                }
            }

            if !results.sessions.isEmpty {
                Section("Sessionök") {
                    ForEach(Array(results.sessions.enumerated()), id: \.offset) { _, hit in
                        sessionRow(hit)
                    }
                }
            }

            if !results.files.isEmpty {
                Section(fileSectionTitle(results)) {
                    ForEach(results.files, id: \.path) { hit in
                        fileRow(hit)
                    }
                }
            }

            if !results.notes.isEmpty {
                Section("Jegyzetek") {
                    ForEach(Array(results.notes.enumerated()), id: \.offset) { _, hit in
                        noteRow(hit)
                    }
                }
            }
        }
    }

    private func fileSectionTitle(_ results: SearchResults) -> String {
        results.totalFileMatches > results.files.count
            ? "Fájlok (\(results.files.count) / \(results.totalFileMatches))"
            : "Fájlok"
    }

    // MARK: - Rows

    private func targetRow(_ hit: (target: String, displayName: String)) -> some View {
        Button {
            appState.currentPage = .target(hit.target)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.displayName).bold()
                    if hit.displayName != hit.target {
                        Text(hit.target).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ hit: (target: String, date: String)) -> some View {
        Button {
            appState.pendingTargetSegment = .sessions
            appState.pendingSessionSelection = hit.date
            appState.currentPage = .target(hit.target)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.date).bold()
                    Text(hit.target).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ hit: (path: String, kind: String, sizeBytes: Int64)) -> some View {
        let url = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).appendingPathComponent(hit.path)
        let parentTarget = parentTarget(of: hit.path)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text((hit.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(hit.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(TDFormat.bytes(hit.sizeBytes)).font(.caption).foregroundStyle(.secondary)
            if let parentTarget {
                Button("Célpont") { appState.currentPage = .target(parentTarget) }
                    .buttonStyle(.link).font(.caption)
            }
            Button("Finderben") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func noteRow(_ hit: (target: String, date: String, key: String, value: String)) -> some View {
        Button {
            appState.pendingTargetSegment = .notes
            appState.currentPage = .target(hit.target)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(hit.key): \(hit.value)").lineLimit(1)
                    Text("\(hit.target) · \(hit.date)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The target folder a `sessions/<target>/...` path belongs to, `nil`
    /// for a file outside `sessions/` (e.g. `calibration_library/`) --
    /// those files have no single "parent target" link to offer.
    private func parentTarget(of path: String) -> String? {
        let components = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == "sessions" else { return nil }
        return String(components[1])
    }
}
