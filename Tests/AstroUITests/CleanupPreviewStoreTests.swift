@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: `CleanupPreviewStore`
/// used to be a `private final class` embedded in `CleanupPreviewView.swift`
/// that resolved `CleanupPreviewQuery.production` directly inside `load`/
/// `buildPlan` -- there was no way to load it against anything but a real
/// on-disk library, so this whole screen had zero unit-test surface. This is
/// that surface.
@MainActor
@Suite("V2 Cleanup preview store")
struct CleanupPreviewStoreTests {
    private static func makeIndex() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try Database(path: index.path)
        try db.upsertFile(FileRecord(
            path: "stacks/IC1396/process/r_light.fit", size: 1_048_576, mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other, scannedAt: 0
        ))
        return index
    }

    @Test("Loading a library populates the cleanup preview snapshot")
    func loadingPopulatesSnapshot() async throws {
        let index = try Self.makeIndex()
        let store = CleanupPreviewStore(queryFactory: { _, _ in CleanupPreviewQuery(indexDatabaseForTesting: index) })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly)

        #expect(store.snapshot?.totalBytes == 1_048_576)
        #expect(store.errorMessage == nil)
    }

    @Test("Toggling a category selection tracks membership both ways")
    func togglingSelectionTracksMembership() async throws {
        let index = try Self.makeIndex()
        let store = CleanupPreviewStore(queryFactory: { _, _ in CleanupPreviewQuery(indexDatabaseForTesting: index) })
        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly)
        let category = try #require(store.snapshot?.groups.first?.category)

        store.toggleSelection(category)
        #expect(store.selectedCategories.contains(category))

        store.toggleSelection(category)
        #expect(!store.selectedCategories.contains(category))
    }

    @Test("Building a plan with nothing selected returns nil rather than an empty plan")
    func buildPlanWithNoSelectionReturnsNil() throws {
        let store = CleanupPreviewStore()
        #expect(store.buildPlan() == nil)
    }

    // MARK: Task 10 prerequisite -- preselect

    @Test("preselect pre-checks the given categories")
    func preselectPreChecksTheGivenCategories() {
        let store = CleanupPreviewStore()
        store.preselect(["duplicate-content", "residue"])
        #expect(store.selectedCategories == ["duplicate-content", "residue"])
    }

    @Test("Re-preselecting the same set the store already holds is a no-op, matching this codebase's equal-value-guard convention")
    func preselectWithTheSameValueIsANoOp() {
        let store = CleanupPreviewStore()
        store.preselect(["duplicate-content"])
        store.preselect(["duplicate-content"])
        #expect(store.selectedCategories == ["duplicate-content"])
    }

    @Test("Preselecting a genuinely different set still overwrites -- this is a preset, not a merge")
    func preselectWithADifferentValueOverwrites() {
        let store = CleanupPreviewStore()
        store.preselect(["duplicate-content"])
        store.preselect(["residue"])
        #expect(store.selectedCategories == ["residue"])
    }
}
