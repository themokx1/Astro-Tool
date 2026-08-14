import AstroApplication
import SwiftUI

public struct ProjectsView: View {
    let snapshot: LibrarySnapshot?
    @Bindable var store: ProjectsStore
    let createProject: () -> Void
    let chooseLibrary: () -> Void
    let reviewProject: (ProjectRecord) -> Void
    let showResults: (ProjectRecord) -> Void
    let openProject: (ProjectRecord) -> Void
    @State private var searchText = ""
    @State private var visibleProjects: [ProjectRecord] = []

    public var body: some View {
        if snapshot == nil {
            ContentUnavailableView {
                Label("No library open", systemImage: "folder")
            } description: {
                Text("Open a library to keep every target's nights, series, stacks, and results together.")
            } actions: {
                Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
            }
            .navigationTitle("Projects")
            .accessibilityLabel("Projects")
            .accessibilityIdentifier("v2.detail.projects")
        } else {
            projectsWorkspace
        }
    }

    private var projectsWorkspace: some View {
        WorkspaceTablePage(
            eyebrow: "Your sky",
            title: "Projects",
            subtitle: "One target, every night, series, stack, and result — kept together."
        ) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: snapshot.map { "\($0.projectCount)" } ?? "—", detail: "Recognized target folders", systemImage: "folder")
                MetricCard(title: "Nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Across the open library", systemImage: "moon.stars")
            }

            GroupBox("Start cleanly") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    Label("Search by catalog number, English name, or Hungarian name.", systemImage: "sparkle.magnifyingglass")
                    Label("AstroTool proposes one canonical folder name to prevent duplicates.", systemImage: "checkmark.seal")
                    Button("New Project…", action: createProject)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AstroTokens.Spacing.compact)
            }

            if !store.projects.isEmpty {
                TextField("Search projects, catalog, filter, setup, or status", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("v2.projects.search")
                    .onChange(of: searchText) { _, value in
                        Task { visibleProjects = (try? await store.search(value)) ?? [] }
                    }
            }
        } table: {
            tableContent
        } footer: {
            detailFooter
        }
        .navigationTitle("Projects")
        .accessibilityLabel("Projects")
        .accessibilityIdentifier("v2.detail.projects")
        .task(id: store.projects) {
            visibleProjects = (try? await store.search(searchText)) ?? store.projects
        }
    }

    @ViewBuilder
    private var tableContent: some View {
        if !store.projects.isEmpty {
            GroupBox("Saved projects") {
                Table(filteredRows, selection: projectSelection) {
                    TableColumn("Project") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.project.displayName).font(.headline)
                            Text(row.project.catalogID).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openProject(row.project) }
                    }
                    TableColumn("Phase") { row in Text(row.project.phase.rawValue.capitalized) }
                        .width(min: 85, ideal: 100)
                    TableColumn("Nights") { row in Text(row.nightCount.formatted()).monospacedDigit() }
                        .width(60)
                    TableColumn("Integration") { row in Text(duration(row.integrationSeconds)).monospacedDigit() }
                        .width(85)
                    TableColumn("Frames") { row in
                        Text("\(row.usableFrames) / \(row.excludedFrames)").monospacedDigit()
                            .help("Usable / excluded")
                    }.width(80)
                    TableColumn("Latest") { row in Text(row.latestNight ?? "—").monospacedDigit() }
                        .width(100)
                    TableColumn("Next") { row in Text(row.nextAction).lineLimit(1) }
                    TableColumn("") { row in
                        HStack(spacing: 4) {
                            Button { reviewProject(row.project) } label: { Image(systemName: "checklist") }
                                .help("Review frames")
                            Button { showResults(row.project) } label: { Image(systemName: "square.stack.3d.up") }
                                .help("Results")
                        }
                        .buttonStyle(.borderless)
                    }.width(58)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let row = store.workspaceRows.first(where: { $0.id == id }) {
                        Button("Open Project") { openProject(row.project) }
                        Button("Review Frames") { reviewProject(row.project) }
                        Button("Results") { showResults(row.project) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let row = store.workspaceRows.first(where: { $0.id == id }) {
                        openProject(row.project)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Bounded to its own scroll region rather than left to grow freely --
    /// unlike the table above it, this is not a virtualizing control, so an
    /// explicit cap keeps a project with many nights/series from pushing the
    /// table region down to nothing.
    @ViewBuilder
    private var detailFooter: some View {
        if store.isLoading, store.selectedProjectID != nil, store.selectedProject == nil {
            ProgressView("Loading project…")
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let detail = store.selectedProject {
            ScrollView {
                ProjectAcquisitionDetail(
                    snapshot: detail,
                    review: { reviewProject(detail.project) },
                    results: { showResults(detail.project) }
                )
            }
            .frame(maxHeight: 340)
        }
    }

    private var filteredRows: [ProjectWorkspaceRow] {
        let ids = Set(visibleProjects.map(\.id))
        return store.workspaceRows.filter { ids.contains($0.id) }
    }

    private var projectSelection: Binding<UUID?> {
        Binding(
            get: { store.selectedProjectID },
            set: { id in
                Task { try? await store.selectProject(id) }
                if let id, let project = store.projects.first(where: { $0.id == id }) {
                    openProject(project)
                }
            }
        )
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ProjectAcquisitionDetail: View {
    let snapshot: ProjectSnapshot
    let review: () -> Void
    let results: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.project.displayName)
                            .font(.title2.weight(.semibold))
                        Text(snapshot.canonicalFolderName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Review frames", action: review)
                    Button("Results", action: results)
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(
                        title: "Usable integration",
                        value: duration(snapshot.integrationSeconds),
                        detail: "\(snapshot.usableFrames) of \(snapshot.totalFrames) frames",
                        systemImage: "timer"
                    )
                    MetricCard(
                        title: "Nights",
                        value: "\(snapshot.nights.count)",
                        detail: "\(snapshot.series.count) capture series",
                        systemImage: "moon.stars"
                    )
                    MetricCard(
                        title: "Excluded",
                        value: "\(snapshot.totalFrames - snapshot.usableFrames)",
                        detail: "Rejected or archived frames",
                        systemImage: "archivebox"
                    )
                }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.nextAction.title).font(.headline)
                        Text(snapshot.nextAction.explanation)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.forward.circle.fill")
                        .foregroundStyle(AstroTokens.Color.spectralBlue)
                }

                Divider()

                ForEach(snapshot.nights) { night in
                    ProjectNightSection(snapshot: night)
                }
            }
            .padding(AstroTokens.Spacing.compact)
        } label: {
            Label("Project acquisition", systemImage: "rectangle.stack")
        }
        .accessibilityIdentifier("v2.projects.detail")
    }

    private func duration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

private struct ProjectNightSection: View {
    let snapshot: ProjectNightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(snapshot.night.localDate, systemImage: "moon.stars.fill")
                    .font(.headline)
                Spacer()
                Text("\(snapshot.usableFrames) usable · \(duration(snapshot.integrationSeconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.series) { item in
                HStack(spacing: 10) {
                    Image(systemName: passbandIcon(item.series.passband))
                        .foregroundStyle(AstroTokens.Color.spectralViolet)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seriesTitle(item))
                            .font(.callout.weight(.medium))
                        Text(seriesDetail(item))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(item.usableFrames) × \(exposure(item.series.exposureSeconds))")
                        .font(.callout.monospacedDigit())
                    if item.excludedFrames > 0 {
                        Text("\(item.excludedFrames) excluded")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .accessibilityIdentifier("v2.projects.night")
    }

    private func seriesTitle(_ item: ProjectSeriesSnapshot) -> String {
        [item.series.sensorMode.rawValue.uppercased(), item.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, item.filterName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func seriesDetail(_ item: ProjectSeriesSnapshot) -> String {
        [item.series.setupDescriptor, "bin \(item.series.binning)", item.series.gain.map { "gain \($0.formatted())" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func exposure(_ seconds: Double) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    private func duration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private func passbandIcon(_ passband: SeriesPassband) -> String {
        switch passband {
        case .dualBand, .narrowband: "line.3.horizontal.decrease.circle"
        case .broadband, .unfiltered: "camera.aperture"
        default: "circle.lefthalf.filled"
        }
    }
}

public struct NewProjectView: View {
    @State private var search: String
    @State private var selectedID: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @Bindable var store: ProjectsStore
    let dismiss: () -> Void
    let didCreate: (ProjectRecord) -> Void

    public init(
        store: ProjectsStore,
        initialQuery: String = "",
        dismiss: @escaping () -> Void,
        didCreate: @escaping (ProjectRecord) -> Void = { _ in }
    ) {
        _store = Bindable(store)
        _search = State(initialValue: initialQuery)
        self.dismiss = dismiss
        self.didCreate = didCreate
    }

    private var matches: [ProjectCatalogMatch] {
        ProjectsQuery.searchCatalog(search, limit: 12)
    }

    private var selected: ProjectCatalogMatch? {
        matches.first { $0.id == selectedID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title)
                    .foregroundStyle(AstroTokens.Color.spectralViolet)
                VStack(alignment: .leading) {
                    Text("New Project").font(.title2.weight(.semibold))
                    Text("Choose the target first; AstroTool will keep its identity canonical.")
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Catalog number or target name", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.new-project.search")
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("Find a target", systemImage: "scope")
                } description: {
                    Text("Try IC 1396, Elephant's Trunk, or Elefántormány-köd.")
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                List(matches, selection: $selectedID) { match in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.displayName).font(.headline)
                        HStack(spacing: 8) {
                            if let englishName = match.englishName { Text(englishName) }
                            Text(match.canonicalFolderName).font(.caption.monospaced())
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(match.id)
                }
                .frame(minHeight: 210)
            }
            if let selected {
                HStack {
                    Image(systemName: "folder.badge.plus").foregroundStyle(AstroTokens.Color.spectralBlue)
                    Text("Folder preview")
                    Spacer()
                    Text(selected.canonicalFolderName).font(.caption.monospaced()).textSelection(.enabled)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Create Project") {
                    guard let selected else { return }
                    isSaving = true
                    saveError = nil
                    Task {
                        do {
                            let project = try await store.createProject(from: selected)
                            didCreate(project)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                            isSaving = false
                        }
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || isSaving)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(minWidth: 640, minHeight: 520)
        .accessibilityIdentifier("v2.new-project")
    }
}
