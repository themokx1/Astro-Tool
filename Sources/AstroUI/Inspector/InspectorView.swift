import AppKit
import AstroApplication
import SwiftUI

/// Wave 3 Task 8: the shell's `.inspector()` panel, made contextual --
/// switches on the router's current selection and renders real content
/// sourced from the stores already open in this window (`ProjectsStore`/
/// `NightsStore`/`ReviewStore`), the same data their own detail views
/// already show. W4-6 (owner decision) first removed the (by-then honest-
/// placeholder-only) `.result` case's own lineage query, then the route
/// cleanup pass removed `LibrarySelection.result`/`ContentRoute.result`
/// entirely: no writer anywhere in the product ever populated the two
/// lineage tables the old query read, schema v8 dropped them, and global
/// search had already stopped producing `.result` hits, leaving nothing
/// left that could ever construct the case.
///
/// Every branch that cannot find real data for its selection (the
/// project/night/series string doesn't resolve against what's currently
/// loaded, or a `.frame` selection -- which nothing in production actually
/// constructs today, see `LibrarySelection.frame`'s own doc comment)
/// renders an honest, quiet placeholder rather than pretending to show
/// something -- never a silent no-op.
///
/// W3-9 (Defect 3): an owner screenshot showed the project detail page open
/// (real project metadata visible in the detail column) while this
/// inspector showed its generic "No Selection" empty state -- two
/// contradictory states implying the app didn't know what was open. The
/// cause: this view only ever rendered from `selection`
/// (`AppRouter.inspectorSelection`), which is a narrower concept than "what
/// route is currently open" -- it is `nil` on plenty of ticks where a
/// project legitimately IS open in the detail column but nothing MORE
/// specific (a night/series/frame) is selected inside it. The old
/// body treated that exactly like "nothing is open at all". Finder's own
/// inspector doesn't do this: with no specific item selected it shows the
/// CURRENT FOLDER, not a blank panel -- the folder is the fallback, not the
/// empty state. `isProjectRouteActive` is that same fallback signal here:
/// when true, a missing `selection` falls back to the currently open
/// project's own `ProjectInspectorPanel` (already loaded in
/// `projectsStore.selectedProject`, the same data `ProjectWorkspaceView`
/// itself renders from); the "No Selection" empty state is now reserved for
/// when there is truly no context at all (Home, Nights, Planning, Library,
/// Insights, or the bare Projects list).
public struct InspectorView: View {
    public let selection: LibrarySelection?
    /// `true` whenever the active route sits inside the Projects journey
    /// below its own list root (a project is open in the detail column,
    /// whether or not anything more specific is selected inside it) -- see
    /// this type's own doc comment.
    public let isProjectRouteActive: Bool
    public let rootURL: URL?
    public let projectsStore: ProjectsStore
    public let nightsStore: NightsStore
    public let reviewStore: ReviewStore
    private let hideInspector: () -> Void
    @Environment(OperationHost.self) private var operationHost

    public init(
        selection: LibrarySelection?,
        isProjectRouteActive: Bool = false,
        rootURL: URL?,
        projectsStore: ProjectsStore,
        nightsStore: NightsStore,
        reviewStore: ReviewStore,
        hideInspector: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.isProjectRouteActive = isProjectRouteActive
        self.rootURL = rootURL
        self.projectsStore = projectsStore
        self.nightsStore = nightsStore
        self.reviewStore = reviewStore
        self.hideInspector = hideInspector
    }

    public var body: some View {
        Group {
            if let selection {
                selectionDetails(selection)
            } else if isProjectRouteActive, let snapshot = projectsStore.selectedProject {
                // The route's own context, per this type's own doc comment --
                // the exact same data `ProjectWorkspaceView` itself renders
                // from, never re-queried here.
                ProjectInspectorPanel(
                    snapshot: snapshot,
                    rootURL: rootURL
                )
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "sidebar.right")
                } description: {
                    Text("Select a project, night, or series to inspect it here.")
                } actions: {
                    Button("Hide Inspector", action: hideInspector)
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
        .accessibilityLabel("Inspector")
        .accessibilityIdentifier("v2.inspector")
    }

    @ViewBuilder
    private func selectionDetails(_ selection: LibrarySelection) -> some View {
        switch selection {
        case .project(let rawID):
            projectPanel(rawID)
        case .night(let rawID):
            nightPanel(rawID)
        case .series(let rawID):
            seriesPanel(rawID)
        case .frame:
            framePanel()
        }
    }

    @ViewBuilder
    private func projectPanel(_ rawID: String) -> some View {
        if let id = UUID(uuidString: rawID),
           let snapshot = projectsStore.selectedProject,
           snapshot.id == id {
            ProjectInspectorPanel(
                snapshot: snapshot,
                rootURL: rootURL
            )
        } else {
            unavailable(
                "Project", systemImage: "folder",
                message: "This project's details aren't loaded in this window yet."
            )
        }
    }

    @ViewBuilder
    private func nightPanel(_ rawID: String) -> some View {
        if let id = UUID(uuidString: rawID),
           let row = nightsStore.nights.first(where: { $0.id == id }) {
            NightInspectorPanel(row: row, rootURL: rootURL)
        } else {
            unavailable(
                "Night", systemImage: "moon.stars",
                message: "This night's details aren't loaded in this window yet."
            )
        }
    }

    @ViewBuilder
    private func seriesPanel(_ rawID: String) -> some View {
        if let id = UUID(uuidString: rawID),
           let reviewSnapshot = reviewStore.snapshot?.series.first(where: { $0.id == id }) {
            // Richest case: this series' project is open for review, so the
            // full `SeriesInspector` (with filter assignment) applies as-is.
            SeriesInspector(snapshot: reviewSnapshot)
        } else if let id = UUID(uuidString: rawID),
                  let projectSnapshot = projectsStore.selectedProject,
                  let item = projectSnapshot.nights.flatMap(\.series).first(where: { $0.id == id }) {
            // Lean fallback: the project workspace already loaded this
            // series' capture settings even though Review hasn't been
            // opened for it -- a smaller, read-only summary from that.
            SeriesSummaryPanel(item: item)
        } else {
            unavailable(
                "Series", systemImage: "square.stack.3d.up",
                message: "Open this series' project to inspect its capture settings."
            )
        }
    }

    @ViewBuilder
    private func framePanel() -> some View {
        // No production call site constructs `.frame(_:)` today (its
        // `Int64` payload matches no identifier `FrameDecisionRecord`
        // actually uses -- see `LibrarySelection.frame`'s own doc comment
        // in `AppRoute.swift`), and `ReviewWorkspace`'s own embedded
        // inspector already shows `FrameInspector` with a real archive
        // action while a review is open. This panel exists only for the
        // structurally-possible-but-unreachable case a stale restored
        // selection or a future deep link lands here without an open
        // review -- honest, not a silent no-op.
        unavailable(
            "Frame", systemImage: "photo",
            message: "Frame details are shown while reviewing frames in the Review workspace."
        )
    }

    // W3-9 sweep: `title`/`message` used to be `String`, so every call site
    // below -- despite passing literal text -- routed through `Label`/
    // `Text`'s verbatim overload once the literal crossed this function's
    // own parameter boundary (the same class of bug this task exists to
    // fix, just via a helper function instead of a store). `LocalizedStringKey`
    // lets each call site's literal actually localize, with no call site
    // changes needed.
    @ViewBuilder
    private func unavailable(_ title: LocalizedStringKey, systemImage: String, message: LocalizedStringKey) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

/// Project selection's inspector content: identity and the two Finder
/// quick actions the plan calls for -- both resolved against the latest
/// night's session folder, the only on-disk location a (potentially
/// many-night) project maps to directly.
///
/// Task 2 (owner review wave 4-4): "the project page duplicates itself into
/// the inspector" -- this used to ALSO carry a "Progress" section
/// (Integration/usable frames/latest night, plus an optional goal
/// `ProgressView`) that repeated `ProjectWorkspaceView`'s own three hero
/// metric cards (Integráció/Képkockák/Legutóbbi éjszaka) as a second set of
/// rows, side by side with the page itself. One fact, one home: the page
/// keeps its hero cards, and this panel keeps only what is NOT already
/// shown there -- identity and Quick actions. `annotation` (the goal-hours
/// value the removed section alone read) is dropped from this panel
/// entirely along with it; nothing else here used it.
private struct ProjectInspectorPanel: View {
    let snapshot: ProjectSnapshot
    let rootURL: URL?

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Catalog ID", value: snapshot.project.catalogID)
                LabeledContent("Name", value: snapshot.project.displayName)
                LabeledContent("Folder", value: snapshot.canonicalFolderName)
                LabeledContent("Phase") { Text(snapshot.project.phase.displayLabel) }
            }
            Section("Quick actions") {
                Button("Open in Finder", systemImage: "folder", action: openLatestNightFolder)
                    .disabled(latestNightURL == nil)
                    .help("Open the latest night's session folder in Finder")
                Button("Reveal in Finder", systemImage: "magnifyingglass", action: revealLatestNightFolder)
                    .disabled(latestNightURL == nil)
                    .help("Select the latest night's session folder in its Finder window")
            }
        }
        .formStyle(.grouped)
        // Task 6 (2026-08-17, Liquid Glass): the inspector row of the
        // plan's own material table -- a `Form` of `LabeledContent`/`Button`
        // rows, never a `Table`/`List`, so it is one of the containers that
        // gets real glass rather than the panel's system-default fill.
        .glassEffect(.regular, in: ConcentricRectangle())
        .accessibilityIdentifier("v2.inspector.project")
    }

    /// One-letter-drift fix (2026-08-17): `snapshot.canonicalFolderName` is
    /// the catalog's own idea of the folder name, which can disagree with
    /// what the scanner actually found on disk (see `ProjectsQuery.
    /// resolvedFolderName`'s own doc comment) -- resolved here so "Open"/
    /// "Reveal in Finder" don't silently disable themselves for a project
    /// whose real session folder is spelled differently than its catalog
    /// canonical name.
    private var latestNightURL: URL? {
        guard let rootURL, let date = snapshot.nights.first?.night.localDate else { return nil }
        let target = ProjectsQuery.resolvedFolderName(canonical: snapshot.canonicalFolderName, rootURL: rootURL)
        return FrameThumbnailCell.resolvedURL(
            rootURL: rootURL,
            relativePath: "sessions/\(target)/\(date)"
        )
    }

    private func openLatestNightFolder() {
        guard let url = latestNightURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealLatestNightFolder() {
        guard let url = latestNightURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Night selection's inspector content, from the already-loaded `NightRow`
/// (`NightsStore.nights` -- the exact rows `NightsView`'s own table
/// shows), plus the same Finder quick actions the project panel offers.
private struct NightInspectorPanel: View {
    let row: NightRow
    let rootURL: URL?

    var body: some View {
        Form {
            Section("Night") {
                LabeledContent("Date", value: row.date)
                LabeledContent("Projects", value: row.projectSummary.isEmpty ? "—" : row.projectSummary)
                LabeledContent("Series", value: "\(row.seriesCount)")
                // `LabeledContent(_:value:)` always renders `value:` with
                // `Text(verbatim:)`, whatever type it's given -- `.rawValue`
                // used to leak English here even after `TriageState` gained
                // its own `displayLabel`/`localizedText` pair (W3-9 sweep);
                // `localizedText` is the eagerly-resolved `String` this
                // specific call shape needs.
                LabeledContent("Status", value: row.triageState.localizedText)
            }
            Section("Frames") {
                LabeledContent("Usable", value: "\(row.snapshot.usableFrames)")
                LabeledContent("Excluded", value: "\(row.excludedFrames)")
                LabeledContent("Integration", value: row.integrationSummary)
            }
            Section("Quick actions") {
                Button("Open in Finder", systemImage: "folder", action: openFolder)
                    .disabled(folderURL == nil)
                    .help("Open this night's session folder in Finder")
                Button("Reveal in Finder", systemImage: "magnifyingglass", action: revealFolder)
                    .disabled(folderURL == nil)
                    .help("Select this night's session folder in its Finder window")
            }
        }
        .formStyle(.grouped)
        // Task 6 (2026-08-17, Liquid Glass): same treatment as
        // `ProjectInspectorPanel` above -- see its own comment.
        .glassEffect(.regular, in: ConcentricRectangle())
        .accessibilityIdentifier("v2.inspector.night")
    }

    /// Same one-letter-drift fix as `ProjectInspectorPanel.latestNightURL`
    /// above -- resolved against disk before it becomes a path.
    private var folderURL: URL? {
        guard let rootURL, let project = row.snapshot.projects.first else { return nil }
        let canonical = ProjectsQuery.canonicalFolderName(for: project)
        let target = ProjectsQuery.resolvedFolderName(canonical: canonical, rootURL: rootURL)
        return FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: "sessions/\(target)/\(row.date)")
    }

    private func openFolder() {
        guard let url = folderURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealFolder() {
        guard let url = folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The lean series fallback (no open Review session for this series):
/// the same capture-settings fields `SeriesWorkspaceView` already shows,
/// from `ProjectSeriesSnapshot` -- no filter-assignment editor, since that
/// belongs to the series workspace itself, not a supplementary panel.
///
/// Task 2 (owner review wave 4-4): "Check .projectSeries for the same
/// pattern" -- this used to ALSO carry a "Frames" section (Usable/Excluded/
/// Integration) that repeated `SeriesWorkspaceView`'s own "Usable"/
/// "Integration" hero metric cards as a second set of rows. Dropped for the
/// same "one fact, one home" reason as `ProjectInspectorPanel`'s own
/// "Progress" section above; Capture/Setup stay, since nothing on the page
/// itself shows them as hero cards.
private struct SeriesSummaryPanel: View {
    let item: ProjectSeriesSnapshot

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Exposure", value: exposure)
                LabeledContent("Sensor", value: item.series.sensorMode.localizedText)
                LabeledContent("Passband", value: passband)
                LabeledContent("Filter", value: item.series.filterName ?? NSLocalizedString("No filter recorded", bundle: .main, comment: ""))
            }
            Section("Setup") {
                LabeledContent("Equipment", value: item.series.setupDescriptor)
                LabeledContent("Binning", value: item.series.binning)
            }
        }
        .formStyle(.grouped)
        // Task 6 (2026-08-17, Liquid Glass): same treatment as
        // `ProjectInspectorPanel` -- see its own comment.
        .glassEffect(.regular, in: ConcentricRectangle())
        .accessibilityIdentifier("v2.inspector.series-summary")
    }

    private var exposure: String {
        "\(item.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...2)))) s"
    }

    private var passband: String {
        item.series.passband.localizedText
    }
}

/// `LabeledContent(_:value:)` always renders `value:` with `Text(verbatim:)`
/// (see `NightInspectorPanel`'s own comment above) -- these three eagerly
/// resolve the same way `SeriesPassband.localizedText`/
/// `NightRow.TriageState.localizedText` do, for the enums this file's
/// `SeriesSummaryPanel` renders through `LabeledContent`.
extension SeriesSensorMode {
    var localizedText: String {
        switch self {
        case .osc: NSLocalizedString("OSC", bundle: .main, comment: "")
        case .mono: NSLocalizedString("MONO", bundle: .main, comment: "")
        case .dslr: NSLocalizedString("DSLR", bundle: .main, comment: "")
        case .unknown: NSLocalizedString("Unknown", bundle: .main, comment: "")
        }
    }
}

