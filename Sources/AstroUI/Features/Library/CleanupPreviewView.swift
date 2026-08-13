import AstroApplication
import SwiftUI

@MainActor
@Observable
private final class CleanupPreviewStore {
    var snapshot: CleanupPreviewSnapshot?
    var isLoading = false
    var errorMessage: String?

    func load(rootURL: URL) async {
        isLoading = true
        defer { isLoading = false }
        do { snapshot = try await CleanupPreviewQuery.production(rootURL: rootURL).snapshot() }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct CleanupPreviewView: View {
    let rootURL: URL
    let dismiss: () -> Void
    @State private var store = CleanupPreviewStore()

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "archivebox").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Cleanup Preview").font(.title2.bold())
                    Text("Review candidates before any quarantine operation.").foregroundStyle(.secondary)
                }
                Spacer(); Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            Group {
                if store.isLoading { ProgressView("Reading cleanup candidates…") }
                else if let snapshot = store.snapshot { preview(snapshot) }
                else { ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(store.errorMessage ?? "No cleanup index is available.")) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Label("Preview only · no files moved", systemImage: "lock.shield").foregroundStyle(.green)
                Spacer()
                Button("Quarantine is not enabled yet") {}.disabled(true)
            }.padding(16)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(.background)
        .task { await store.load(rootURL: rootURL) }
        .accessibilityIdentifier("v2.cleanup.preview")
    }

    private func preview(_ snapshot: CleanupPreviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    MetricCard(title: "Candidates", value: "\(snapshot.groups.reduce(0) { $0 + $1.fileCount })", detail: "Nothing selected automatically", systemImage: "doc.on.doc")
                    MetricCard(title: "Recoverable", value: ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file), detail: "If every candidate is approved", systemImage: "internaldrive")
                }
                if snapshot.groups.isEmpty {
                    ContentUnavailableView("Nothing to clean up", systemImage: "checkmark.circle", description: Text("The external index contains no recognized residue or cached duplicates."))
                }
                ForEach(snapshot.groups) { group in
                    GroupBox(categoryTitle(group.category)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(group.fileCount) files · \(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))")
                                .font(.headline)
                            ForEach(group.paths, id: \.self) { path in
                                Label(path, systemImage: "doc").font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if group.truncatedCount > 0 { Text("+ \(group.truncatedCount) more").foregroundStyle(.secondary) }
                            Label("Proposed action: move to quarantine · never delete", systemImage: "archivebox")
                                .font(.caption).foregroundStyle(.orange)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }.padding(24)
        }
    }

    private func categoryTitle(_ category: String) -> String {
        category.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
