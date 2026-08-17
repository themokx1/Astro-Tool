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

    @Test("Findings sharing a parent folder group into one folder row, not one row each")
    func groupingCollapsesASharedFolderIntoOneRow() async throws {
        let store = ArchiveTaskDetailStore(
            factory: { _, _ in
                (1...28).map { i in
                    ArchiveFinding(id: Int64(i), path: "library/biases/bias_\(i).fit", bytes: 50_000_000)
                }
            }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .misplacedCalibration)

        #expect(store.rows.count == 1, "28 files under one folder must collapse into a single folder row")
        guard case .folder(let path, let fileCount, let bytes) = store.rows[0].kind else {
            Issue.record("expected a folder row")
            return
        }
        #expect(path == "library/biases")
        #expect(fileCount == 28)
        #expect(bytes == 28 * 50_000_000)
        #expect(store.rows[0].children?.count == 28, "every file must still be reachable as a child of its folder")
        for child in store.rows[0].children ?? [] {
            guard case .finding = child.kind else {
                Issue.record("a folder's children must be `.finding` rows, never nested folders")
                return
            }
        }
    }

    @Test("Distinct folders each get their own row, biggest folder first")
    func groupingSeparatesDistinctFoldersBiggestFirst() async throws {
        let store = ArchiveTaskDetailStore(
            factory: { _, _ in
                [
                    ArchiveFinding(id: 1, path: "library/darks/dark_1.fit", bytes: 10),
                    ArchiveFinding(id: 2, path: "library/biases/bias_1.fit", bytes: 900),
                    ArchiveFinding(id: 3, path: "library/biases/bias_2.fit", bytes: 900),
                ]
            }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .misplacedCalibration)

        #expect(store.rows.count == 2)
        let paths = store.rows.compactMap { row -> String? in
            guard case .folder(let path, _, _) = row.kind else { return nil }
            return path
        }
        #expect(paths == ["library/biases", "library/darks"], "the 1800-byte folder must sort before the 10-byte folder")
    }

    @Test("A folder row is never mistaken for a zero-byte file: its own case carries fileCount and bytes, not a finding")
    func folderRowIsNeverAFindingLookalike() async throws {
        let store = ArchiveTaskDetailStore(
            factory: { _, _ in [ArchiveFinding(id: 1, path: "library/darks/dark_1.fit", bytes: 12345)] }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"), kind: .misplacedCalibration)

        guard case .folder(let path, let fileCount, let bytes) = store.rows[0].kind else {
            Issue.record("expected a folder row even for a single-file folder")
            return
        }
        #expect(path == "library/darks")
        #expect(fileCount == 1)
        #expect(bytes == 12345, "the folder's own row must carry the real total, never 0")
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
