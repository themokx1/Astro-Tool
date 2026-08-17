@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
@Suite("V2 Review store")
struct ReviewStoreTests {
    @Test("Opening review selects the first exposure series and keeps distinct captures")
    func openSelectsFirstSeries() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })

        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)

        #expect(store.snapshot?.series.map(\.series.exposureSeconds) == [30, 120, 300])
        #expect(store.selectedSeriesID == fixture.series[0].id)
        #expect(store.selectedSeries?.series.exposureSeconds == 30)
    }

    @Test("A bulk reject refreshes series counts and logical exclusion")
    func bulkRejectRefreshesSnapshot() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        store.selectSeries(fixture.series[2].id)

        try await store.setVerdict(
            relativePaths: ["lights/SV220_001.fit", "lights/SV220_002.fit"],
            verdict: .rejected
        )

        #expect(store.selectedSeries?.rejectedCount == 2)
        #expect(store.selectedSeries?.decisions.allSatisfy(\.logicallyExcluded) == true)
        #expect(store.selectedSeriesID == fixture.series[2].id)
    }

    @Test("An equipment filter can be assigned inline to the selected series")
    func assignFilterInline() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        let filter = EquipmentFilter(id: UUID(), manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        try await store.assignFilter(filter)

        #expect(store.selectedSeries?.series.filterName == "SVBONY SV220")
        #expect(store.selectedSeries?.series.passband == .dualBand)
        #expect(store.selectedSeries?.series.filterID == filter.id.uuidString.lowercased())
    }

    @Test("Opening a review loads measured quality metrics for every indexed frame")
    func openLoadsQualityMetrics() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let quality = try fixture.installQualityFixture()
        let store = ReviewStore(
            metadataFactory: { _ in fixture.metadata },
            qualityQueryFactory: { _ in FrameQualityQuery(db: quality.db, config: quality.config) },
            ratingCommandFactory: { root in FrameRatingCommand(db: quality.db, config: quality.config, root: root) }
        )

        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)

        #expect(store.quality(for: "lights/SV220_001.fit")?.score == 0.75)
        #expect(store.quality(for: "lights/SV220_002.fit")?.score == nil, "a never-rated frame reports no measured score")
    }

    @Test("Rating the selected series runs through OperationHost, refreshes metrics, and toasts success")
    func rateSelectedSeriesRunsThroughOperationHostAndRefreshes() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let quality = try fixture.installQualityFixture()
        let store = ReviewStore(
            metadataFactory: { _ in fixture.metadata },
            qualityQueryFactory: { _ in FrameQualityQuery(db: quality.db, config: quality.config) },
            ratingCommandFactory: { root in FrameRatingCommand(db: quality.db, config: quality.config, root: root) }
        )
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        store.selectSeries(fixture.series[2].id)
        let host = OperationHost(center: OperationCenter())

        await store.rateSelectedSeries(mode: .nativeOnly, operationHost: host)
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
        // The fixture frame's own real pixels rate to a real background
        // value once native-only rating actually ran through the store.
        #expect(store.quality(for: "lights/SV220_001.fit")?.background != nil)
    }

    @Test("Rating with no series selected notifies instead of crashing")
    func rateWithNoSeriesSelectedNoOps() async throws {
        let store = ReviewStore(
            metadataFactory: { _ in throw ReviewStoreTestFailure.shouldNotBeCalled },
            qualityQueryFactory: { _ in throw ReviewStoreTestFailure.shouldNotBeCalled },
            ratingCommandFactory: { _ in throw ReviewStoreTestFailure.shouldNotBeCalled }
        )
        let host = OperationHost(center: OperationCenter())

        await store.rateSelectedSeries(mode: .nativeOnly, operationHost: host)

        #expect(host.activeOperations.isEmpty)
        #expect(host.toasts.contains { $0.level == .info })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum ReviewStoreTestFailure: Error, Equatable {
    case shouldNotBeCalled
}

// MARK: - Quality/rating fixture helpers

private func reviewStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func reviewStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(reviewStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A minimal signed-16-bit FITS light frame -- just enough for
/// `NativeStats.compute` to read real pixel data, mirroring
/// `Tests/AstroApplicationTests/FrameRatingCommandTests.swift`'s own helper
/// (duplicated rather than shared -- AstroUITests cannot import
/// AstroApplicationTests' file-private target).
private func reviewStoreBuildFITSFrame(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = reviewStoreHeaderData(cards)
    for value in pixels {
        let unsigned = UInt16(bitPattern: Int16(value))
        data.append(UInt8(unsigned >> 8))
        data.append(UInt8(unsigned & 0xFF))
    }
    return data
}

/// The AstroCore index DB half of a review fixture -- `ReviewStoreFixture`
/// itself only ever populates the separate V2 metadata DB (`MetadataStore`),
/// so quality/rating tests that need real `files`/`ratings` rows install
/// this alongside it, using the exact same `relativePath`s
/// `ReviewStoreFixture` seeds its `FrameDecisionRecord`s with.
private struct ReviewQualityFixture {
    let db: Database
    let config: AstroConfig
}

private extension ReviewStoreFixture {
    /// Writes a real FITS frame + `ratings` row for `lights/SV220_001.fit`
    /// (already-measured) and a scanned-but-unrated row for
    /// `lights/SV220_002.fit`, both under `root` so `FrameRatingCommand`'s
    /// own native-only re-measure can run against real bytes.
    func installQualityFixture() throws -> ReviewQualityFixture {
        let dbDir = root.appendingPathComponent(".astro_tool_test_db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = root.path

        func writeFrame(_ relativePath: String, pixels: [Int]) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try reviewStoreBuildFITSFrame(width: 4, height: 4, pixels: pixels).write(to: url)
        }

        try writeFrame("lights/SV220_001.fit", pixels: Array(repeating: 300, count: 16))
        let ratedID = try db.upsertFile(FileRecord(
            path: "lights/SV220_001.fit", size: 2880 + 32, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: "IC 1396", sessionDate: "2026-08-08", role: .light,
            scannedAt: Date().timeIntervalSince1970
        ))
        try db.upsertRating(RatingRecord(
            fileID: ratedID, background: 300, score: 0.75, ratedAt: Date().timeIntervalSince1970,
            inputSig: "irrelevant-for-quality-read"
        ))

        try writeFrame("lights/SV220_002.fit", pixels: Array(repeating: 310, count: 16))
        try db.upsertFile(FileRecord(
            path: "lights/SV220_002.fit", size: 2880 + 32, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: "IC 1396", sessionDate: "2026-08-08", role: .light,
            scannedAt: Date().timeIntervalSince1970
        ))

        return ReviewQualityFixture(db: db, config: config)
    }
}

private struct ReviewStoreFixture {
    let root: URL
    let metadata: MetadataStore
    let project: ProjectRecord
    let series: [SeriesRecord]

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-ReviewStore-\(UUID().uuidString)", isDirectory: true
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
                sensorMode: .osc, passband: exposure == 30 ? .broadband : .dualBand,
                exposureSeconds: exposure, filterName: exposure == 30 ? nil : "SV220",
                filterID: exposure == 30 ? nil : "svbony-sv220",
                gain: 100, offset: 50, binning: "1x1"
            )
        }
        // Two undecided frame decisions on the 300s series -- the exact
        // `relativePath`s `installQualityFixture()` writes real FITS bytes
        // and `ratings` rows for, so quality/rating tests have something to
        // look up without disturbing `bulkRejectRefreshesSnapshot`'s own use
        // of these same two paths (it just moves them from undecided to
        // rejected, same as if they'd never existed beforehand).
        let qualityDecisions = ["lights/SV220_001.fit", "lights/SV220_002.fit"].map { path in
            FrameDecisionRecord(
                id: UUID(), seriesID: series[2].id, relativePath: path,
                verdict: .undecided, logicallyExcluded: false
            )
        }
        try await metadata.save(MetadataWriteBatch(
            projects: [project], nights: [night], series: series, frameDecisions: qualityDecisions
        ))
        return Self(root: root, metadata: metadata, project: project, series: series)
    }
}
