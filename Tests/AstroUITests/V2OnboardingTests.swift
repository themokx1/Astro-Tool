@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("Read-only V2 onboarding")
struct V2OnboardingTests {
    @Test("Onboarding starts neutral and scans a temporary library read-only")
    func startsWithoutPersonalDefaultsAndNeverRequestsMutation() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let manifestBefore = try await LibraryManifest.capture(root: fixture.root)
        let scopedAccess = ScopedAccessProbe()
        let pickerURL = fixture.root
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        let store = OnboardingStore(
            sessionFactory: .production,
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: scopedAccess.client
        )

        #expect(store.phase == .chooseLibrary)
        #expect(store.selectedRoot == nil)
        #expect(store.accessMode == .readOnly)
        #expect(store.personalizationIsOptional)

        try await store.openAndScan(pickerURL)

        let snapshot = try #require(store.phase.summary)
        #expect(snapshot.frameCount == 1)
        #expect(store.accessMode == .readOnly)
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)
        let indexURL = try #require(store.indexDatabaseURL)
        #expect(!indexURL.path.hasPrefix(fixture.root.path + "/"))
        #expect(indexURL.path.hasPrefix(fixture.caches.path + "/"))
        #expect(try await LibraryManifest.capture(root: fixture.root) == manifestBefore)
        #expect(scopedAccess.startedURLs == [pickerURL])
        #expect(scopedAccess.stoppedURLs.isEmpty)

        store.returnToLibraryChoice()
        #expect(scopedAccess.stoppedURLs == [pickerURL])
    }

    @Test("Scanning is observable, cancellable, and returns to an unselected choice")
    func cancellationIsSafe() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let session = OnboardingSessionClient(
            accessMode: .readOnly,
            scan: {
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
        )
        let store = OnboardingStore(
            sessionFactory: .constant(session),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )
        let task = Task { try await store.openAndScan(fixture.root) }

        await Task.yield()
        #expect(store.phase.isScanning)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(store.phase == .chooseLibrary)
        #expect(store.selectedRoot == nil)
        #expect(store.indexDatabaseURL == nil)
    }

    @Test("Access failures are actionable and retry starts from a clean choice")
    func accessFailureAndBack() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let store = OnboardingStore(
            sessionFactory: .failing(TestFailure.denied),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )

        await #expect(throws: TestFailure.denied) {
            try await store.openAndScan(fixture.root)
        }
        #expect(store.phase.accessProblemMessage != nil)
        // Task 5b (2026-08-17): `accessProblem` is the raw-case counterpart
        // `V2RootView`'s `LibraryAccessProblemBanner` now reads instead of
        // the plain-string `accessProblemMessage` above, so it can render a
        // translatable `Text` via `LibraryWelcomeView.accessProblemText(for:)`.
        #expect(store.phase.accessProblem != nil)
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)

        store.returnToLibraryChoice()

        #expect(store.phase == .chooseLibrary)
        #expect(store.selectedRoot == nil)
        #expect(store.indexDatabaseURL == nil)
    }

    @Test("Progress is observable, clamped, and never moves backward")
    func progressIsMonotonic() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let thirdGate = AsyncGate()
        let finalGate = AsyncGate()
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 0,
            nightCount: 0,
            frameCount: 1
        )
        let store = OnboardingStore(
            sessionFactory: .constant(
                OnboardingSessionClient(accessMode: .readOnly) { progress in
                    progress(LibraryScanProgress(scanned: -4, total: 100))
                    await firstGate.wait()
                    progress(LibraryScanProgress(scanned: 60, total: 100))
                    await secondGate.wait()
                    progress(LibraryScanProgress(scanned: 20, total: 100))
                    await thirdGate.wait()
                    progress(LibraryScanProgress(scanned: 140, total: 100))
                    await finalGate.wait()
                    return snapshot
                }
            ),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )
        let task = Task { try await store.openAndScan(fixture.root) }

        try await expectProgress(0, in: store)
        await firstGate.open()
        try await expectProgress(0.6, in: store)
        await secondGate.open()
        try await Task.sleep(for: .milliseconds(10))
        #expect(store.phase.progress == 0.6)
        await thirdGate.open()
        try await expectProgress(1, in: store)
        await finalGate.open()
        try await task.value

        #expect(store.phase.summary == snapshot)
    }

    @Test("A superseded scan cannot overwrite the newer scan")
    func staleCompletionCannotClobberNewerScan() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let oldRoot = fixture.root
        let newRoot = fixture.container.appendingPathComponent("NewLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let oldGate = AsyncGate()
        let newGate = AsyncGate()
        let oldSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: oldRoot),
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 1
        )
        let newSnapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: newRoot),
            revision: 1,
            projectCount: 2,
            nightCount: 2,
            frameCount: 2
        )
        let factory = SequencedSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                await oldGate.wait()
                return oldSnapshot
            },
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                await newGate.wait()
                return newSnapshot
            },
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )

        let oldTask = Task { try await store.openAndScan(oldRoot) }
        await oldGate.waitUntilWaiting()
        let newTask = Task { try await store.openAndScan(newRoot) }
        await newGate.waitUntilWaiting()
        await newGate.open()
        try await newTask.value
        #expect(store.phase.summary == newSnapshot)
        #expect(store.selectedRoot == newRoot.standardizedFileURL)

        await oldGate.open()
        try await oldTask.value
        #expect(store.phase.summary == newSnapshot)
        #expect(store.selectedRoot == newRoot.standardizedFileURL)
    }

    @Test("A late cancellation from an old scan cannot reset the replacement")
    func staleCancellationCannotResetNewerScan() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let newRoot = fixture.container.appendingPathComponent("Replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let oldGate = AsyncGate()
        let replacementGate = AsyncGate()
        let replacement = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: newRoot),
            revision: 1,
            projectCount: 0,
            nightCount: 0,
            frameCount: 2
        )
        let factory = SequencedSessionFactory([
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                await oldGate.wait()
                throw CancellationError()
            },
            OnboardingSessionClient(accessMode: .readOnly) { _ in
                await replacementGate.wait()
                return replacement
            },
        ])
        let store = OnboardingStore(
            sessionFactory: factory.client,
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )

        let oldTask = Task { try await store.openAndScan(fixture.root) }
        await oldGate.waitUntilWaiting()
        let replacementTask = Task { try await store.openAndScan(newRoot) }
        await replacementGate.waitUntilWaiting()
        await replacementGate.open()
        try await replacementTask.value

        await oldGate.open()
        await #expect(throws: CancellationError.self) { try await oldTask.value }
        #expect(store.phase.summary == replacement)
        #expect(store.selectedRoot == newRoot.standardizedFileURL)
    }

    @Test("A dropped file is rejected with an actionable folder choice")
    func droppedFileIsRejected() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("not-a-folder.fit")
        try Data("file".utf8).write(to: file)
        let store = OnboardingStore(
            sessionFactory: .failing(TestFailure.denied),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )

        await #expect(throws: OnboardingStoreError.notDirectory) {
            try await store.openAndScan(file)
        }

        #expect(store.phase.accessProblemMessage?.contains("Choose a folder") == true)
        #expect(store.selectedRoot == file.standardizedFileURL)
        #expect(store.indexDatabaseURL == nil)
    }

    @Test("Summary continuation and preference setup remain separate optional choices")
    func summaryChoicesAreExplicit() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 2,
            nightCount: 3,
            frameCount: 5
        )
        let store = OnboardingStore(
            sessionFactory: .constant(
                OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot })
            ),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)

        store.continueWithoutPersonalizing()
        #expect(store.completionChoice == .library)

        store.setUpPreferences()
        #expect(store.completionChoice == .preferences)
        #expect(store.phase.summary == snapshot)
    }

    @Test("Dismissing completed onboarding preserves the scanned library")
    func completedScanIsNotCancelledOnDismissal() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 13,
            nightCount: 20,
            frameCount: 8_221
        )
        let store = OnboardingStore(
            sessionFactory: .constant(
                OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot })
            ),
            storageFactory: .temporary(
                applicationSupport: fixture.applicationSupport,
                caches: fixture.caches
            ),
            securityScopedAccess: .inactive
        )
        try await store.openAndScan(fixture.root)

        store.continueWithoutPersonalizing()
        store.cancelActiveScan()

        #expect(store.completionChoice == .library)
        #expect(store.phase.summary == snapshot)
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)
        #expect(store.indexDatabaseURL != nil)
    }

    @Test("A chosen library is restored from its bookmark on the next launch")
    func savedLibraryRestoresAcrossStoreInstances() async throws {
        let fixture = try OnboardingFixture.make()
        defer { fixture.remove() }
        let bookmarks = InMemoryLibraryBookmarks()
        let snapshot = LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 4,
            projectCount: 13,
            nightCount: 20,
            frameCount: 8_221
        )
        let makeStore = {
            OnboardingStore(
                sessionFactory: .constant(
                    OnboardingSessionClient(accessMode: .readOnly, scan: { snapshot })
                ),
                storageFactory: .temporary(
                    applicationSupport: fixture.applicationSupport,
                    caches: fixture.caches
                ),
                securityScopedAccess: .inactive,
                bookmarkStore: bookmarks.client
            )
        }

        let firstLaunch = makeStore()
        try await firstLaunch.openAndScan(fixture.root)
        #expect(bookmarks.savedURL == fixture.root.standardizedFileURL)

        let nextLaunch = makeStore()
        #expect(try await nextLaunch.restoreSavedLibrary())
        #expect(nextLaunch.phase.summary == snapshot)
        #expect(nextLaunch.selectedRoot == fixture.root.standardizedFileURL)
    }

    @Test("Onboarding surfaces use honest actions and contain no personal defaults")
    func sourceSafetyAndActions() throws {
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let onboardingRoot = sourceRoot.appendingPathComponent("Onboarding")
        let files = [
            onboardingRoot.appendingPathComponent("LibraryWelcomeView.swift"),
            onboardingRoot.appendingPathComponent("FirstScanView.swift"),
            onboardingRoot.appendingPathComponent("FirstScanSummaryView.swift"),
        ]
        let onboardingSource = try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let home = try String(
            contentsOf: sourceRoot.appendingPathComponent("Features/Home/HomeView.swift"),
            encoding: .utf8
        )
        let root = try String(
            contentsOf: sourceRoot.appendingPathComponent("App/V2RootView.swift"),
            encoding: .utf8
        )

        #expect(onboardingSource.contains("Choose Image Library…"))
        #expect(onboardingSource.contains("Files stay where they are"))
        #expect(onboardingSource.contains("Application Support"))
        #expect(onboardingSource.contains("rootBookmark"))
        #expect(onboardingSource.contains("dropDestination"))
        #expect(onboardingSource.contains("keyboardShortcut(.cancelAction)"))
        #expect(onboardingSource.contains("ProgressView(value:"))
        #expect(home.contains("Choose Image Library…"))
        #expect(root.contains("LibraryWelcomeView"))
        #expect(root.contains("openSettings"))

        for forbidden in ["/Users/", "Zoltan", "zoltan", "Canon", "Nikon", "Budapest"] {
            #expect(!onboardingSource.contains(forbidden))
        }
        #expect(!onboardingSource.contains("mutationEnabled"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func expectProgress(
        _ expected: Double,
        in store: OnboardingStore
    ) async throws {
        for _ in 0..<500 {
            if store.phase.progress == expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected onboarding progress \(expected), got \(String(describing: store.phase.progress))")
    }
}

private enum TestFailure: Error, Equatable {
    case denied
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var isWaiting = false

    func wait() async {
        isWaiting = true
        waitingContinuation?.resume()
        waitingContinuation = nil
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class SequencedSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [OnboardingSessionClient]

    init(_ sessions: [OnboardingSessionClient]) {
        self.sessions = sessions
    }

    var client: OnboardingSessionFactory {
        OnboardingSessionFactory { [self] _, _ in
            try lock.withLock {
                guard !sessions.isEmpty else { throw TestFailure.denied }
                return sessions.removeFirst()
            }
        }
    }
}

private final class ScopedAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var client: SecurityScopedAccess {
        SecurityScopedAccess(
            start: { [weak self] url in
                self?.recordStart(url)
                return true
            },
            stop: { [weak self] url in
                self?.recordStop(url)
            }
        )
    }

    var startedURLs: [URL] {
        lock.withLock { started }
    }

    var stoppedURLs: [URL] {
        lock.withLock { stopped }
    }

    private func recordStart(_ url: URL) {
        lock.withLock { started.append(url) }
    }

    private func recordStop(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}

private final class InMemoryLibraryBookmarks: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?

    var client: LibraryBookmarkStore {
        LibraryBookmarkStore(
            load: { [weak self] in self?.lock.withLock { self?.storedURL } ?? nil },
            save: { [weak self] url in self?.lock.withLock { self?.storedURL = url } },
            clear: { [weak self] in self?.lock.withLock { self?.storedURL = nil } }
        )
    }

    var savedURL: URL? {
        lock.withLock { storedURL }
    }
}

private struct OnboardingFixture {
    let container: URL
    let root: URL
    let applicationSupport: URL
    let caches: URL

    static func make(fileManager: FileManager = .default) throws -> Self {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("AstroToolOnboarding-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let applicationSupport = container.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = container.appendingPathComponent("Caches", isDirectory: true)
        let frame = root.appendingPathComponent("Target/Night/light.fit")
        try fileManager.createDirectory(at: frame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("temporary fixture".utf8).write(to: frame)
        return Self(
            container: container,
            root: root,
            applicationSupport: applicationSupport,
            caches: caches
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: container)
    }
}

private extension OnboardingStorageFactory {
    static func temporary(applicationSupport: URL, caches: URL) -> Self {
        OnboardingStorageFactory { root in
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: LibraryIdentity(rootURL: root),
                libraryRoot: root
            )
        }
    }
}

private extension OnboardingSessionFactory {
    static func constant(_ session: OnboardingSessionClient) -> Self {
        OnboardingSessionFactory { _, _ in session }
    }

    static func failing(_ error: any Error & Sendable) -> Self {
        OnboardingSessionFactory { _, _ in throw error }
    }
}
