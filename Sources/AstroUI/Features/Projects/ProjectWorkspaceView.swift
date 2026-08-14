import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

public struct ProjectWorkspaceView: View {
    public enum Section: String, CaseIterable {
        case overview = "Overview"
        case nights = "Nights"
        case series = "Series"
        case results = "Results"
        case notes = "Notes"
    }

    let snapshot: ProjectSnapshot
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let review: () -> Void
    let results: () -> Void
    let openNight: (UUID) -> Void
    let openSeries: (UUID) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    let annotation: ProjectAnnotationRecord?
    let saveAnnotation: (Double?, String) async throws -> Void
    @State private var section = Section.overview
    @State private var goalHours: Double?
    @State private var projectNotes: String
    @State private var saveError: String?
    @State private var isSaving = false

    public init(
        snapshot: ProjectSnapshot,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        annotation: ProjectAnnotationRecord?,
        review: @escaping () -> Void,
        results: @escaping () -> Void,
        openNight: @escaping (UUID) -> Void,
        openSeries: @escaping (UUID) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in },
        saveAnnotation: @escaping (Double?, String) async throws -> Void
    ) {
        self.snapshot = snapshot
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.annotation = annotation
        self.review = review
        self.results = results
        self.openNight = openNight
        self.openSeries = openSeries
        self.openCalibration = openCalibration
        self.openInsights = openInsights
        self.saveAnnotation = saveAnnotation
        _goalHours = State(initialValue: annotation?.integrationGoalHours)
        _projectNotes = State(initialValue: annotation?.notes ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Project section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            ScrollView {
                content.padding(AstroTokens.Spacing.spacious)
            }
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle(snapshot.project.displayName)
        .accessibilityIdentifier("v2.project.workspace")
        // Wave 4 Task 2: this workspace's own primary actions (Export,
        // Review Frames, Results) used to be an in-body button row in
        // `header` below -- they now render in the shell's own stable
        // toolbar instead (see `WorkspaceActions`'s doc comment), so the
        // header keeps ONLY identity (the eyebrow/title/summary) plus the
        // global breadcrumb above it.
        .focusedSceneValue(\.workspaceActions, workspaceActions)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Project › \(snapshot.project.catalogID)")
                .font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.spectralBlue)
            Text(snapshot.project.displayName).font(.title2.weight(.semibold))
            Text("\(duration(snapshot.integrationSeconds)) usable · \(snapshot.nights.count) nights · \(snapshot.series.count) series")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .custom(id: "v2.project.export") {
                ExportMenu(items: projectExportItems, accessibilityID: "v2.project.export")
            },
            .button(WorkspaceAction(
                id: "v2.project.review",
                title: "Review Frames",
                systemImage: "checkmark.rectangle.stack",
                help: "Open the frame-by-frame review workspace for this project",
                action: review
            )),
            .button(WorkspaceAction(
                id: "v2.project.results",
                title: "Results",
                systemImage: "square.stack.3d.up",
                help: "Inspect stacks, processed variants, and their provenance",
                action: results
            )),
        ])
    }

    /// Acquisition (all three V1 formats), the target report, and the latest
    /// night's stack list -- every project-scoped export V1's per-target
    /// context menu offered (`AppState.exportAcquisition`/`exportTargetReport`/
    /// `exportStackList`), all through `ExportService`. `[]` when no library
    /// is open at all (`rootURL == nil`, never true once a project workspace
    /// is actually reachable, but `ExportMenu` degrades to disabled rather
    /// than assume).
    private var projectExportItems: [ExportMenuItem] {
        guard let rootURL else { return [] }
        let target = snapshot.canonicalFolderName
        let latestNightDate = snapshot.nights.first?.night.localDate
        var items: [ExportMenuItem] = [
            .file(title: "Acquisition (AstroBin CSV)…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .astrobin)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .file(title: "Acquisition (CSV)…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .csv)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .file(title: "Acquisition (Markdown)…", systemImage: "doc.text", contentType: .init(filenameExtension: "md") ?? .plainText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .md)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .divider,
            .file(title: "Target Report…", systemImage: "doc.richtext", contentType: .html) {
                let export = try ExportService.production(rootURL: rootURL).targetReport(target: target)
                return (export.content, export.suggestedFilename, [])
            },
        ]
        if let latestNightDate {
            items.append(
                .file(title: "Stack List (Latest Night)…", systemImage: "square.stack.3d.up", contentType: .commaSeparatedText) {
                    let export = try ExportService.production(rootURL: rootURL).stackList(target: target, date: latestNightDate)
                    return (export.content, export.suggestedFilename, [])
                }
            )
        }
        return items
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .overview:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Integration", value: duration(snapshot.integrationSeconds), detail: "Usable exposure", systemImage: "timer")
                    MetricCard(title: "Frames", value: "\(snapshot.usableFrames)", detail: "\(snapshot.totalFrames - snapshot.usableFrames) excluded", systemImage: "photo.stack")
                    MetricCard(title: "Latest night", value: snapshot.nights.first?.night.localDate ?? "—", detail: snapshot.canonicalFolderName, systemImage: "moon.stars")
                }
                GroupBox("Next action") {
                    Label(snapshot.nextAction.title, systemImage: "arrow.forward.circle.fill")
                    Text(snapshot.nextAction.explanation).foregroundStyle(.secondary)
                }
            }
        case .nights:
            ProjectNightsSummary(
                snapshot: snapshot, rootURL: rootURL, accessMode: accessMode,
                openNight: openNight, openCalibration: openCalibration, openInsights: openInsights
            )
        case .series:
            ProjectSeriesSummary(snapshot: snapshot, openSeries: openSeries)
        case .results:
            ContentUnavailableView("Open Results workspace", systemImage: "square.stack.3d.up", description: Text("Use the Results button to inspect stack and processing lineage."))
        case .notes:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                GroupBox("Acquisition goal") {
                    LabeledContent("Integration goal") {
                        HStack(spacing: 6) {
                            TextField("Hours", value: $goalHours, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 90)
                            Text("hours").foregroundStyle(.secondary)
                        }
                    }
                    .padding(AstroTokens.Spacing.compact)
                }
                GroupBox("Project notes") {
                    TextEditor(text: $projectNotes)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(6)
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
                HStack {
                    Text(annotation.map { "Last saved \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "Not saved yet")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Project Details") {
                        isSaving = true
                        saveError = nil
                        Task {
                            do { try await saveAnnotation(goalHours, projectNotes) }
                            catch { saveError = error.localizedDescription }
                            isSaving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || (goalHours != nil && goalHours! <= 0))
                }
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ProjectNightsSummary: View {
    let snapshot: ProjectSnapshot
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let openNight: (UUID) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    @State private var selection: UUID?
    @State private var noteEditorTarget: NightNoteEditingTarget?

    var body: some View {
        Table(snapshot.nights, selection: $selection) {
            TableColumn("Night") { Text($0.night.localDate).monospacedDigit() }
            TableColumn("Series") { Text($0.series.count.formatted()).monospacedDigit() }
            TableColumn("Usable") { Text($0.usableFrames.formatted()).monospacedDigit() }
            TableColumn("Integration") { Text(duration($0.integrationSeconds)).monospacedDigit() }
        }
        .frame(minHeight: 320)
        .contextMenu(forSelectionType: UUID.self) { nightIDs in
            if let id = nightIDs.first, let night = snapshot.nights.first(where: { $0.id == id }) {
                NightActionMenu(
                    target: snapshot.canonicalFolderName,
                    date: night.night.localDate,
                    setupDescriptor: night.series.first?.series.setupDescriptor,
                    nightID: night.id,
                    rootURL: rootURL,
                    openNight: { openNight(id) },
                    editNotes: {
                        noteEditorTarget = NightNoteEditingTarget(
                            target: snapshot.canonicalFolderName, date: night.night.localDate
                        )
                    },
                    openCalibration: openCalibration,
                    openInsights: openInsights
                )
            }
        }
        .onChange(of: selection) { _, id in if let id { openNight(id) } }
        .sheet(item: $noteEditorTarget) { editing in
            if let rootURL {
                NightNoteSheet(
                    rootURL: rootURL, target: editing.target, date: editing.date,
                    accessMode: accessMode, dismiss: { noteEditorTarget = nil }
                )
            }
        }
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ProjectSeriesSummary: View {
    let snapshot: ProjectSnapshot
    let openSeries: (UUID) -> Void
    @State private var selection: UUID?
    var body: some View {
        Table(snapshot.nights.flatMap(\.series), selection: $selection) {
            TableColumn("Filter") { Text($0.filterName ?? "Unfiltered") }
            TableColumn("Exposure") { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
            TableColumn("Setup") { Text($0.series.setupDescriptor).lineLimit(1) }
            TableColumn("Frames") { Text("\($0.usableFrames) / \($0.excludedFrames)").monospacedDigit() }
        }
        .frame(minHeight: 320)
        .onChange(of: selection) { _, id in if let id { openSeries(id) } }
    }
}
