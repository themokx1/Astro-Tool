import AstroApplication
import SwiftUI

public struct InsightsView: View {
    let snapshot: LibrarySnapshot?
    let chooseLibrary: () -> Void

    public var body: some View {
        WorkspacePage(eyebrow: "Long-term signal", title: "Insights", subtitle: "See what you photographed, how much you collected, and where the workflow needs attention.") {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: snapshot.map { "\($0.projectCount)" } ?? "—", detail: "Library coverage", systemImage: "folder")
                MetricCard(title: "Nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Capture history", systemImage: "moon.stars")
                MetricCard(title: "Frames", value: snapshot.map { "\($0.frameCount)" } ?? "—", detail: "Indexed material", systemImage: "photo.stack")
            }
            GroupBox("Beta dashboard") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("The first beta reports only facts verified by the local index.", systemImage: "checkmark.shield")
                    Label("Integration time, filter balance, quality trends, and archive savings will appear as their workflow stores connect.", systemImage: "chart.xyaxis.line")
                    if snapshot == nil { Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .navigationTitle("Insights")
        .accessibilityLabel("Insights")
        .accessibilityIdentifier("v2.detail.insights")
    }
}
