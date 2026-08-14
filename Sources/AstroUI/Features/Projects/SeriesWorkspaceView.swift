import AstroApplication
import SwiftUI

public struct SeriesWorkspaceView: View {
    let item: ProjectSeriesSnapshot
    let project: ProjectRecord
    let night: NightRecord
    let review: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project › \(project.catalogID) › Night › \(night.localDate) › Series › \(exposure)")
                    .font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.spectralViolet)
                Text(seriesTitle).font(.title2.weight(.semibold))
                Text(item.series.setupDescriptor).font(.callout).foregroundStyle(.secondary)
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                    HStack(spacing: AstroTokens.Spacing.standard) {
                        MetricCard(title: "Usable", value: item.usableFrames.formatted(), detail: "\(item.excludedFrames) excluded", systemImage: "photo.stack")
                        MetricCard(title: "Integration", value: duration(item.integrationSeconds), detail: "\(item.totalFrames) total frames", systemImage: "timer")
                        MetricCard(title: "Exposure", value: exposure, detail: item.series.binning, systemImage: "camera.shutter.button")
                    }
                    GroupBox("Capture settings") {
                        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                            row("Sensor mode", item.series.sensorMode.rawValue.uppercased())
                            row("Passband", item.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            row("Filter", item.series.filterName ?? "Unfiltered")
                            row("Setup", item.series.setupDescriptor)
                            row("Gain / offset", gainOffset)
                            row("Binning", item.series.binning)
                        }.padding(8)
                    }
                }
                .padding(AstroTokens.Spacing.spacious)
            }
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle(seriesTitle)
        .accessibilityIdentifier("v2.series.workspace")
        // Wave 4 Task 2: "Review Frames" used to be an in-body button in
        // this same header -- it now renders in the shell's own stable
        // toolbar (see `WorkspaceActions`'s doc comment).
        .focusedSceneValue(\.workspaceActions, workspaceActions)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .button(WorkspaceAction(
                id: "v2.series.review",
                title: "Review Frames",
                systemImage: "checkmark.rectangle.stack",
                action: review
            )),
        ])
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
    private var exposure: String { "\(item.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...1)))) s" }
    private var seriesTitle: String { [item.series.filterName, exposure].compactMap { $0 }.joined(separator: " · ") }
    private var gainOffset: String {
        let values = [item.series.gain.map { String($0) }, item.series.offset.map { String($0) }].compactMap { $0 }
        return values.isEmpty ? "—" : values.joined(separator: " / ")
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
