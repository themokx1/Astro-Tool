import AstroApplication
import SwiftUI

public struct NightsView: View {
    let snapshot: LibrarySnapshot?
    let chooseLibrary: () -> Void

    public var body: some View {
        WorkspacePage(eyebrow: "Capture history", title: "Nights", subtitle: "Review each observing night without losing its series boundaries.") {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Observed nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Detected date-based sessions", systemImage: "calendar")
                MetricCard(title: "Frames", value: snapshot.map { "\($0.frameCount)" } ?? "—", detail: "Indexed read-only", systemImage: "photo.stack")
            }
            GroupBox("Session model") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A night can contain multiple OSC, narrowband, exposure, and filter series.", systemImage: "square.stack.3d.up")
                    Label("Quality and reports stay comparable per series and roll up to the night.", systemImage: "chart.line.uptrend.xyaxis")
                    if snapshot == nil { Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .navigationTitle("Nights")
        .accessibilityLabel("Nights")
        .accessibilityIdentifier("v2.detail.nights")
    }
}
