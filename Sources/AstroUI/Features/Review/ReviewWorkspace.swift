import AstroApplication
import AstroCore
import SwiftUI

public struct ReviewWorkspace: View {
    @Bindable var store: ReviewStore
    let rootURL: URL
    let projectID: UUID
    @State private var selectedDecisionIDs: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<ReviewFrameRow>] = [KeyPathComparator(\.scoreSortKey, order: .reverse)]
    @State private var selectedCaptureSlug: String?
    @State private var selectedNightFilter: String?
    @State private var blinkReviewStore: FrameBlinkReviewStore?
    @Environment(OperationHost.self) private var operationHost
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString

    public init(
        store: ReviewStore,
        rootURL: URL,
        projectID: UUID
    ) {
        self.store = store
        self.rootURL = rootURL
        self.projectID = projectID
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
        .background(AstroTokens.Color.ground.opacity(0.22))
        .task(id: projectID) {
            try? await store.open(rootURL: rootURL, projectID: projectID)
        }
        // Wave 3 Task 7: the Actions menu's "Rate Frames in Review" --
        // mirrors the toolbar's own "Rate Frames…" menu primary action
        // (native-only rate of the selected series, built by
        // `workspaceActions` below), `isAvailable` mirroring that menu's own
        // `isDisabled` condition.
        .focusedSceneValue(
            \.reviewRate,
            ReviewRateCommand(
                isAvailable: (store.selectedSeries.map { !$0.decisions.isEmpty } ?? false)
                    && runningRatingOperation == nil,
                action: { Task { await store.rateSelectedSeries(mode: .nativeOnly, operationHost: operationHost) } }
            )
        )
        .onChange(of: store.selectedSeriesID) { _, _ in selectedDecisionIDs.removeAll() }
        .onChange(of: store.snapshot) { _, _ in
            guard let blinkReviewStore, let selected = store.selectedSeries else { return }
            blinkReviewStore.refresh(decisions: qualityRows(for: selected).map(\.decision))
        }
        .sheet(isPresented: Binding(
            get: { blinkReviewStore != nil },
            set: { if !$0 { blinkReviewStore = nil } }
        )) {
            if let blinkReviewStore {
                FrameBlinkReview(
                    store: blinkReviewStore,
                    rootURL: rootURL,
                    qualityLookup: { store.quality(for: $0) },
                    dismiss: { self.blinkReviewStore = nil }
                )
            }
        }
        .accessibilityIdentifier("v2.review.workspace")
        // Wave 4 Task 2: Rate Frames/Review Frames… (blink) used to be an
        // in-body button row of the per-series "Frames" panel below -- they
        // now render in the shell's own stable toolbar (see
        // `WorkspaceActions`'s doc comment). Empty (no items) whenever no
        // series is selected, exactly matching that row's own old
        // conditional visibility.
        // Wave 4 (post-20014) fix: published from discrete lifecycle/state-
        // change events rather than from `body` itself -- see
        // `WorkspaceActionCenter`'s own doc comment. `runningRatingOperation`
        // (below) derives from `operationHost.activeOperations`, which
        // changes independently of series selection whenever a rating run
        // starts or finishes.
        .onAppear { publishWorkspaceActions() }
        .onChange(of: store.selectedSeries) { _, _ in publishWorkspaceActions() }
        .onChange(of: operationHost.activeOperations) { _, _ in publishWorkspaceActions() }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    private var workspaceActions: WorkspaceActions {
        guard let selected = store.selectedSeries else { return WorkspaceActions([]) }
        return WorkspaceActions([
            .menu(WorkspaceActionMenu(
                id: "v2.review.rate",
                title: "Rate Frames…",
                systemImage: "star.leadinghalf.filled",
                isDisabled: selected.decisions.isEmpty || runningRatingOperation != nil,
                items: [
                    WorkspaceMenuItem(id: "v2.review.rate.full", title: "Full Re-measure (Siril + native)") {
                        Task { await store.rateSelectedSeries(mode: .fullReMeasure, operationHost: operationHost) }
                    },
                    WorkspaceMenuItem(id: "v2.review.rate.native", title: "Native Only (no Siril)") {
                        Task { await store.rateSelectedSeries(mode: .nativeOnly, operationHost: operationHost) }
                    },
                ],
                primaryAction: {
                    Task { await store.rateSelectedSeries(mode: .nativeOnly, operationHost: operationHost) }
                }
            )),
            .button(WorkspaceAction(
                id: "v2.review.blink",
                title: "Review Frames…",
                systemImage: "eye",
                isDisabled: selected.decisions.isEmpty,
                action: { openBlinkReview(selected) }
            )),
        ])
    }

    /// Opens the blink-review sheet on `selected`'s frames, in EXACTLY the
    /// order/filter the frame table is currently showing (`qualityRows`
    /// already applies `selectedCaptureSlug` + `sortOrder`) -- mirrors V1
    /// `FrameReviewSheet`'s own "never re-sorts or re-filters" contract.
    /// Starts on the single selected row when there is one, otherwise the
    /// first frame.
    private func openBlinkReview(_ selected: ReviewSeriesSnapshot) {
        let rows = qualityRows(for: selected)
        guard !rows.isEmpty else { return }
        let initialPath = selectedDecisionIDs.count == 1
            ? rows.first(where: { selectedDecisionIDs.contains($0.decision.id) })?.decision.relativePath
            : nil
        blinkReviewStore = FrameBlinkReviewStore(
            decisions: rows.map(\.decision),
            initialRelativePath: initialPath,
            verdictHandler: { path, verdict in
                try await store.setVerdict(relativePaths: [path], verdict: verdict)
            }
        )
    }

    private func quickLookSelectedFrame(_ selected: ReviewSeriesSnapshot) {
        guard selectedDecisionIDs.count == 1,
              let id = selectedDecisionIDs.first,
              let decision = selected.decisions.first(where: { $0.id == id }),
              let url = FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: decision.relativePath)
        else { return }
        QuickLookPreviewController.shared.preview(url)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.rectangle.stack")
                .font(.title2)
                .foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot?.project.displayName ?? "Frame Review")
                    .font(.title2.weight(.semibold))
                Text("Review one capture series at a time. Source files are never moved here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AstroTokens.Spacing.standard)
    }

    private func reviewContent(_ snapshot: ReviewProjectSnapshot) -> some View {
        // V2 UI/UX audit (2026-08-14) systemic pattern S10: this three-pane
        // split's own minimums used to sum to 765 -- almost exactly the
        // outer view's old 800pt sheet-era floor (removed above), so
        // relaxing that outer floor alone would not have fixed anything;
        // the narrower detail column the shell's split view actually gives
        // this route (sidebar + inspector both showing) needs these three
        // panes to still fit without forcing the window wider.
        HSplitView {
            seriesList(snapshot.series)
                .frame(minWidth: 140, idealWidth: 200, maxWidth: 290)
            frameReview
                .frame(minWidth: 240, maxWidth: .infinity)
            if let selectedSeries = store.selectedSeries {
                inspector(for: selectedSeries)
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 300)
            }
        }
    }

    private func seriesList(_ series: [ReviewSeriesSnapshot]) -> some View {
        let nights = Array(Set(series.map(\.nightLocalDate))).sorted()
        let visible = series.filter { selectedNightFilter == nil || $0.nightLocalDate == selectedNightFilter }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CAPTURE SERIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if nights.count > 1 {
                    Menu(selectedNightFilter ?? "All nights") {
                        Button("All nights") { selectedNightFilter = nil }
                        Divider()
                        ForEach(nights, id: \.self) { night in
                            Button(night) { selectedNightFilter = night }
                        }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("v2.review.session-filter")
                }
            }
            if visible.isEmpty {
                ContentUnavailableView(
                    "No series yet",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Add or import capture metadata to begin review.")
                )
            } else {
                List(visible, selection: Binding(
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
            let rows = qualityRows(for: selected)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Frames").font(.headline)
                            MetricInfoButton(metrics: Self.qualityMetricInfo)
                        }
                        Text(seriesSubtitle(selected.series)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    reviewActions(selected)
                }
                .padding(AstroTokens.Spacing.standard)
                Divider()
                HStack(spacing: 10) {
                    if !captureSlugs(in: selected).isEmpty {
                        Menu(selectedCaptureSlug ?? "All capture groups") {
                            Button("All capture groups") { selectedCaptureSlug = nil }
                            Divider()
                            ForEach(captureSlugs(in: selected), id: \.self) { slug in
                                Button(slug) { selectedCaptureSlug = slug }
                            }
                        }
                        .font(.caption)
                        .accessibilityIdentifier("v2.review.capture-group-filter")
                    }
                    Spacer()
                    if let running = runningRatingOperation {
                        ProgressView().controlSize(.small)
                        Text("Rating frames…").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { Task { await operationHost.cancel(id: running.id) } }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, AstroTokens.Spacing.standard)
                .padding(.vertical, 8)
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
                    Table(rows, selection: $selectedDecisionIDs, sortOrder: $sortOrder) {
                        TableColumn("Preview") { row in
                            FrameThumbnailCell(rootURL: rootURL, relativePath: row.decision.relativePath)
                        }
                        .width(min: 36, ideal: 36, max: 36)
                        TableColumn("Frame") { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: row.decision.relativePath).lastPathComponent)
                                    .font(.body.monospaced())
                                Text(row.decision.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                        TableColumn("Decision") { row in
                            FrameVerdictLabel(decision: row.decision)
                        }
                        .width(min: 105, ideal: 120)
                        TableColumn("Library status") { row in
                            Text(row.decision.logicallyExcluded ? "Excluded" : "Included")
                                .foregroundStyle(row.decision.logicallyExcluded ? AstroTokens.Color.critical : .secondary)
                        }
                        .width(min: 100, ideal: 115)
                        TableColumn("Score", value: \.scoreSortKey) { row in
                            HStack(spacing: 4) {
                                if row.isOutlier {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(AstroTokens.Color.attention)
                                        .help("Outlier: scores well below this session's other frames")
                                }
                                Text(Self.formatted(row.score, fractionDigits: 2))
                            }
                            .accessibilityIdentifier("v2.review.quality-columns.\(row.id.uuidString)")
                        }
                        .width(min: 70, ideal: 85)
                        TableColumn("FWHM", value: \.fwhmSortKey) { row in
                            Text(Self.formatted(row.fwhm, fractionDigits: 2))
                        }
                        .width(min: 55, ideal: 65)
                        TableColumn("Roundness", value: \.roundnessSortKey) { row in
                            Text(Self.formatted(row.roundness, fractionDigits: 2))
                        }
                        .width(min: 70, ideal: 85)
                        TableColumn("Background", value: \.backgroundSortKey) { row in
                            Text(Self.formatted(row.background, fractionDigits: 0))
                        }
                        .width(min: 70, ideal: 90)
                        TableColumn("Sat. %", value: \.saturatedFractionSortKey) { row in
                            Text(row.saturatedFraction.map { "\(($0 * 100).formatted(.number.precision(.fractionLength(1))))%" } ?? "—")
                        }
                        .width(min: 55, ideal: 65)
                        TableColumn("Percentile") { row in
                            HStack(spacing: 6) {
                                PercentileDot(result: row.quality?.libraryPercentile)
                                Text(row.percentile.map { "\($0)" } ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 60, ideal: 75)
                    }
                    .contextMenu(forSelectionType: UUID.self) { decisionIDs in
                        Button("Accept") { apply(.accepted, decisionIDs: decisionIDs, in: selected) }
                        Button("Reset Decision") { apply(.undecided, decisionIDs: decisionIDs, in: selected) }
                        Divider()
                        Button("Reject") { apply(.rejected, decisionIDs: decisionIDs, in: selected) }
                        Divider()
                        Button("Quick Look") { quickLookSelectedFrame(selected) }
                            .disabled(decisionIDs.count != 1)
                    }
                    .background(QuickLookSpacebarMonitor(
                        isEnabled: { selectedDecisionIDs.count == 1 },
                        onSpace: { quickLookSelectedFrame(selected) }
                    ))
                    .accessibilityIdentifier("v2.review.frames-table")
                }
            }
            .accessibilityIdentifier("v2.review.quality")
        } else {
            ContentUnavailableView("Select a series", systemImage: "square.stack.3d.up")
        }
    }

    /// Every frame decision of `selected`, joined with its measured quality
    /// (`store.qualityByPath`, keyed by `relativePath`) and narrowed by
    /// `selectedCaptureSlug` when one is chosen -- the Table's own data
    /// source, so sorting/filtering only ever touches this one array.
    private func qualityRows(for selected: ReviewSeriesSnapshot) -> [ReviewFrameRow] {
        selected.decisions
            .map { ReviewFrameRow(decision: $0, quality: store.quality(for: $0.relativePath)) }
            .filter { selectedCaptureSlug == nil || $0.captureSlug == selectedCaptureSlug }
            .sorted(using: sortOrder)
    }

    private func captureSlugs(in selected: ReviewSeriesSnapshot) -> [String] {
        Array(Set(selected.decisions.compactMap { store.quality(for: $0.relativePath)?.captureSlug })).sorted()
    }

    private var runningRatingOperation: OperationHost.ActiveOperation? {
        guard let selectedSeriesID = store.selectedSeriesID else { return nil }
        let kind = OperationKind.rate(series: selectedSeriesID.uuidString)
        return operationHost.activeOperations.first { $0.kind == kind }
    }

    /// Backs the "Frames" header's ⓘ button -- what the measured quality
    /// columns mean, per V1's `QualitySegment`-era explanations.
    private static let qualityMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Score", explanation: "This library's overall quality ranking for the frame, combining FWHM, roundness, background, and saturation into one number. Higher is better. The outlier flag next to a low score uses this library's z-score threshold.", glossaryTerm: "z-score"),
        .init(title: "FWHM", explanation: "Full Width at Half Maximum -- how sharp the stars are. A smaller value is a sharper frame.", glossaryTerm: "FWHM"),
        .init(title: "Roundness", explanation: "How far star shapes deviate from a perfect circle. A high value can mean coma, trailing, or a guiding error.", glossaryTerm: "Roundness"),
        .init(title: "Background", explanation: "The measured sky-background level for the frame, in ADU unless a sensor profile makes e⁻/s/″² available.", glossaryTerm: "ADU"),
        .init(title: "Sat. %", explanation: "The fraction of pixels at or near the sensor's saturation point -- a high value can mean an overexposed core or a bright satellite trail."),
        .init(title: "Percentile", explanation: "How this frame's score compares to every other frame measured in this library."),
    ]

    private static func formatted(_ value: Double?, fractionDigits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    private func reviewActions(_ selected: ReviewSeriesSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Accept") { apply(.accepted, decisionIDs: selectedDecisionIDs, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .accessibilityIdentifier("v2.review.accept")
            Button("Reset") { apply(.undecided, decisionIDs: selectedDecisionIDs, in: selected) }
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
                .accessibilityIdentifier("v2.review.reset")
            Button("Reject") { apply(.rejected, decisionIDs: selectedDecisionIDs, in: selected) }
                .buttonStyle(.borderedProminent)
                .tint(AstroTokens.Color.critical)
                .disabled(selectedDecisionIDs.isEmpty || store.isApplyingDecision)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier("v2.review.reject")
        }
    }

    @ViewBuilder
    private func inspector(for selected: ReviewSeriesSnapshot) -> some View {
        if selectedDecisionIDs.count == 1,
           let id = selectedDecisionIDs.first,
           let decision = selected.decisions.first(where: { $0.id == id }) {
            FrameInspector(decision: decision)
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
                    segment(count: snapshot.acceptedCount, totalWidth: geometry.size.width, color: AstroTokens.Color.ok)
                    segment(count: snapshot.undecidedCount, totalWidth: geometry.size.width, color: AstroTokens.Color.dataUnclassified)
                    segment(count: snapshot.rejectedCount, totalWidth: geometry.size.width, color: AstroTokens.Color.critical)
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
        // When there are zero decisions yet, render one full-width bar in
        // the "undecided" (`dataUnclassified`) color as the empty-state
        // placeholder rather than three zero-width bars -- the comparison
        // below identifies that segment by its token, the same
        // `AstroTokens.Color.dataUnclassified` static value passed at the
        // call site above, so it still recognizes it after the literal
        // `.gray` this used to compare against became a token.
        color.frame(width: snapshot.decisions.isEmpty
            ? (color == AstroTokens.Color.dataUnclassified ? totalWidth : 0)
            : totalWidth * Double(count) / Double(snapshot.decisions.count))
    }
}

/// A `FrameDecisionRecord` joined with its measured quality
/// (`FrameQualityMetrics`, when any exists) for the frame table -- mirrors
/// V1 `QualitySegment.Row`'s "flatten for `Table`, expose `xxxSortKey`
/// computed properties defaulting missing values to `-.infinity`" pattern,
/// so `KeyPathComparator` (which requires `Comparable`, not
/// `Comparable?`) can sort a column with unmeasured frames in it -- an
/// unmeasured frame always sorts as if it scored below every measured one,
/// regardless of sort direction.
private struct ReviewFrameRow: Identifiable {
    let decision: FrameDecisionRecord
    let quality: FrameQualityMetrics?

    var id: UUID { decision.id }
    var fwhm: Double? { quality?.fwhm }
    var roundness: Double? { quality?.roundness }
    var background: Double? { quality?.background }
    var saturatedFraction: Double? { quality?.saturatedFraction }
    var score: Double? { quality?.score }
    var isOutlier: Bool { quality?.isOutlier ?? false }
    var percentile: Int? { quality?.libraryPercentile?.percentile }
    var captureSlug: String? { quality?.captureSlug }

    var scoreSortKey: Double { score ?? -.infinity }
    var fwhmSortKey: Double { fwhm ?? -.infinity }
    var roundnessSortKey: Double { roundness ?? -.infinity }
    var backgroundSortKey: Double { background ?? -.infinity }
    var saturatedFractionSortKey: Double { saturatedFraction ?? -.infinity }
}

/// A small color dot showing where a frame's score falls within this
/// library's own score distribution -- `ok`/muted/`attention` for
/// best/middle/worst third (`PercentileBand`), `dataUnclassified` (the
/// palette's own "the app knows nothing about it" gray) for a low sample,
/// since a low sample means there isn't enough data to rank the frame at
/// all, not that the frame itself scored badly. Renders nothing when
/// `result` is `nil` (the frame has no score to rank, e.g. never rated).
private struct PercentileDot: View {
    let result: LibraryPercentileResult?

    var body: some View {
        if let result {
            Circle()
                .fill(result.isLowSample ? AstroTokens.Color.dataUnclassified : Self.color(for: result.band))
                .frame(width: 7, height: 7)
                .help(Self.tooltipText(result))
        }
    }

    private static func color(for band: PercentileBand) -> Color {
        switch band {
        case .best: AstroTokens.Color.ok
        // The middle third isn't a status worth signaling -- it's an
        // unremarkable, average frame. `ok`/`attention` are reserved for
        // the two thirds that ARE worth a color opinion (best, worst);
        // `.secondary` (a semantic system role that adapts with
        // appearance, not a specific hue -- see this gate's own doc
        // comment) says "no particular status" instead of inventing a
        // third arbitrary hue the way the old raw `.yellow` did.
        case .middle: .secondary
        case .worst: AstroTokens.Color.attention
        }
    }

    private static func tooltipText(_ result: LibraryPercentileResult) -> String {
        if result.isLowSample {
            return "Too few rated frames in this library yet (\(result.sampleCount)/\(LibraryPercentiles.minimumSampleSize))"
        }
        return "Percentile \(result.percentile) across every rated frame in this library."
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
                    Text(filter).font(.caption.weight(.medium)).foregroundStyle(AstroTokens.Color.accent)
                }
            }
            Text(snapshot.series.setupDescriptor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 10) {
                Label("\(snapshot.acceptedCount)", systemImage: "checkmark.circle.fill").foregroundStyle(AstroTokens.Color.ok)
                Label("\(snapshot.rejectedCount)", systemImage: "xmark.circle.fill").foregroundStyle(AstroTokens.Color.critical)
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
        case .accepted: AstroTokens.Color.ok
        case .rejected: AstroTokens.Color.critical
        case .undecided: .secondary
        }
    }
}
