import AppKit
import AstroApplication
import Foundation
import SwiftUI

/// The route `ArchiveTaskAction.showFindings(kind:)` pushes to -- Task 3
/// (wave 3)'s fix for the wave 1 design error where a card's single
/// `revealInFinder(path:)` action carried only the FIRST of a kind's
/// findings, arbitrarily, whenever there was more than one ("33 kalibráció
/// rossz mappában" opened one of the 33 and silently dropped the other 32).
/// This page shows every one of that kind's findings, each with its own
/// real path and its own reveal-in-Finder button, plus a bulk quarantine-
/// preview action where the kind supports one (`ArchiveTaskKind
/// .supportsBulkQuarantinePreview`).
///
/// Follows `WorkspaceTablePage`'s non-scrolling-root-plus-one-`Table` shape
/// (see `HealthView`'s own findings table for the established precedent) --
/// the real library's own worst card covers 3 231 findings, and a `Table`
/// nested inside a scrolling container is proposed unbounded height, so
/// AppKit cannot virtualize it and lays out every row on every pass (the
/// exact freeze this project spent five rounds fixing elsewhere; see
/// `WorkspaceTablePage`'s own doc comment for the incident). `store.findings`
/// is loaded once via `ArchiveTaskDetailStore`'s generation-guarded `load`,
/// never queried from a computed getter or from `body` itself.
public struct ArchiveTaskDetailView: View {
    let rootURL: URL
    let kind: ArchiveTaskKind
    /// Pushes the existing Cleanup Preview route, pre-checked to this kind's
    /// own categories -- the same hand-off `ArchiveView`'s own
    /// `openQuarantinePreview` closure already documents, reused verbatim so
    /// both surfaces land on the exact same, already-tested destination.
    let openQuarantinePreview: (Set<String>) -> Void
    @Bindable var store: ArchiveTaskDetailStore

    public init(
        rootURL: URL,
        kind: ArchiveTaskKind,
        openQuarantinePreview: @escaping (Set<String>) -> Void,
        store: ArchiveTaskDetailStore = ArchiveTaskDetailStore()
    ) {
        self.rootURL = rootURL
        self.kind = kind
        self.openQuarantinePreview = openQuarantinePreview
        self.store = store
    }

    public var body: some View {
        WorkspaceTablePage(subtitle: "Every finding behind this card, each with its own path.") {
            toolbarContent
        } table: {
            tableContent
        }
        .task { await store.load(rootURL: rootURL, kind: kind) }
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
            // Task 3 (wave 3): only the reclaim kinds get a bulk action --
            // an error kind's only honest per-finding response is "go look
            // at it", so there is no safe destructive action to offer in
            // bulk here (see `ArchiveTaskKind.supportsBulkQuarantinePreview`'s
            // own doc comment).
            if kind.supportsBulkQuarantinePreview, !store.findings.isEmpty {
                Button("Preview Quarantine…") {
                    openQuarantinePreview(Set(kind.findingCategories))
                }
                // Task 6 (2026-08-17, Liquid Glass): this row is
                // `WorkspaceTablePage`'s own "toolbar" slot, which now
                // floats as one glass bar above the table (see that type's
                // own comment) -- `.glassProminent` is the button style
                // Apple pairs with a glass surface; the former
                // `.borderedProminent` drew its own opaque capsule, which
                // read as a flat patch sitting on top of translucent glass.
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("v2.archive.task-detail.preview-quarantine")
            }
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
            GroupBox("All findings") {
                Table(store.findings) {
                    TableColumn("Path") { finding in
                        Text(finding.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                    TableColumn("Size") { finding in
                        Text(Self.formatBytes(finding.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("") { finding in
                        Button {
                            revealInFinder(path: finding.path)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    .width(36)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("v2.archive.task-detail.table")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Same validated resolve-under-root, confirm-no-escape, confirm-exists
    /// shape `ArchiveView.revealInFinder(relativePath:)` already uses --
    /// duplicated rather than shared because each feature area owns its own
    /// copy of this check today (see that method's own doc comment for the
    /// other established copies).
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
