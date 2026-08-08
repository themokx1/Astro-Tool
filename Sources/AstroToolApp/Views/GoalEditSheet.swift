import SwiftUI

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
    let currentHours: Double
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
    @State private var hours: Double
    /// R11-T5/F2: "Szűrőnként" section state -- overrides
    /// `appState.filterGoalEditorRows`' own `goalHours` per filter as the
    /// user moves each row's stepper, keyed by filter name (not the row
    /// array itself, so a still-loading/absent row never blocks editing the
    /// ones already on screen).
    @State private var filterHoursByFilter: [String: Double] = [:]
    @State private var filtersExpanded = false

    init(target: String, initialHours: Double) {
        self.target = target
        _hours = State(initialValue: initialHours)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cél (óra)").font(.headline)
            Text(target).foregroundStyle(.secondary)
            Stepper(value: $hours, in: 0...300, step: 0.5) {
                Text(String(format: "%.1f óra", hours))
            }

            if let rows = appState.filterGoalEditorRows, !rows.isEmpty {
                DisclosureGroup("Szűrőnként", isExpanded: $filtersExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            filterRow(row)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }

            HStack {
                Button("Cél törlése") {
                    appState.setGoal(target: target, hours: nil)
                    dismiss()
                }
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Mentés") {
                    appState.setGoal(target: target, hours: hours)
                    saveFilterGoalsIfAny()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            appState.loadFilterGoalEditor(target: target)
        }
        .onDisappear {
            appState.clearFilterGoalEditor()
        }
    }

    // MARK: - Szűrőnként (R11-T5/F2)

    private func filterRow(_ row: AppState.FilterGoalEditRow) -> some View {
        let binding = filterHoursBinding(row.filter, default: row.goalHours)
        return HStack {
            Text(row.filter).frame(width: 56, alignment: .leading)
            Text("megvan \(TDFormat.hm(row.usableSeconds))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Spacer()
            Stepper(value: binding, in: 0...300, step: 0.5) {
                let value = binding.wrappedValue
                Text(value > 0 ? String(format: "%.1f ó", value) : "nincs cél")
                    .font(.caption)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private func filterHoursBinding(_ filter: String, default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { filterHoursByFilter[filter] ?? defaultValue },
            set: { filterHoursByFilter[filter] = $0 }
        )
    }

    /// Builds the final per-filter row set (each row's stepper override, if
    /// any, else its loaded default) and hands it to `AppState.
    /// setFilterGoals` -- a no-op when the editor never finished loading
    /// (e.g. the user hit "Mentés" before `loadFilterGoalEditor` returned).
    private func saveFilterGoalsIfAny() {
        guard let rows = appState.filterGoalEditorRows, !rows.isEmpty else { return }
        let updated = rows.map { row in
            AppState.FilterGoalEditRow(
                filter: row.filter, usableSeconds: row.usableSeconds,
                goalHours: filterHoursByFilter[row.filter] ?? row.goalHours
            )
        }
        appState.setFilterGoals(target: target, rows: updated)
    }
}
