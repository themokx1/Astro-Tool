@testable import AstroUI
@testable import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
@Suite("V2 sidebar badge store")
struct SidebarBadgeStoreTests {
    @Test("Refreshing reports non-zero counts from fixture data needing attention")
    func refreshReportsNonZeroCounts() async throws {
        let fixture = try await Self.makeFixture()
        let nightsStore = NightsStore(metadataFactory: { _ in fixture.metadata })
        try await nightsStore.open(rootURL: fixture.root)

        let badges = SidebarBadgeStore(
            taskSummaryFactory: { _ in
                try await ArchiveTaskQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: fixture.metadata).summary()
            }
        )

        await badges.refresh(rootURL: fixture.root, nights: nightsStore.nights)

        #expect(badges.nightsNeedingAttention == 1)
        #expect(badges.libraryAttentionCount > 0)
    }

    @Test("A night with no excluded frames does not count toward the badge")
    func readyNightDoesNotCount() async throws {
        let fixture = try await Self.makeReadyFixture()
        let nightsStore = NightsStore(metadataFactory: { _ in fixture.metadata })
        try await nightsStore.open(rootURL: fixture.root)

        let badges = SidebarBadgeStore(
            taskSummaryFactory: { _ in
                try await ArchiveTaskQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: fixture.metadata).summary()
            }
        )

        await badges.refresh(rootURL: fixture.root, nights: nightsStore.nights)

        #expect(badges.nightsNeedingAttention == 0)
    }

    @Test("A night with a rejected-but-fully-decided frame does not count toward the badge")
    func rejectedButDecidedNightDoesNotCount() async throws {
        // V2 product/UX audit (2026-08-15) section 2.3, CRITICAL: this
        // fixture is exactly the shape that used to permanently mark a
        // night "needs review" the moment morning triage rejected a bad
        // frame -- one rejected, one accepted, zero undecided. It must no
        // longer count.
        let fixture = try await Self.makeRejectedButDecidedFixture()
        let nightsStore = NightsStore(metadataFactory: { _ in fixture.metadata })
        try await nightsStore.open(rootURL: fixture.root)

        let badges = SidebarBadgeStore(
            taskSummaryFactory: { _ in
                try await ArchiveTaskQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: fixture.metadata).summary()
            }
        )

        await badges.refresh(rootURL: fixture.root, nights: nightsStore.nights)

        #expect(badges.nightsNeedingAttention == 0)
    }

    @Test("A health-query failure leaves the library badge at zero rather than crashing")
    func healthQueryFailureIsHandledGracefully() async throws {
        let fixture = try await Self.makeReadyFixture()
        let badges = SidebarBadgeStore(taskSummaryFactory: { _ in throw SidebarBadgeStoreTestFailure.queryFailed })

        await badges.refresh(rootURL: fixture.root, nights: [])

        #expect(badges.libraryAttentionCount == 0)
    }

    private struct Fixture {
        let root: URL
        let indexDatabase: URL
        let metadata: MetadataStore
    }

    /// One session with a still-undecided frame (so its night's triage
    /// state is `.needsReview` -- V2 product/UX audit 2026-08-15 section
    /// 2.3: a rejected-but-decided frame no longer counts) and no session
    /// flat/dark (so `LibraryHealthQuery` reports calibration-gap findings)
    /// -- both badge counts should be non-zero.
    private static func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroSidebarBadges-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = AstroConfig()
        config.rootPath = root.path
        let db = try Database(path: storage.indexDatabase.path)

        let lightURL = root.appendingPathComponent("sessions/IC_1396/2026-08-08/lights/light.fit")
        try FileManager.default.createDirectory(at: lightURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("light".utf8).write(to: lightURL)

        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()

        // W4-7 item 2: the badge now sums ArchiveTaskQuery.summary()'s cards
        // (the same query the Archive page renders), which reads the latest
        // AUDIT run's findings -- so the fixture seeds one, in exactly the
        // shape AuditEngine writes (mirrors ArchiveTaskQueryTests' rows).
        let raw = try SQLiteDB(path: storage.indexDatabase.path)
        try raw.exec("INSERT INTO runs(kind, started_at, root) VALUES('audit', 2000.0, '\(root.path)');")
        try raw.exec("""
            INSERT INTO findings(run_id, severity, category, path, message)
            VALUES ((SELECT MAX(id) FROM runs WHERE kind='audit'),
                    'suspicious', 'residue', 'sessions/IC_1396/2026-08-08/lights/light.fit', 'leftover');
            """)

        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "IC 1396", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: "sessions/IC_1396/2026-08-08/lights/light1.fit",
            verdict: .undecided, logicallyExcluded: false
        ))
        try await metadata.save(FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: "sessions/IC_1396/2026-08-08/lights/light2.fit",
            verdict: .accepted, logicallyExcluded: false
        ))

        return Fixture(root: root, indexDatabase: storage.indexDatabase, metadata: metadata)
    }

    /// A single session with every frame accepted and not excluded, so its
    /// night's triage state is `.ready` -- used to prove the badge does NOT
    /// count nights that need no attention.
    private static func makeReadyFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroSidebarBadgesReady-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesReadySupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesReadyCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)

        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-09", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: "sessions/M_31/2026-08-09/lights/light1.fit",
            verdict: .accepted, logicallyExcluded: false
        ))

        return Fixture(root: root, indexDatabase: storage.indexDatabase, metadata: metadata)
    }

    /// One session, one accepted frame and one rejected frame -- zero
    /// undecided. Every frame has a verdict, so the night's triage state is
    /// `.ready` despite the rejection.
    private static func makeRejectedButDecidedFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroSidebarBadgesRejected-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesRejectedSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroSidebarBadgesRejectedCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)

        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 45", displayName: "M 45", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-10", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: "sessions/M_45/2026-08-10/lights/light1.fit",
            verdict: .accepted, logicallyExcluded: false
        ))
        try await metadata.save(FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: "sessions/M_45/2026-08-10/lights/light2.fit",
            verdict: .rejected, logicallyExcluded: true
        ))

        return Fixture(root: root, indexDatabase: storage.indexDatabase, metadata: metadata)
    }
}

private enum SidebarBadgeStoreTestFailure: Error, Equatable {
    case queryFailed
}
