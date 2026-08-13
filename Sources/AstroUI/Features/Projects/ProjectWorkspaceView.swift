import AstroApplication
import SwiftUI

public struct ProjectWorkspaceView: View {
    public enum Section: String, CaseIterable {
        case overview = "Overview"
        case nights = "Nights"
        case series = "Series"
        case results = "Results"
        case notes = "Notes"
    }

    let snapshot: ProjectSnapshot
    let close: () -> Void
    let review: () -> Void
    let results: () -> Void
    let openNight: (UUID) -> Void
    let openSeries: (UUID) -> Void
    @State private var section = Section.overview

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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
            Button(action: close) { Label("Projects", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 4) {
                Text("Project › \(snapshot.project.catalogID)")
                    .font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.spectralBlue)
                Text(snapshot.project.displayName).font(.title2.weight(.semibold))
                Text("\(duration(snapshot.integrationSeconds)) usable · \(snapshot.nights.count) nights · \(snapshot.series.count) series")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review Frames", action: review)
            Button("Results", action: results).buttonStyle(.borderedProminent)
        }
        .padding(AstroTokens.Spacing.spacious)
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
            ProjectNightsSummary(snapshot: snapshot, openNight: openNight)
        case .series:
            ProjectSeriesSummary(snapshot: snapshot, openSeries: openSeries)
        case .results:
            ContentUnavailableView("Open Results workspace", systemImage: "square.stack.3d.up", description: Text("Use the Results button to inspect stack and processing lineage."))
        case .notes:
            ContentUnavailableView("No project notes yet", systemImage: "note.text", description: Text("Project notes remain attached to this canonical target."))
        }
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

private struct ProjectNightsSummary: View {
    let snapshot: ProjectSnapshot
    let openNight: (UUID) -> Void
    @State private var selection: UUID?
    var body: some View {
        Table(snapshot.nights, selection: $selection) {
            TableColumn("Night") { Text($0.night.localDate).monospacedDigit() }
            TableColumn("Series") { Text($0.series.count.formatted()).monospacedDigit() }
            TableColumn("Usable") { Text($0.usableFrames.formatted()).monospacedDigit() }
            TableColumn("Integration") { Text(duration($0.integrationSeconds)).monospacedDigit() }
        }
        .frame(minHeight: 320)
        .onChange(of: selection) { _, id in if let id { openNight(id) } }
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
