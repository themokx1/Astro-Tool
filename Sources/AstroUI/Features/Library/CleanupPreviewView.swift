import AstroApplication
import SwiftUI

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: this used to be a
/// `private final class` with `CleanupPreviewQuery.production` called
/// directly inside its own methods, so this whole screen had zero
/// unit-test surface. Follows `LibraryHealthStore`'s query-factory
/// injection pattern so tests can supply a fixture-backed
/// `CleanupPreviewQuery` without touching the filesystem-resolving
/// `production` constructor.
@MainActor
@Observable
public final class CleanupPreviewStore {
    public typealias QueryFactory = @Sendable (URL, LibraryAccessMode) throws -> CleanupPreviewQuery

    public private(set) var snapshot: CleanupPreviewSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var selectedCategories: Set<String> = []
    public private(set) var planErrorMessage: String?

    private let queryFactory: QueryFactory
    private var rootURL: URL?
    private var accessMode: LibraryAccessMode = .readOnly

    public init(
        queryFactory: @escaping QueryFactory = { rootURL, accessMode in
            try CleanupPreviewQuery.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.queryFactory = queryFactory
    }

    public func load(rootURL: URL, accessMode: LibraryAccessMode) async {
        isLoading = true
        self.rootURL = rootURL
        self.accessMode = accessMode
        defer { isLoading = false }
        do {
            snapshot = try await queryFactory(rootURL, accessMode).snapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleSelection(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }

    /// Task 10 prerequisite: pre-checks `categories` before the user has
    /// touched a single `Toggle` -- the Archive page's task cards already
    /// know exactly which categories their own "Preview Quarantine…" action
    /// covers, so there is no reason to make the user re-select them here by
    /// hand. Equal-value guarded like every other setter in this codebase:
    /// `@Observable` signals a mutation regardless of equality, and an
    /// unguarded assignment here (called from `CleanupPreviewView.init`
    /// every time its own default argument is re-evaluated) is exactly the
    /// shape that produced this project's one prior infinite transaction
    /// loop.
    public func preselect(_ categories: Set<String>) {
        guard selectedCategories != categories else { return }
        selectedCategories = categories
    }

    /// Builds the quarantine plan for whichever groups are currently
    /// selected -- available regardless of `accessMode` (building a plan
    /// never writes anything); `QuarantineApplyCommand.apply` is what
    /// actually gates on write access, once the confirmation sheet is
    /// shown.
    public func buildPlan() -> LibraryMutationPlan? {
        guard let rootURL, !selectedCategories.isEmpty else { return nil }
        planErrorMessage = nil
        do {
            return try queryFactory(rootURL, accessMode)
                .plan(selecting: selectedCategories, confirmationToken: UUID().uuidString)
        } catch {
            planErrorMessage = error.localizedDescription
            return nil
        }
    }
}

public struct CleanupPreviewView: View {
    let rootURL: URL
    let accessMode: LibraryAccessMode
    let presentQuarantineApply: (LibraryMutationPlan) -> Void
    @State private var store: CleanupPreviewStore

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode = .readOnly,
        presentQuarantineApply: @escaping (LibraryMutationPlan) -> Void = { _ in },
        /// Task 10 prerequisite: the Archive page's task cards preset this
        /// through `AppRouter.pendingCleanupCategories` (see its own doc
        /// comment) right before pushing `.cleanup` -- `nil` (every OTHER
        /// call site, e.g. Health's plain "Cleanup Preview" action) leaves
        /// `store`'s selection at its own default, empty set.
        initialCategories: Set<String>? = nil,
        store: CleanupPreviewStore = CleanupPreviewStore()
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.presentQuarantineApply = presentQuarantineApply
        if let initialCategories {
            store.preselect(initialCategories)
        }
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "archivebox").font(.title2).foregroundStyle(AstroTokens.Color.attention)
                VStack(alignment: .leading) {
                    Text("Cleanup Preview").font(.title2.bold())
                    Text("Review candidates before any quarantine operation.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            Group {
                if store.isLoading { ProgressView("Reading cleanup candidates…") }
                else if let snapshot = store.snapshot { preview(snapshot) }
                else { ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(store.errorMessage ?? "No cleanup index is available.")) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Label("Preview only · no files moved", systemImage: "lock.shield").foregroundStyle(AstroTokens.Color.ok)
                Spacer()
                if accessMode != .mutationEnabled {
                    Label("Requires write access. Enable write operations in Settings to apply quarantine.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let planErrorMessage = store.planErrorMessage {
                    Text(planErrorMessage).font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                Button("Apply Quarantine…") {
                    if let plan = store.buildPlan() { presentQuarantineApply(plan) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(accessMode != .mutationEnabled || store.selectedCategories.isEmpty)
                .accessibilityIdentifier("v2.cleanup.apply-quarantine")
            }.padding(16)
        }
        .background(.background)
        .task { await store.load(rootURL: rootURL, accessMode: accessMode) }
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
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { store.selectedCategories.contains(group.category) },
                                    set: { _ in store.toggleSelection(group.category) }
                                )) {
                                    Text("\(group.fileCount) files · \(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))")
                                        .font(.headline)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("v2.cleanup.select.\(group.category)")
                            }
                            ForEach(group.paths, id: \.self) { path in
                                Label(path, systemImage: "doc").font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if group.truncatedCount > 0 { Text("+ \(group.truncatedCount) more").foregroundStyle(.secondary) }
                            Label("Proposed action: move to quarantine · never delete", systemImage: "archivebox")
                                .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }.padding(24)
        }
        .accessibilityIdentifier("v2.cleanup.groups")
    }

    private func categoryTitle(_ category: String) -> String {
        category.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
