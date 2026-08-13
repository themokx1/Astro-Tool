import AstroApplication
import SwiftUI

public struct ReviewWorkspace: View {
    @Bindable var store: ReviewStore
    let rootURL: URL
    let projectID: UUID
    let dismiss: () -> Void
    @State private var selectedDecisionIDs: Set<UUID> = []
    @State private var archivePreview: ReviewArchivePlan?

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
        .frame(minWidth: 800, minHeight: 580)
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
                .frame(minWidth: 205, idealWidth: 240, maxWidth: 290)
            frameReview
                .frame(minWidth: 340, maxWidth: .infinity)
            if let selectedSeries = store.selectedSeries {
                inspector(for: selectedSeries)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
            }
        }
        .sheet(item: $archivePreview) { plan in
            ArchivePreviewSheet(plan: plan) { archivePreview = nil }
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
                QualityDistribution(snapshot: selected)
                    .padding(.horizontal, AstroTokens.Spacing.standard)
                    .padding(.vertical, 10)
                Divider()
                if selected.decisions.isEmpty {
                    ContentUnavailableView {
                        Label("No reviewed frames", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Frame decisions will appear here after this series is indexed for review.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(selected.decisions, selection: $selectedDecisionIDs) {
                        TableColumn("Frame") { decision in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: decision.relativePath).lastPathComponent)
                                    .font(.body.monospaced())
                                Text(decision.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                        TableColumn("Decision") { decision in
                            FrameVerdictLabel(decision: decision)
                        }
                        .width(min: 105, ideal: 120)
                        TableColumn("Library status") { decision in
                            Text(decision.logicallyExcluded ? "Excluded" : "Included")
                                .foregroundStyle(decision.logicallyExcluded ? .red : .secondary)
                        }
                        .width(min: 100, ideal: 115)
                    }
                    .contextMenu(forSelectionType: UUID.self) { decisionIDs in
                        Button("Accept") { apply(.accepted, decisionIDs: decisionIDs, in: selected) }
                        Button("Reset Decision") { apply(.undecided, decisionIDs: decisionIDs, in: selected) }
                        Divider()
                        Button("Reject") { apply(.rejected, decisionIDs: decisionIDs, in: selected) }
                    }
                    .accessibilityIdentifier("v2.review.frames-table")
                }
            }
            .accessibilityIdentifier("v2.review.quality")
        } else {
            ContentUnavailableView("Select a series", systemImage: "square.stack.3d.up")
        }
    }

    private func reviewActions(_ selected: ReviewSeriesSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Accept") { apply(.accepted, decisionIDs: selectedDecisionIDs, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Reset") { apply(.undecided, decisionIDs: selectedDecisionIDs, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
            Button("Reject") { apply(.rejected, decisionIDs: selectedDecisionIDs, in: selected) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder
    private func inspector(for selected: ReviewSeriesSnapshot) -> some View {
        if selectedDecisionIDs.count == 1,
           let id = selectedDecisionIDs.first,
           let decision = selected.decisions.first(where: { $0.id == id }) {
            FrameInspector(decision: decision) {
                archivePreview = try? store.archivePlan(for: decision)
            }
        } else {
            SeriesInspector(snapshot: selected) { filter in
                Task { try? await store.assignFilter(filter) }
            }
        }
    }

    private func apply(
        _ verdict: FrameVerdict,
        decisionIDs: Set<UUID>,
        in selected: ReviewSeriesSnapshot
    ) {
        let paths = selected.decisions
            .filter { decisionIDs.contains($0.id) }
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

private struct QualityDistribution: View {
    let snapshot: ReviewSeriesSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Review distribution").font(.caption.weight(.semibold))
                Spacer()
                Text("\(snapshot.decisions.count) indexed").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    segment(count: snapshot.acceptedCount, totalWidth: geometry.size.width, color: .green)
                    segment(count: snapshot.undecidedCount, totalWidth: geometry.size.width, color: .gray)
                    segment(count: snapshot.rejectedCount, totalWidth: geometry.size.width, color: .red)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .accessibilityLabel(
                "\(snapshot.acceptedCount) accepted, \(snapshot.undecidedCount) undecided, \(snapshot.rejectedCount) rejected"
            )
        }
    }

    private func segment(count: Int, totalWidth: Double, color: Color) -> some View {
        color.frame(width: snapshot.decisions.isEmpty
            ? (color == .gray ? totalWidth : 0)
            : totalWidth * Double(count) / Double(snapshot.decisions.count))
    }
}

private struct ArchivePreviewSheet: View {
    let plan: ReviewArchivePlan
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            Label("Archive preview", systemImage: "archivebox")
                .font(.title2.weight(.semibold))
            Text("No file has moved. Review the exact source and destination first.")
                .foregroundStyle(.secondary)
            GroupBox("Planned move") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { Text("From").foregroundStyle(.secondary); Text(plan.sourceRelative).monospaced() }
                    GridRow { Text("To").foregroundStyle(.secondary); Text(plan.destinationRelative).monospaced() }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            Label(
                "Applying archive moves will be enabled only after write access is explicitly granted.",
                systemImage: "lock.shield"
            )
            .font(.callout).foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Move to Archive") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(minWidth: 620, minHeight: 360)
        .accessibilityIdentifier("v2.review.archive-preview")
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

private struct FrameVerdictLabel: View {
    let decision: FrameDecisionRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label)
                .foregroundStyle(color)
                .font(.callout.weight(.medium))
        }
    }

    private var label: String {
        switch decision.verdict {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .undecided: "Undecided"
        }
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
