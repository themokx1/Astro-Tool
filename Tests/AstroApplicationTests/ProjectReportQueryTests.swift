@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func projectReportQueryCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func projectReportQueryHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(projectReportQueryCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

private struct ProjectReportQueryFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> ProjectReportQueryFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-report-query-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-report-query-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return ProjectReportQueryFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
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
        try projectReportQueryHeaderData(cards).write(to: url)
        return url
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

/// W5-1: pins `ProjectReportQuery.run`'s assembly against the exact same
/// `AstroCore` engine calls `TargetReport.render`'s HTML path makes, so the
/// numbers `ProjectWorkspaceView`'s Áttekintés tab shows are provably the
/// same numbers the deleted "Célpont-riport" HTML export would have shown
/// for the identical fixture.
@Suite("ProjectReportQuery")
struct ProjectReportQueryTests {
    @Test("Project report query assembles the same facts TargetReport.render's HTML draws from")
    func matchesTargetReportAssembly() throws {
        let fixture = try ProjectReportQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300, filter: "L-eXtreme")
        try fixture.writeFITSLight("sessions/T1/2026-01-11/lights/b.fit", exptime: 600, filter: "Ha")
        try fixture.scan()

        let html = try TargetReport.render(target: "T1", db: fixture.db, config: fixture.config)

        let result = try ProjectReportQuery(db: fixture.db, config: fixture.config).run(target: "T1")

        let expectedStat = try StatsQueries.target("T1", db: fixture.db, config: fixture.config)
        #expect(result.stat == expectedStat)
        #expect(result.sessions.count == 2)

        let expectedSessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
        #expect(result.sessions.map(\.session) == expectedSessions)

        for row in result.sessions {
            let expectedCalib = try SessionMatcher.match(target: "T1", date: row.session.dateRaw, db: fixture.db, config: fixture.config)
            #expect(row.calibration == expectedCalib)
        }

        let expectedFilters = FilterGoalQueries.merge(
            breakdown: try FilterBreakdownQueries.breakdown(db: fixture.db, config: fixture.config, target: "T1"),
            tags: expectedStat?.tags ?? []
        )
        #expect(result.filterRows == expectedFilters)
        #expect(Set(result.filterRows.map(\.filter)) == ["L-eXtreme", "Ha"])

        let expectedStacks = try StackDiscovery.stacks(target: "T1", db: fixture.db, config: fixture.config)
        #expect(result.stacks == expectedStacks)

        // Cross-checked against the artifact the old path actually produced.
        #expect(html.contains(String(result.stat.usableFrameCount)))
        #expect(result.target == "T1")
    }

    @Test("Project report query throws for a target with no session/stack/processed file at all")
    func throwsForUnknownTarget() throws {
        let fixture = try ProjectReportQueryFixture.make()
        defer { fixture.cleanup() }
        try fixture.scan()

        #expect(throws: (any Error).self) {
            _ = try ProjectReportQuery(db: fixture.db, config: fixture.config).run(target: "Ghost")
        }
    }

    // MARK: - One-letter folder drift (W3-11 carried forward)
    //
    // `ExportService.targetReport` is deleted by this ticket along with its
    // export menu item; `ProjectReportQuery` is what now owns this
    // resolution, so this drift coverage moves with it rather than being
    // lost.

    private static let driftedCanonicalTarget = ProjectsQuery.canonicalFolderName(
        for: ProjectRecord(id: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", phase: .processing)
    )
    private static let driftedOnDiskTarget = "NGC_7000_North_American_Nebula"

    @Test("Project report query resolves a catalog-canonical target name that has drifted from the on-disk folder")
    func resolvesDriftedFolderName() throws {
        let fixture = try ProjectReportQueryFixture.make()
        defer { fixture.cleanup() }
        let onDisk = Self.driftedOnDiskTarget
        let canonical = Self.driftedCanonicalTarget

        try fixture.writeFITSLight("sessions/\(onDisk)/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try TargetReport.render(target: onDisk, db: fixture.db, config: fixture.config)
        let result = try ProjectReportQuery(db: fixture.db, config: fixture.config).run(target: canonical)

        #expect(result.target == onDisk)
        #expect(expected.contains(onDisk))
    }
}
