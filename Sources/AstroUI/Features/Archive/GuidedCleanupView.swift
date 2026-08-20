import AstroApplication
import SwiftUI

/// Feature 5.3 (V3 prestack program spec) -- a step-by-step walkthrough over
/// the SAME preview -> confirm -> apply -> receipt/undo chain the plain,
/// table-based Cleanup Preview screen already uses, one category at a time
/// ("quarantine this / leave this") instead of a multi-select table. Follows
/// `CaptureImportView`'s own shape: one `CaseIterable` step enum
/// (`GuidedCleanupStep`), one `@Observable` store (`GuidedCleanupStore`)
/// owning every step's data, this view only switches on `store.step`.
///
/// Zero new mutation path: every write this view can ever cause happens
/// inside `store.mutationStore` (a real `MutationConfirmationStore`), the
/// exact type `MutationConfirmationSheet` itself drives -- see that store's
/// own doc comment. This view never calls `QuarantineApplyCommand`
/// directly.
public struct GuidedCleanupView: View {
    let dismiss: () -> Void
    /// The risk mitigation the spec calls out by name: "if the step-by-step
    /// flow feels slower than today's table, the owner will switch back" --
    /// so every step offers a direct escape hatch to the existing table
    /// screen, carrying along whichever category was current so the table
    /// opens pre-checked to it, exactly like `ArchiveTaskDetailView`'s own
    /// `openQuarantinePreview` hand-off.
    let switchToTable: (Set<String>) -> Void
    @State private var store: GuidedCleanupStore

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        tasks: [ArchiveTask],
        dismiss: @escaping () -> Void,
        switchToTable: @escaping (Set<String>) -> Void,
        store: GuidedCleanupStore? = nil
    ) {
        _store = State(initialValue: store ?? GuidedCleanupStore(rootURL: rootURL, accessMode: accessMode, tasks: tasks))
        self.dismiss = dismiss
        self.switchToTable = switchToTable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            header
            Divider()
            if store.isFinished {
                doneStep
            } else {
                switch store.step {
                case .selectCategory: selectCategoryStep
                case .reviewFinding: reviewFindingStep
                case .decide: decideStep
                case .confirmBatch, .quarantine: confirmStep
                case .receipt: receiptStep
                }
            }
        }
        .padding(AstroTokens.Spacing.standard)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 600)
        .accessibilityIdentifier("v2.guided-cleanup")
    }

    private var header: some View {
        HStack {
            Image(systemName: "list.bullet.rectangle").font(.title).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading) {
                Text("Guided Cleanup").font(.title2.weight(.semibold))
                Text(stepSubtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.isFinished {
                Button("Switch to Table View") {
                    switchToTable(store.currentCandidate.map { Set($0.kind.findingCategories) } ?? [])
                    dismiss()
                }
                .accessibilityIdentifier("v2.guided-cleanup.switch-to-table")
            }
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }

    private var stepSubtitle: LocalizedStringKey {
        guard !store.isFinished else { return "Done" }
        switch store.step {
        case .selectCategory: return "Category"
        case .reviewFinding: return "Review"
        case .decide: return "Decide"
        case .confirmBatch: return "Confirm"
        case .quarantine: return "Quarantining"
        case .receipt: return "Receipt"
        }
    }

    // MARK: - selectCategory

    private var selectCategoryStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let candidate = store.currentCandidate {
                Text("\(store.queue.count - store.currentIndex) of \(store.queue.count) categories left to go through.")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ArchiveTaskPresentation.title(for: candidate.kind))
                        .font(.title3.weight(.semibold))
                    Text("\(candidate.affectedFileCount.formatted()) file(s) · \(AstroFormat.bytes(candidate.bytes))")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(candidate.evidencePaths, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .astroRecessedSurface()
                Spacer()
                HStack {
                    Spacer()
                    Button("Review These Files") { Task { await store.beginReview() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.guided-cleanup.begin-review")
                }
            }
        }
    }

    // MARK: - reviewFinding

    private var reviewFindingStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            if store.isLoadingFindings {
                ProgressView("Loading findings…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = store.findingsErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AstroTokens.Color.attention)
            } else if store.findings.isEmpty {
                Text("No individual findings to show for this category.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let finding = store.currentFinding {
                Text("File \(store.findingCursor + 1) of \(store.findings.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding.path).font(.callout.monospaced()).textSelection(.enabled)
                    Text(AstroFormat.bytes(finding.bytes)).font(.caption).foregroundStyle(.secondary)
                }
                .astroRecessedSurface()
                Spacer()
                HStack {
                    Button("Previous") { store.previousFinding() }
                        .disabled(store.findingCursor == 0)
                    Button("Next") { store.nextFinding() }
                        .disabled(store.findingCursor + 1 >= store.findings.count)
                        .accessibilityIdentifier("v2.guided-cleanup.next-finding")
                    Spacer()
                    Button("Decide") { store.proceedToDecide() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.guided-cleanup.proceed-to-decide")
                }
            }
        }
    }

    // MARK: - decide

    private var decideStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let candidate = store.currentCandidate {
                Text("Quarantine \(candidate.affectedFileCount.formatted()) file(s) in “\(ArchiveTaskPresentation.titleText(for: candidate.kind))”, or leave them where they are?")
                    .font(.callout)
                Label("Files are moved into quarantine, never deleted.", systemImage: "archivebox")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = store.planErrorMessage {
                    Text(message).font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                if store.accessMode != .mutationEnabled {
                    Label("Requires write access. Enable write operations in Settings to apply this quarantine.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Button("Leave These") { store.decideSkip() }
                        .accessibilityIdentifier("v2.guided-cleanup.decide-skip")
                    Spacer()
                    Button("Quarantine These…") { store.decideQuarantine() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.accessMode != .mutationEnabled)
                        .accessibilityIdentifier("v2.guided-cleanup.decide-quarantine")
                }
            }
        }
    }

    // MARK: - confirmBatch / quarantine -- both driven by the SAME embedded
    // MutationConfirmationStore, the exact engine call MutationConfirmationSheet
    // itself uses.

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let mutationStore = store.mutationStore {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Files affected", value: "\(mutationStore.plan.entries.count)")
                    LabeledContent("Total size", value: AstroFormat.bytes(mutationStore.plan.totalBytes))
                }
                .astroRecessedSurface()
                Text("Type the confirmation token to enable Apply.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Confirmation token", text: Binding(
                    get: { mutationStore.confirmationText },
                    set: { mutationStore.confirmationText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.guided-cleanup.token-field")
                Text(mutationStore.plan.confirmationToken)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let message = mutationStore.errorMessage {
                    Text(message).font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                Spacer()
                HStack {
                    if store.step == .quarantine { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Apply") { Task { await store.beginApply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!mutationStore.canApply || store.step == .quarantine)
                        .accessibilityIdentifier("v2.guided-cleanup.apply")
                }
            }
        }
    }

    // MARK: - receipt

    private var receiptStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let mutationStore = store.mutationStore, let receipt = mutationStore.receipt {
                Label("\(receipt.entries.count) files moved to quarantine.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(AstroTokens.Color.ok)
                if mutationStore.isRolledBack {
                    Label("Rolled back — files restored to their original location.", systemImage: "arrow.uturn.backward.circle")
                        .foregroundStyle(AstroTokens.Color.attention)
                } else {
                    Button("Undo") { Task { await store.rollbackCurrent() } }
                        .disabled(mutationStore.isRollingBack)
                        .accessibilityIdentifier("v2.guided-cleanup.undo")
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Continue") { store.continueToNextCategory() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.guided-cleanup.continue")
                }
            }
        }
    }

    // MARK: - done

    private var doneStep: some View {
        VStack(alignment: .center, spacing: AstroTokens.Spacing.standard) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(AstroTokens.Color.ok)
            if store.completedCategories.isEmpty, store.skippedCategories.isEmpty {
                Text("Nothing needs a guided pass right now.").font(.title3.weight(.semibold))
            } else {
                Text("All caught up.").font(.title3.weight(.semibold))
                Text("\(store.completedCategories.count.formatted()) quarantined · \(store.skippedCategories.count.formatted()) left as-is")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: dismiss).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("v2.guided-cleanup.done")
    }
}
