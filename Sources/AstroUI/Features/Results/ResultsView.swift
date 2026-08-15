import AstroApplication
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: this used to be a
/// `private final class` that resolved `ProjectsStore.productionMetadata`
/// directly inside `load`, so this whole screen had zero unit-test surface.
/// Follows `ProjectsStore`'s own `metadataFactory` injection pattern so
/// tests can supply a fixture-backed `MetadataStore` without touching the
/// filesystem-resolving production path.
@MainActor
@Observable
public final class ResultsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore

    public private(set) var snapshot: ResultsSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// This project's own library/folder key and most recent night, loaded
    /// alongside `snapshot` -- everything the "Export Stack List" menu item
    /// needs to call `ExportService.stackList(target:date:)`, without the
    /// export menu having to know how to resolve either on its own.
    public private(set) var canonicalFolderName: String?
    public private(set) var latestNightDate: String?

    private let metadataFactory: MetadataFactory

    public init(metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

    public func load(rootURL: URL, projectID: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL)
            snapshot = try await ResultsQuery(metadata: metadata).snapshot(projectID: projectID)
            if let projectSnapshot = try await ProjectsQuery(metadata: metadata).project(id: projectID) {
                canonicalFolderName = projectSnapshot.canonicalFolderName
                latestNightDate = projectSnapshot.nights.first?.night.localDate
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Wave 4 Task 3: `ProjectWorkspaceView`'s own Results tab hosts this exact
/// table/detail/QuickLook content, scoped to its project, instead of the
/// `ContentUnavailableView` placeholder that used to tell the reader to
/// press a separate "Results" button. Rather than duplicate `ResultsStore`
/// and every table/detail helper into a second type, `ResultsView` itself
/// grew a `showsHeader` switch: the full `.resultsWorkspace(projectID:)`
/// route shows its own title/icon/quick-actions header (`showsHeader:
/// true`, `ResultsView`'s own default), while `ProjectResultsPane` renders
/// the identical content with that header suppressed -- the tab's own
/// segmented picker is already the "what am I looking at" context, so a
/// second "Results" headline immediately under it would be redundant.
public struct ProjectResultsPane: View {
    let rootURL: URL
    let project: ProjectRecord

    public init(rootURL: URL, project: ProjectRecord) {
        self.rootURL = rootURL
        self.project = project
    }

    public var body: some View {
        ResultsView(rootURL: rootURL, project: project, showsHeader: false)
    }
}

public struct ResultsView: View {
    let rootURL: URL
    let project: ProjectRecord
    let showsHeader: Bool
    @State private var store: ResultsStore
    @State private var selectedResultID: UUID?
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString

    public init(rootURL: URL, project: ProjectRecord, showsHeader: Bool = true, store: ResultsStore = ResultsStore()) {
        self.rootURL = rootURL
        self.project = project
        self.showsHeader = showsHeader
        _store = State(initialValue: store)
    }

    // Wave 4 navigation-rework code-review fix: publishing workspace actions
    // used to be unconditional on the view below, so when this same content
    // is embedded (`showsHeader == false`, as `ProjectResultsPane` renders it
    // on the project workspace's own Results tab) it shadowed
    // `ProjectWorkspaceView`'s own published actions (Export/Review Frames/
    // Results) the moment that tab was showing -- the shell's toolbar
    // silently lost two of its three buttons. The fix branches at `body`'s
    // own top level: the publish hooks are only ever attached to the tree at
    // all on the STANDALONE route (`showsHeader == true`); the embedded
    // branch renders the identical `workspaceContent` with none of them
    // anywhere underneath it, so it never calls `workspaceActionCenter
    // .publish`/`.clear` at all -- it simply never becomes an owner.
    public var body: some View {
        if showsHeader {
            workspaceContent
                // Wave 4 Task 2: the Export Stack List menu used to be an
                // in-body button in this header -- it now renders in the
                // shell's own stable toolbar (see `WorkspaceActions`'s doc
                // comment).
                // Wave 4 (post-20014) fix: published from discrete
                // lifecycle/state-change events rather than from `body`
                // itself -- see `WorkspaceActionCenter`'s own doc comment.
                // `store.canonicalFolderName`/`store.latestNightDate` start
                // `nil` and are filled in asynchronously by `store.load`
                // (below), so both are watched explicitly rather than
                // relying on some unrelated re-render to catch them landing.
                .onAppear { publishWorkspaceActions() }
                .onChange(of: store.canonicalFolderName) { _, _ in publishWorkspaceActions() }
                .onChange(of: store.latestNightDate) { _, _ in publishWorkspaceActions() }
                .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
        } else {
            workspaceContent
        }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            if store.isLoading {
                ProgressView("Reading result lineage…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage {
                ContentUnavailableView("Results unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let snapshot = store.snapshot, !snapshot.results.isEmpty {
                // V2 UI/UX audit (2026-08-14) systemic pattern S10: this
                // split's own minimums (440 + 430 = 870) used to be an even
                // bigger floor than the outer view's old 780pt sheet-era one
                // (removed below) -- reduced so both panes still fit inside
                // the narrower detail column the shell's split view
                // actually gives this route.
                HSplitView {
                    resultTable(snapshot).frame(minWidth: 260, idealWidth: 400)
                    resultDetail(snapshot).frame(minWidth: 220)
                }
            } else {
                ContentUnavailableView {
                    Label("No results recorded", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("Prepared stacks and processed variants will appear here with their sources and software provenance.")
                }
            }
        }
        .background(.background)
        .task { await store.load(rootURL: rootURL, projectID: project.id) }
        // Wave 4 Task 3: a distinct identifier while embedded (no header) as
        // `ProjectWorkspaceView`'s Results tab, so UI automation can tell the
        // pushed `.resultsWorkspace(projectID:)` route apart from this same
        // content hosted inline in a project's own tab.
        .accessibilityIdentifier(showsHeader ? "v2.results.workspace" : "v2.project.results.pane")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(AstroTokens.Color.spectralViolet)
            VStack(alignment: .leading, spacing: 2) {
                Text("Results").font(.title2.bold())
                Text("\(project.displayName) · stacks, variants, and provenance").foregroundStyle(.secondary)
            }
            Spacer()
            if let snapshot = store.snapshot,
               let result = selectedResult(in: snapshot) {
                resultActions(result)
            }
        }.padding(20)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .exportMenu(WorkspaceActionExportMenu(
                id: "v2.results.export", items: stackListExportItems, accessibilityID: "v2.results.export"
            )),
        ])
    }

    /// The project's latest-night stack list (`AppState.exportStackList`'s
    /// V2 equivalent) -- `[]` until `store.load` has resolved this project's
    /// own library/folder key and most recent night.
    private var stackListExportItems: [ExportMenuItem] {
        guard let target = store.canonicalFolderName, let date = store.latestNightDate else { return [] }
        return [
            .file(title: "Stack List…", systemImage: "square.stack.3d.up", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).stackList(target: target, date: date)
                return (export.content, export.suggestedFilename, [])
            },
        ]
    }

    private func resultTable(_ snapshot: ResultsSnapshot) -> some View {
        Table(snapshot.results, selection: $selectedResultID) {
            TableColumn("Preview") { result in
                if let relativePath = result.relativePath {
                    FrameThumbnailCell(rootURL: rootURL, relativePath: relativePath)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .opacity(0.35)
                        .frame(width: 28, height: 28)
                }
            }
            .width(min: 36, ideal: 36, max: 36)
            TableColumn("Result") { result in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Label(result.role.rawValue.capitalized, systemImage: result.role == .final ? "checkmark.seal.fill" : "square.stack")
                            .font(.headline)
                        if snapshot.publishableResultID == result.id {
                            Text("Publishable").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(AstroTokens.Color.success.opacity(0.18), in: Capsule())
                                .accessibilityIdentifier("v2.results.publishable")
                        }
                    }
                    Text(result.relativePath ?? "Path not recorded")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 4)
            }
            TableColumn("Created") { result in
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 125, ideal: 145)
            TableColumn("Software") { result in
                Text(softwareLabel(result)).lineLimit(1)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: UUID.self) { resultIDs in
            if let result = snapshot.results.first(where: { resultIDs.contains($0.id) }) {
                resultActionMenu(result)
            }
        } primaryAction: { resultIDs in
            if let result = snapshot.results.first(where: { resultIDs.contains($0.id) }) {
                openResult(result)
            }
        }
        .background(QuickLookSpacebarMonitor(
            isEnabled: { selectedResultID != nil },
            onSpace: {
                if let result = selectedResult(in: snapshot) {
                    quickLook(result)
                }
            }
        ))
        .accessibilityIdentifier("v2.results.table")
        .onAppear {
            selectedResultID = selectedResultID ?? snapshot.publishableResultID ?? snapshot.results.last?.id
        }
    }

    private func resultActions(_ result: ResultLineageSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Open Result") { openResult(result) }
                .disabled(resultURL(for: result) == nil)
                .help("Open this result's file with its default application")
            Menu {
                resultActionMenu(result)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func resultActionMenu(_ result: ResultLineageSnapshot) -> some View {
        Button("Open Result") { openResult(result) }
            .disabled(resultURL(for: result) == nil)
        Button("Show in Finder") { revealResult(result) }
            .disabled(resultURL(for: result) == nil)
        Button("Quick Look") { quickLook(result) }
            .disabled(resultURL(for: result) == nil)
        Divider()
        Button("Copy Path") { copyPath(result) }
            .disabled(result.relativePath == nil)
    }

    private func selectedResult(in snapshot: ResultsSnapshot) -> ResultLineageSnapshot? {
        snapshot.results.first { $0.id == selectedResultID }
    }

    private func softwareLabel(_ result: ResultLineageSnapshot) -> String {
        [result.softwareName, result.softwareVersion]
            .compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown"
    }

    private func resultURL(for result: ResultLineageSnapshot) -> URL? {
        guard let relativePath = result.relativePath else { return nil }
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func openResult(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealResult(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func quickLook(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        QuickLookPreviewController.shared.preview(url)
    }

    private func copyPath(_ result: ResultLineageSnapshot) {
        guard let relativePath = result.relativePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePath, forType: .string)
    }

    @ViewBuilder private func resultDetail(_ snapshot: ResultsSnapshot) -> some View {
        if let result = snapshot.results.first(where: { $0.id == selectedResultID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(result.role.rawValue.capitalized).font(.largeTitle.bold())
                    HStack(spacing: 12) {
                        metric("Kind", result.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        metric("Created", result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        metric("Software", [result.softwareName, result.softwareVersion].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown")
                    }
                    GroupBox("Lineage") {
                        VStack(alignment: .leading, spacing: 10) {
                            lineageRow("Input series", count: result.inputSeriesIDs.count, icon: "camera.aperture")
                            lineageRow("Input frames", count: result.sourceFrameIDs.count, icon: "photo.stack")
                            lineageRow("Source result", count: result.sourceResultIDs.count, icon: "arrow.triangle.branch")
                            lineageRow("Calibration assets", count: result.calibrationAssets.count, icon: "circle.lefthalf.filled")
                            if let parent = result.parentResultID {
                                Text("Parent · \(parent.uuidString)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(AstroTokens.Spacing.compact)
                    }.accessibilityIdentifier("v2.results.lineage")
                    GroupBox("File") {
                        Text(result.relativePath ?? "No path recorded")
                            .font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(AstroTokens.Spacing.compact)
                    }
                    Spacer()
                }.padding(AstroTokens.Spacing.section)
            }
        } else {
            ContentUnavailableView("Select a result", systemImage: "square.stack.3d.up")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lineageRow(_ title: String, count: Int, icon: String) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
