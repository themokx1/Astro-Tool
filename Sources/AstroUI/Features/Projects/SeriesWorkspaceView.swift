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

        /// W3-9: the segmented picker below used to render `Text($0.rawValue)`.
        var displayLabel: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }

    let item: ProjectSeriesSnapshot
    let project: ProjectRecord
    let night: NightRecord
    let review: () -> Void
    /// Task 4 (2026-08-17 owner-feedback wave 3): the owner could not find a
    /// way back from this page ("ha a sorozat listára jutok, nem tudom hogy
    /// megyek vissza") -- the global `BreadcrumbBar` above the detail stack
    /// already offers one (its "Project" crumb pops right back here), but it
    /// apparently was not visible/discoverable enough on its own. `back`
    /// gives this page ITS OWN explicit, visible way back, right next to its
    /// other primary actions; `DetailHost` wires it to `router.pop()`, the
    /// same "one step back" `AppRouter.pop()`'s own doc comment describes as
    /// the programmatic equivalent of the native Back chevron.
    let back: () -> Void
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
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(seriesTitle).font(.title2.weight(.semibold))
                    Text(item.series.setupDescriptor).font(.callout).foregroundStyle(.secondary)
                }
                // Task 4 (2026-08-17 owner-feedback wave 3): this page's own
                // primary action (Review Frames) plus an explicit, visible
                // way back to the project -- both above the content, next to
                // the identity they belong to. The toolbar keeps its own
                // "Review Frames" copy (`workspaceActions` below).
                HStack(spacing: 8) {
                    Button(action: back) {
                        Label("Back to Project", systemImage: "chevron.backward")
                    }
                    .help("Return to \(project.displayName)")
                    .accessibilityIdentifier("v2.series.page.back")

                    Button(action: review) {
                        Label("Review Frames", systemImage: "checkmark.rectangle.stack")
                    }
                    .accessibilityIdentifier("v2.series.page.review")
                }
                .buttonStyle(.bordered)
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            Picker("Series section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            .accessibilityIdentifier("v2.series.workspace.tab")
            ScrollView {
                content.padding(AstroTokens.Spacing.spacious)
            }
        }
        // Task 7b (2026-08-17): self-tint removed -- `V2RootView`'s detail
        // column owns the single opaque `ground` page backdrop now.
        .navigationTitle(seriesTitle)
        .accessibilityIdentifier("v2.series.workspace")
        // Task 4 (2026-08-17 owner-feedback wave 3) reverses Wave 4 Task 2's
        // "Review Frames lives only in the shell's stable toolbar" decision
        // -- it (plus an explicit Back button) is back in the header above,
        // directly on the page; the toolbar (`workspaceActions` below) keeps
        // its own "Review Frames" copy. Wave 4 Task 3's removed chained
        // "Project"/"Series" eyebrow prefix stays gone -- redundant with the
        // now-global breadcrumb either way.
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
                    MetricCard(title: "Integration", value: AstroFormat.duration(seconds: item.integrationSeconds), detail: "\(item.totalFrames) total frames", systemImage: "timer")
                    MetricCard(title: "Exposure", value: exposure, detail: LocalizedStringKey(item.series.binning), systemImage: "camera.shutter.button")
                }
                // Task 7 (2026-08-17, GroupBox removal): a label/value grid
                // is exactly what a standard `Form`/`Section` renders --
                // `FrameInspector`'s own `Form { Section("Frame") {
                // LabeledContent(...) } }` is the precedent this follows,
                // rather than a `GroupBox` wrapping a hand-rolled `Grid`.
                Form {
                    Section("Capture settings") {
                        LabeledContent("Sensor mode", value: item.series.sensorMode.rawValue.uppercased())
                        LabeledContent("Passband", value: item.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        LabeledContent("Filter", value: item.series.filterName ?? "Unfiltered")
                        LabeledContent("Setup", value: item.series.setupDescriptor)
                        LabeledContent("Gain / offset", value: gainOffset)
                        LabeledContent("Binning", value: item.series.binning)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            }
        case .frames:
            // Task 7c: a sentence plus its action is a content block, so it
            // reads on the raised layer rather than as loose text on grey.
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                Text("\(item.usableFrames) usable · \(item.excludedFrames) excluded frames in this series.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review Frames") { review() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
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

    private var exposure: String { AstroFormat.exposureSeconds(item.series.exposureSeconds) }
    private var seriesTitle: String { [item.series.filterName, exposure].compactMap { $0 }.joined(separator: " · ") }
    private var gainOffset: String {
        let values = [item.series.gain.map { String($0) }, item.series.offset.map { String($0) }].compactMap { $0 }
        return values.isEmpty ? "—" : values.joined(separator: " / ")
    }
}
