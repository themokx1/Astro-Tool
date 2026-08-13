@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// Covers `AppModel`'s cross-scene state (V2 parity wave 2, task 9): the
/// currently open library root (read by `V2SettingsView`'s Support tab, a
/// separate `Settings` scene with no direct reference to any window's
/// `OnboardingStore`), the recent-libraries list the Libraries settings tab
/// shows, and the pending-switch hand-off a "Switch" action on one of those
/// entries uses to reach the open window.
@MainActor
@Suite("App model cross-scene state")
struct AppModelTests {
    @Test("Opening a library records it as current and as the newest recent entry")
    func libraryDidOpenRecordsCurrentAndRecent() {
        let store = InMemoryRecentLibrariesStore()
        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: store.store)
        let root = URL(fileURLWithPath: "/Users/test/Astro Library")

        model.libraryDidOpen(rootURL: root, metadataStore: nil)

        #expect(model.currentLibraryRootURL == root.standardizedFileURL)
        #expect(model.recentLibraries.first?.path == root.standardizedFileURL.path)
        #expect(model.recentLibraries.first?.displayName == "Astro Library")
        #expect(store.saved.last?.first?.path == root.standardizedFileURL.path)
    }

    @Test("Opening the same library again moves it to the front instead of duplicating it")
    func reopeningMovesEntryToFrontWithoutDuplicating() {
        let store = InMemoryRecentLibrariesStore()
        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: store.store)
        let first = URL(fileURLWithPath: "/Users/test/First")
        let second = URL(fileURLWithPath: "/Users/test/Second")

        model.libraryDidOpen(rootURL: first, metadataStore: nil)
        model.libraryDidOpen(rootURL: second, metadataStore: nil)
        model.libraryDidOpen(rootURL: first, metadataStore: nil)

        #expect(model.recentLibraries.map(\.path) == [first.standardizedFileURL.path, second.standardizedFileURL.path])
    }

    @Test("The recent list is capped at five entries, newest first")
    func recentListIsCappedAtFive() {
        let store = InMemoryRecentLibrariesStore()
        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: store.store)

        for index in 0..<7 {
            model.libraryDidOpen(rootURL: URL(fileURLWithPath: "/Users/test/Library\(index)"), metadataStore: nil)
        }

        #expect(model.recentLibraries.count == 5)
        #expect(model.recentLibraries.first?.path == URL(fileURLWithPath: "/Users/test/Library6").standardizedFileURL.path)
        #expect(model.recentLibraries.last?.path == URL(fileURLWithPath: "/Users/test/Library2").standardizedFileURL.path)
    }

    @Test("The recent list is restored from the injected store at init")
    func recentListIsLoadedAtInit() {
        let existing = RecentLibraryEntry(path: "/Users/test/Existing", displayName: "Existing", lastOpenedAt: Date())
        let store = InMemoryRecentLibrariesStore(seed: [existing])

        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: store.store)

        #expect(model.recentLibraries == [existing])
    }

    @Test("Opening a library records its already-open metadata store for Support diagnostics to reuse")
    func libraryDidOpenRecordsMetadataStore() async throws {
        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: .inactive)
        let metadataStore = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Users/test/Astro Library")

        model.libraryDidOpen(rootURL: root, metadataStore: metadataStore)

        #expect(model.currentMetadataStore === metadataStore)
    }

    @Test("Requesting a library switch sets and clears the pending URL")
    func requestLibrarySwitchSetsAndClears() {
        let model = AppModel(restorationValidator: .allowingAll, recentLibrariesStore: .inactive)
        let root = URL(fileURLWithPath: "/Users/test/Astro Library")

        model.requestLibrarySwitch(to: root)
        #expect(model.pendingLibrarySwitchURL == root.standardizedFileURL)

        model.clearPendingLibrarySwitch()
        #expect(model.pendingLibrarySwitchURL == nil)
    }
}

@MainActor
private final class InMemoryRecentLibrariesStore {
    private(set) var current: [RecentLibraryEntry]
    private(set) var saved: [[RecentLibraryEntry]] = []

    init(seed: [RecentLibraryEntry] = []) {
        current = seed
    }

    var store: RecentLibrariesStore {
        RecentLibrariesStore(
            load: { [weak self] in self?.current ?? [] },
            save: { [weak self] entries in
                self?.current = entries
                self?.saved.append(entries)
            }
        )
    }
}
