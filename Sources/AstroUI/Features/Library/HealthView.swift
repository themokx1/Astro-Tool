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
    @State private var showsSensors = false
    @State private var category: LibraryHealthCategory?

    public var body: some View {
        WorkspacePage(eyebrow: "Read-only diagnostics", title: "Library Health", subtitle: "Actionable calibration and integrity checks without changing source files.") {
            if let snapshot = store.snapshot {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Sessions", value: "\(snapshot.sessionCount)", detail: "Indexed nights", systemImage: "moon.stars")
                    MetricCard(title: "Calibration", value: "\(snapshot.calibrationIssues)", detail: "Needs attention", systemImage: "exclamationmark.triangle")
                    MetricCard(title: "Duplicates", value: "\(snapshot.duplicateFiles)", detail: "Additional copies", systemImage: "square.on.square")
                    MetricCard(title: "Organization", value: "\(snapshot.organizationIssues)", detail: "Reviewable residue", systemImage: "tray.full")
                    MetricCard(title: "Access", value: snapshot.isReadOnly ? "Read only" : "Writable", detail: "Images protected", systemImage: "lock.shield")
                }
                Picker("Category", selection: $category) {
                    Text("All findings").tag(LibraryHealthCategory?.none)
                    ForEach(LibraryHealthCategory.allCases, id: \.rawValue) { value in
                        Text(value.rawValue.capitalized).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.health.categories")
                GroupBox("Health findings") {
                    VStack(spacing: 0) {
                        ForEach(snapshot.items.filter { category == nil || $0.category == category }) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: icon(item.severity)).foregroundStyle(color(item.severity))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline)
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(item.category.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                    Text(nextStep(item.category)).font(.caption2).foregroundStyle(AstroTokens.Color.spectralBlue)
                                }
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }.padding(.horizontal, 8)
                }
                HStack {
                    Button("Review Cleanup Candidates…") { showsCleanup = true }.buttonStyle(.bordered)
                    Button("Sensor Profiles…") { showsSensors = true }.buttonStyle(.bordered)
                }
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
            } else if showsSensors, let rootURL {
                SensorProfilesView(rootURL: rootURL) { showsSensors = false }
            }
        }
    }

    private func icon(_ severity: LibraryHealthSeverity) -> String { severity == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    private func color(_ severity: LibraryHealthSeverity) -> Color { severity == .healthy ? .green : .orange }
    private func nextStep(_ category: LibraryHealthCategory) -> String {
        switch category {
        case .flat, .dark, .bias: "Review calibration"
        case .duplicates, .organization, .storage: "Preview cleanup"
        case .integrity: "No action needed"
        }
    }
}
