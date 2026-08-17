import AppKit
import AstroApplication
import Foundation
import SwiftUI

/// The route `ArchiveTaskAction.showFindings(kind:)` pushes to -- Task 3
/// (wave 3)'s fix for the wave 1 design error where a card's single
/// `revealInFinder(path:)` action carried only the FIRST of a kind's
/// findings, arbitrarily, whenever there was more than one ("33 kalibráció
/// rossz mappában" opened one of the 33 and silently dropped the other 32).
/// This page shows every one of that kind's findings, grouped by parent
/// folder (W4-7 item 3, owner review: "28 identical bias files from one
/// folder" used to read as 28 flat rows), each with its own real path and
/// its own reveal-in-Finder button, plus a selection-gated bulk quarantine
/// action where the kind supports one (`ArchiveTaskKind
/// .supportsBulkQuarantinePreview`) and an honest "what to do instead" row
/// where it does not.
///
/// Follows `WorkspaceTablePage`'s non-scrolling-root-plus-one-`Table` shape
/// (see `HealthView`'s own findings table for the established precedent) --
/// the real library's own worst card covers 3 231 findings, and a `Table`
/// nested inside a scrolling container is proposed unbounded height, so
/// AppKit cannot virtualize it and lays out every row on every pass (the
/// exact freeze this project spent five rounds fixing elsewhere; see
/// `WorkspaceTablePage`'s own doc comment for the incident). `store.rows`
/// is grouped once via `ArchiveTaskDetailStore`'s generation-guarded `load`,
/// never re-derived from a computed getter or from `body` itself.
public struct ArchiveTaskDetailView: View {
    let rootURL: URL
    let kind: ArchiveTaskKind
    /// Defaults closed (`.readOnly`) rather than open: a caller that has not
    /// been updated to pass the library's real access mode gets a page whose
    /// mutation-gated action stays disabled, never one that silently gains
    /// write access it was never told it had.
    let accessMode: LibraryAccessMode
    /// Pushes the existing Cleanup Preview route, pre-checked to this kind's
    /// own categories -- the same hand-off `ArchiveView`'s own
    /// `openQuarantinePreview` closure already documents, reused verbatim so
    /// both surfaces land on the exact same, already-tested destination.
    let openQuarantinePreview: (Set<String>) -> Void
    /// Re-runs the same audit `ArchiveView`'s own toolbar "Check Library"
    /// action already triggers -- offered here only for `.unverified`, whose
    /// honest "instead" action (see this type's own `actionRow`) is "look
    /// again", not "move something". `nil` (its default) degrades to plain
    /// guidance text pointing at that same toolbar action instead of a
    /// button with nothing wired behind it.
    let runCheck: (() -> Void)?
    @Bindable var store: ArchiveTaskDetailStore
    /// The page's own selection -- native `Table` row selection, unused
    /// until now. W4-7 item 3 (owner review): "there is nothing to DO on
    /// the page" -- the bulk quarantine action below is gated on this being
    /// non-empty, so pressing it is always a deliberate, reviewed choice,
    /// never an accidental whole-category sweep triggered by opening the
    /// page. Selecting a folder row does not implicitly select its
    /// children: the button's own `.help` text says plainly that it queues
    /// this KIND's whole category (identical to what the toolbar's own
    /// "Preview Quarantine…" already did) for the next screen's per-item
    /// preview, never only the highlighted rows -- the underlying
    /// `CleanupPreviewQuery.plan(selecting:)` has no finer-grained mechanism
    /// than a category, and inventing one here would be exactly the "new
    /// mutation path" this task's own iron rule forbids.
    @State private var selection: Set<String> = []

    public init(
        rootURL: URL,
        kind: ArchiveTaskKind,
        openQuarantinePreview: @escaping (Set<String>) -> Void,
        runCheck: (() -> Void)? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        store: ArchiveTaskDetailStore = ArchiveTaskDetailStore()
    ) {
        self.rootURL = rootURL
        self.kind = kind
        self.openQuarantinePreview = openQuarantinePreview
        self.runCheck = runCheck
        self.accessMode = accessMode
        self.store = store
    }

    public var body: some View {
        WorkspaceTablePage(subtitle: "Every finding behind this card, grouped by the folder it lives in.") {
            toolbarContent
        } table: {
            tableContent
        } footer: {
            actionRow
        }
        .task { await store.load(rootURL: rootURL, kind: kind) }
        .onChange(of: store.rows) { _, _ in selection.removeAll() }
        .navigationTitle(ArchiveTaskPresentation.title(for: kind))
        .accessibilityIdentifier("v2.archive.task-detail.\(kind.rawValue)")
    }

    @ViewBuilder
    private var toolbarContent: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            if store.isLoading, store.findings.isEmpty {
                ProgressView().controlSize(.small)
            }
            Text("\(store.findings.count.formatted()) finding(s) · \(Self.formatBytes(store.totalBytes))")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var tableContent: some View {
        if store.isLoading, store.findings.isEmpty {
            ProgressView("Loading findings…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage {
            ContentUnavailableView {
                Label("Could not read findings", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.findings.isEmpty {
            ContentUnavailableView {
                Label("Nothing here anymore", systemImage: "checkmark.circle")
            } description: {
                Text("A newer check no longer finds anything of this kind.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Task 7 (2026-08-17, GroupBox removal): heading + Divider +
            // Table, `ReviewWorkspace.frameReview`'s own shape --
            // `WorkspaceTablePage` already gives this whole `table:` slot
            // one solid `AstroTokens.Color.surface` background, so a
            // `GroupBox` here painted a second, opaque box inside it (the
            // exact "box in a box" the owner reported). The heading text
            // stays a plain sibling of the `Table`, never its glassed
            // container, so `noTableOrListHasAGlassParent` still holds.
            VStack(alignment: .leading, spacing: 0) {
                Text("All findings").font(.headline)
                    .padding(.horizontal, AstroTokens.Spacing.standard)
                    .padding(.vertical, AstroTokens.Spacing.compact)
                Divider()
                // `Table(children:)` -- the same hierarchical shape
                // `ResultsView.resultTable` already established for stack
                // families/variants -- so a folder heading and its files
                // read as one page-level convention, not a bespoke one
                // invented here.
                Table(store.rows, children: \.children, selection: $selection) {
                    TableColumn("Path") { row in pathCell(row) }
                    TableColumn("Size") { row in sizeCell(row) }
                        .width(min: 70, ideal: 90)
                    TableColumn("") { row in revealButton(row) }
                        .width(36)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("v2.archive.task-detail.table")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A folder row renders its own heading -- file count and folder path,
    /// bold, with a folder glyph -- and NEVER through the same cell a file
    /// row uses. W4-7 item 3 (owner review): "the first row is a bare
    /// FOLDER shown with 0 KB among files" was exactly this ambiguity; a
    /// `switch` over `row.kind` makes the two cases structurally impossible
    /// to render the same way, rather than relying on some shared field
    /// (like a fake zero byte count) to tell them apart.
    @ViewBuilder
    private func pathCell(_ row: ArchiveFindingRow) -> some View {
        switch row.kind {
        case .folder(let path, let fileCount, _):
            Label {
                Text("\(fileCount) files · \(path)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
            }
        case .finding(let finding):
            Text(finding.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func sizeCell(_ row: ArchiveFindingRow) -> some View {
        switch row.kind {
        case .folder(_, _, let bytes):
            Text(Self.formatBytes(bytes))
                .monospacedDigit()
                .font(.callout.weight(.semibold))
        case .finding(let finding):
            Text(Self.formatBytes(finding.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func revealButton(_ row: ArchiveFindingRow) -> some View {
        let path: String = {
            switch row.kind {
            case .folder(let folderPath, _, _): folderPath
            case .finding(let finding): finding.path
            }
        }()
        Button {
            revealInFinder(path: path)
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Reveal in Finder")
    }

    // MARK: Footer action row -- Task 3 (W4-7 item 3, owner review): "there
    // is nothing to DO on the page"

    /// One of two shapes, decided once by `kind.supportsBulkQuarantinePreview`
    /// -- never both at once, so the page never offers an action next to a
    /// sentence explaining why there isn't one.
    @ViewBuilder
    private var actionRow: some View {
        if !store.rows.isEmpty {
            if kind.supportsBulkQuarantinePreview {
                quarantineActionRow
            } else {
                noQuarantineActionRow
            }
        }
    }

    private var quarantineActionRow: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            Text(selectionSummaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Move to Quarantine…") {
                openQuarantinePreview(Set(kind.findingCategories))
            }
            .buttonStyle(.glassProminent)
            .disabled(selection.isEmpty || accessMode != .mutationEnabled)
            .help(quarantineActionHelpText)
            .accessibilityIdentifier("v2.archive.task-detail.quarantine")
        }
    }

    private var selectionSummaryText: LocalizedStringKey {
        selection.isEmpty
            ? "Select one or more rows to continue"
            : "\(selection.count) row(s) selected"
    }

    /// Explains the disabled state in place, matching this task's own rule
    /// ("disabled state explains itself when read-only") -- the same
    /// pattern `CleanupPreviewView`'s own Apply button already follows for
    /// the identical `accessMode != .mutationEnabled` gate.
    private var quarantineActionHelpText: LocalizedStringKey {
        if accessMode != .mutationEnabled {
            "Requires write access. Enable write operations in Settings to move these to quarantine."
        } else if selection.isEmpty {
            "Select one or more rows to continue"
        } else {
            "Moves this finding's whole category into quarantine for review, not only the selected rows -- confirm on the next screen before anything moves."
        }
    }

    /// The escape valve this task's own instructions name for a finding
    /// class with no sensible bulk quarantine action: say what to do
    /// instead, using an operation that actually exists. `.unverified` is
    /// the one kind where re-running the check is that operation;
    /// everything else's only honest answer is still "go look at it" --
    /// exactly what `ArchiveTaskKind.supportsBulkQuarantinePreview`'s own
    /// doc comment already says, so this row states it instead of inventing
    /// a button with nothing safe behind it.
    @ViewBuilder
    private var noQuarantineActionRow: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(noQuarantineExplanationText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if kind == .unverified, let runCheck {
                Button("Run Check", action: runCheck)
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("v2.archive.task-detail.run-check")
            }
        }
    }

    private var noQuarantineExplanationText: LocalizedStringKey {
        switch kind {
        case .unverified:
            runCheck != nil
                ? "An unread or rewritten file cannot be fixed automatically. Run the check again to see if it is still unread."
                : "An unread or rewritten file cannot be fixed automatically. Run Check from the Archive page's toolbar to look again."
        case .misplacedCalibration, .brokenNames, .corruption:
            "There is no automatic fix for this. Use each row's Reveal in Finder button to inspect it and correct it by hand."
        case .intermediateFiles, .osMetadata, .duplicateContent, .auditNeverRun:
            // Gated out above by `kind.supportsBulkQuarantinePreview` --
            // reachable here only if that gate regresses.
            ""
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Same validated resolve-under-root, confirm-no-escape, confirm-exists
    /// shape `ArchiveView.revealInFinder(relativePath:)` already uses --
    /// duplicated rather than shared because each feature area owns its own
    /// copy of this check today (see that method's own doc comment for the
    /// other established copies). Works equally for a file path or a folder
    /// path: `FileManager.fileExists` and `activateFileViewerSelecting` both
    /// accept either.
    private func revealInFinder(path: String) {
        let root = rootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path), FileManager.default.fileExists(atPath: candidate.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }
}
