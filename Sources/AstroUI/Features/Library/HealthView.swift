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
    @State private var selectedFindingID: String?

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
                    Table(filteredItems(snapshot), selection: $selectedFindingID) {
                        TableColumn("Finding") { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(item.severity)).foregroundStyle(color(item.severity))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline)
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        TableColumn("Target / Night") { item in
                            Text([item.target, item.sessionDate].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
                                .font(.callout.monospaced())
                        }
                        .width(min: 145, ideal: 190)
                        TableColumn("Category") { item in
                            Text(item.category.rawValue.capitalized)
                        }
                        .width(min: 90, ideal: 110)
                        TableColumn("Next step") { item in
                            Text(nextStep(item.category)).foregroundStyle(AstroTokens.Color.spectralBlue)
                        }
                        .width(min: 115, ideal: 145)
                    }
                    .frame(minHeight: 250)
                    .contextMenu(forSelectionType: String.self) { findingIDs in
                        if let item = filteredItems(snapshot).first(where: { findingIDs.contains($0.id) }) {
                            healthActionMenu(item)
                        }
                    }
                    .accessibilityIdentifier("v2.health.findings-table")
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

    private func filteredItems(_ snapshot: LibraryHealthSnapshot) -> [LibraryHealthItem] {
        snapshot.items.filter { category == nil || $0.category == category }
    }

    @ViewBuilder
    private func healthActionMenu(_ item: LibraryHealthItem) -> some View {
        switch item.category {
        case .duplicates, .organization, .storage:
            Button("Preview Cleanup…") { showsCleanup = true }
        case .flat, .dark, .bias:
            Button("Review Sensor Profiles…") { showsSensors = true }
        case .integrity:
            Text("No action required")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
