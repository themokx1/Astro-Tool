@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// Covers the global rescan action (V2 parity wave 2, task 3): re-running
/// the same read-only scan pipeline `OnboardingStore.openAndScan` uses
/// against the *already open* root, through `OperationHost.run` so it is
/// observable, cancellable, and reports progress -- without disturbing the
/// onboarding state a fresh library pick owns (unlike `openAndScan`, a
/// cancelled or failed rescan must leave the last known-good snapshot and
/// `selectedRoot` alone).
@MainActor
@Suite("Library rescan")
struct LibraryRescanTests {
    @Test("Rescanning an open library reruns the scan pipeline through OperationHost and refreshes the snapshot")
    func rescanRefreshesSnapshotThroughOperationHost() async throws {
        let fixture = try RescanFixture.make()
        defer { fixture.remove() }
        let firstSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 3
        )
        let secondSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 2,
            projectCount: 2,
            nightCount: 2,
            frameCount: 9
        )
        let factory = SequencedRescanSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly, scan: { firstSnapshot }),
            OnboardingSessionClient(accessMode: .readOnly, scan: { secondSnapshot }),
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)
        #expect(store.phase.summary == firstSnapshot)
        let host = OperationHost(center: OperationCenter())

        await store.rescan(operationHost: host)
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(store.phase.summary == secondSnapshot)
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)
        #expect(host.toasts.contains { $0.level == .success })
        #expect(host.recentOutcomes.contains { $0.kind == .scan(library: fixture.root.lastPathComponent) })
    }

    @Test("A rescan reports progress through OperationHost while it runs")
    func rescanReportsProgress() async throws {
        let fixture = try RescanFixture.make()
        defer { fixture.remove() }
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 1
        )
        let gate = RescanGate()
        let factory = SequencedRescanSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot }),
            OnboardingSessionClient(accessMode: .readOnly) { progress in
                progress(LibraryScanProgress(scanned: 5, total: 10))
                await gate.wait()
                return snapshot
            },
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)
        let host = OperationHost(center: OperationCenter())

        await store.rescan(operationHost: host)

        try await waitUntilCondition {
            host.activeOperations.first?.completed == 5 && host.activeOperations.first?.total == 10
        }

        await gate.open()
        try await waitUntil { host.activeOperations.isEmpty }
    }

    @Test("Cancelling a rescan leaves the last known-good snapshot and selected root untouched")
    func cancellingRescanPreservesPriorState() async throws {
        let fixture = try RescanFixture.make()
        defer { fixture.remove() }
        let firstSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 1
        )
        let factory = SequencedRescanSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly, scan: { firstSnapshot }),
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                // `Task.sleep` is cancellation-aware (throws `CancellationError`
                // the moment the running task is cancelled), unlike a plain
                // continuation-based gate -- which is exactly why this test
                // uses it rather than `RescanGate` below (that one is only
                // ever opened explicitly, and would hang forever waiting for
                // an `open()` call that a cancelled task's cleanup can't make
                // `OperationHost.cancel(id:)` wait past).
                try await Task.sleep(for: .seconds(30))
                return LibrarySnapshot(
                    libraryID: LibraryIdentity(rootURL: fixture.root),
                    revision: 99,
                    projectCount: 99,
                    nightCount: 99,
                    frameCount: 99
                )
            },
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)
        let host = OperationHost(center: OperationCenter())

        await store.rescan(operationHost: host)
        try await waitUntilCondition { host.activeOperations.count == 1 }
        let id = try #require(host.activeOperations.first?.id)

        let didCancel = await host.cancel(id: id)

        #expect(didCancel)
        #expect(store.phase.summary == firstSnapshot)
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)
        #expect(!host.toasts.contains { $0.level == .failure })
    }

    @Test("A rescan already in flight cannot be started a second time")
    func overlappingRescanIsRejected() async throws {
        let fixture = try RescanFixture.make()
        defer { fixture.remove() }
        let firstSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 1
        )
        let gate = RescanGate()
        let factory = SequencedRescanSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly, scan: { firstSnapshot }),
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                await gate.wait()
                return firstSnapshot
            },
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)
        let host = OperationHost(center: OperationCenter())

        await store.rescan(operationHost: host)
        try await waitUntilCondition { host.activeOperations.count == 1 }

        await store.rescan(operationHost: host)

        #expect(host.activeOperations.count == 1)
        #expect(host.toasts.contains { $0.level == .info && $0.message.contains("already running") })

        await gate.open()
        try await waitUntil { host.activeOperations.isEmpty }
    }

    @Test("Rescanning with no library open is a no-op that notifies instead of crashing")
    func rescanWithNoLibraryOpenNoOps() async throws {
        let store = OnboardingStore(
            sessionFactory: .failing(RescanTestFailure.shouldNotBeCalled),
            storageFactory: .failing(),
            securityScopedAccess: .inactive
        )
        let host = OperationHost(center: OperationCenter())

        await store.rescan(operationHost: host)

        #expect(host.activeOperations.isEmpty)
        #expect(host.recentOutcomes.isEmpty)
        #expect(host.toasts.contains { $0.level == .info || $0.level == .failure })
        #expect(store.phase == .chooseLibrary)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        try await waitUntilCondition(timeout: timeout, condition)
    }

    private func waitUntilCondition(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum RescanTestFailure: Error, Equatable {
    case shouldNotBeCalled
}

private actor RescanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class SequencedRescanSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [OnboardingSessionClient]

    init(_ sessions: [OnboardingSessionClient]) {
        self.sessions = sessions
    }

    var client: OnboardingSessionFactory {
        OnboardingSessionFactory { [self] _, _ in
            try lock.withLock {
                guard !sessions.isEmpty else { throw RescanTestFailure.shouldNotBeCalled }
                return sessions.removeFirst()
            }
        }
    }
}

private extension OnboardingSessionFactory {
    static func failing(_ error: any Error & Sendable) -> Self {
        OnboardingSessionFactory { _, _ in throw error }
    }
}

private extension OnboardingStorageFactory {
    static func failing() -> Self {
        OnboardingStorageFactory { _ in throw RescanTestFailure.shouldNotBeCalled }
    }
}

private struct RescanFixture {
    let container: URL
    let root: URL
    let storageFactory: OnboardingStorageFactory

    static func make(fileManager: FileManager = .default) throws -> Self {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("AstroToolRescanFixture-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let applicationSupport = container.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = container.appendingPathComponent("Caches", isDirectory: true)
        let frame = root.appendingPathComponent("Target/Night/light.fit")
        try fileManager.createDirectory(at: frame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("temporary fixture".utf8).write(to: frame)
        return Self(
            container: container,
            root: root,
            storageFactory: OnboardingStorageFactory { root in
                try AppStoragePaths(
                    applicationSupport: applicationSupport,
                    caches: caches,
                    libraryID: LibraryIdentity(rootURL: root),
                    libraryRoot: root
                )
            }
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: container)
    }
}
