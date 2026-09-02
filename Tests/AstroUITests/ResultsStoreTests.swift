@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: `ResultsStore` used to
/// be a `private final class` embedded in `ResultsView.swift` that resolved
/// `ProjectsStore.productionMetadata` directly inside `load` -- there was no
/// way to load it against anything but a real on-disk library, so this
/// whole screen had zero unit-test surface. This is that surface.
///
/// Task 7 (2026-08-17 owner-feedback wave 3) rewrote what it loads. The old
/// tests here were the exact fixture trap this project has hit before: they
/// called `metadata.save(ResultRecord(...))` and went green, while
/// production never writes a `ResultRecord` anywhere -- so the tests proved
/// the store could display rows the product could not create. Every fixture
/// below goes through `files`, the table the scanner genuinely populates,
/// and through `StackDiscovery`, the engine that reads it.
@MainActor
@Suite("V2 Results store")
struct ResultsStoreTests {
    /// `IC 1396` is a real catalog designation, so `ProjectsQuery.
    /// canonicalFolderName` resolves it to the library folder the scanner
    /// also files this target's stacks under -- the whole point of keying
    /// discovery on that name rather than on the project's display name.
    private static let catalogID = "IC 1396"

    private func project() -> ProjectRecord {
        ProjectRecord(id: UUID(), catalogID: Self.catalogID, displayName: "Elefántormány-köd", phase: .processing)
    }

    private func libraryFolder(for project: ProjectRecord) -> String {
        ProjectsQuery.canonicalFolderName(for: project)
    }

    @discardableResult
    private func insertFile(
        db: Database, path: String, size: Int64 = 50_000_000, area: LibraryArea,
        target: String, sessionDate: String?
    ) throws -> Int64 {
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: size, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: area, target: target, sessionDate: sessionDate, role: .stack,
            scannedAt: 1_700_000_100
        ))
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        return fileID
    }

    /// One stack family with two variants, filed under `folder`.
    private func discoveryFixture(folder: String) throws -> Database {
        let db = try Database(path: ":memory:")
        let stem = "Mu_Cephei_068x300sec_19860s_drizzle-2-0x_2026-08-15_1735"
        try insertFile(db: db, path: "stacks/\(folder)/2026-08-15/\(stem)_og.fit", area: .stacks, target: folder, sessionDate: "2026-08-15")
        try insertFile(db: db, path: "stacks/\(folder)/2026-08-15/starless_\(stem)_og.fit", size: 60_000_000, area: .stacks, target: folder, sessionDate: "2026-08-15")
        try insertFile(db: db, path: "processed/\(folder)/2026-08-15/\(stem)_og_work_graxpert.fit", size: 90_000_000, area: .processed, target: folder, sessionDate: "2026-08-15")
        return db
    }

    private func queryFactory(_ db: Database) -> ResultsStore.ResultsQueryFactory {
        { _ in
            ResultsQuery(stackGroups: { target in
                try StackDiscovery.groupedStacks(target: target, db: db, config: AstroConfig())
            })
        }
    }

    @Test("Loading a project shows the stacks the library actually contains, not a lineage table nothing writes")
    func loadingPopulatesDiscoveredStacks() async throws {
        let metadata = try MetadataStore.temporary()
        let project = project()
        let folder = libraryFolder(for: project)
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let store = ResultsStore(
            metadataFactory: { _ in metadata },
            resultsQueryFactory: queryFactory(try discoveryFixture(folder: folder))
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id, sharedMetadata: nil)

        #expect(store.errorMessage == nil)
        #expect(store.canonicalFolderName == folder)
        #expect(store.snapshot?.target == folder)
        #expect(store.groupCount == 1)
        #expect(store.fileCount == 3)
        #expect(!store.isLoading)
    }

    @Test("Variants nest under the family they belong to instead of forming their own top-level rows")
    func variantsNestUnderTheirFamily() async throws {
        let metadata = try MetadataStore.temporary()
        let project = project()
        let folder = libraryFolder(for: project)
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let store = ResultsStore(
            metadataFactory: { _ in metadata },
            resultsQueryFactory: queryFactory(try discoveryFixture(folder: folder))
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id, sharedMetadata: nil)

        #expect(store.rows.count == 1)
        let family = try #require(store.rows.first)
        #expect(family.children?.count == 2)
        #expect(family.file.variantKind == .original)
        // Every row -- family and variant alike -- resolves back to its file
        // and to the family it belongs to, so a row action never has to
        // search the tree.
        let familyStem = try #require(store.family(rowID: family.id)).stem
        for row in [family] + (family.children ?? []) {
            #expect(store.file(rowID: row.id) == row.file)
            #expect(store.family(rowID: row.id)?.stem == familyStem)
        }
    }

    @Test("A project whose library folder has no finished stack reports an honest empty snapshot")
    func projectWithoutStacksIsEmpty() async throws {
        let metadata = try MetadataStore.temporary()
        let project = project()
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let store = ResultsStore(
            metadataFactory: { _ in metadata },
            resultsQueryFactory: queryFactory(try Database(path: ":memory:"))
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id, sharedMetadata: nil)

        #expect(store.rows.isEmpty)
        #expect(store.fileCount == 0)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test("A load failure surfaces its error message rather than throwing past the view")
    func loadFailureSurfacesError() async throws {
        struct BoomError: Error {}
        let store = ResultsStore(
            metadataFactory: { _ in throw BoomError() },
            resultsQueryFactory: { _ in ResultsQuery(stackGroups: { _ in [] }) }
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: UUID(), sharedMetadata: nil)

        #expect(store.snapshot == nil)
        #expect(store.errorMessage != nil)
        #expect(!store.isLoading)
    }

    /// A slow scan that started first must never land on top of a newer one.
    /// Held open at a defined point rather than with a sleep, so this is
    /// deterministic: the first load is inside the provider when the second
    /// one runs to completion.
    @Test("A load overtaken by a newer one writes nothing")
    func staleLoadIsDropped() async throws {
        let metadata = try MetadataStore.temporary()
        let project = project()
        let folder = libraryFolder(for: project)
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let db = try discoveryFixture(folder: folder)
        let gate = LoadGate()

        let store = ResultsStore(
            metadataFactory: { _ in metadata },
            resultsQueryFactory: { _ in
                ResultsQuery(stackGroups: { target in
                    // Only the FIRST call waits; the second sails past it.
                    if await gate.claimFirstCall() { await gate.wait() }
                    return try StackDiscovery.groupedStacks(target: target, db: db, config: AstroConfig())
                })
            }
        )

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let stale = Task { await store.load(rootURL: root, projectID: project.id, sharedMetadata: nil) }
        await gate.awaitFirstCallStarted()
        await store.load(rootURL: root, projectID: project.id, sharedMetadata: nil)
        #expect(store.groupCount == 1)

        await gate.open()
        await stale.value

        // The stale load resumed last and must have written nothing -- the
        // newer load's own result still stands, and the screen is not stuck
        // in a loading state either.
        #expect(store.groupCount == 1)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    // MARK: - v5 library-switch fixes, item 3 (follow-up): this store used
    // to open its own confined `MetadataStore` connection through
    // `metadataFactory` on every load, competing with `ProjectsStore`'s
    // already-open one for the same file.

    @Test("An already-open metadata store is reused instead of opening a second connection")
    func sharedMetadataStoreIsUsedInsteadOfTheFactory() async throws {
        let metadata = try MetadataStore.temporary()
        let project = project()
        let folder = libraryFolder(for: project)
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let store = ResultsStore(
            // Opening one here would be the bug -- the load must go through
            // `sharedMetadata` and never touch this.
            metadataFactory: { _ in throw ResultsStoreTestFailure.shouldNotOpenASecondConnection },
            resultsQueryFactory: queryFactory(try discoveryFixture(folder: folder))
        )

        await store.load(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id, sharedMetadata: metadata
        )

        #expect(store.errorMessage == nil)
        #expect(store.canonicalFolderName == folder)
        #expect(store.groupCount == 1)
    }
}

private enum ResultsStoreTestFailure: Error, Equatable {
    case shouldNotOpenASecondConnection
}

/// Test-only coordination for `staleLoadIsDropped`.
private actor LoadGate {
    private var firstCallClaimed = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func claimFirstCall() -> Bool {
        guard !firstCallClaimed else { return false }
        firstCallClaimed = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        return true
    }

    func awaitFirstCallStarted() async {
        guard !firstCallClaimed else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
