import AstroApplication
import SwiftUI

public struct ReviewWorkspace: View {
    @Bindable var store: ReviewStore
    let rootURL: URL
    let projectID: UUID
    let dismiss: () -> Void
    @State private var selectedDecisionIDs: Set<UUID> = []

    public init(
        store: ReviewStore,
        rootURL: URL,
        projectID: UUID,
        dismiss: @escaping () -> Void
    ) {
        self.store = store
        self.rootURL = rootURL
        self.projectID = projectID
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if store.isLoading && store.snapshot == nil {
                    ProgressView("Loading capture series…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot = store.snapshot {
                    reviewContent(snapshot)
                } else {
                    ContentUnavailableView(
                        "Review unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(store.errorMessage ?? "This project could not be opened.")
                    )
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(AstroTokens.Color.graphite.opacity(0.22))
        .task(id: projectID) {
            try? await store.open(rootURL: rootURL, projectID: projectID)
        }
        .onChange(of: store.selectedSeriesID) { _, _ in selectedDecisionIDs.removeAll() }
        .accessibilityIdentifier("v2.review.workspace")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.rectangle.stack")
                .font(.title2)
                .foregroundStyle(AstroTokens.Color.spectralViolet)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot?.project.displayName ?? "Frame Review")
                    .font(.title2.weight(.semibold))
                Text("Review one capture series at a time. Source files are never moved here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
        }
        .padding(AstroTokens.Spacing.standard)
    }

    private func reviewContent(_ snapshot: ReviewProjectSnapshot) -> some View {
        HSplitView {
            seriesList(snapshot.series)
                .frame(minWidth: 245, idealWidth: 280, maxWidth: 330)
            frameReview
                .frame(minWidth: 430, maxWidth: .infinity)
            if let selectedSeries = store.selectedSeries {
                SeriesInspector(snapshot: selectedSeries)
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            }
        }
    }

    private func seriesList(_ series: [ReviewSeriesSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPTURE SERIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if series.isEmpty {
                ContentUnavailableView(
                    "No series yet",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Add or import capture metadata to begin review.")
                )
            } else {
                List(series, selection: Binding(
                    get: { store.selectedSeriesID },
                    set: { if let id = $0 { store.selectSeries(id) } }
                )) { item in
                    SeriesRow(snapshot: item).tag(item.id)
                }
                .listStyle(.sidebar)
            }
        }
        .padding(AstroTokens.Spacing.standard)
        .accessibilityIdentifier("v2.review.series-list")
    }

    @ViewBuilder
    private var frameReview: some View {
        if let selected = store.selectedSeries {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frames").font(.headline)
                        Text(seriesSubtitle(selected.series)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    reviewActions(selected)
                }
                .padding(AstroTokens.Spacing.standard)
                Divider()
                if selected.decisions.isEmpty {
                    ContentUnavailableView {
                        Label("No reviewed frames", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Frame decisions will appear here after this series is indexed for review.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedDecisionIDs) {
                        ForEach(selected.decisions, id: \.id) { decision in
                            FrameDecisionRow(decision: decision).tag(decision.id)
                        }
                    }
                }
            }
            .accessibilityIdentifier("v2.review.quality")
        } else {
            ContentUnavailableView("Select a series", systemImage: "square.stack.3d.up")
        }
    }

    private func reviewActions(_ selected: ReviewSeriesSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Accept") { apply(.accepted, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
            Button("Reset") { apply(.undecided, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
            Button("Reject") { apply(.rejected, in: selected) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
        }
    }

    private func apply(_ verdict: FrameVerdict, in selected: ReviewSeriesSnapshot) {
        let paths = selected.decisions
            .filter { selectedDecisionIDs.contains($0.id) }
            .map(\.relativePath)
        Task {
            try? await store.setVerdict(relativePaths: paths, verdict: verdict)
            selectedDecisionIDs.removeAll()
        }
    }

    private func seriesSubtitle(_ series: SeriesRecord) -> String {
        [
            "\(series.exposureSeconds.formatted(.number.precision(.fractionLength(0...2)))) s",
            series.filterName,
            series.sensorMode.rawValue.uppercased()
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct SeriesRow: View {
    let snapshot: ReviewSeriesSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(snapshot.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...2)))) s")
                    .font(.headline)
                Spacer()
                if let filter = snapshot.series.filterName {
                    Text(filter).font(.caption.weight(.medium)).foregroundStyle(.purple)
                }
            }
            Text(snapshot.series.setupDescriptor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 10) {
                Label("\(snapshot.acceptedCount)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("\(snapshot.rejectedCount)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Label("\(snapshot.undecidedCount)", systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .padding(.vertical, 5)
    }
}

private struct FrameDecisionRow: View {
    let decision: FrameDecisionRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: decision.relativePath).lastPathComponent)
                    .font(.body.monospaced())
                Text(decision.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if decision.logicallyExcluded {
                Text("Excluded").font(.caption.weight(.medium)).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        switch decision.verdict {
        case .accepted: "checkmark.circle.fill"
        case .rejected: "xmark.circle.fill"
        case .undecided: "circle.dashed"
        }
    }

    private var color: Color {
        switch decision.verdict {
        case .accepted: .green
        case .rejected: .red
        case .undecided: .secondary
        }
    }
}
