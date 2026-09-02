@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
struct ArchiveStoreTests {
    @Test("A fresh store holds nothing and has run nothing")
    func initIsSideEffectFree() {
        let store = ArchiveStore(
            mapFactory: { _ in Issue.record("init must not query"); throw CancellationError() },
            taskFactory: { _ in Issue.record("init must not query"); throw CancellationError() }
        )
        #expect(store.snapshot == nil)
        #expect(store.tasks.isEmpty)
        #expect(store.uncovered.isEmpty)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("Loading publishes the snapshot, the tasks, and the uncovered findings together")
    func loadPublishesBoth() async throws {
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 1000) },
            taskFactory: { _ in
                ArchiveTaskSummary(
                    tasks: [.stub(kind: .intermediateFiles, bytes: 400)],
                    uncovered: UncoveredFindings(count: 3, bytes: 900, categories: ["tool-output": 3])
                )
            }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"))

        #expect(store.snapshot?.totalBytes == 1000)
        #expect(store.tasks.count == 1)
        #expect(store.uncovered.count == 3)
        #expect(store.uncovered.bytes == 900)
        #expect(store.uncovered.categories == ["tool-output": 3])
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("A failing query surfaces its message instead of leaving a silent blank page")
    func loadFailureIsVisible() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "index unreadable" } }
        let store = ArchiveStore(
            mapFactory: { _ in throw Boom() },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"))

        #expect(store.snapshot == nil)
        #expect(store.errorMessage == "index unreadable")
        #expect(!store.isLoading)
        #expect(store.uncovered == .none)
    }

    @Test("A superseded load never overwrites a newer result")
    func staleLoadIsDiscarded() async throws {
        let gate = AsyncGate()
        let store = ArchiveStore(
            mapFactory: { url in
                if url.lastPathComponent == "slow" { await gate.wait() }
                return .stub(totalBytes: url.lastPathComponent == "slow" ? 1 : 2)
            },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) }
        )

        let slow = Task { await store.load(rootURL: URL(fileURLWithPath: "/tmp/slow")) }
        // Let the slow load reach its suspension point inside the factory
        // before the second one starts and bumps the generation.
        while await !gate.isWaiting { await Task.yield() }
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/fast"))
        await gate.open()
        await slow.value

        #expect(store.snapshot?.totalBytes == 2, "the superseded slow load must not overwrite")
        #expect(!store.isLoading, "the superseded load must not clear the newer load's flag either")
    }

    @Test("Setting the same class filter twice does not republish")
    func filterSetterGuardsEqualValues() {
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 0) },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) }
        )
        store.selectedClass = .light
        let first = store.filterChangeCount
        store.selectedClass = .light
        #expect(store.filterChangeCount == first)
    }

    // W3-12 finding 1: `ArchiveView.acknowledge` used to open its own
    // `MetadataStore` inline and swallow any write failure in an empty
    // `catch` -- a failed acknowledge left the card on screen with nothing
    // telling the user why. `ArchiveStore.acknowledge` replaces that with a
    // real, injectable write path that reports through `OperationHost`,
    // exactly like every other V2 write.

    @Test("Acknowledging a task notifies success and reloads the map once the write lands")
    func acknowledgeSucceedsAndReloads() async throws {
        let loadCount = ArchiveStoreTestCounter()
        let store = ArchiveStore(
            mapFactory: { _ in await loadCount.increment(); return .stub(totalBytes: 500) },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) },
            metadataFactory: { _ in try MetadataStore.temporary() }
        )
        let host = OperationHost(center: OperationCenter())
        let task = ArchiveTask.stub(kind: .intermediateFiles, bytes: 400)

        await store.acknowledge(task, note: "known", rootURL: URL(fileURLWithPath: "/tmp/lib"), operationHost: host)
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
        #expect(await loadCount.value == 1, "acknowledging must reload the map so the card actually disappears")
    }

    @Test("A failing acknowledge write notifies failure instead of leaving the card silently unchanged")
    func acknowledgeFailureNotifiesInsteadOfSwallowing() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "metadata store unavailable" } }
        let loadCount = ArchiveStoreTestCounter()
        let store = ArchiveStore(
            mapFactory: { _ in await loadCount.increment(); return .stub(totalBytes: 500) },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) },
            metadataFactory: { _ in throw Boom() }
        )
        let host = OperationHost(center: OperationCenter())
        let task = ArchiveTask.stub(kind: .intermediateFiles, bytes: 400)

        await store.acknowledge(task, note: nil, rootURL: URL(fileURLWithPath: "/tmp/lib"), operationHost: host)
        await host.settle()

        #expect(host.toasts.contains { $0.level == .failure && $0.message.contains("metadata store unavailable") })
        #expect(await loadCount.value == 0, "a failed acknowledge must not silently pretend a reload happened")
    }

    // MARK: - v5 library-switch fixes, item 3 (follow-up): `acknowledge`
    // used to open its own confined `MetadataStore` connection through
    // `metadataFactory` on every call, competing with `ProjectsStore`'s
    // already-open one for the same file.

    @Test("An already-open metadata store is reused instead of opening a second connection")
    func acknowledgeReusesTheSharedMetadataStore() async throws {
        let root = URL(fileURLWithPath: "/tmp/lib")
        let shared = try MetadataStore.temporary()
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 500) },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) },
            // Opening one here would be the bug -- `acknowledge` must go
            // through `sharedMetadataProvider` and never touch this.
            metadataFactory: { _ in throw ArchiveStoreTestFailure.shouldNotOpenASecondConnection }
        )
        store.sharedMetadataProvider = { asked in asked == root ? shared : nil }
        let host = OperationHost(center: OperationCenter())
        let task = ArchiveTask.stub(kind: .intermediateFiles, bytes: 400)

        await store.acknowledge(task, note: "known", rootURL: root, operationHost: host)
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
    }

    @Test("A root the shared provider does not own still falls back to this store's own factory")
    func acknowledgeFallsBackWhenNoSharedStoreIsOpenForThisRoot() async throws {
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 500) },
            taskFactory: { _ in ArchiveTaskSummary(tasks: [], uncovered: .none) },
            metadataFactory: { _ in try MetadataStore.temporary() }
        )
        // The window's store is open for some OTHER library -- exactly the
        // mid-switch state where reusing it would answer for the wrong root.
        store.sharedMetadataProvider = { _ in nil }
        let host = OperationHost(center: OperationCenter())
        let task = ArchiveTask.stub(kind: .intermediateFiles, bytes: 400)

        await store.acknowledge(task, note: "known", rootURL: URL(fileURLWithPath: "/tmp/lib"), operationHost: host)
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
    }

    // MARK: - v5 library-switch fixes, item 2 (follow-up): nothing reset
    // this store's map/tasks/filter on a library switch, the same
    // staleness `ReviewStore.reset()`/`LibraryHealthStore.reset()` already
    // fix for their own state.

    @Test("reset forgets the previous library's map, tasks, and class filter")
    func resetClearsEverything() async throws {
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 1000) },
            taskFactory: { _ in
                ArchiveTaskSummary(
                    tasks: [.stub(kind: .intermediateFiles, bytes: 400)],
                    uncovered: UncoveredFindings(count: 3, bytes: 900, categories: ["tool-output": 3])
                )
            }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"))
        store.selectedClass = .light

        store.reset()

        #expect(store.snapshot == nil)
        #expect(store.tasks.isEmpty)
        #expect(store.uncovered == .none)
        #expect(store.visibleRows.isEmpty)
        #expect(store.errorMessage == nil)
        #expect(store.selectedClass == nil)
    }
}

private enum ArchiveStoreTestFailure: Error, Equatable {
    case shouldNotOpenASecondConnection
}

/// A plain `Sendable` counter for `mapFactory`/`taskFactory` closures (both
/// `@Sendable`) to increment from off the main actor -- mirrors
/// `WorkspaceActionsTests`' own `NotificationCounter`.
private actor ArchiveStoreTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A one-shot suspension point the test opens by hand, so "a slow load is
/// overtaken by a fast one" is deterministic rather than a race the test
/// hopes to win.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private extension ArchiveMapSnapshot {
    static func stub(totalBytes: Int64) -> ArchiveMapSnapshot {
        ArchiveMapSnapshot(
            totalBytes: totalBytes, fileCount: 0, targetCount: 0, nightCount: 0,
            slices: [], rows: [],
            reclaimableBytes: 0, reclaimableFiles: 0,
            lastScanAt: nil, lastAuditAt: nil
        )
    }
}

private extension ArchiveTask {
    static func stub(kind: ArchiveTaskKind, bytes: Int64) -> ArchiveTask {
        ArchiveTask(
            kind: kind, severity: .reclaim,
            affectedFileCount: 0, bytes: bytes,
            evidencePaths: [], action: .unavailable
        )
    }
}
