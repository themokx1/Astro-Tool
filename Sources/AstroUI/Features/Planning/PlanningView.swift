import SwiftUI

public struct PlanningView: View {
    let createProject: () -> Void

    public var body: some View {
        WorkspacePage(eyebrow: "Next clear night", title: "Planning", subtitle: "Move from a target idea to a capture-ready plan with fewer decisions.") {
            GroupBox("Planning baseline") {
                VStack(alignment: .leading, spacing: 14) {
                    Label("10 hours at f/5 on APS-C is the approachable reference baseline.", systemImage: "timer")
                    Label("Targets adjust that goal by brightness and surface brightness — never by a single universal number.", systemImage: "circle.lefthalf.filled")
                    Label("Setup, framing, filters, Moon, and altitude remain visible before committing a night.", systemImage: "scope")
                    Button("Choose a Target…", action: createProject).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .navigationTitle("Planning")
        .accessibilityLabel("Planning")
        .accessibilityIdentifier("v2.detail.planning")
    }
}
