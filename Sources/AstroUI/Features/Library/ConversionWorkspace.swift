import AppKit
import AstroApplication
import AstroCore
import SwiftUI

/// Backs `ConversionWorkspace`: browses available target/date sessions
/// (`ConversionUseCase.availableSessions`, a lightweight read-only listing),
/// then drives the real preview -> edit -> resolve -> apply/rollback flow
/// through `SessionConversionCommand` -- the V1 engine's own
/// plan/resolvingAmbiguity/editingGroup/apply/rollback, gated on
/// `LibraryAccessMode`. Follows `CalibrationStore`'s query/command-factory
/// injection pattern so tests can supply a fixture-backed
/// `SessionConversionCommand` without touching the filesystem-resolving
/// `production` constructor.
@MainActor
@Observable
public final class ConversionStore {
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode) throws -> SessionConversionCommand

    public private(set) var sessions: [ConversionSessionID] = []
    public private(set) var plan: SessionConversionPlan?
    public private(set) var isLoading = false
    public private(set) var isPlanning = false
    public private(set) var errorMessage: String?
    public private(set) var planErrorMessage: String?
    public private(set) var accessMode: LibraryAccessMode = .readOnly
    /// The most recently applied-or-rolled-back receipt. Set by `applyPlan`
    /// (which also clears `plan`, since the applied plan is now stale) and
    /// updated in place by `undoReceipt`.
    public private(set) var lastReceipt: SessionConversionReceipt?

    public var selection: ConversionSessionID?
    public var mode: SessionConversionMode = .logicalOnly
    /// One candidate group slug per still-open ambiguity id, chosen by the
    /// picker in the "Resolve" step before `resolveAmbiguity` commits it.
    public var ambiguityChoices: [String: String] = [:]

    private let useCase: ConversionUseCase
    private let commandFactory: CommandFactory
    private var rootURL: URL?

    public init(
        useCase: ConversionUseCase,
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try SessionConversionCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.useCase = useCase
        self.commandFactory = commandFactory
    }

    /// `true` only once every blocking ambiguity has been resolved and there
    /// are no unresolved conflicts -- mirrors `SessionConversionPlan.canApply`
    /// exactly, so the UI never has to re-derive that rule.
    public var canApply: Bool { plan?.canApply == true }

    public func load(rootURL: URL, accessMode: LibraryAccessMode = .readOnly) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        self.rootURL = rootURL.standardizedFileURL
        self.accessMode = accessMode
        do {
            sessions = try await useCase.availableSessions()
            selection = selection ?? sessions.first
            try await refreshPlan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Builds a fresh preview for the current `selection`/`mode` -- always
    /// available, even in read-only mode; nothing is written by this call.
    public func refreshPlan() async throws {
        guard let rootURL, let selection else { plan = nil; return }
        isPlanning = true
        planErrorMessage = nil
        defer { isPlanning = false }
        let command = try commandFactory(rootURL, accessMode)
        plan = try command.plan(target: selection.target, date: selection.date, mode: mode)
        ambiguityChoices = [:]
        lastReceipt = nil
    }

    /// Commits the currently chosen candidate (or the ambiguity's own first
    /// candidate, if none was explicitly chosen yet) for one ambiguity --
    /// pure plan transformation, no filesystem or database access.
    public func resolveAmbiguity(_ ambiguity: ConversionAmbiguity) {
        guard let rootURL, let plan else { return }
        guard let slug = ambiguityChoices[ambiguity.id] ?? ambiguity.candidateGroupSlugs.first else { return }
        do {
            let command = try commandFactory(rootURL, accessMode)
            self.plan = try command.resolvingAmbiguity(id: ambiguity.id, withGroupSlug: slug, in: plan)
            planErrorMessage = nil
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    /// Overwrites one proposed group's editable fields in place on `plan` --
    /// the group's `slug` (and therefore every move/assignment referencing
    /// it) never changes.
    public func editGroup(
        slug: String,
        displayName: String,
        sensorMode: SensorMode,
        signalMode: SignalMode,
        filterManufacturer: String?,
        filterModel: String?,
        filterName: String?
    ) {
        guard let rootURL, let plan else { return }
        do {
            let command = try commandFactory(rootURL, accessMode)
            self.plan = try command.editingGroup(
                slug: slug,
                displayName: displayName,
                sensorMode: sensorMode,
                signalMode: signalMode,
                filterManufacturer: filterManufacturer,
                filterModel: filterModel,
                filterName: filterName,
                in: plan
            )
            planErrorMessage = nil
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    /// Applies the current `plan` through `OperationHost` so it shows up in
    /// the toolbar with a progress toast; the engine's own apply is a single
    /// synchronous session-scoped operation with no mid-flight cancellation
    /// point, so this runs with `.unavailable` cancellation rather than
    /// offering a cancel control that could never actually interrupt it.
    /// Sets `planErrorMessage` (rather than throwing) in read-only mode --
    /// belt-and-suspenders backstop, the caller is expected to already
    /// disable the apply control outside write mode.
    public func applyPlan(operationHost: OperationHost) async {
        guard let rootURL, let plan else { return }
        guard accessMode == .mutationEnabled else {
            planErrorMessage = "Requires write access. Enable write operations in Settings to apply this conversion."
            return
        }
        do {
            let command = try commandFactory(rootURL, accessMode)
            let kind = OperationKind.convert(session: "\(plan.scope.target)/\(plan.scope.date)")
            let title = plan.mode == .physical ? "Applying conversion" : "Saving capture organization"
            _ = await operationHost.run(kind: kind, title: title, cancellation: .unavailable) { [weak self] in
                let receipt = try command.apply(plan)
                await self?.recordReceipt(receipt)
            }
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    /// Rolls back `lastReceipt` through `OperationHost`, same cancellation
    /// posture as `applyPlan`.
    public func undoReceipt(operationHost: OperationHost) async {
        guard let rootURL, let receipt = lastReceipt else { return }
        guard accessMode == .mutationEnabled else {
            planErrorMessage = "Requires write access. Enable write operations in Settings to undo this conversion."
            return
        }
        do {
            let command = try commandFactory(rootURL, accessMode)
            let kind = OperationKind.convert(session: "\(receipt.scope.target)/\(receipt.scope.date)")
            _ = await operationHost.run(kind: kind, title: "Undoing conversion", cancellation: .unavailable) { [weak self] in
                let rolledBack = try command.rollback(receipt)
                await self?.recordRolledBack(rolledBack)
            }
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    private func recordReceipt(_ receipt: SessionConversionReceipt) {
        lastReceipt = receipt
        plan = nil
    }

    private func recordRolledBack(_ receipt: SessionConversionReceipt) {
        lastReceipt = receipt
    }
}

public struct ConversionWorkspace: View {
    private enum WizardStep: Hashable {
        case choose
        case review
        case resolve
        case apply
    }

    @State private var store: ConversionStore
    @State private var stepIndex = 0
    @State private var confirmingApply = false
    @State private var confirmingUndo = false
    let rootURL: URL
    let accessMode: LibraryAccessMode
    @Environment(OperationHost.self) private var operationHost

    public init(
        useCase: ConversionUseCase,
        rootURL: URL,
        accessMode: LibraryAccessMode = .readOnly
    ) {
        _store = State(initialValue: ConversionStore(useCase: useCase))
        self.rootURL = rootURL
        self.accessMode = accessMode
    }

    /// Only includes the ambiguity-resolution step while the current plan
    /// actually has one -- a session with nothing to decide never shows an
    /// empty "Resolve" screen.
    private var steps: [WizardStep] {
        var result: [WizardStep] = [.choose, .review]
        if let plan = store.plan, !plan.ambiguities.isEmpty {
            result.append(.resolve)
        }
        result.append(.apply)
        return result
    }

    private var currentStep: WizardStep {
        steps[min(stepIndex, steps.count - 1)]
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: AstroTokens.Spacing.section) {
                stepsRail
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(AstroTokens.Spacing.section)
            Divider()
            footer
        }
        .background(.background)
        .task { await store.load(rootURL: rootURL, accessMode: accessMode) }
        .accessibilityIdentifier("v2.conversion.workspace")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.split.2x1").font(.title2).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Organize one session").font(.title2.bold())
                Text("Preview first. Nothing is written until you apply.").foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                store.accessMode == .mutationEnabled ? "Writable" : "Read only",
                systemImage: store.accessMode == .mutationEnabled ? "lock.open" : "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }.padding(20)
    }

    private var stepsRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepLabel(index + 1, title(for: step), detail(for: step), isCurrent: index == stepIndex)
            }
        }.frame(width: 190, alignment: .topLeading)
    }

    private func title(for step: WizardStep) -> String {
        switch step {
        case .choose: return "Choose"
        case .review: return "Review"
        case .resolve: return "Resolve"
        case .apply: return "Apply"
        }
    }

    private func detail(for step: WizardStep) -> String {
        switch step {
        case .choose: return "One target and night"
        case .review: return "Detected capture groups"
        case .resolve: return "Ambiguous file decisions"
        case .apply: return "Exact impact and apply"
        }
    }

    private func stepLabel(_ number: Int, _ title: String, _ detail: String, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 24, height: 24)
                .background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18), in: Circle())
                .foregroundStyle(isCurrent ? .white : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading {
            ProgressView("Reading AstroTool's index…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.sessions.isEmpty {
            ContentUnavailableView("No sessions found", systemImage: "moon.zzz", description: Text("Scan a library containing light frames first."))
        } else {
            switch currentStep {
            case .choose: chooseStep
            case .review: reviewStep
            case .resolve: resolveStep
            case .apply: applyStep
            }
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Which session should AstroTool organize?").font(.title3.bold())
            Text("Only the selected target and date are in scope. Nothing else in the library is included.")
                .foregroundStyle(.secondary)
            Picker("Session", selection: $store.selection) {
                ForEach(store.sessions, id: \.self) { session in
                    Text("\(session.target) · \(session.date)").tag(Optional(session))
                }
            }.labelsHidden().frame(maxWidth: 480)
            Picker("Organization mode", selection: $store.mode) {
                Text("Logical · no file moves").tag(SessionConversionMode.logicalOnly)
                Text("Physical · reorganize files on disk").tag(SessionConversionMode.physical)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .onChange(of: store.mode) { _, _ in Task { try? await store.refreshPlan() } }
            .onChange(of: store.selection) { _, _ in Task { try? await store.refreshPlan() } }
            Label("Exactly 1 session", systemImage: "scope").foregroundStyle(AstroTokens.Color.ok)
            Spacer()
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Detected capture groups").font(.title3.bold())
            if store.isPlanning {
                ProgressView("Building plan…")
            } else if let plan = store.plan {
                Text("\(plan.scope.target) · \(plan.scope.date)").foregroundStyle(.secondary)
                // `humanSummary` is the English sibling of `humanSummaryHU`
                // (V1/CLI's own consumer, unchanged) -- see that property's
                // own doc comment. Every plan `ConversionStore` actually
                // builds here comes fresh from `SessionConversionPlanner.plan`
                // (never decoded from an old `plan.json`), so `humanSummary`
                // is always populated in practice; falling back to the
                // Hungarian sibling would defeat the point of this property,
                // so an empty string is the honest fallback instead.
                Text(plan.humanSummary ?? "").font(.callout).foregroundStyle(.secondary)
                if plan.proposedGroups.isEmpty {
                    Label("Every capture group already exists as-is; nothing new to name.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AstroTokens.Color.ok)
                } else {
                    Text("Names, sensor, signal, and filter can be corrected before applying. The slug is fixed since every move/assignment refers to it.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.proposedGroups) { proposed in
                        groupEditorCard(proposed)
                    }
                }
            } else if let planErrorMessage = store.planErrorMessage {
                Text(planErrorMessage).foregroundStyle(AstroTokens.Color.attention)
            }
            Spacer()
        }
        .accessibilityIdentifier("v2.conversion.review-step")
    }

    @ViewBuilder
    private func groupEditorCard(_ proposed: ProposedCaptureGroup) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Group name", text: nameBinding(for: proposed))
                        .accessibilityIdentifier("v2.conversion.group-name")
                    Text(proposed.draft.slug).font(.body.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Sensor", selection: sensorBinding(for: proposed)) {
                        ForEach(SensorMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier("v2.conversion.group-sensor")
                    Picker("Signal", selection: signalBinding(for: proposed)) {
                        ForEach(SignalMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier("v2.conversion.group-signal")
                }
                TextField("Filter", text: filterNameBinding(for: proposed))
                    .accessibilityIdentifier("v2.conversion.group-filter")
            }
            .padding(6)
        } label: {
            Label(
                proposed.existingGroupID == nil ? "New capture group" : "Updates an existing capture group",
                systemImage: proposed.existingGroupID == nil ? "plus.circle" : "arrow.triangle.2.circlepath.circle"
            )
        }
    }

    private func currentDraft(for slug: String) -> CaptureGroupDraft? {
        store.plan?.proposedGroups.first { $0.draft.slug == slug }?.draft
    }

    private func nameBinding(for proposed: ProposedCaptureGroup) -> Binding<String> {
        Binding(
            get: { currentDraft(for: proposed.draft.slug)?.displayName ?? proposed.draft.displayName },
            set: { newValue in applyEdit(slug: proposed.draft.slug) { $0.displayName = newValue } }
        )
    }

    private func sensorBinding(for proposed: ProposedCaptureGroup) -> Binding<SensorMode> {
        Binding(
            get: { currentDraft(for: proposed.draft.slug)?.sensorMode ?? proposed.draft.sensorMode },
            set: { newValue in applyEdit(slug: proposed.draft.slug) { $0.sensorMode = newValue } }
        )
    }

    private func signalBinding(for proposed: ProposedCaptureGroup) -> Binding<SignalMode> {
        Binding(
            get: { currentDraft(for: proposed.draft.slug)?.signalMode ?? proposed.draft.signalMode },
            set: { newValue in applyEdit(slug: proposed.draft.slug) { $0.signalMode = newValue } }
        )
    }

    private func filterNameBinding(for proposed: ProposedCaptureGroup) -> Binding<String> {
        Binding(
            get: { currentDraft(for: proposed.draft.slug)?.filterName ?? proposed.draft.filterName ?? "" },
            set: { newValue in
                applyEdit(slug: proposed.draft.slug) { $0.filterName = newValue.isEmpty ? nil : newValue }
            }
        )
    }

    private func applyEdit(slug: String, mutate: (inout CaptureGroupDraft) -> Void) {
        guard var draft = currentDraft(for: slug) else { return }
        mutate(&draft)
        store.editGroup(
            slug: slug,
            displayName: draft.displayName,
            sensorMode: draft.sensorMode,
            signalMode: draft.signalMode,
            filterManufacturer: draft.filterManufacturer,
            filterModel: draft.filterModel,
            filterName: draft.filterName
        )
    }

    private var resolveStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which capture group does each file belong to?").font(.title3.bold())
            Text("These files could not be matched automatically. Applying is blocked until every one is decided.")
                .foregroundStyle(.secondary)
            if let plan = store.plan {
                ForEach(plan.ambiguities) { ambiguity in
                    ambiguityCard(ambiguity)
                }
                if plan.ambiguities.isEmpty {
                    Label("Every file is assigned to a capture group.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(AstroTokens.Color.ok)
                }
            }
            Spacer()
        }
        .accessibilityIdentifier("v2.conversion.ambiguity-step")
    }

    private func ambiguityCard(_ ambiguity: ConversionAmbiguity) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(ambiguity.titleEnglish, systemImage: "questionmark.diamond.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AstroTokens.Color.attention)
                Text(ambiguity.explanationEnglish).font(.caption).foregroundStyle(.secondary)
                Text("\(ambiguity.affectedPaths.count) file(s): \(ambiguity.affectedPaths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(.caption.monospaced()).lineLimit(2)
                HStack {
                    Picker("Belongs to", selection: choiceBinding(for: ambiguity)) {
                        ForEach(ambiguity.candidateGroupSlugs, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Record Decision") { store.resolveAmbiguity(ambiguity) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func choiceBinding(for ambiguity: ConversionAmbiguity) -> Binding<String> {
        Binding(
            get: { store.ambiguityChoices[ambiguity.id] ?? ambiguity.candidateGroupSlugs.first ?? "" },
            set: { store.ambiguityChoices[ambiguity.id] = $0 }
        )
    }

    private var applyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exact impact").font(.title3.bold())
            if let receipt = store.lastReceipt {
                receiptSummary(receipt)
            } else if let plan = store.plan {
                operationsSummary(plan)
            } else if let planErrorMessage = store.planErrorMessage {
                Text(planErrorMessage).foregroundStyle(AstroTokens.Color.attention)
            }
            Spacer()
        }
        .accessibilityIdentifier("v2.conversion.apply-step")
    }

    @ViewBuilder
    private func operationsSummary(_ plan: SessionConversionPlan) -> some View {
        if plan.mode == .logicalOnly {
            Label("0 files moved", systemImage: "checkmark.shield.fill").foregroundStyle(AstroTokens.Color.ok).font(.headline)
            Text("AstroTool keeps the session together and represents each exposure/filter combination as its own capture group.")
        } else {
            Label("\(plan.moves.count) file(s) will move", systemImage: "arrow.triangle.branch").font(.headline)
        }
        GroupBox("Assignments and moves") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(plan.summary.fileAssignmentCount) file assignment(s) · \(plan.summary.moveCount) move(s) · \(plan.summary.directoryCount) new folder(s)")
                    .font(.callout)
                if !plan.conflicts.isEmpty {
                    ForEach(plan.conflicts) { conflict in
                        Label("\(conflict.path): \(conflict.messageEnglish)", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(AstroTokens.Color.critical)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        if store.accessMode != .mutationEnabled {
            Label("Requires write access. Enable write operations in Settings to apply this conversion.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        } else if !plan.canApply {
            Label("Resolve every ambiguity before applying.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(AstroTokens.Color.attention)
        }
        if let planErrorMessage = store.planErrorMessage {
            Text(planErrorMessage).foregroundStyle(AstroTokens.Color.attention)
        }
        HStack {
            Spacer()
            Button("Apply Conversion…") { confirmingApply = true }
                .buttonStyle(.borderedProminent)
                .disabled(store.accessMode != .mutationEnabled || !plan.canApply)
                .help(store.accessMode != .mutationEnabled ? "Requires write access" : "Apply this conversion")
                .accessibilityIdentifier("v2.conversion.apply")
        }
        .confirmationDialog(
            plan.mode == .physical ? "Move these files and update capture groups?" : "Save this capture organization?",
            isPresented: $confirmingApply
        ) {
            Button(plan.mode == .physical ? "Convert and Move Files" : "Save Organization") {
                Task { await store.applyPlan(operationHost: operationHost) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(plan.summary.fileAssignmentCount) assignment(s) · \(plan.summary.moveCount) move(s). A rollback receipt is kept either way.")
        }
    }

    @ViewBuilder
    private func receiptSummary(_ receipt: SessionConversionReceipt) -> some View {
        Label(
            receipt.status == .applied ? "Conversion applied" : "Conversion undone",
            systemImage: receipt.status == .applied ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill"
        )
        .font(.headline)
        .foregroundStyle(receipt.status == .applied ? AstroTokens.Color.ok : AstroTokens.Color.accent)
        Text("Receipt: \(receipt.id) · \(receipt.moves.count) file move(s)")
            .font(.caption.monospaced()).foregroundStyle(.secondary)
        HStack {
            Button("Show Receipt in Finder") { revealReceipt(receipt) }
                .disabled(receiptURL(receipt) == nil)
            if receipt.status == .applied {
                Button("Undo Conversion…", role: .destructive) { confirmingUndo = true }
                    .accessibilityIdentifier("v2.conversion.undo")
            }
        }
        .confirmationDialog(
            "Undo this conversion and restore every moved file?",
            isPresented: $confirmingUndo
        ) {
            Button("Undo Conversion", role: .destructive) {
                Task { await store.undoReceipt(operationHost: operationHost) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(receipt.moves.count) file move(s) will be reversed and the capture groups restored.")
        }
    }

    private func receiptURL(_ receipt: SessionConversionReceipt) -> URL? {
        FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: receipt.receiptRelativePath)
    }

    private func revealReceipt(_ receipt: SessionConversionReceipt) {
        guard let url = receiptURL(receipt) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The wizard's own step Back/Continue -- unrelated to the surrounding
    /// `NavigationStack`'s native Back chevron (that leaves the whole
    /// workspace; this moves between the wizard's internal steps). Wave 4
    /// Task 1: the final "Apply" step no longer shows a trailing "Done"
    /// button that used to dismiss the workspace outright -- Apply/Undo are
    /// already the real actionable controls inside `operationsSummary`, and
    /// leaving is now the native Back chevron.
    private var footer: some View {
        HStack {
            if stepIndex > 0 {
                Button("Back") { stepIndex -= 1 }
                    .accessibilityIdentifier("v2.conversion.back")
            }
            Spacer()
            if stepIndex < steps.count - 1 {
                Button("Continue") { stepIndex += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                    .accessibilityIdentifier("v2.conversion.continue")
            }
        }.padding(16)
    }

    private var canContinue: Bool {
        switch currentStep {
        case .choose: return store.selection != nil
        case .review: return true
        case .resolve: return store.plan?.ambiguities.isEmpty ?? true
        case .apply: return true
        }
    }
}
