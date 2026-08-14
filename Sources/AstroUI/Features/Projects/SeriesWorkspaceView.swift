import AstroApplication
import SwiftUI

public struct SeriesWorkspaceView: View {
    /// Wave 4 Task 3: unlike `ProjectWorkspaceView`/`NightWorkspaceView`,
    /// this tab is plain local `@State`, not a router property. A series is
    /// a LEAF of the navigation stack -- nothing is ever pushed on top of
    /// it, so `.id(route)` (see `DetailHost`'s doc comment) only ever resets
    /// this state when the route itself changes to a DIFFERENT series,
    /// which should reasonably start that different series back on
    /// Overview anyway. Router-backed state would only earn its keep if a
    /// deeper push-and-pop-back could reset it first, which cannot happen
    /// here.
    private enum Tab: String, CaseIterable {
        case overview = "Overview"
        case frames = "Frames"
    }

    let item: ProjectSeriesSnapshot
    let project: ProjectRecord
    let night: NightRecord
    let review: () -> Void
    @State private var tab = Tab.overview
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here. This view is a navigation-stack
    /// LEAF (see this type's own doc comment above), so unlike the other
    /// workspaces it has no deeper `.onChange(of:)` hook to add: its own
    /// actions never vary within one instance's lifetime.
    @State private var actionOwner = UUID().uuidString

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(seriesTitle).font(.title2.weight(.semibold))
                Text(item.series.setupDescriptor).font(.callout).foregroundStyle(.secondary)
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            Picker("Series section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            ScrollView {
                content.padding(AstroTokens.Spacing.spacious)
            }
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle(seriesTitle)
        .accessibilityIdentifier("v2.series.workspace")
        // Wave 4 Task 2: "Review Frames" used to be an in-body button in
        // this same header -- it now renders in the shell's own stable
        // toolbar (see `WorkspaceActions`'s doc comment). Wave 4 Task 3
        // removed the redundant chained "Project"/"Series" eyebrow prefix that
        // used to duplicate the now-global breadcrumb.
        // Wave 4 (post-20014) fix: published from `.onAppear` rather than
        // from `body` itself -- see `WorkspaceActionCenter`'s own doc
        // comment.
        .onAppear { workspaceActionCenter.publish(owner: actionOwner, workspaceActions) }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview:
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
        case .frames:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                Text("\(item.usableFrames) usable · \(item.excludedFrames) excluded frames in this series.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review Frames") { review() }
                    .buttonStyle(.borderedProminent)
            }
        }
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
