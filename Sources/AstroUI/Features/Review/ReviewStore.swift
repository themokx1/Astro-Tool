import AstroApplication
import Foundation
import Observation

public enum ReviewStoreError: LocalizedError, Equatable {
    case reviewNotOpen
    case seriesNotSelected

    public var errorDescription: String? {
        switch self {
        case .reviewNotOpen: "Open a project before reviewing its frames."
        case .seriesNotSelected: "Select a capture series first."
        }
    }
}

/// Thread-safe box for `FrameRatingCommand.run`'s `(done, total)` progress
/// pair, bridged into `OperationHost.reportProgress`'s async, polled-from-
/// the-outside world -- mirrors `SensorProfilesStore`'s own progress-counter
/// box, just carrying a `(done, total)` pair instead of a plain increment
/// count, since `FrameRatingCommand` (unlike `SensorMeasurementCommand`)
/// already knows its own total up front.
private final class FrameRatingProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _total: Int64 = 0
    func update(done: Int, total: Int) {
        lock.lock(); _done = Int64(done); _total = Int64(total); lock.unlock()
    }
    var current: (done: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (_done, _total)
    }
}

@MainActor
@Observable
public final class ReviewStore {
    public typealias MetadataFactory = ProjectsStore.MetadataFactory
    public typealias QualityQueryFactory = @Sendable (URL) throws -> FrameQualityQuery
    public typealias RatingCommandFactory = @Sendable (URL) throws -> FrameRatingCommand

    public private(set) var snapshot: ReviewProjectSnapshot?
    public private(set) var selectedSeriesID: UUID?
    public private(set) var isLoading = false
    public private(set) var isApplyingDecision = false
    public private(set) var errorMessage: String?
    /// Measured quality metrics, keyed by `FrameDecisionRecord.relativePath`,
    /// for every frame in the currently open project -- refreshed whenever
    /// `open`/`setVerdict`/`rateSelectedSeries` change what's on record. A
    /// path absent from this dictionary (rather than present with `nil`
    /// fields) means it simply hasn't been queried yet -- use
    /// `quality(for:)` rather than subscripting directly.
    public private(set) var qualityByPath: [String: FrameQualityMetrics] = [:]

    public var selectedSeries: ReviewSeriesSnapshot? {
        guard let selectedSeriesID else { return nil }
        return snapshot?.series.first { $0.id == selectedSeriesID }
    }

    private let metadataFactory: MetadataFactory
    private let qualityQueryFactory: QualityQueryFactory
    private let ratingCommandFactory: RatingCommandFactory
    private var metadata: MetadataStore?
    private var projectID: UUID?
    private var rootURL: URL?

    public init(
        metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata,
        qualityQueryFactory: @escaping QualityQueryFactory = { rootURL in try FrameQualityQuery.production(rootURL: rootURL) },
        ratingCommandFactory: @escaping RatingCommandFactory = { rootURL in try FrameRatingCommand.production(rootURL: rootURL) }
    ) {
        self.metadataFactory = metadataFactory
        self.qualityQueryFactory = qualityQueryFactory
        self.ratingCommandFactory = ratingCommandFactory
    }

    /// v5 library-switch fixes (item 2): forgets the project this store had
    /// open. Nothing reset it on a library switch, so a `.review` route left
    /// over from the previous library kept rendering that library's frames
    /// (and its Accept/Reject actions kept writing to that library's
    /// metadata store) under the newly opened one.
    public func reset() {
        snapshot = nil
        selectedSeriesID = nil
        errorMessage = nil
        qualityByPath = [:]
        metadata = nil
        projectID = nil
        rootURL = nil
    }

    public func open(rootURL: URL, projectID: UUID) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            self.metadata = metadata
            self.projectID = projectID
            self.rootURL = rootURL.standardizedFileURL
            let loaded = try await ReviewQuery(metadata: metadata).project(projectID)
            snapshot = loaded
            if selectedSeriesID == nil || !loaded.series.contains(where: { $0.id == selectedSeriesID }) {
                selectedSeriesID = loaded.series.first?.id
            }
            await refreshQuality()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// This frame's measured quality, or `nil` when it hasn't been rated (or
    /// hasn't been queried into `qualityByPath` yet at all).
    public func quality(for relativePath: String) -> FrameQualityMetrics? {
        qualityByPath[relativePath]
    }

    /// Re-reads measured quality for every frame across every series of the
    /// currently open project. Best-effort: a query failure (e.g. no index
    /// DB has been created for this library yet) leaves `qualityByPath`
    /// untouched rather than failing the caller -- quality metrics are
    /// supplementary to the review workflow itself (accept/reject/archive
    /// all work with zero measured data).
    private func refreshQuality() async {
        guard let rootURL, let snapshot else { return }
        let paths = snapshot.series.flatMap { $0.decisions.map(\.relativePath) }
        guard !paths.isEmpty else {
            qualityByPath = [:]
            return
        }
        do {
            let query = try qualityQueryFactory(rootURL)
            let metrics = try query.metrics(relativePaths: paths)
            qualityByPath = Dictionary(uniqueKeysWithValues: metrics.map { ($0.relativePath, $0) })
        } catch {
            // Supplementary data -- see doc comment above.
        }
    }

    /// Rates the selected series' frames through `operationHost`: registers
    /// under `.rate(series:)` (so a second rating run cannot start on the
    /// SAME series while one is already in flight), reports incremental
    /// progress as `FrameRatingCommand` completes each frame, and refreshes
    /// both `snapshot` and `qualityByPath` once the run settles -- on
    /// success AND on cancellation/failure alike, since `Rater` upserts each
    /// frame's measurement before moving to the next, so even a cancelled
    /// run may have measured real frames worth showing immediately.
    public func rateSelectedSeries(mode: FrameRatingMode, operationHost: OperationHost) async {
        guard let rootURL, let projectID, let selected = selectedSeries else {
            operationHost.notify(.info, message: OperationHost.localized("Select a capture series before rating its frames."))
            return
        }
        let label = "\(snapshot?.project.displayName ?? "Project") · \(AstroFormat.exposureSeconds(selected.series.exposureSeconds))"
        let kind = OperationKind.rate(series: selected.series.id.uuidString)
        // Exclusive against EVERY rating scope, not just this series':
        // "Rate All" and a single project's rating both cover these same
        // frames. See `OperationKind.isRating`.
        if let running = operationHost.activeOperations.first(where: { $0.kind.isRating }) {
            operationHost.notify(.info, message: OperationHost.localized(
                running.kind == kind
                    ? "Frame rating is already running for this series."
                    : "Frame rating is already running."
            ))
            return
        }

        do {
            let command = try ratingCommandFactory(rootURL)
            let relativePaths = selected.decisions.map(\.relativePath)
            let box = FrameRatingProgressBox()

            let id = await operationHost.run(kind: kind, title: "\(OperationHost.localized("Rating frames")) — \(label)", cancellation: .cooperative) { [weak self] in
                do {
                    try Task.checkCancellation()
                    _ = try command.run(
                        relativePaths: relativePaths,
                        mode: mode,
                        progress: { done, total in box.update(done: done, total: total) },
                        isCancelled: { Task.isCancelled }
                    )
                } catch {
                    await self?.refreshAfterRating(rootURL: rootURL, projectID: projectID)
                    throw error
                }
                await self?.refreshAfterRating(rootURL: rootURL, projectID: projectID)
            }

            operationHost.relayProgress(id: id) {
                let progress = box.current
                return OperationProgress(completed: progress.done, total: progress.total > 0 ? progress.total : nil)
            }
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Frame rating failed:")) \(error.localizedDescription)")
        }
    }

    private func refreshAfterRating(rootURL: URL, projectID: UUID) async {
        if let metadata, let fresh = try? await ReviewQuery(metadata: metadata).project(projectID) {
            snapshot = fresh
        }
        await refreshQuality()
    }

    public func selectSeries(_ id: UUID) {
        guard snapshot?.series.contains(where: { $0.id == id }) == true else { return }
        selectedSeriesID = id
    }

    public func setVerdict(
        relativePaths: [String],
        verdict: FrameVerdict
    ) async throws {
        guard let metadata, let projectID else { throw ReviewStoreError.reviewNotOpen }
        guard let selectedSeriesID else { throw ReviewStoreError.seriesNotSelected }
        guard !relativePaths.isEmpty else { return }
        isApplyingDecision = true
        errorMessage = nil
        defer { isApplyingDecision = false }
        do {
            _ = try await ReviewCommands(metadata: metadata).setVerdict(
                seriesID: selectedSeriesID,
                relativePaths: relativePaths,
                verdict: verdict
            )
            snapshot = try await ReviewQuery(metadata: metadata).project(projectID)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Deliberately has no UI consumer today. Task 11 (2026-08-16 Archive
    /// Map wave) deleted `FrameInspector`'s "Move to Archive…" button and
    /// `ReviewWorkspace`'s `ArchivePreviewSheet`: the sheet's only button was
    /// `Close`, and no code path anywhere ever applied the plan it
    /// previewed -- a door painted on a wall, per the 2026-08-15 product
    /// audit. This method and `ReviewCommands.archivePlan(relativePath:)`
    /// are kept and stay tested because they are the real, correct core of
    /// a future archive-move feature -- just not one wired to any surface
    /// yet. Do not "helpfully" wire a button back to this without also
    /// building the actual move-and-confirm flow (source/destination
    /// resolution, write-access gating, and applying the plan), or you will
    /// recreate the exact false promise this task removed.
    public func archivePlan(for decision: FrameDecisionRecord) throws -> ReviewArchivePlan {
        guard let metadata else { throw ReviewStoreError.reviewNotOpen }
        return try ReviewCommands(metadata: metadata).archivePlan(relativePath: decision.relativePath)
    }

    /// W3-12 finding 3: used to be written straight through with no
    /// `do`/`catch` at all, and its one call site (`ReviewWorkspace.inspector
    /// (for:)`) wrapped it in `try?` -- a failed filter assignment vanished
    /// with no message AND no correction, since `SeriesInspector`'s own
    /// "Save and Use" flow cleared its manufacturer/model fields and any
    /// local `filterError` immediately after firing this off, before the
    /// write had actually settled (a lie: the form read as "done" whether or
    /// not the write landed). Now matches `setVerdict`/`open`'s own shape --
    /// `errorMessage` set on failure, then rethrown so the caller (now doing
    /// real error handling instead of `try?`) can react too.
    ///
    /// W6-F: kept as the "assign to whatever THIS store currently has
    /// selected" shape for `ReviewWorkspace`, which really does mean that --
    /// its own series list drives `selectedSeriesID` via `selectSeries(_:)`.
    /// Anything inspecting a series it names explicitly (a different
    /// concept -- see `assignFilter(_:toSeriesID:)` below) should call that
    /// overload instead, not this one.
    public func assignFilter(_ filter: EquipmentFilter) async throws {
        guard let selectedSeriesID else { throw ReviewStoreError.seriesNotSelected }
        try await assignFilter(filter, toSeriesID: selectedSeriesID)
    }

    /// W6-F: the app-wide `InspectorView`'s series panel -- the "series
    /// page" surface an owner repro (filter created via "Save and Use" but
    /// never landing on the series) traced to -- inspects whichever series
    /// `AppRouter.inspectorSelection` currently names, which has no relation
    /// to this store's own `selectedSeriesID`: that field only ever moves
    /// when `ReviewWorkspace`'s in-workspace list calls `selectSeries(_:)`,
    /// which does not happen just from browsing to a series elsewhere (the
    /// Projects/Library surfaces that host `InspectorView`). Before this
    /// overload existed, `InspectorView` had no correct way to call
    /// `assignFilter(_:)` at all: going through the ambient-selection
    /// overload above could silently write the new filter onto whichever
    /// series `ReviewWorkspace` last had selected (possibly a different one,
    /// possibly none, in which case it threw `seriesNotSelected` with no
    /// visible cause) rather than the series actually on screen. Call sites
    /// that already know their target series -- because they were handed its
    /// ID, not because they infer it from this store's ambient selection --
    /// use this instead.
    public func assignFilter(_ filter: EquipmentFilter, toSeriesID seriesID: UUID) async throws {
        guard let metadata, let projectID else { throw ReviewStoreError.reviewNotOpen }
        guard let selected = snapshot?.series.first(where: { $0.id == seriesID })?.series else {
            throw ReviewStoreError.seriesNotSelected
        }
        let passband: SeriesPassband = switch filter.passband {
        case .broadband: .broadband
        case .dualBand: .dualBand
        case .narrowband: .narrowband
        case .unknown: .unknown
        }
        let displayName = [filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " ")
        let updated = SeriesRecord(
            id: selected.id, projectID: selected.projectID, nightID: selected.nightID,
            setupID: selected.setupID, setupDescriptor: selected.setupDescriptor,
            sensorMode: selected.sensorMode, passband: passband,
            exposureSeconds: selected.exposureSeconds, filterName: displayName,
            filterID: filter.id.uuidString.lowercased(), gain: selected.gain,
            offset: selected.offset, binning: selected.binning
        )
        do {
            try await metadata.save(updated)
            snapshot = try await ReviewQuery(metadata: metadata).project(projectID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
