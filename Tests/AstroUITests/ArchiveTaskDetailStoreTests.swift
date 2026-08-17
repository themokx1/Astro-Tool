@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
struct ArchiveTaskDetailStoreTests {
    @Test("A fresh store holds nothing and has run nothing")
    func initIsSideEffectFree() {
        let store = ArchiveTaskDetailStore(
            factory: { _, _ in Issue.record("init must not query"); throw CancellationError() }
        )
        #expect(store.findings.isEmpty)
        #expect(store.totalBytes == 0)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("Loading publishes the findings and their summed byte total")
    func loadPublishesFindingsAndTotal() async throws {
        let store = ArchiveTaskDetailStore(
            factory: { _, kind in
                #expect(kind == .intermediateFiles)
                return [
                    ArchiveFinding(id: 1, path: "a.fit", bytes: 100),
                    ArchiveFinding(id: 2, path: "b.fit", bytes: 250),
                ]
            }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .intermediateFiles)

        #expect(store.findings.map(\.path) == ["a.fit", "b.fit"])
        #expect(store.totalBytes == 350)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("A failing query surfaces its message instead of leaving a silent blank page")
    func loadFailureIsVisible() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "index unreadable" } }
        let store = ArchiveTaskDetailStore(factory: { _, _ in throw Boom() })
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .intermediateFiles)

        #expect(store.findings.isEmpty)
        #expect(store.totalBytes == 0)
        #expect(store.errorMessage == "index unreadable")
        #expect(!store.isLoading)
    }

    @Test("A superseded load never overwrites a newer result")
    func staleLoadIsDiscarded() async throws {
        let gate = AsyncGate()
        let store = ArchiveTaskDetailStore(
            factory: { _, kind in
                if kind == .intermediateFiles { await gate.wait() }
                return kind == .intermediateFiles
                    ? [ArchiveFinding(id: 1, path: "slow.fit", bytes: 1)]
                    : [ArchiveFinding(id: 2, path: "fast.fit", bytes: 2)]
            }
        )

        let slow = Task { await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .intermediateFiles) }
        while await !gate.isWaiting { await Task.yield() }
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .duplicateContent)
        await gate.open()
        await slow.value

        #expect(store.findings.map(\.path) == ["fast.fit"], "the superseded slow load must not overwrite")
        #expect(!store.isLoading, "the superseded load must not clear the newer load's flag either")
    }
}

/// A one-shot suspension point the test opens by hand, mirroring
/// `ArchiveStoreTests`'s own `AsyncGate` -- deterministic instead of a race
/// the test merely hopes to win.
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
