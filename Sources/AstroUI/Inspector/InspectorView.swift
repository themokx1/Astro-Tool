import AppKit
import AstroApplication
import SwiftUI

/// Wave 3 Task 8: the shell's `.inspector()` panel, made contextual --
/// switches on the router's current selection and renders real content
/// sourced from the stores already open in this window (`ProjectsStore`/
/// `NightsStore`/`ReviewStore`), the same data their own detail views
/// already show. No new queries are introduced here except `ResultsQuery`
/// for the result case, which -- like every store's own `open()` -- simply
/// calls an existing query type against the already-open `MetadataStore`;
/// no result-lineage store exists anywhere in the environment to reuse
/// instead (`ResultsView` keeps its own `ResultsStore` entirely private).
///
/// Every branch that cannot find real data for its selection (the
/// project/night/series/result string doesn't resolve against what's
/// currently loaded, or a `.frame` selection -- which nothing in
/// production actually constructs today, see `LibrarySelection.frame`'s
/// own doc comment) renders an honest, quiet placeholder rather than
/// pretending to show something -- never a silent no-op.
public struct InspectorView: View {
    public let selection: LibrarySelection?
    public let rootURL: URL?
    public let projectsStore: ProjectsStore
    public let nightsStore: NightsStore
    public let reviewStore: ReviewStore
    private let hideInspector: () -> Void
    @Environment(OperationHost.self) private var operationHost

    public init(
        selection: LibrarySelection?,
        rootURL: URL?,
        projectsStore: ProjectsStore,
        nightsStore: NightsStore,
        reviewStore: ReviewStore,
        hideInspector: @escaping () -> Void = {}
    ) {
        self.selection = selection
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
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "sidebar.right")
                } description: {
                    Text("Select a project, night, series, or result to inspect it here.")
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
        case .result(let rawID):
            resultPanel(rawID)
        }
    }

    @ViewBuilder
    private func projectPanel(_ rawID: String) -> some View {
        if let id = UUID(uuidString: rawID),
           let snapshot = projectsStore.selectedProject,
           snapshot.id == id {
            ProjectInspectorPanel(
                snapshot: snapshot,
                annotation: projectsStore.selectedProjectAnnotation,
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

    @ViewBuilder
    private func resultPanel(_ rawID: String) -> some View {
        ResultInspectorPanel(
            resultIDString: rawID,
            metadataStore: projectsStore.metadataStore,
            projectID: projectsStore.selectedProjectID
        )
    }

    @ViewBuilder
    private func unavailable(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

/// Project selection's inspector content: identity, progress toward its
/// integration goal, and the two Finder quick actions the plan calls for
/// -- both resolved against the latest night's session folder, the only
/// on-disk location a (potentially many-night) project maps to directly.
private struct ProjectInspectorPanel: View {
    let snapshot: ProjectSnapshot
    let annotation: ProjectAnnotationRecord?
    let rootURL: URL?

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Catalog ID", value: snapshot.project.catalogID)
                LabeledContent("Name", value: snapshot.project.displayName)
                LabeledContent("Folder", value: snapshot.canonicalFolderName)
                LabeledContent("Phase") { Text(snapshot.project.phase.displayLabel) }
            }
            Section("Progress") {
                LabeledContent("Integration", value: duration(snapshot.integrationSeconds))
                if let goalHours = annotation?.integrationGoalHours, goalHours > 0 {
                    LabeledContent("Goal", value: "\(goalHours.formatted(.number.precision(.fractionLength(0...1)))) h")
                    ProgressView(value: min(1, (snapshot.integrationSeconds / 3600) / goalHours))
                }
                LabeledContent("Usable frames", value: "\(snapshot.usableFrames)")
                LabeledContent("Latest night", value: snapshot.nights.first?.night.localDate ?? "—")
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
        .accessibilityIdentifier("v2.inspector.project")
    }

    private var latestNightURL: URL? {
        guard let rootURL, let date = snapshot.nights.first?.night.localDate else { return nil }
        return FrameThumbnailCell.resolvedURL(
            rootURL: rootURL,
            relativePath: "sessions/\(snapshot.canonicalFolderName)/\(date)"
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

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
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
                LabeledContent("Status", value: row.triageState.rawValue)
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
        .accessibilityIdentifier("v2.inspector.night")
    }

    private var folderURL: URL? {
        guard let rootURL, let project = row.snapshot.projects.first else { return nil }
        let target = ProjectsQuery.canonicalFolderName(for: project)
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
private struct SeriesSummaryPanel: View {
    let item: ProjectSeriesSnapshot

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Exposure", value: exposure)
                LabeledContent("Sensor", value: item.series.sensorMode.rawValue.uppercased())
                LabeledContent("Passband", value: passband)
                LabeledContent("Filter", value: item.series.filterName ?? "No filter recorded")
            }
            Section("Setup") {
                LabeledContent("Equipment", value: item.series.setupDescriptor)
                LabeledContent("Binning", value: item.series.binning)
            }
            Section("Frames") {
                LabeledContent("Usable", value: "\(item.usableFrames)")
                LabeledContent("Excluded", value: "\(item.excludedFrames)")
                LabeledContent("Integration", value: duration(item.integrationSeconds))
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.inspector.series-summary")
    }

    private var exposure: String {
        "\(item.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...2)))) s"
    }

    private var passband: String {
        item.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Result selection's inspector content: a provenance summary in the same
/// vocabulary as `ResultsView`'s own (private) `resultDetail` -- role,
/// kind, software, and lineage counts -- loaded through `ResultsQuery`
/// against the already-open `MetadataStore` `ProjectsStore` exposes.
/// `metadataStore`/`projectID` are both `nil` until a project is open in
/// this window (the only way `.result` selections are reached today: a
/// global-search hit or a deep link, both of which select the owning
/// project first), so this degrades to an honest placeholder rather than
/// querying with no store or no project to scope the lookup to.
///
/// Wave 4 Task 1: also reused directly as `V2RootView`'s
/// `.navigationDestination` content for the `.result(String)` route (a
/// lean provenance panel, per the navigation-rework plan) -- not `private`
/// so `V2RootView.swift` can construct it too.
struct ResultInspectorPanel: View {
    let resultIDString: String
    let metadataStore: MetadataStore?
    let projectID: UUID?
    @State private var result: ResultLineageSnapshot?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let result {
                ResultProvenancePanel(result: result)
            } else if isLoading {
                ProgressView("Reading result lineage…")
            } else {
                ContentUnavailableView {
                    Label("Result", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Open this result from its project or from search to inspect its provenance here.")
                }
            }
        }
        .task(id: taskID) { await load() }
    }

    private var taskID: String { "\(resultIDString)|\(projectID?.uuidString ?? "-")" }

    private func load() async {
        result = nil
        guard let metadataStore, let projectID, let resultID = UUID(uuidString: resultIDString) else { return }
        isLoading = true
        defer { isLoading = false }
        let snapshot = try? await ResultsQuery(metadata: metadataStore).snapshot(projectID: projectID)
        result = snapshot?.results.first { $0.id == resultID }
    }
}

private struct ResultProvenancePanel: View {
    let result: ResultLineageSnapshot

    var body: some View {
        Form {
            Section("Result") {
                LabeledContent("Role", value: result.role.rawValue.capitalized)
                LabeledContent("Kind", value: result.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                LabeledContent("Created", value: result.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Software", value: softwareLabel)
            }
            Section("Lineage") {
                LabeledContent("Input series", value: "\(result.inputSeriesIDs.count)")
                LabeledContent("Input frames", value: "\(result.sourceFrameIDs.count)")
                LabeledContent("Source results", value: "\(result.sourceResultIDs.count)")
                LabeledContent("Calibration assets", value: "\(result.calibrationAssets.count)")
            }
            Section("File") {
                Text(result.relativePath ?? "No path recorded")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.inspector.result")
    }

    private var softwareLabel: String {
        let joined = [result.softwareName, result.softwareVersion].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? "Unknown" : joined
    }
}
