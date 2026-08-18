@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

/// W6-F: an owner repro on the SERIES page's inspector (`InspectorView`'s
/// `.series(rawID)` branch, hosting `SeriesInspector` -- distinct from
/// `ReviewWorkspace`'s own embedded copy) -- create a filter via "Save and
/// Use", watch it silently fail to land on the series. Reproduced end to
/// end: `InspectorView.seriesPanel` used to construct `SeriesInspector` with
/// no `assignFilter` argument at all, which fell back to the type's own
/// no-op default (`{ _ in }` -- see `SeriesInspector.init`). The filter WAS
/// created (`SettingsStore.createFilter` persists to `UserDefaults`
/// independent of any project), so it showed up afterward in the "Choose
/// Filter…" menu and the add-filter form cleared as if the write had
/// settled -- but the series itself was never touched, matching the owner's
/// screenshot (empty Gyártó/Modell fields, the new filter already selectable
/// above, no error, and the series' own "Filter" row still unset).
///
/// The fix has two parts, both covered below:
///  1. `InspectorView.seriesPanel` now passes a real closure
///     (`ReviewStoreTests`'s existing `assignFilterInline`/
///     `assignFilterSurfacesWriteFailure` already cover `ReviewStore
///     .assignFilter(_:)`'s own write/error-surface behavior once called --
///     this suite is about whether the series page's inspector ever calls
///     it at all).
///  2. That closure targets the exact series the panel is showing
///     (`ReviewStore.assignFilter(_:toSeriesID:)`), not whatever
///     `ReviewStore.selectedSeriesID` happens to hold -- a separate,
///     `ReviewWorkspace`-owned concept the series page's inspector has no
///     reason to match (see that method's own doc comment in
///     `ReviewStore.swift`).
@MainActor
@Suite("W6-F filter assignment persistence")
struct W6FFilterAssignmentPersistenceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: 1. The series page's inspector must wire a real assignFilter closure.

    @Test("InspectorView's series panel no longer constructs SeriesInspector with the default no-op assignFilter")
    func inspectorViewWiresRealAssignFilterClosure() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        #expect(
            !source.contains("SeriesInspector(snapshot: reviewSnapshot)\n"),
            "constructing SeriesInspector with no trailing closure falls back to its silent no-op default"
        )
        #expect(
            source.contains("reviewStore.assignFilter(filter, toSeriesID: id)"),
            "the series page must route \"Save and Use\"/menu picks through a real write, targeted at the series actually on screen"
        )
    }

    // MARK: 2. End-to-end: assigning by explicit series ID persists across a fresh store, without touching the ambient selection.

    @Test("Assigning a filter by explicit series ID persists to that series across a fresh store reload, and never touches the ambient selectedSeriesID")
    func assignFilterByExplicitSeriesIDPersistsAcrossReload() async throws {
        let fixture = try await W6FFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)

        // `open` defaults the ambient selection to the FIRST series --
        // deliberately not the one this test targets, mirroring the owner's
        // shape: he was on the series page for one series while Review (if
        // ever opened this session) may have a completely different one
        // selected.
        #expect(store.selectedSeriesID == fixture.series[0].id)
        let targetSeries = fixture.series[2]
        #expect(targetSeries.id != store.selectedSeriesID)

        let filter = EquipmentFilter(id: UUID(), manufacturer: "SvBony", model: "Sv220", passband: .dualBand)
        try await store.assignFilter(filter, toSeriesID: targetSeries.id)

        // Landed on the right series, immediately, in this store.
        let updated = store.snapshot?.series.first { $0.id == targetSeries.id }
        #expect(updated?.series.filterName == "SvBony Sv220")
        #expect(updated?.series.filterID == filter.id.uuidString.lowercased())
        #expect(updated?.series.passband == .dualBand)

        // The ambient selection (ReviewWorkspace's own concept) must be
        // undisturbed -- this call site never meant "assign to whatever is
        // selected".
        #expect(store.selectedSeriesID == fixture.series[0].id)
        #expect(store.snapshot?.series.first { $0.id == fixture.series[0].id }?.series.filterName == nil)

        // Full round trip: a brand-new store instance, over the SAME
        // metadata DB file (not the same in-memory object), must see the
        // write too -- this is the "reload the store fresh" half of the
        // owner's repro: does it actually save, or does it only look saved
        // until the app restarts.
        let reopened = try MetadataStore(databaseURL: fixture.metadata.databaseURL)
        let freshStore = ReviewStore(metadataFactory: { _ in reopened })
        try await freshStore.open(rootURL: fixture.root, projectID: fixture.project.id)
        let reloaded = freshStore.snapshot?.series.first { $0.id == targetSeries.id }
        #expect(reloaded?.series.filterName == "SvBony Sv220")
        #expect(reloaded?.series.filterID == filter.id.uuidString.lowercased())
    }

    @Test("Assigning a filter by explicit series ID to a series absent from the loaded project throws instead of silently no-oping")
    func assignFilterByExplicitSeriesIDRejectsUnknownSeries() async throws {
        let fixture = try await W6FFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        let filter = EquipmentFilter(id: UUID(), manufacturer: "SvBony", model: "Sv220", passband: .dualBand)

        await #expect(throws: (any Error).self) {
            try await store.assignFilter(filter, toSeriesID: UUID())
        }
    }
}

private struct W6FFixture {
    let root: URL
    let metadata: MetadataStore
    let project: ProjectRecord
    let series: [SeriesRecord]

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-W6F-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = [30.0, 120.0, 300.0].map { exposure in
            SeriesRecord(
                id: UUID(), projectID: project.id, nightID: night.id,
                setupID: "asi2600mc-261", setupDescriptor: "ASI2600MC · 261 mm",
                sensorMode: .osc, passband: .unknown,
                exposureSeconds: exposure, filterName: nil,
                filterID: nil, gain: 100, offset: 50, binning: "1x1"
            )
        }
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: series))
        return Self(root: root, metadata: metadata, project: project, series: series)
    }
}
