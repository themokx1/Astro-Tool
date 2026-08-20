@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters, block-pads to 2880 -- same
/// duplicated helper `ExportServiceTests`/`CalibrationQueryTests` already
/// carry their own copy of (see either's own doc comment for why).
private func nightReportQueryCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func nightReportQueryHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(nightReportQueryCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

private struct NightReportQueryFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> NightReportQueryFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-report-query-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-report-query-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return NightReportQueryFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func writeFITSLight(_ relativePath: String, exptime: Double = 300, filter: String? = nil) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        cards.append("EXPTIME =                \(exptime)")
        if let filter { cards.append("FILTER  = '\(filter)'") }
        cards.append("END")
        try nightReportQueryHeaderData(cards).write(to: url)
        return url
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

/// W5-1: pins `NightReportQuery.run`'s assembly against the exact same
/// `AstroCore` engine calls `NightReport.render`'s HTML path makes, so the
/// numbers `NightWorkspaceView`'s new Overview sections show are provably
/// the same numbers the deleted "Éjszaka-riport" HTML export would have
/// shown for the identical fixture.
@Suite("NightReportQuery")
struct NightReportQueryTests {
    @Test("Night report query assembles the same facts NightReport.render's HTML draws from")
    func matchesNightReportAssembly() throws {
        let fixture = try NightReportQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300, filter: "L-eXtreme")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/b.fit", exptime: 300, filter: "L-eXtreme")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/c.fit", exptime: 600, filter: "Ha")
        try fixture.scan()

        // The old HTML path must still render successfully against this
        // fixture -- proof the fixture is valid input for both paths.
        let html = try NightReport.render(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

        let result = try NightReportQuery(db: fixture.db, config: fixture.config).run(target: "T1", date: "2026-01-10")

        // Every field is the SAME call `NightReport.render` itself makes --
        // re-run independently here (not read back out of the query) so a
        // wiring mistake (wrong argument order, wrong date) would show up as
        // a mismatch rather than a tautology.
        let expectedSession = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
            .first { $0.dateRaw == "2026-01-10" }
        #expect(result.session == expectedSession)
        #expect(result.session.usableLightCount == 3)

        let expectedTimeline = try SessionTimeline.timeline(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
        #expect(result.timeline == expectedTimeline)

        let expectedFilters = try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1", date: "2026-01-10")
        #expect(result.filterRows == expectedFilters)
        #expect(Set(result.filterRows.map(\.filter)) == ["L-eXtreme", "Ha"])

        let expectedAdvice = try ExposureAdvisor.advise(target: "T1", db: fixture.db, config: fixture.config)
        #expect(result.advice.notAvailableReason == expectedAdvice.notAvailableReason)

        let expectedCalib = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
        #expect(result.calibration == expectedCalib)

        // Cross-checked against the artifact the old path actually produced:
        // the same usable-frame count appears in its "Összefoglaló számok".
        #expect(html.contains(">\(result.session.usableLightCount)<"))
        #expect(result.displayName == "T1")
        #expect(result.target == "T1")
    }

    // MARK: - W5-3: mixed-exposure run-suffix reconciliation
    //
    // Reproduces the exact 221-vs-151 mismatch the owner flagged live
    // against the real 2026-05-24 IC 4604 Rho Ophiuchi night: a single
    // target/calendar-night whose captures were split across two session
    // date-dirs by `SessionConversionPlanner`'s mixed-exposure fix
    // (`1e20c25`) -- `2026-05-24` (the primary session) and `2026-05-24-2`
    // (the run-suffix sibling `SessionDateParser` parses to the SAME
    // canonical `start`). Before this fix, `NightReportQuery.run(date:
    // "2026-05-24")` only ever saw the primary session's own frames; the
    // hero card (`NightsQuery`, built from the V2 metadata layer's own
    // `night_id`-keyed roll-up, which has no notion of this suffix at all)
    // summed both. This fixture is the shape of that mismatch in miniature:
    // 2 frames in the primary session, 1 in the run-suffix sibling.

    @Test("Night report query folds a mixed-exposure run-suffix sibling session into the same night's tables")
    func mergesRunSuffixSiblingSession() throws {
        let fixture = try NightReportQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-05-24/lights/a.fit", exptime: 15)
        try fixture.writeFITSLight("sessions/T1/2026-05-24/lights/b.fit", exptime: 15)
        try fixture.writeFITSLight("sessions/T1/2026-05-24-2/lights/c.fit", exptime: 30)
        try fixture.scan()

        // Ground truth: what a night-level (calendar-date, not exact
        // session_date string) roll-up would show, computed independently
        // from the same `SessionStatsQueries.sessions` list the query
        // itself reads -- never from the query's own output, so a wiring
        // mistake here would show up as a mismatch rather than a tautology.
        let allSessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
        let primary = try #require(allSessions.first { $0.dateRaw == "2026-05-24" })
        let sibling = try #require(allSessions.first { $0.dateRaw == "2026-05-24-2" })
        #expect(primary.usableLightCount == 2)
        #expect(sibling.usableLightCount == 1)
        let nightTotalUsableFrames = primary.usableLightCount + sibling.usableLightCount
        #expect(nightTotalUsableFrames == 3)

        let result = try NightReportQuery(db: fixture.db, config: fixture.config).run(target: "T1", date: "2026-05-24")

        // The mismatch this ticket exists to close: the tables' own total
        // now equals the night's real total, not just the primary
        // session's 2-frame slice.
        #expect(result.mergedSessionDates == ["2026-05-24-2"])
        #expect(result.filterRows.reduce(0) { $0 + $1.usableFrameCount } == nightTotalUsableFrames)
        #expect(result.captureGroups.reduce(0) { $0 + $1.group.usableLightCount } == nightTotalUsableFrames)

        // Each session's own implicit capture group (no explicit
        // `capture_groups` row exists in this fixture, so `CaptureQueries
        // .summarize` buckets every frame into one `isImplicit` group per
        // session -- see that type's own doc comment) shares the literal
        // `CaptureGroupSummary.id` "implicit" regardless of which session
        // it came from. Without `NightCaptureGroupRow.sessionDate`
        // namespacing its own `id`, merging two sessions' rows would
        // collide two distinct rows onto one SwiftUI identity.
        #expect(result.captureGroups.count == 2)
        #expect(Set(result.captureGroups.map(\.id)).count == 2)
        #expect(Set(result.captureGroups.map(\.sessionDate)) == ["2026-05-24", "2026-05-24-2"])

        // The exact bug shape, spelled out: had the merge never happened,
        // the tables would have shown only the primary session's 2 frames
        // against the night's real 3 -- the same unexplained-remainder
        // pattern as the live 221-vs-151 report.
        #expect(result.filterRows.reduce(0) { $0 + $1.usableFrameCount } != primary.usableLightCount)
    }

    @Test("Night report query throws for a session that was never scanned")
    func throwsForUnknownSession() throws {
        let fixture = try NightReportQueryFixture.make()
        defer { fixture.cleanup() }
        try fixture.scan()

        #expect(throws: (any Error).self) {
            _ = try NightReportQuery(db: fixture.db, config: fixture.config).run(target: "Ghost", date: "2026-01-10")
        }
    }

    // MARK: - One-letter folder drift (W3-11 carried forward)
    //
    // `ExportService.nightReport` is deleted by this ticket along with its
    // export menu item; `NightReportQuery` is what now owns this resolution,
    // so this drift coverage moves with it rather than being lost.

    private static let driftedCanonicalTarget = ProjectsQuery.canonicalFolderName(
        for: ProjectRecord(id: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", phase: .processing)
    )
    private static let driftedOnDiskTarget = "NGC_7000_North_American_Nebula"

    @Test("Night report query resolves a catalog-canonical target name that has drifted from the on-disk folder")
    func resolvesDriftedFolderName() throws {
        let fixture = try NightReportQueryFixture.make()
        defer { fixture.cleanup() }
        let onDisk = Self.driftedOnDiskTarget
        let canonical = Self.driftedCanonicalTarget
        #expect(canonical == "NGC_7000_North_America_Nebula")
        #expect(canonical != onDisk)

        try fixture.writeFITSLight("sessions/\(onDisk)/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try NightReport.render(target: onDisk, date: "2026-01-10", db: fixture.db, config: fixture.config)
        let result = try NightReportQuery(db: fixture.db, config: fixture.config).run(target: canonical, date: "2026-01-10")

        #expect(result.target == onDisk)
        #expect(expected.contains(onDisk))
    }
}
