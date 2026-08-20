import AstroApplication
import Foundation
import Observation

/// Loads `ArchiveMapSnapshot` and `[ArchiveTask]` for the Archive map view and
/// holds the strip's class filter. Follows `LibraryHealthStore`'s
/// factory-injection shape so it is testable without a database, and obeys
/// the freeze antipatterns `PlanningStore.swift` documents inline (five
/// separate freeze regressions, builds 20013/20015/20016/20017): no query in
/// a computed getter, a side-effect-free `init`, an equal-value guard on
/// every setter/`didSet`, and a generation guard on the async load so a
/// superseded slow load can never overwrite a newer result or clear its
/// `isLoading`.
@MainActor
@Observable
public final class ArchiveStore {
    public typealias MapFactory = @Sendable (URL) async throws -> ArchiveMapSnapshot
    public typealias TaskFactory = @Sendable (URL) async throws -> ArchiveTaskSummary
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore

    public private(set) var snapshot: ArchiveMapSnapshot?
    /// Convenience for the view: the cards half of the last-loaded
    /// `ArchiveTaskSummary`. Kept alongside `uncovered` rather than making
    /// callers dig into a summary struct for the common case.
    public private(set) var tasks: [ArchiveTask] = []
    /// What `ArchiveTaskQuery` could not cover -- the footer reads this so
    /// the page never silently implies it saw more findings than it did.
    public private(set) var uncovered: UncoveredFindings = .none
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// Which class the user clicked in the strip, filtering the target rows
    /// below it. `nil` = no filter.
    public var selectedClass: ArchiveClass? {
        didSet {
            guard oldValue != selectedClass else { return }
            filterChangeCount += 1
            recomputeVisibleRows()
        }
    }
    /// Test-visible proof the equal-value guard above actually fires.
    public private(set) var filterChangeCount = 0

    /// Rows after the strip filter -- a stored property recomputed on load
    /// and on filter change, never a computed getter (see this file's
    /// required reading: a query in a computed getter is what froze
    /// Planning).
    public private(set) var visibleRows: [ArchiveTargetRow] = []

    private let mapFactory: MapFactory
    private let taskFactory: TaskFactory
    private let metadataFactory: MetadataFactory
    private var generation = 0

    public init(
        mapFactory: @escaping MapFactory = { rootURL in
            try await ArchiveMapQuery.production(rootURL: rootURL).snapshot()
        },
        taskFactory: @escaping TaskFactory = { rootURL in
            try await ArchiveTaskQuery.production(rootURL: rootURL).summary()
        },
        metadataFactory: @escaping MetadataFactory = ArchiveStore.productionMetadata
    ) {
        self.mapFactory = mapFactory
        self.taskFactory = taskFactory
        self.metadataFactory = metadataFactory
    }

    public func load(rootURL: URL) async {
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        do {
            let map = try await mapFactory(rootURL)
            let loaded = try await taskFactory(rootURL)
            guard token == generation else { return }
            snapshot = map
            tasks = loaded.tasks
            uncovered = loaded.uncovered
            recomputeVisibleRows()
        } catch {
            guard token == generation else { return }
            snapshot = nil
            tasks = []
            uncovered = .none
            visibleRows = []
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }

    public func recomputeVisibleRows() {
        guard let snapshot else { visibleRows = []; return }
        guard let selectedClass else { visibleRows = snapshot.rows; return }
        visibleRows = snapshot.rows.filter { row in
            row.slices.contains { $0.archiveClass == selectedClass }
        }
    }

    /// Marks one archive task's finding group as acknowledged, then reloads
    /// so the card actually disappears. Routed through `OperationHost`
    /// rather than this store's own `errorMessage` -- `errorState`/
    /// `ArchiveView`'s own branch order treats a non-nil `errorMessage` as
    /// "the whole page failed to load" (it blanks `snapshot`/`tasks` right
    /// alongside it), which would wrongly blank an already-loaded map out
    /// from under the user over a single card's write failure. `OperationHost`
    /// gives a failed acknowledge the same toast receipt every other V2
    /// write gets instead -- W3-12 replaces `ArchiveView.acknowledge`'s own
    /// empty `catch` (a failed write used to leave the card on screen with
    /// no visible reason why) with this.
    public func acknowledge(
        _ task: ArchiveTask,
        note: String?,
        rootURL: URL,
        operationHost: OperationHost
    ) async {
        let standardizedRoot = rootURL.standardizedFileURL
        let kind = OperationKind.acknowledge(library: standardizedRoot.path)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("An acknowledgement is already being saved for this library."))
            return
        }
        do {
            let metadata = try metadataFactory(standardizedRoot)
            let title = OperationHost.localized("Acknowledging finding")
            _ = await operationHost.run(kind: kind, title: title, cancellation: .unavailable) { [weak self] in
                try await metadata.acknowledgeFindingGroup(
                    category: ArchiveTask.ackCategory, groupKey: task.ackGroupKey, note: note
                )
                await self?.load(rootURL: standardizedRoot)
            }
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Could not save acknowledgement:")) \(error.localizedDescription)")
        }
    }

    public static func productionMetadata(rootURL: URL) throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return try MetadataStore(storagePaths: storage)
    }
}
