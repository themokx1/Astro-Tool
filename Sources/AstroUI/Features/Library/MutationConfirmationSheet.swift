import AstroApplication
import Foundation
import Observation
import SwiftUI

/// Backs `MutationConfirmationSheet`: holds the already-built
/// `LibraryMutationPlan` (from `CleanupPreviewQuery.plan(selecting:
/// confirmationToken:)`) and drives `QuarantineApplyCommand.apply`/
/// `rollback`. `canApply` is the same belt-and-suspenders gate the sheet's
/// Apply button disables on -- write access AND the exact confirmation
/// token typed back -- but `apply()` itself re-checks `accessMode` (via
/// `QuarantineApplyCommand`) regardless of what the UI already enforced.
@MainActor
@Observable
public final class MutationConfirmationStore {
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode) throws -> QuarantineApplyCommand

    public let plan: LibraryMutationPlan
    public let rootURL: URL
    public let accessMode: LibraryAccessMode
    public var confirmationText: String = ""
    public private(set) var isApplying = false
    public private(set) var isRollingBack = false
    public private(set) var receipt: MutationReceipt?
    public private(set) var isRolledBack = false
    public private(set) var errorMessage: String?
    /// Fired after `apply()`/`rollback()` each succeed -- lets `V2RootView`
    /// keep the sidebar's Library badge fresh without this store needing to
    /// know anything about `SidebarBadgeStore` itself (wave 3 follow-up fix:
    /// the badge previously never refreshed after a quarantine apply or
    /// rollback at all).
    public var onLibraryFindingsChanged: (() -> Void)?

    private let commandFactory: CommandFactory

    public init(
        plan: LibraryMutationPlan,
        rootURL: URL,
        accessMode: LibraryAccessMode,
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try QuarantineApplyCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.plan = plan
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.commandFactory = commandFactory
    }

    /// The exact gate the sheet's Apply button disables on: write access
    /// enabled, nothing applied yet, and the confirmation field matching
    /// the plan's own token character-for-character.
    public var canApply: Bool {
        accessMode == .mutationEnabled && receipt == nil && confirmationText == plan.confirmationToken
    }

    /// Attempts the apply regardless of `canApply` -- the sheet's Apply
    /// button already gates on it, this is the belt-and-suspenders backstop
    /// (mirroring `CalibrationStore.applyPlan`): a wrong token or read-only
    /// access still produces the command's own real error rather than a
    /// silent no-op, in case this is ever invoked without the UI gate.
    public func apply() async {
        guard receipt == nil else { return }
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }
        do {
            let command = try commandFactory(rootURL, accessMode)
            receipt = try await command.apply(plan, confirmation: confirmationText)
            onLibraryFindingsChanged?()
        } catch LibraryMutationError.readOnly {
            errorMessage = "Requires write access. Enable write operations in Settings to apply this quarantine."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func rollback() async {
        guard let receipt else { return }
        isRollingBack = true
        errorMessage = nil
        defer { isRollingBack = false }
        do {
            let command = try commandFactory(rootURL, accessMode)
            try await command.rollback(receiptID: receipt.id)
            isRolledBack = true
            onLibraryFindingsChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The real screen behind `PresentationRoute.mutationConfirmation` -- shows
/// what a quarantine apply would move (file count, total size, destination
/// folder), requires the confirmation token to be typed back before Apply
/// activates, and once applied shows the receipt plus an Undo (rollback)
/// button. Never moves a file itself; every write goes through
/// `MutationConfirmationStore` -> `QuarantineApplyCommand` ->
/// `LibraryMutationAuthorizer`.
public struct MutationConfirmationSheet: View {
    let dismiss: () -> Void
    @State private var store: MutationConfirmationStore

    public init(
        plan: LibraryMutationPlan,
        rootURL: URL,
        accessMode: LibraryAccessMode,
        dismiss: @escaping () -> Void,
        onLibraryFindingsChanged: (() -> Void)? = nil
    ) {
        self.dismiss = dismiss
        let store = MutationConfirmationStore(
            plan: plan, rootURL: rootURL, accessMode: accessMode
        )
        store.onLibraryFindingsChanged = onLibraryFindingsChanged
        _store = State(initialValue: store)
    }

    private var quarantineDestinationDirectory: String {
        guard let first = store.plan.entries.first else { return "—" }
        return first.destination.deletingLastPathComponent().lastPathComponent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            HStack {
                Label("Confirm Quarantine", systemImage: "checkmark.shield").font(.title3.bold())
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Files affected", value: "\(store.plan.entries.count)")
                LabeledContent("Total size", value: ByteCountFormatter.string(fromByteCount: store.plan.totalBytes, countStyle: .file))
                LabeledContent("Destination", value: quarantineDestinationDirectory)
                    .help("Files move under .astro_tool/cleanup_quarantine — never deleted.")
            }
            .padding(AstroTokens.Spacing.compact)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))

            Label("Files are moved into quarantine, never deleted.", systemImage: "archivebox")
                .font(.caption).foregroundStyle(.secondary)

            if let receipt = store.receipt {
                Label("Applied \(receipt.entries.count) file(s) into quarantine.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                if store.isRolledBack {
                    Label("Rolled back — files restored to their original location.", systemImage: "arrow.uturn.backward.circle")
                        .foregroundStyle(.orange)
                } else {
                    Button("Undo") { Task { await store.rollback() } }
                        .disabled(store.isRollingBack)
                        .accessibilityIdentifier("v2.mutation-confirmation.undo")
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Type the confirmation token to enable Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Confirmation token", text: $store.confirmationText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("v2.mutation-confirmation.token-field")
                    Text(store.plan.confirmationToken)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if store.accessMode != .mutationEnabled {
                        Label("Requires write access. Enable write operations in Settings to apply this quarantine.", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let errorMessage = store.errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Apply") { Task { await store.apply() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canApply || store.isApplying)
                            .accessibilityIdentifier("v2.mutation-confirmation.apply")
                    }
                }
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(minWidth: 460, minHeight: 320)
        .accessibilityIdentifier("v2.mutation-confirmation")
    }
}
