import AstroApplication
import Observation
import SwiftUI

@MainActor @Observable
public final class LibraryHealthStore {
    public private(set) var snapshot: LibraryHealthSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    public func load(rootURL: URL) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { snapshot = try await LibraryHealthQuery.production(rootURL: rootURL).snapshot() }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct HealthView: View {
    let rootURL: URL?
    let chooseLibrary: () -> Void
    @State private var store = LibraryHealthStore()
    @State private var showsCleanup = false

    public var body: some View {
        WorkspacePage(eyebrow: "Read-only diagnostics", title: "Library Health", subtitle: "Actionable calibration and integrity checks without changing source files.") {
            if let snapshot = store.snapshot {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Sessions", value: "\(snapshot.sessionCount)", detail: "Indexed nights", systemImage: "moon.stars")
                    MetricCard(title: "Calibration", value: "\(snapshot.calibrationIssues)", detail: "Needs attention", systemImage: "exclamationmark.triangle")
                    MetricCard(title: "Access", value: snapshot.isReadOnly ? "Read only" : "Writable", detail: "Images protected", systemImage: "lock.shield")
                }
                GroupBox("Health findings") {
                    VStack(spacing: 0) {
                        ForEach(snapshot.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon(item.severity)).foregroundStyle(color(item.severity))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline)
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.category.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }.padding(.horizontal, 8)
                }
                Button("Review Cleanup Candidates…") { showsCleanup = true }
                    .buttonStyle(.bordered)
            } else if store.isLoading {
                ProgressView("Checking library health…").frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ContentUnavailableView {
                    Label("No library open", systemImage: "externaldrive.badge.questionmark")
                } description: { Text(store.errorMessage ?? "Choose an image library to run read-only health checks.") }
                actions: { Button("Choose Image Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                .frame(minHeight: 300)
            }
        }
        .task(id: rootURL) { if let rootURL { await store.load(rootURL: rootURL) } }
        .navigationTitle("Library Health")
        .accessibilityLabel("Library Health")
        .accessibilityIdentifier("v2.detail.library.health")
        .overlay {
            if showsCleanup, let rootURL {
                CleanupPreviewView(rootURL: rootURL) { showsCleanup = false }
            }
        }
    }

    private func icon(_ severity: LibraryHealthSeverity) -> String { severity == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    private func color(_ severity: LibraryHealthSeverity) -> Color { severity == .healthy ? .green : .orange }
}
