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
        #expect(store.selectedRoot == fixture.root.standardizedFileURL)

        store.returnToLibraryChoice()

        #expect(store.phase == .chooseLibrary)
        #expect(store.selectedRoot == nil)
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
        #expect(onboardingSource.contains("dropDestination"))
        #expect(onboardingSource.contains("keyboardShortcut(.cancelAction)"))
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
}

private enum TestFailure: Error, Equatable {
    case denied
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
