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
