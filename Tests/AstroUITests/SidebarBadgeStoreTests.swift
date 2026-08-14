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
            healthQueryFactory: { _ in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: fixture.metadata)
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
            healthQueryFactory: { _ in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: fixture.metadata)
            }
        )

        await badges.refresh(rootURL: fixture.root, nights: nightsStore.nights)

        #expect(badges.nightsNeedingAttention == 0)
    }

    @Test("A health-query failure leaves the library badge at zero rather than crashing")
    func healthQueryFailureIsHandledGracefully() async throws {
        let fixture = try await Self.makeReadyFixture()
        let badges = SidebarBadgeStore(healthQueryFactory: { _ in throw SidebarBadgeStoreTestFailure.queryFailed })

        await badges.refresh(rootURL: fixture.root, nights: [])

        #expect(badges.libraryAttentionCount == 0)
    }

    private struct Fixture {
        let root: URL
        let indexDatabase: URL
        let metadata: MetadataStore
    }

    /// One session with a rejected frame (so its night's triage state is
    /// `.needsReview`) and no session flat/dark (so `LibraryHealthQuery`
    /// reports calibration-gap findings) -- both badge counts should be
    /// non-zero.
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
            verdict: .rejected, logicallyExcluded: true
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
}

private enum SidebarBadgeStoreTestFailure: Error, Equatable {
    case queryFailed
}
