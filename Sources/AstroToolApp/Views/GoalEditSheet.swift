import SwiftUI
import AstroCore

// MARK: - Goal-editing sheet (R10-B7: the app's ONE goal editor)

/// Identifies which target's goal is being edited so a `@State` of this type
/// can drive `.sheet(item:)` -- a SHEET (not a popover) because this is
/// triggered from several different places (a `Table` cell's plain link, a
/// row context menu, AND -- since R10-B7 -- `TargetDetailPage`'s header
/// goal-tile pencil button too) and a popover needs a still-on-screen anchor
/// view to attach to, which a context-menu item (which closes immediately on
/// selection) can't provide. Moved out of `TonightPage.swift` (R10-B7,
/// alongside `GoalEditSheet` below) into its own file now that
/// `TargetDetailPage` reuses it too, rather than that page reaching into a
/// different page's file for a type with nothing "Tonight-specific" left
/// about it. Not `private`: `AllTargetsPage`'s target row context menu and
/// `TargetDetailPage`'s header both reuse this same sheet rather than
/// duplicating it.
struct GoalEditingTarget: Identifiable {
    let target: String
    let currentHours: Double?
    var id: String { target }
}

/// The app's single goal editor (R10-B7 unifies this with the near-identical
/// popover editor `TargetDetailPage`'s header used to carry privately):
/// Stepper 0-300h × 0.5h + Cél törlése/Mégse/Mentés, nothing more. Every
/// "edit this target's goal" affordance across the app (`TonightPage`'s plan
/// table link/context-menu item, `AllTargetsPage`'s target context menu,
/// `TargetDetailPage`'s header pencil button) presents this exact sheet.
struct GoalEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    @State private var overallHours: Double?
    @State private var filterDrafts: [FilterDraft] = []
    @State private var didLoadDrafts = false
    @State private var filtersExpanded = false
    @State private var showDeleteChoices = false

    private struct FilterDraft: Identifiable {
        let id = UUID()
        var name: String
        var usableSeconds: Double
        var hours: Double
        var isNew: Bool
    }

    init(target: String, initialHours: Double?) {
        self.target = target
        _overallHours = State(initialValue: initialHours)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cél (óra)").font(.headline)
            Text(target).foregroundStyle(.secondary)
            Stepper(value: overallHoursBinding, in: 0...300, step: 0.5) {
                if let overallHours {
                    Text(String(format: "%.1f óra", overallHours))
                } else {
                    Text("Nincs összcél (0,0 óra)").foregroundStyle(.secondary)
                }
            }

            if appState.filterGoalEditorRows != nil {
                DisclosureGroup("Szűrőnként", isExpanded: $filtersExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($filterDrafts) { $draft in
                            filterRow($draft)
                        }
                        Button("+ Szűrő") {
                            filterDrafts.append(FilterDraft(name: "", usableSeconds: 0, hours: 1, isNew: true))
                            filtersExpanded = true
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            } else {
                ProgressView("Szűrőcélok betöltése…")
                    .controlSize(.small)
            }

            HStack {
                Button("Cél törlése") {
                    if hasPersistedFilterGoals {
                        showDeleteChoices = true
                    } else {
                        save(overallHours: nil, rows: persistedRows)
                    }
                }
                .disabled(overallHours == nil && !hasPersistedFilterGoals)
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Mentés") {
                    save(overallHours: overallHours, rows: editableRows)
                }
                .disabled(hasValidationError || appState.filterGoalEditorRows == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            appState.loadFilterGoalEditor(target: target)
        }
        .onDisappear {
            appState.clearFilterGoalEditor()
        }
        .onChange(of: appState.filterGoalEditorRows) { _, rows in
            guard !didLoadDrafts, let rows else { return }
            didLoadDrafts = true
            filterDrafts = rows.map {
                FilterDraft(name: $0.filter, usableSeconds: $0.usableSeconds, hours: $0.goalHours, isNew: false)
            }
            filtersExpanded = rows.contains { $0.goalHours > 0 }
        }
        .confirmationDialog("Melyik célokat töröljem?", isPresented: $showDeleteChoices) {
            Button("Csak az összcél törlése") {
                save(overallHours: nil, rows: persistedRows)
            }
            Button("Minden cél törlése", role: .destructive) {
                save(overallHours: nil, rows: persistedRows.map {
                    AppState.FilterGoalEditRow(filter: $0.filter, usableSeconds: $0.usableSeconds, goalHours: 0)
                })
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            Text("A célponthoz szűrőnkénti célok is tartoznak.")
        }
    }

    // MARK: - Szűrőnként (R11-T5/F2)

    private func filterRow(_ draft: Binding<FilterDraft>) -> some View {
        let error = validationError(for: draft.wrappedValue)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("Szűrő neve", text: draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("megvan \(TDFormat.hm(draft.wrappedValue.usableSeconds))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Spacer()
                Stepper(value: draft.hours, in: 0...300, step: 0.5) {
                    Text(draft.wrappedValue.hours > 0 ? String(format: "%.1f ó", draft.wrappedValue.hours) : "nincs cél")
                        .font(.caption)
                        .frame(width: 70, alignment: .trailing)
                }
                Button {
                    filterDrafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Szűrőcél eltávolítása")
            }
            if let error {
                Text(validationMessage(error)).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private var overallHoursBinding: Binding<Double> {
        Binding(
            get: { overallHours ?? 0 },
            set: { overallHours = $0 > 0 ? $0 : nil }
        )
    }

    private var persistedRows: [AppState.FilterGoalEditRow] {
        appState.filterGoalEditorRows ?? []
    }

    private var editableRows: [AppState.FilterGoalEditRow] {
        filterDrafts.map {
            AppState.FilterGoalEditRow(
                filter: GoalTag.normalizedFilterGoalName($0.name),
                usableSeconds: $0.usableSeconds,
                goalHours: $0.hours
            )
        }
    }

    private var hasPersistedFilterGoals: Bool {
        persistedRows.contains { $0.goalHours > 0 }
    }

    private var hasValidationError: Bool {
        filterDrafts.contains { validationError(for: $0) != nil }
    }

    private func validationError(for draft: FilterDraft) -> GoalTag.FilterGoalValidationError? {
        let others = filterDrafts.filter { $0.id != draft.id }.map(\.name)
        if !draft.isNew && draft.hours == 0 {
            let name = GoalTag.normalizedFilterGoalName(draft.name)
            if name.isEmpty { return .blankName }
            if others.contains(where: { GoalTag.normalizedFilterGoalName($0).caseInsensitiveCompare(name) == .orderedSame }) {
                return .duplicateName
            }
            return nil
        }
        return GoalTag.validateFilterGoal(name: draft.name, hours: draft.hours, otherNames: others)
    }

    private func validationMessage(_ error: GoalTag.FilterGoalValidationError) -> String {
        switch error {
        case .blankName: return "Add meg a szűrő nevét."
        case .duplicateName: return "Ez a szűrő már szerepel."
        case .nonpositiveHours: return "A cél legyen nagyobb 0 óránál."
        }
    }

    private func save(overallHours: Double?, rows: [AppState.FilterGoalEditRow]) {
        appState.saveGoals(target: target, overallHours: overallHours, filterRows: rows)
        dismiss()
    }
}
