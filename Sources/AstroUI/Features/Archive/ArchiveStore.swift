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
    public typealias TaskFactory = @Sendable (URL) async throws -> [ArchiveTask]

    public private(set) var snapshot: ArchiveMapSnapshot?
    public private(set) var tasks: [ArchiveTask] = []
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
    private var generation = 0

    public init(
        mapFactory: @escaping MapFactory = { rootURL in
            try await ArchiveMapQuery.production(rootURL: rootURL).snapshot()
        },
        taskFactory: @escaping TaskFactory = { rootURL in
            try await ArchiveTaskQuery.production(rootURL: rootURL).tasks()
        }
    ) {
        self.mapFactory = mapFactory
        self.taskFactory = taskFactory
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
            tasks = loaded
            recomputeVisibleRows()
        } catch {
            guard token == generation else { return }
            snapshot = nil
            tasks = []
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
}
