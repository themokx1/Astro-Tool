import AstroApplication
import SwiftUI

public struct ProjectsView: View {
    let snapshot: LibrarySnapshot?
    let createProject: () -> Void
    let chooseLibrary: () -> Void

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
        }
        .navigationTitle("Projects")
        .accessibilityLabel("Projects")
        .accessibilityIdentifier("v2.detail.projects")
    }
}

public struct NewProjectView: View {
    @State private var search = ""
    let dismiss: () -> Void

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
            ContentUnavailableView {
                Label(search.isEmpty ? "Find a target" : "Catalog search is connecting", systemImage: "scope")
            } description: {
                Text(search.isEmpty ? "Try IC 1396, Elephant's Trunk, or Elefántormány-köd." : "The beta already protects the workflow shape; catalog-backed creation arrives in the next beta increment.")
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(minWidth: 560, minHeight: 390)
        .accessibilityIdentifier("v2.new-project")
    }
}
