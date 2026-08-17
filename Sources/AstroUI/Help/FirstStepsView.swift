import AstroApplication
import SwiftUI

/// Help ▸ First Steps -- a static checklist of the first things worth doing
/// in a freshly opened library, each linking straight into the app section
/// that covers it via `AppRouter`. Unlike V1's `FirstStepsChecklistView`
/// (which tracked live done/not-done state off `AppState`), this is
/// intentionally static content: V2 has no equivalent per-step completion
/// tracker yet, and a checklist that always shows "what to try next" is
/// still useful without one.
public struct FirstStepsView: View {
    private struct Step: Identifiable {
        // Task 5b (2026-08-17): `title`/`reason`/`actionTitle` were plain
        // `String` -- an eighth instance of the same defect this task's gate
        // now catches by name/shape (`title`/`actionTitle` are in the
        // gate's own word list; `reason` is not, and was found only by
        // reading this struct next to them -- see the gate's own "what this
        // does not catch" note). `id` used to be `title` itself (unique by
        // construction, per the original comment on `steps` below); now
        // that `title` is a `LocalizedStringKey` (not `Hashable`/`Equatable`
        // in a way this struct wants to lean on for identity), `id` reads a
        // separate, still-plain-`String` `key` instead.
        let title: LocalizedStringKey
        let reason: LocalizedStringKey
        let actionTitle: LocalizedStringKey
        let systemImage: String
        let perform: (AppRouter) -> Void
        let key: String
        var id: String { key }
    }

    private static let steps: [Step] = [
        Step(
            title: "Choose your image library",
            reason: "AstroTool builds a local, read-only index of your capture folder -- nothing in it is ever moved or modified.",
            actionTitle: "Open Library", systemImage: "photo.on.rectangle.angled",
            perform: { $0.navigate(to: .library) }, key: "library"
        ),
        Step(
            title: "Check Library Health",
            reason: "See calibration gaps, duplicate files, and audit findings before you head out for another night.",
            actionTitle: "Open Health", systemImage: "checkmark.shield",
            perform: { $0.navigate(toContent: .health) }, key: "health"
        ),
        Step(
            title: "Review your captured frames",
            reason: "Accept, reject, and score frames from a session, then see how each series measures up.",
            actionTitle: "Open Projects", systemImage: "square.stack.3d.up",
            perform: { $0.navigate(to: .projects) }, key: "review"
        ),
        Step(
            title: "Plan your next clear night",
            reason: "Compare honest framing and integration-time estimates for upcoming targets before you commit a night to one.",
            actionTitle: "Open Planning", systemImage: "calendar",
            perform: { $0.navigate(to: .planning) }, key: "planning"
        ),
        Step(
            title: "Track your observing nights",
            reason: "See duty cycle, triage state, and which nights still need a decision.",
            actionTitle: "Open Nights", systemImage: "moon.stars",
            perform: { $0.navigate(to: .nights) }, key: "nights"
        ),
        Step(
            title: "Learn the vocabulary",
            reason: "Look up any unfamiliar term -- FWHM, Bortle, dither, and the rest -- any time.",
            actionTitle: "Open Glossary", systemImage: "character.book.closed",
            perform: { $0.present(.glossary(nil)) }, key: "glossary"
        ),
    ]

    let router: AppRouter
    let dismiss: () -> Void

    public init(router: AppRouter, dismiss: @escaping () -> Void) {
        self.router = router
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("First Steps").font(.headline)
                Spacer()
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.steps) { step in
                    row(step)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("v2.help.first-steps")
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.systemImage)
                .foregroundStyle(AstroTokens.Color.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.callout).bold()
                Text(step.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(step.actionTitle) {
                step.perform(router)
                dismiss()
            }
            .buttonStyle(.link)
        }
    }
}
