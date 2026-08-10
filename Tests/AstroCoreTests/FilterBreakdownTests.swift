import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-filter-breakdown-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Same shape as `StatsTests.swift`'s private `StatsFixture` (not reusable
/// across files since it's file-private there) -- a fresh fixture library +
/// fresh sqlite-backed `Database` per test.
private struct FilterFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> FilterFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return FilterFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITSLight(_ relativePath: String, exptime: Double?, filter: String?) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - Basic per-filter breakdown

@Test func breakdownGroupsUsableFramesByFilterSecondsDescending() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/ha\(i).fit", exptime: 300.0, filter: "Ha")
    }
    for i in 1...5 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/oiii\(i).fit", exptime: 300.0, filter: "OIII")
    }
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1")
    #expect(breakdown.map(\.filter) == ["OIII", "Ha"])
    #expect(breakdown.first { $0.filter == "OIII" }?.usableFrameCount == 5)
    #expect(breakdown.first { $0.filter == "OIII" }?.integrationSeconds == 1500.0)
    #expect(breakdown.first { $0.filter == "Ha" }?.usableFrameCount == 3)
    #expect(breakdown.first { $0.filter == "Ha" }?.integrationSeconds == 900.0)
}

@Test func breakdownBucketsFramesWithNoFilterHeaderUnderTheSentinelKey() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, filter: nil)
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l2.fit", exptime: 60.0, filter: nil)
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1")
    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == FilterBreakdownQueries.noFilterSentinel)
    #expect(breakdown[0].usableFrameCount == 2)
    #expect(breakdown[0].integrationSeconds == 120.0)
}

@Test func breakdownUsesCaptureGroupFilterWhenFITSHeaderHasNone() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/sv220.fit",
        exptime: 300.0,
        filter: nil
    )
    try fixture.scan()

    var group = CaptureGroupRecord(
        target: "T1",
        sessionDate: "2026-01-10",
        slug: "sv220",
        displayName: "OSC · Dual-band · SV220 · 300 s",
        sensorMode: .osc,
        signalMode: .dualBand,
        filterManufacturer: "SVBONY",
        filterModel: "SV220",
        createdAt: 1,
        updatedAt: 1
    )
    group.id = try fixture.db.upsertCaptureGroup(group)
    _ = try fixture.db.upsertCaptureSource(
        CaptureSourceRecord(
            captureGroupID: try #require(group.id),
            relativePath: "sessions/T1/2026-01-10/lights",
            role: .light
        )
    )

    let breakdown = try FilterBreakdownQueries.breakdown(
        db: fixture.db,
        config: fixture.config,
        target: "T1"
    )

    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == "SVBONY SV220")
    #expect(breakdown[0].usableFrameCount == 1)
    #expect(breakdown[0].integrationSeconds == 300.0)

    // Every user-visible roll-up must resolve the same capture snapshot;
    // otherwise the capture card and the report/table would disagree.
    let targetStats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(targetStats.filters == ["SVBONY SV220"])
    let session = try #require(try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config).first)
    #expect(session.filters == ["SVBONY SV220"])
    let night = try #require(try NightsQueries.allNights(db: fixture.db, config: fixture.config).first)
    #expect(night.filters == ["SVBONY SV220"])
    #expect(night.filterBreakdown.map(\.filter) == ["SVBONY SV220"])
}

@Test func exactFileFilterOverrideWinsOverCaptureGroupAndFITSHeader() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    let relativePath = "sessions/T1/2026-01-10/lights/frame.fit"
    try fixture.writeFITSLight(relativePath, exptime: 300, filter: "L")
    try fixture.scan()

    var group = CaptureGroupRecord(
        target: "T1", sessionDate: "2026-01-10", slug: "sv220",
        displayName: "SV220", sensorMode: .osc, signalMode: .dualBand,
        filterManufacturer: "SVBONY", filterModel: "SV220"
    )
    group.id = try fixture.db.upsertCaptureGroup(group)
    let file = try #require(try fixture.db.allFiles(includeMissing: false).first { $0.path == relativePath })
    try fixture.db.upsertFileCaptureAssignment(
        FileCaptureAssignmentRecord(
            fileID: try #require(file.id),
            captureGroupID: try #require(group.id),
            signalModeOverride: .narrowband,
            filterManufacturerOverride: "Antlia",
            filterModelOverride: "3 nm",
            filterNameOverride: "Hα"
        )
    )

    let breakdown = try FilterBreakdownQueries.breakdown(
        db: fixture.db, config: fixture.config, target: "T1"
    )
    #expect(breakdown.map(\.filter) == ["Antlia 3 nm Hα"])
}

// MARK: - Dedup (must reuse FrameSet, not reimplement it)

/// A hardlinked triage copy of the same physical exposure (same inode) must
/// count once toward `usableFrameCount`/`integrationSeconds`, exactly like
/// `StatsQueries`' own `statsDedupesHardlinkedTriageCopyCountingItOnceTowardIntegration`
/// asserts for the aggregate number -- this is the same guarantee, per filter.
@Test func breakdownDedupesHardlinkedTriageCopyCountingItOnce() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "L")
    let originalURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/l1.fit")
    let linkURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/Review/l1.fit")
    try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: originalURL, to: linkURL)

    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1")
    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == "L")
    #expect(breakdown[0].usableFrameCount == 1)
    #expect(breakdown[0].integrationSeconds == 300.0)
}

@Test func breakdownExcludesRejectedFramesFromUsableTotals() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "L")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/Reject/blurry/l2.fit", exptime: 120.0, filter: "L")
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1")
    #expect(breakdown.count == 1)
    #expect(breakdown[0].usableFrameCount == 1)
    #expect(breakdown[0].integrationSeconds == 300.0)
}

// MARK: - Excluded (_hibas) session: dropped at target level, kept per-date

@Test func breakdownDropsHibasLabeledSessionFromWholeTargetRollup() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.writeFITSLight("sessions/T1/2026-01-11/lights/l2.fit", exptime: 60.0, filter: "Ha")
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1")
    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == "Ha")
    #expect(breakdown[0].usableFrameCount == 1)
    #expect(breakdown[0].integrationSeconds == 60.0)
}

@Test func breakdownScopedToHibasDateStillReportsThatNightsOwnFrames() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.writeFITSLight("sessions/T1/2026-01-11/lights/l2.fit", exptime: 60.0, filter: "Ha")
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(
        db: fixture.db, config: fixture.config, target: "T1", date: "2026-01-10_hibas"
    )
    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == "Ha")
    #expect(breakdown[0].usableFrameCount == 1)
    #expect(breakdown[0].integrationSeconds == 300.0)
}

@Test func breakdownScopedToOneDateOnlyCountsThatSessionsFrames() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.writeFITSLight("sessions/T1/2026-01-11/lights/l2.fit", exptime: 60.0, filter: "OIII")
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(
        db: fixture.db, config: fixture.config, target: "T1", date: "2026-01-10"
    )
    #expect(breakdown.count == 1)
    #expect(breakdown[0].filter == "Ha")
    #expect(breakdown[0].integrationSeconds == 300.0)
}

@Test func breakdownReturnsEmptyForTargetWithNoUsableFrames() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "L")
    try fixture.scan()

    let breakdown = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "DoesNotExist")
    #expect(breakdown.isEmpty)
}

@Test func snapshotComputeMatchesPublicDateScopedBreakdown() throws {
    let fixture = try FilterFixture.make()
    defer { fixture.cleanup() }
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/ha.fit", exptime: 300, filter: "Ha")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/o.fit", exptime: 60, filter: "OIII")
    try fixture.scan()

    let files = try fixture.db.allFiles(includeMissing: false)
    let meta = try fixture.db.fitsMetaBatch(fileIDs: files.compactMap(\.id))
    let snapshot = FilterBreakdownQueries.compute(
        target: "T1", date: "2026-01-10", files: files, meta: meta, config: fixture.config
    )
    let queried = try FilterBreakdownQueries.breakdown(
        db: fixture.db, config: fixture.config, target: "T1", date: "2026-01-10"
    )
    #expect(snapshot == queried)
}
