@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// Task 2 (V2 UI/UX audit section 2.2): `restoreSavedLibrary()` ->
/// `openAndScan()` used to run completely unrouted at launch -- no
/// `OperationHost` registration, so the toolbar's status control never
/// showed progress or offered Cancel, and a failure only ever set
/// `phase = .accessProblem` for a view (`LibraryWelcomeView`) that production
/// never presents. These tests cover `openAndScan(_:through:)` and
/// `restoreSavedLibrary(through:)`, the operationHost-routed counterparts
/// `V2RootView` now calls instead.
@MainActor
@Suite("Library launch scan through OperationHost")
struct LibraryLaunchScanTests {
    @Test("openAndScan(_:through:) registers a scan operation and reports success through OperationHost")
    func openAndScanThroughOperationHostSucceeds() async throws {
        let fixture = try LaunchScanFixture.make()
        defer { fixture.remove() }
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1, projectCount: 1, nightCount: 1, frameCount: 1
        )
        let store = OnboardingStore(
            sessionFactory: .constant(OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot })),
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        let host = OperationHost(center: OperationCenter())

        await store.openAndScan(fixture.root, through: host)

        try await waitUntil { host.activeOperations.isEmpty }
        #expect(store.phase.summary == snapshot)
        #expect(host.toasts.contains { $0.level == .success })
        #expect(host.recentOutcomes.contains { $0.kind == .scan(library: fixture.root.lastPathComponent) })
    }

    @Test("openAndScan(_:through:) surfaces a failed scan as an access problem and a failure toast")
    func openAndScanThroughOperationHostFails() async throws {
        struct ScanFailure: Error, LocalizedError {
            var errorDescription: String? { "volume not mounted" }
        }
        let fixture = try LaunchScanFixture.make()
        defer { fixture.remove() }
        let store = OnboardingStore(
            sessionFactory: .constant(OnboardingSessionClient(accessMode: .readOnly, scan: { throw ScanFailure() })),
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive
        )
        let host = OperationHost(center: OperationCenter())

        await store.openAndScan(fixture.root, through: host)

        try await waitUntil { host.activeOperations.isEmpty }
        #expect(store.phase.accessProblemMessage != nil)
        #expect(host.toasts.contains { $0.level == .failure })
    }

    @Test("restoreSavedLibrary(through:) with a saved bookmark scans it through OperationHost")
    func restoreSavedLibraryThroughOperationHostScansTheBookmarkedRoot() async throws {
        let fixture = try LaunchScanFixture.make()
        defer { fixture.remove() }
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1, projectCount: 2, nightCount: 2, frameCount: 4
        )
        let bookmark = FakeBookmarkStore(saved: fixture.root)
        let store = OnboardingStore(
            sessionFactory: .constant(OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot })),
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive,
            bookmarkStore: bookmark.client
        )
        let host = OperationHost(center: OperationCenter())

        let didStart = await store.restoreSavedLibrary(through: host)

        #expect(didStart)
        try await waitUntil { host.activeOperations.isEmpty }
        #expect(store.phase.summary == snapshot)
        #expect(host.recentOutcomes.contains { $0.kind == .scan(library: fixture.root.lastPathComponent) })
    }

    @Test("restoreSavedLibrary(through:) with no saved bookmark is a no-op that registers nothing")
    func restoreSavedLibraryThroughOperationHostNoBookmarkNoOps() async throws {
        let bookmark = FakeBookmarkStore(saved: nil)
        let store = OnboardingStore(
            sessionFactory: .failing(),
            storageFactory: .failing(),
            securityScopedAccess: .inactive,
            bookmarkStore: bookmark.client
        )
        let host = OperationHost(center: OperationCenter())

        let didStart = await store.restoreSavedLibrary(through: host)

        #expect(!didStart)
        #expect(host.activeOperations.isEmpty)
        #expect(host.recentOutcomes.isEmpty)
        #expect(store.phase == .chooseLibrary)
    }

    @Test("restoreSavedLibrary(through:) clears the bookmark once the restore fails, like the raw restoreSavedLibrary() already does")
    func restoreSavedLibraryThroughOperationHostClearsBookmarkOnFailure() async throws {
        struct ScanFailure: Error {}
        let fixture = try LaunchScanFixture.make()
        defer { fixture.remove() }
        let bookmark = FakeBookmarkStore(saved: fixture.root)
        let store = OnboardingStore(
            sessionFactory: .constant(OnboardingSessionClient(accessMode: .readOnly, scan: { throw ScanFailure() })),
            storageFactory: fixture.storageFactory,
            securityScopedAccess: .inactive,
            bookmarkStore: bookmark.client
        )
        let host = OperationHost(center: OperationCenter())

        _ = await store.restoreSavedLibrary(through: host)
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(bookmark.load() == nil)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
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

private final class FakeBookmarkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: URL?

    init(saved: URL?) {
        self.saved = saved
    }

    func load() -> URL? {
        lock.withLock { saved }
    }

    var client: LibraryBookmarkStore {
        LibraryBookmarkStore(
            load: { [self] in lock.withLock { saved } },
            save: { [self] url in lock.withLock { saved = url } },
            clear: { [self] in lock.withLock { saved = nil } }
        )
    }
}

private extension OnboardingSessionFactory {
    static func constant(_ session: OnboardingSessionClient) -> Self {
        OnboardingSessionFactory { _, _ in session }
    }

    static func failing() -> Self {
        OnboardingSessionFactory { _, _ in throw LaunchScanTestFailure.shouldNotBeCalled }
    }
}

private extension OnboardingStorageFactory {
    static func failing() -> Self {
        OnboardingStorageFactory { _ in throw LaunchScanTestFailure.shouldNotBeCalled }
    }
}

private enum LaunchScanTestFailure: Error, Equatable {
    case shouldNotBeCalled
}

private struct LaunchScanFixture {
    let container: URL
    let root: URL
    let storageFactory: OnboardingStorageFactory

    static func make(fileManager: FileManager = .default) throws -> Self {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("AstroToolLaunchScanFixture-\(UUID().uuidString)", isDirectory: true)
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
