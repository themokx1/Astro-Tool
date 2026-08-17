import AppKit
import AstroApplication
import Foundation
import SwiftUI

// MARK: - ArchiveView
//
// `ArchiveVerdict`, `ArchiveVerdictDetail`, and `ArchiveVerdictHeader` live in
// the sibling file `ArchiveVerdict.swift` -- this file alone would otherwise
// pass ~550 lines.

/// The Archive page: the redesigned home for what used to be the old
/// `LibraryView` (three counter cards, now deleted) plus `HealthView`'s
/// findings table, folded into one screen that leads with a verdict
/// sentence instead of filler copy. Toolbar actions and the actual audit run
/// are taken as injected closures -- this view never wires them to a
/// concrete store itself; `V2RootView` (Task 10) wires `runAudit` to
/// `LibraryHealthStore.runAudit` and builds this view for both its `.library`
/// and (for backward-compatible restoration only) `.health` routes.
public struct ArchiveView: View {
    let rootURL: URL?
    /// Accepted for parity with `HealthView`'s own initializer, and for a
    /// future write-enabled action on this page, but
    /// not rendered as its own badge today: every action this page performs
    /// directly (Check Library, Rescan) is read-only regardless of this
    /// value -- same reasoning as `HealthView.subtitleText`'s own doc
    /// comment -- and the write-capable actions it links to (Cleanup
    /// Preview, Organize One Session) already show their own access-mode
    /// state on their own pages.
    let accessMode: LibraryAccessMode
    let chooseLibrary: () -> Void
    let rescan: () -> Void
    let convertSession: () -> Void
    /// Pushes the existing, already-tested Cleanup Preview page, carrying
    /// along whichever `CleanupPreviewGroup.category` values the triggering
    /// action already knows about. Task 10 prerequisite: `CleanupPreviewStore`
    /// now supports pre-checking categories (`preselect(_:)`), so a task
    /// card's own `.previewQuarantine(categories:)` action passes them
    /// straight through here rather than promising the filtering it cannot
    /// deliver, as an earlier version of this doc comment claimed. The
    /// Targets section's own bare "Preview Quarantine…" row (no specific
    /// category in play there) calls this with an empty set, which leaves
    /// `CleanupPreviewStore.selectedCategories` at its own default. The
    /// caller (`V2RootView`'s `.library`/`.health` destinations) is expected
    /// to stash the categories on `AppRouter.pendingCleanupCategories`
    /// before pushing `.cleanup` -- this view has no `router` of its own to
    /// do that itself.
    let openQuarantinePreview: (Set<String>) -> Void
    /// Task 3 (wave 3): pushes `ArchiveTaskDetailView` for a card whose own
    /// `ArchiveTaskAction.showFindings(kind:)` fired -- i.e. its finding
    /// count is greater than one, so its own primary button can no longer
    /// honestly hand back a single arbitrary path (see that action's own
    /// doc comment for the wave 1 bug this replaces).
    let openTaskDetail: (ArchiveTaskKind) -> Void
    /// Runs the read-only audit. Never called directly by this view for
    /// "Run Check" task-card presses without going through this same
    /// closure -- there is exactly one audit entry point, matching the
    /// toolbar's own "Check Library" action.
    let runAudit: (AuditRunMode) -> Void
    @Bindable var store: ArchiveStore

    @Environment(OperationHost.self) private var operationHost
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix pattern: see `HealthView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString
    @State private var verdict: ArchiveVerdict?
    @State private var maxTargetBytes: Int64 = 0
    @State private var acknowledgeRequest: ArchiveTask?

    public init(
        rootURL: URL?,
        accessMode: LibraryAccessMode = .readOnly,
        chooseLibrary: @escaping () -> Void,
        rescan: @escaping () -> Void,
        convertSession: @escaping () -> Void,
        openQuarantinePreview: @escaping (Set<String>) -> Void,
        openTaskDetail: @escaping (ArchiveTaskKind) -> Void,
        runAudit: @escaping (AuditRunMode) -> Void,
        store: ArchiveStore = ArchiveStore()
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.chooseLibrary = chooseLibrary
        self.rescan = rescan
        self.convertSession = convertSession
        self.openQuarantinePreview = openQuarantinePreview
        self.openTaskDetail = openTaskDetail
        self.runAudit = runAudit
        self.store = store
    }

    public var body: some View {
        Group {
            if rootURL == nil {
                noLibraryState
            } else if store.isLoading && store.snapshot == nil {
                ProgressView("Reading the archive…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = store.errorMessage {
                errorState(message)
            } else if let snapshot = store.snapshot {
                if snapshot.totalBytes == 0 {
                    emptyLibraryState
                } else {
                    loadedState(snapshot: snapshot)
                }
            } else {
                // rootURL is set but nothing has loaded, failed, or is
                // marked loading yet -- the instant before `.task(id:
                // rootURL)` first fires. Same honest "reading" state as the
                // loading branch above, never a blank screen.
                ProgressView("Reading the archive…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AstroTokens.Color.ground.opacity(0.36))
        .navigationTitle("Archive")
        .accessibilityLabel("Archive")
        .accessibilityIdentifier("v2.detail.library")
        .task(id: rootURL) { if let rootURL { await store.load(rootURL: rootURL) } }
        .task(id: store.snapshot) { recomputeDerivedState() }
        .task(id: store.tasks) { recomputeDerivedState() }
        // Wave 4 Task 2 pattern (see `HealthView.swift`'s own comment at the
        // same spot): published from discrete lifecycle/state-change events,
        // never from `body` itself -- that is what turned a `FocusedValues`
        // publish into a 100% CPU invalidation loop through the toolbar in
        // an earlier build (`WorkspaceActionCenter`'s own doc comment has
        // the full incident). `runningAuditOperation` derives from
        // `operationHost.activeOperations`, which changes independently of
        // any route/selection change, so it is watched here explicitly.
        .onAppear { publishWorkspaceActions() }
        .onChange(of: rootURL) { _, _ in publishWorkspaceActions() }
        .onChange(of: operationHost.activeOperations) { _, _ in publishWorkspaceActions() }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
        .sheet(item: $acknowledgeRequest) { task in
            ArchiveAcknowledgeSheet(
                task: task,
                onAcknowledge: { note in
                    Task {
                        await acknowledge(task, note: note)
                        acknowledgeRequest = nil
                    }
                },
                onCancel: { acknowledgeRequest = nil }
            )
        }
    }

    // MARK: Required state branches

    private var noLibraryState: some View {
        ContentUnavailableView {
            Label("No library open", systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text("Choose a folder to build a local, read-only index. Your image files stay untouched.")
        } actions: {
            Button("Choose Image Library…", action: chooseLibrary)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.archive.choose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could not read the archive", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { if let rootURL { await store.load(rootURL: rootURL) } }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("v2.archive.try-again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("Nothing indexed yet", systemImage: "tray")
        } description: {
            Text("This library has not been scanned yet, or every file in it is currently missing.")
        } actions: {
            Button("Rescan", action: rescan)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.archive.rescan-empty")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded state -- non-scrolling root, one scrolling List

    /// Non-scrolling outer `VStack` with exactly one scrolling `List` inside
    /// it, given a genuinely bounded height by `.frame(maxHeight: .infinity)`
    /// -- the same shape `WorkspaceTablePage`'s own doc comment prescribes
    /// (read it in full at `Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift`)
    /// and for the same reason: an unbounded-height container proposes
    /// unlimited height to whatever is inside it, so AppKit cannot
    /// virtualize rows and lays out every one of them on every pass. This
    /// page does not reuse that component directly because its own verdict
    /// sentence and strip need to render large and prominent above the
    /// fold, not inside a muted subtitle line -- but the underlying
    /// non-scrolling-root-plus-one-list shape is identical.
    @ViewBuilder
    private func loadedState(snapshot: ArchiveMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            if let verdict {
                ArchiveVerdictHeader(verdict: verdict)
            }
            ArchiveStripView(
                slices: snapshot.slices,
                reclaimableBytes: snapshot.reclaimableBytes,
                totalBytes: snapshot.totalBytes,
                selectedClass: store.selectedClass,
                onSelect: { store.selectedClass = $0 }
            )
            List {
                if !store.tasks.isEmpty {
                    Section("Needs you") {
                        ForEach(store.tasks) { task in
                            ArchiveTaskCard(
                                task: task,
                                onAction: { perform($0) },
                                onAcknowledge: { acknowledgeRequest = task }
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                    }
                }
                Section("Targets") {
                    ForEach(store.visibleRows) { row in
                        ArchiveTargetRowView(
                            row: row,
                            maxTargetBytes: maxTargetBytes,
                            onRevealInFinder: { revealInFinder(row: row) },
                            onPreviewQuarantine: { openQuarantinePreview([]) }
                        )
                    }
                }
                if !store.uncovered.isEmpty {
                    uncoveredFooterRow
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("v2.archive.list")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    /// What `ArchiveTaskQuery` intentionally could not turn into a card --
    /// see `UncoveredFindings`'s own doc comment. Rendered quietly at the
    /// bottom of the list rather than dropped: four cards and nothing else
    /// would read as complete coverage, and it is not one.
    private var uncoveredFooterRow: some View {
        Text("\(store.uncovered.count.formatted()) more findings in categories this page has no action for · \(ByteCountFormatter.string(fromByteCount: store.uncovered.bytes, countStyle: .file))")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help(uncoveredCategoryBreakdown())
            .accessibilityIdentifier("v2.archive.uncovered")
    }

    /// Category names here are the audit engine's own raw `findings.category`
    /// values (e.g. `capture-unassigned-artifact`), not authored UI
    /// vocabulary -- there is no natural-language phrase to localize, only a
    /// literal accounting of what the footer line's count is made of, so
    /// this is verbatim data, not a translatable sentence.
    private func uncoveredCategoryBreakdown() -> String {
        store.uncovered.categories
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    // MARK: Derived state -- computed once per snapshot/tasks change, never in body

    private func recomputeDerivedState() {
        guard let snapshot = store.snapshot else {
            verdict = nil
            maxTargetBytes = 0
            return
        }
        verdict = ArchiveVerdict(tasks: store.tasks, snapshot: snapshot)
        maxTargetBytes = snapshot.rows.map(\.totalBytes).max() ?? 0
    }

    // MARK: Task card actions

    private func perform(_ action: ArchiveTaskAction) {
        switch action {
        case .previewQuarantine(let categories):
            openQuarantinePreview(Set(categories))
        case .revealInFinder(let path):
            revealInFinder(relativePath: path)
        case .showFindings(let kind):
            openTaskDetail(kind)
        case .runAudit:
            runAudit(.full)
        case .unavailable:
            // `ArchiveTaskQuery` gates this out before a card is ever built
            // (`ArchiveTaskQueryTests.everyCardIsActionable`) -- reachable
            // here only if that gate regresses, in which case doing nothing
            // is the safe failure.
            break
        }
    }

    /// Reveals a finding's own evidence path -- a real, stored relative path
    /// from `files.path`, validated the same way `CalibrationView.masterURL`
    /// and `ConversionWorkspace`'s receipt reveal already do: resolve under
    /// `rootURL`, confirm it did not escape the library root, confirm it
    /// still exists, and only then hand it to Finder. Any failure falls back
    /// to revealing the library root itself rather than doing nothing.
    private func revealInFinder(relativePath: String) {
        guard let rootURL else { return }
        let root = rootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path), FileManager.default.fileExists(atPath: candidate.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }

    /// A target row only carries its own folder NAME
    /// (`ArchiveTargetRow.target`), not a stored path -- the scanner's
    /// `target` is a logical grouping key that can legitimately correspond
    /// to up to three real folders (`sessions/<target>`, `stacks/<target>`,
    /// `processed/<target>`), never a bare `rootURL/<target>`. This tries
    /// each known area in turn and reveals the first one that actually
    /// exists; the untargeted bucket and a target with none of the three
    /// present both fall back to the library root, matching
    /// `HealthView.revealLibraryInFinder`'s own "no concrete path" honesty.
    private func revealInFinder(row: ArchiveTargetRow) {
        guard let rootURL else { return }
        let root = rootURL.standardizedFileURL
        if let target = row.target {
            for area in ["sessions", "stacks", "processed"] {
                let candidate = root.appendingPathComponent(area).appendingPathComponent(target)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    NSWorkspace.shared.activateFileViewerSelecting([candidate])
                    return
                }
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: Acknowledge

    private func acknowledge(_ task: ArchiveTask, note: String?) async {
        guard let rootURL else { return }
        do {
            let identity = LibraryIdentity(rootURL: rootURL)
            let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let metadata = try MetadataStore(storagePaths: storage)
            try await metadata.acknowledgeFindingGroup(category: ArchiveTask.ackCategory, groupKey: task.ackGroupKey, note: note)
            await store.load(rootURL: rootURL)
        } catch {
            // Best-effort: a failed metadata write just leaves the card
            // visible, which is the safe outcome -- there is nothing else
            // actionable to show for it here.
        }
    }

    // MARK: Toolbar actions -- published on lifecycle events only, never body

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .menu(WorkspaceActionMenu(
                id: "v2.archive.check",
                title: "Check Library",
                help: "Read through the library for leftovers, duplicates, and structural problems",
                isDisabled: rootURL == nil || runningAuditOperation != nil,
                items: [
                    WorkspaceMenuItem(id: "v2.archive.check.fast", title: "Fast (Skip Duplicate Scan)") {
                        runAudit(.fast)
                    },
                ],
                primaryAction: { runAudit(.full) }
            )),
            .button(WorkspaceAction(
                id: "v2.archive.rescan",
                title: "Rescan",
                systemImage: "arrow.clockwise",
                help: "Re-read the library folder for new or changed files (⌘R)",
                action: rescan
            )),
            .button(WorkspaceAction(
                id: "v2.archive.organize",
                title: "Organize One Session…",
                systemImage: "folder.badge.gearshape",
                action: convertSession
            )),
            .button(WorkspaceAction(
                id: "v2.archive.change",
                title: "Change Library…",
                systemImage: "externaldrive",
                action: chooseLibrary
            )),
        ])
    }

    private var runningAuditOperation: OperationHost.ActiveOperation? {
        guard let rootURL else { return nil }
        let kind = OperationKind.audit(library: rootURL.standardizedFileURL.path)
        return operationHost.activeOperations.first { $0.kind == kind }
    }
}

/// Confirms acknowledging one archive task, with an optional note -- the
/// same shape as `HealthView`'s own `AcknowledgeFindingSheet`, kept as a
/// private sibling here rather than shared because the two acknowledge
/// different underlying record types (`LibraryHealthItem` vs `ArchiveTask`).
private struct ArchiveAcknowledgeSheet: View {
    let task: ArchiveTask
    let onAcknowledge: (String?) -> Void
    let onCancel: () -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Mark as Acknowledged").font(.title3.bold())
            Text("This card will not show again for this kind of finding unless it recurs after a new check.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Optional note", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.archive.acknowledge-note")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Acknowledge") {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAcknowledge(trimmed.isEmpty ? nil : trimmed)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.archive.acknowledge-confirm")
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(width: 420)
    }
}
