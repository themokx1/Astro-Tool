import AstroApplication
import SwiftUI

public struct ProjectsView: View {
    let snapshot: LibrarySnapshot?
    @Bindable var store: ProjectsStore
    let createProject: () -> Void
    let chooseLibrary: () -> Void
    let reviewProject: (ProjectRecord) -> Void
    let showResults: (ProjectRecord) -> Void

    public var body: some View {
        WorkspacePage(
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
                    HStack {
                        Button("New Project…", action: createProject)
                            .buttonStyle(.borderedProminent)
                        if snapshot == nil {
                            Button("Open Library…", action: chooseLibrary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if !store.projects.isEmpty {
                GroupBox("Saved projects") {
                    VStack(spacing: 0) {
                        ForEach(store.projects, id: \.id) { project in
                            HStack(spacing: 12) {
                                Image(systemName: "scope").foregroundStyle(AstroTokens.Color.spectralBlue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.displayName).font(.headline)
                                    Text(project.catalogID).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(project.phase.rawValue.capitalized)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                                HStack(spacing: 6) {
                                    Button("Results") { showResults(project) }.buttonStyle(.bordered)
                                    Button("Review") { reviewProject(project) }
                                        .buttonStyle(.bordered)
                                        .accessibilityLabel("Review \(project.displayName)")
                                        .accessibilityIdentifier("v2.projects.review")
                                }
                            }
                            .padding(.vertical, 10)
                            if project.id != store.projects.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .navigationTitle("Projects")
        .accessibilityLabel("Projects")
        .accessibilityIdentifier("v2.detail.projects")
    }
}

public struct NewProjectView: View {
    @State private var search = ""
    @State private var selectedID: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @Bindable var store: ProjectsStore
    let dismiss: () -> Void

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
                            _ = try await store.createProject(from: selected)
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
