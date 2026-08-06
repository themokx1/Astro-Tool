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
            HStack {
                Button("Cél törlése") {
                    appState.setGoal(target: target, hours: nil)
                    dismiss()
                }
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Mentés") {
                    appState.setGoal(target: target, hours: hours)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}
