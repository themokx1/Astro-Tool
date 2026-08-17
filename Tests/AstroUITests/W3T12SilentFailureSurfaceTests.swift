import Foundation
import Testing

/// W3-12: a toast-timing survey found four places where a V2 operation could
/// fail with nothing visible to the user, plus one dead-but-harmless
/// `OperationHost`. `ArchiveStoreTests`/`ReviewStoreTests` cover the store-
/// level halves of these fixes with real, injectable failures; the four
/// tests below cover the halves that are pure view wiring -- "does the view
/// actually read the error the store already tracks" -- which this repo has
/// no rendering harness for (see `V2HonestSurfacesTests`'/`WorkspaceActionsTests`'
/// own doc comments), so they follow this codebase's established "surface"
/// convention of literal source-text assertions instead.
@Suite("W3-12 silent-failure surfaces")
struct W3T12SilentFailureSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: 1. ArchiveView's acknowledge sheet must not have an empty catch.

    @Test("ArchiveView no longer swallows a failed acknowledge in an empty catch -- it routes through the store/OperationHost instead")
    func archiveViewAcknowledgeHasNoEmptyCatch() throws {
        let source = try contents("Sources/AstroUI/Features/Archive/ArchiveView.swift")
        #expect(
            !source.contains("Best-effort: a failed metadata write just leaves the card"),
            "the old empty-catch acknowledge must be gone"
        )
        #expect(source.contains("store.acknowledge("), "acknowledging must go through the store, not an inline MetadataStore the view builds and discards errors from")
    }

    // MARK: 2. SavedTargetsView must render the store's write-failure error.

    @Test("SavedTargetsView renders the store's write-failure error, not just holds it")
    func savedTargetsViewRendersErrorMessage() throws {
        let source = try contents("Sources/AstroUI/Features/Planning/SavedTargetsView.swift")
        // Split at the view type so this only checks the VIEW half reads
        // `errorMessage` -- the store half (property declaration plus its
        // `perform`/`reload` assignments) already does, and always has.
        guard let split = source.range(of: "public struct SavedTargetsView") else {
            Issue.record("SavedTargetsView type not found")
            return
        }
        let viewSource = source[split.lowerBound...]
        #expect(
            viewSource.contains("store.errorMessage"),
            "a failed save/note-update/remove must be visible somewhere in the view, not just recorded on the store"
        )
    }

    // MARK: 3. ReviewStore.assignFilter's call site must not use try?, and

    // SeriesInspector's "Add a new filter" form must not clear itself before

    // the write it just requested has actually settled.

    @Test("ReviewWorkspace no longer swallows a failed filter assignment with try?")
    func reviewWorkspaceDoesNotSwallowAssignFilter() throws {
        let source = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(!source.contains("try? await store.assignFilter"), "a failed filter assignment must surface, not vanish")
    }

    @Test("SeriesInspector only clears its new-filter form after assignFilter's write actually succeeds")
    func seriesInspectorDoesNotOptimisticallyClearOnAssign() throws {
        let source = try contents("Sources/AstroUI/Inspector/SeriesInspector.swift")
        #expect(
            !source.contains(#"assignFilter(filter); manufacturer = ""; model = ""; newFilterPassband = .unknown; filterError = nil"#),
            "the form must not clear itself immediately after firing off an async write whose outcome it never waited for"
        )
        #expect(source.contains("assignFilter: (EquipmentFilter) async throws -> Void"), "the closure must let callers await the real outcome")
    }

    // MARK: 4. HealthView must surface a failed acknowledge with a table already loaded.

    @Test("HealthView surfaces a failed acknowledge even when the findings table is already loaded, not only in the empty/no-library state")
    func healthViewSurfacesErrorInLoadedState() throws {
        let source = try contents("Sources/AstroUI/Features/Library/HealthView.swift")
        let occurrences = source.components(separatedBy: "store.errorMessage").count - 1
        #expect(occurrences >= 2, "the loaded findings table must render store.errorMessage too, not only the no-snapshot empty state")
    }
}
