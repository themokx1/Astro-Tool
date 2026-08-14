import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

public struct NightWorkspaceView: View {
    private struct SeriesRow: Identifiable {
        let series: SeriesRecord
        var id: UUID { series.id }
    }
    let row: NightRow
    let rootURL: URL?
    let close: () -> Void
    let openProject: (ProjectRecord) -> Void
    let reviewProject: (ProjectRecord) -> Void

    public init(
        row: NightRow,
        rootURL: URL? = nil,
        close: @escaping () -> Void,
        openProject: @escaping (ProjectRecord) -> Void,
        reviewProject: @escaping (ProjectRecord) -> Void
    ) {
        self.row = row
        self.rootURL = rootURL
        self.close = close
        self.openProject = openProject
        self.reviewProject = reviewProject
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                Button(action: close) { Label("Nights", systemImage: "chevron.left") }.buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Night › \(row.date)").font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.spectralViolet)
                    Text(row.projectSummary).font(.title2.weight(.semibold))
                    Text("\(row.snapshot.usableFrames) usable · \(row.excludedFrames) excluded · \(row.integrationSummary)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ExportMenu(items: nightExportItems, accessibilityID: "v2.nights.export")
                if let project = row.snapshot.projects.first {
                    Button("Review Frames") { reviewProject(project) }
                    Button("Open Project") { openProject(project) }.buttonStyle(.borderedProminent)
                }
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Integration", value: row.integrationSummary, detail: "Usable light frames", systemImage: "timer")
                    MetricCard(title: "Series", value: row.seriesCount.formatted(), detail: row.filterSummary, systemImage: "square.stack.3d.up")
                    MetricCard(title: "Triage", value: row.triageState.rawValue, detail: "\(row.excludedFrames) excluded", systemImage: "checklist")
                }
                Table(row.snapshot.series.map(SeriesRow.init)) {
                    TableColumn("Project") { series in
                        Text(row.snapshot.projects.first { $0.id == series.series.projectID }?.displayName ?? "Unknown")
                    }
                    TableColumn("Filter") { Text($0.series.filterName ?? "Unfiltered") }
                    TableColumn("Exposure") { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
                    TableColumn("Setup") { Text($0.series.setupDescriptor).lineLimit(1) }
                    TableColumn("Mode") { Text($0.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                }
                .frame(minHeight: 360)
            }
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle(row.date)
        .accessibilityIdentifier("v2.night.workspace")
    }

    /// This night's report (`AppState.exportNightReport`'s V2 equivalent) --
    /// `[]` when no library is open, or this night has no project at all to
    /// resolve a library/folder key from.
    private var nightExportItems: [ExportMenuItem] {
        guard let rootURL, let project = row.snapshot.projects.first else { return [] }
        let target = ProjectsQuery.canonicalFolderName(for: project)
        let date = row.date
        return [
            .file(title: "Night Report…", systemImage: "doc.richtext", contentType: .html) {
                let export = try ExportService.production(rootURL: rootURL).nightReport(target: target, date: date)
                return (export.content, export.suggestedFilename, [])
            },
        ]
    }
}
