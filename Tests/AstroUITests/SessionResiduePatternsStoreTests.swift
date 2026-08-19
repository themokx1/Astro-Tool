@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// V2 UI/UX audit -- `AstroConfig.sessionResiduePatterns` (added by
/// 3b8aeb0, "session-area-scoped residue patterns") got an editable
/// pattern-list UI, but it landed in V1's `LibraryRulesSettingsView`
/// (`Sources/AstroToolApp`), which the default V2 shell can never reach --
/// so a V2-only owner had no way at all to see or change which filenames
/// (`starless*`, `starmask*`, `*graxpert*`, `result_*` by default) count as
/// residue ONLY inside the `sessions/` area, as opposed to being kept stack
/// variants under `stacks/`/`processed/` (see `ResidueMatcher.category`'s
/// own doc comment in `Sources/AstroCore/Audit/Rules.swift`). This store
/// mirrors `EquipmentSetupsStore`'s own shape exactly: same
/// `configLoader`/`configSaver` defaults (`SiteSettingsStore`'s own
/// production implementations, so there is only ever one canonical
/// `config.json` read/write path across every V2 Settings tab), same
/// no-library-open honesty, same round trip through
/// `AstroConfig.save(using:)` -> `WriteGuard`.
@MainActor
@Suite("Session-residue patterns store")
struct SessionResiduePatternsStoreTests {
    private struct TempLibrary {
        let root: URL

        static func make() throws -> TempLibrary {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AstroTool-SessionResiduePatternsStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return TempLibrary(root: root)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func loadConfig() throws -> AstroConfig {
            try AstroConfig.load(from: root.appendingPathComponent(".astro_tool/config.json"))
        }
    }

    // MARK: - No library open

    @Test("With no library open, the store starts empty and every mutation refuses honestly")
    func noLibraryOpenRefusesToSave() throws {
        let store = SessionResiduePatternsStore(rootURL: nil)
        #expect(!store.hasLibraryOpen)
        #expect(store.patterns.isEmpty)

        #expect(!store.add("starless*"))
        #expect(store.lastError == .noLibraryOpen)
        #expect(!store.remove(at: 0))
        #expect(store.lastError == .noLibraryOpen)
        #expect(!store.restoreDefaults())
        #expect(store.lastError == .noLibraryOpen)
    }

    // MARK: - Loading

    @Test("Opening the tab against a library that already has custom patterns loads them")
    func loadsExistingPatterns() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        var config = AstroConfig()
        config.rootPath = library.root.path
        config.sessionResiduePatterns = ["custom_*"]
        try config.save(using: WriteGuard(root: library.root))

        let store = SessionResiduePatternsStore(rootURL: library.root)
        #expect(store.patterns == ["custom_*"])
    }

    @Test("Opening the tab against a fresh library shows the engine's own defaults")
    func loadsEngineDefaultsForAFreshLibrary() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        #expect(store.patterns == AstroConfig().sessionResiduePatterns)
    }

    // MARK: - Add

    @Test("Adding a pattern persists to config.json at the canonical .astro_tool/config.json path")
    func addingAPatternRoundTripsThroughConfig() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        let before = store.patterns

        #expect(store.add("myresidue_*"))
        #expect(store.lastError == nil)
        #expect(store.patterns == before + ["myresidue_*"])

        let reloaded = try library.loadConfig()
        #expect(reloaded.sessionResiduePatterns == before + ["myresidue_*"])
    }

    @Test("A pattern is trimmed of surrounding whitespace before being saved")
    func addingAPatternTrimsWhitespace() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)

        #expect(store.add("  spaced_*  "))
        #expect(store.patterns.last == "spaced_*")
    }

    @Test("An empty or whitespace-only pattern is rejected without writing")
    func rejectsAnEmptyPattern() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        let before = store.patterns

        #expect(!store.add("   "))
        #expect(store.lastError == .emptyPattern)
        #expect(store.patterns == before)
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent(".astro_tool/config.json").path))
    }

    @Test("A pattern that already exists, case-insensitively, is rejected as a duplicate")
    func rejectsADuplicatePattern() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        #expect(store.add("Unique_*"))
        let before = store.patterns

        #expect(!store.add("unique_*"))
        #expect(store.lastError == .duplicatePattern)
        #expect(store.patterns == before)
    }

    // MARK: - Remove

    @Test("Removing a pattern by index removes it from config.json")
    func removingRemovesFromConfig() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        #expect(store.add("removable_*"))
        let index = try #require(store.patterns.firstIndex(of: "removable_*"))

        #expect(store.remove(at: index))
        #expect(!store.patterns.contains("removable_*"))

        let reloaded = try library.loadConfig()
        #expect(!reloaded.sessionResiduePatterns.contains("removable_*"))
    }

    @Test("Removing an out-of-range index is a no-op that reports no error")
    func removingAnOutOfRangeIndexIsANoOp() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        let before = store.patterns

        #expect(store.remove(at: 999))
        #expect(store.lastError == nil)
        #expect(store.patterns == before)
    }

    // MARK: - Restore defaults

    @Test("Restoring defaults resets to the engine's own AstroConfig() defaults and persists")
    func restoringDefaultsResetsAndPersists() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SessionResiduePatternsStore(rootURL: library.root)
        #expect(store.add("temporary_*"))

        #expect(store.restoreDefaults())
        #expect(store.patterns == AstroConfig().sessionResiduePatterns)

        let reloaded = try library.loadConfig()
        #expect(reloaded.sessionResiduePatterns == AstroConfig().sessionResiduePatterns)
    }
}
