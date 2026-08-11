@testable import AstroApplication
import AstroCore
import Dispatch
import Foundation
import Testing

@Suite("Read-only V2 library sessions")
struct LibrarySessionTests {
    @Test("Library access modes are stable Codable values")
    func accessModeCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(LibraryAccessMode.mutationEnabled)

        #expect(try JSONDecoder().decode(LibraryAccessMode.self, from: encoded) == .mutationEnabled)
    }

    @Test("Opening and scanning preserves the complete image root and uses an external index")
    func openingAndScanningIsReadOnlyAndExternal() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let storage = try makeStorage(for: fixture)
        let before = try await LibraryManifest.capture(root: fixture.root)
        let legacyBefore = try Data(contentsOf: fixture.root.appendingPathComponent(".astro_tool/state.json"))

        let session = try await LibrarySession.open(rootURL: fixture.root, storage: storage)
        #expect(await session.accessMode == .readOnly)
        #expect(session.identity == LibraryIdentity(rootURL: fixture.root))
        let snapshot = try await session.scan()

        #expect(snapshot == LibrarySnapshot(
            libraryID: LibraryIdentity(rootURL: fixture.root),
            revision: 1,
            projectCount: 0,
            nightCount: 0,
            frameCount: 4
        ))
        #expect(FileManager.default.fileExists(atPath: storage.indexDatabase.path))
        #expect(!storage.indexDatabase.path.hasPrefix(fixture.root.path + "/"))
        #expect(!FileManager.default.fileExists(
            atPath: storage.metadataDatabase.deletingLastPathComponent().path
        ))
        #expect(!FileManager.default.fileExists(atPath: storage.thumbnails.path))
        #expect(!FileManager.default.fileExists(atPath: storage.migration.path))
        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".astro_tool/state.json")) == legacyBefore)
    }

    @Test("Successful scans advance revisions in actor order")
    func scansAdvanceRevision() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let session = try await LibrarySession.open(
            rootURL: fixture.root,
            storage: makeStorage(for: fixture)
        )

        let first = try await session.scan()
        let second = try await session.scan()

        #expect(first.revision == 1)
        #expect(second.revision == 2)
    }

    @Test("Session scan forwards normalized scanned and total progress")
    func scanProgressIsNormalized() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let session = try await LibrarySession.open(
            rootURL: fixture.root,
            storage: makeStorage(for: fixture)
        )
        let progress = ProgressRecorder()

        _ = try await session.scan(progress: progress.record)

        let updates = progress.values
        let first = try #require(updates.first)
        let last = try #require(updates.last)
        #expect(first.scanned == 0)
        #expect(first.total == nil)
        #expect(last.scanned == last.total!)
        #expect(last.fraction == 1)
        #expect(updates.compactMap(\.fraction).allSatisfy { (0...1).contains($0) })
    }

    @Test("Cancelling a session scan stops the synchronous scanner cooperatively")
    func sessionScanCancellationIsForwarded() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        for index in 0..<256 {
            let file = fixture.root.appendingPathComponent("Cancellation/f\(index).fit")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: file)
        }
        let session = try await LibrarySession.open(
            rootURL: fixture.root,
            storage: makeStorage(for: fixture)
        )
        let blocker = SessionProgressBlocker()
        let task = Task {
            try await session.scan(progress: blocker.recordAndBlock)
        }

        await blocker.waitUntilBlocked()
        task.cancel()
        blocker.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!blocker.values.contains { $0.total != nil })
    }

    @Test("A failed scan does not consume a revision")
    func failedScanDoesNotAdvanceRevision() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let session = try await LibrarySession.open(
            rootURL: fixture.root,
            storage: makeStorage(for: fixture)
        )
        #expect(try await session.scan().revision == 1)
        let displacedRoot = fixture.container.appendingPathComponent("DisplacedLibrary", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: displacedRoot)

        await #expect(throws: AstroError.self) {
            try await session.scan()
        }
        try FileManager.default.moveItem(at: displacedRoot, to: fixture.root)

        #expect(try await session.scan().revision == 2)
    }

    @Test("Storage identity must match the opened library")
    func rejectsMismatchedStorageIdentity() async throws {
        let first = try V2FixtureLibrary.make()
        let second = try V2FixtureLibrary.make()
        defer { first.remove() }
        defer { second.remove() }
        let storage = try makeStorage(for: first)

        await #expect(throws: LibrarySessionError.libraryIdentityMismatch) {
            try await LibrarySession.open(rootURL: second.root, storage: storage)
        }
    }

    @Test("Opening rejects missing, file, and symbolic-link roots")
    func rejectsNonCanonicalDirectoryRoots() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let missing = fixture.container.appendingPathComponent("Missing", isDirectory: true)
        let linked = fixture.container.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.root)

        for root in [missing, fixture.externalFile, linked] {
            let identity = LibraryIdentity(rootURL: root)
            let support = fixture.container.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
            let caches = fixture.container.appendingPathComponent("caches-\(UUID().uuidString)", isDirectory: true)
            let storage = try AppStoragePaths(
                applicationSupport: support,
                caches: caches,
                libraryID: identity,
                libraryRoot: root
            )
            await #expect(throws: LibrarySessionError.invalidRoot) {
                try await LibrarySession.open(rootURL: root, storage: storage)
            }
        }
    }

    @Test("Opening rejects a symbolic-link index database")
    func rejectsSymlinkIndexDatabase() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let storage = try makeStorage(for: fixture)
        try FileManager.default.createDirectory(
            at: storage.indexDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let externalDatabase = fixture.container.appendingPathComponent("outside.sqlite")
        try Data().write(to: externalDatabase)
        try FileManager.default.createSymbolicLink(
            at: storage.indexDatabase,
            withDestinationURL: externalDatabase
        )

        await #expect(throws: LibrarySessionError.indexDatabaseIsSymbolicLink) {
            try await LibrarySession.open(rootURL: fixture.root, storage: storage)
        }
    }

    @Test("An index ancestor swapped to the library before SQLite open cannot write there")
    func ancestorSwapBeforeSQLiteOpenFailsWithoutLibraryWrites() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let storage = try makeStorage(for: fixture)
        let redirectedParent = fixture.root
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(storage.libraryID.id, isDirectory: true)
        try FileManager.default.createDirectory(at: redirectedParent, withIntermediateDirectories: true)
        let before = try await LibraryManifest.capture(root: fixture.root)
        let astroToolDirectory = storage.indexDatabase
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let displacedDirectory = fixture.container
            .appendingPathComponent("DisplacedAstroTool", isDirectory: true)

        await #expect(throws: (any Error).self) {
            try await LibrarySession.open(
                rootURL: fixture.root,
                storage: storage,
                beforeDatabaseOpen: {
                    try FileManager.default.moveItem(
                        at: astroToolDirectory,
                        to: displacedDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: astroToolDirectory,
                        withDestinationURL: fixture.root
                    )
                }
            )
        }

        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
        #expect(!FileManager.default.fileExists(
            atPath: redirectedParent.appendingPathComponent("index.sqlite").path
        ))
    }

    @Test("An index ancestor swapped before parent creation cannot redirect creation into the library")
    func ancestorSwapBeforeParentOpenFailsWithoutLibraryWrites() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let storage = try makeStorage(for: fixture)
        let cachesRoot = storage.indexDatabase
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let before = try await LibraryManifest.capture(root: fixture.root)

        await #expect(throws: (any Error).self) {
            try await LibrarySession.open(
                rootURL: fixture.root,
                storage: storage,
                beforeIndexParentOpen: {
                    try FileManager.default.createSymbolicLink(
                        at: cachesRoot,
                        withDestinationURL: fixture.root
                    )
                },
                beforeDatabaseOpen: {}
            )
        }

        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("AstroTool").path
        ))
    }

    @Test("The index file swapped to a library symlink before SQLite open cannot be followed")
    func finalSymlinkSwapBeforeSQLiteOpenFailsWithoutLibraryWrites() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let storage = try makeStorage(for: fixture)
        let libraryTarget = fixture.root.appendingPathComponent("sqlite-race-target.sqlite")
        try Data("must remain unchanged".utf8).write(to: libraryTarget)
        let before = try await LibraryManifest.capture(root: fixture.root)

        await #expect(throws: (any Error).self) {
            try await LibrarySession.open(
                rootURL: fixture.root,
                storage: storage,
                beforeDatabaseOpen: {
                    try FileManager.default.removeItem(at: storage.indexDatabase)
                    try FileManager.default.createSymbolicLink(
                        at: storage.indexDatabase,
                        withDestinationURL: libraryTarget
                    )
                }
            )
        }

        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
        #expect(try Data(contentsOf: libraryTarget) == Data("must remain unchanged".utf8))
    }

    private func makeStorage(for fixture: V2FixtureLibrary) throws -> AppStoragePaths {
        let support = fixture.container.appendingPathComponent("application-support", isDirectory: true)
        let caches = fixture.container.appendingPathComponent("caches", isDirectory: true)
        return try AppStoragePaths(
            applicationSupport: support,
            caches: caches,
            libraryID: LibraryIdentity(rootURL: fixture.root),
            libraryRoot: fixture.root
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LibraryScanProgress] = []

    var values: [LibraryScanProgress] {
        lock.withLock { stored }
    }

    func record(_ progress: LibraryScanProgress) {
        lock.withLock { stored.append(progress) }
    }
}

private final class SessionProgressBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var didBlock = false
    private var stored: [LibraryScanProgress] = []
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    var values: [LibraryScanProgress] {
        lock.withLock { stored }
    }

    func recordAndBlock(_ progress: LibraryScanProgress) {
        let result = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            stored.append(progress)
            guard !didBlock, progress.scanned >= 64, progress.total == nil else {
                return (false, nil)
            }
            didBlock = true
            defer { waitingContinuation = nil }
            return (true, waitingContinuation)
        }
        result.1?.resume()
        guard result.0 else { return }
        released.wait()
    }

    func waitUntilBlocked() async {
        if lock.withLock({ didBlock }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if didBlock { return true }
                waitingContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        released.signal()
    }
}
