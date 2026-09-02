@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// v5 library-switch fixes (item 3, follow-up): `SavedTargetsStore` used to
/// open its own confined `MetadataStore` connection through `metadataFactory`
/// the first time save/note/remove/reload ran, one more SQLite connection
/// competing with `ProjectsStore`'s already-open one for the same file. It
/// now asks for the window's already-open store first -- see
/// `LibraryHealthStoreTests`' own "shared metadata" tests for the pattern
/// this mirrors.
@MainActor
@Suite("V2 Saved targets store")
struct SavedTargetsStoreTests {
    @Test("An already-open metadata store is reused instead of opening a second connection")
    func savingReusesTheSharedMetadataStore() async throws {
        let shared = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/tmp/lib")
        let store = SavedTargetsStore(
            // Opening one here would be the bug -- the store must go through
            // `sharedMetadataProvider` and never touch this.
            metadataFactory: { _ in throw SavedTargetsStoreTestFailure.shouldNotOpenASecondConnection },
            siteResolver: { _ in nil },
            targetCatalogProvider: { [] }
        )
        store.sharedMetadataProvider = { asked in asked == root ? shared : nil }
        await store.setRootURL(root)

        let saved = await store.save(designation: "M 31")

        #expect(saved)
        #expect(store.isSaved("M 31"))
        #expect(store.errorMessage == nil)
    }

    @Test("A root the shared provider does not own still falls back to this store's own factory")
    func savingFallsBackWhenNoSharedStoreIsOpenForThisRoot() async throws {
        let root = URL(fileURLWithPath: "/tmp/lib")
        let store = SavedTargetsStore(
            metadataFactory: { _ in try MetadataStore.temporary() },
            siteResolver: { _ in nil },
            targetCatalogProvider: { [] }
        )
        // The window's store is open for some OTHER library -- exactly the
        // mid-switch state where reusing it would answer for the wrong root.
        store.sharedMetadataProvider = { _ in nil }
        await store.setRootURL(root)

        let saved = await store.save(designation: "M 31")

        #expect(saved)
        #expect(store.isSaved("M 31"))
    }

    @Test("Nothing shared and no factory succeeding leaves the store honestly unopened")
    func libraryNotOpenIsSurfacedWhenNeitherSourceCanAnswer() async throws {
        let store = SavedTargetsStore(
            metadataFactory: { _ in try MetadataStore.temporary() },
            siteResolver: { _ in nil },
            targetCatalogProvider: { [] }
        )
        // No `setRootURL` at all -- `rootURL` stays nil, so `resolveMetadata`
        // must throw `.libraryNotOpen` rather than silently opening anything.
        let saved = await store.save(designation: "M 31")

        #expect(!saved)
        #expect(store.errorMessage != nil)
    }
}

private enum SavedTargetsStoreTestFailure: Error, Equatable {
    case shouldNotOpenASecondConnection
}
