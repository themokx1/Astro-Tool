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

    /// W7-F item 2 (2026-08-18 expert audit): `raDeg`/`decDeg` are optional
    /// -- only needed by tests that exercise `FieldGeometry.panels`'
    /// clustering (via `ProjectReportQuery.Result.panelReport`/
    /// `.panelDeficits`), same `CRVAL1`/`CRVAL2` header cards
    /// `FieldGeometryTests`' own `insertLight` writes directly to the DB
    /// rather than through a real scanned file.
    @discardableResult
    func writeFITSLight(
        _ relativePath: String, exptime: Double = 300, filter: String? = nil,
        raDeg: Double? = nil, decDeg: Double? = nil
    ) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        cards.append("EXPTIME =                \(exptime)")
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let raDeg { cards.append("CRVAL1  =              \(raDeg)") }
        if let decDeg { cards.append("CRVAL2  =              \(decDeg)") }
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

        // W6-E item 5: the Overview tab's stack summary (family count, best
        // family) reuses `ResultsQuery`'s own `StackResultGroup` grouping
        // rather than re-deriving families, so the two tabs can never
        // disagree about what a "family" is.
        let expectedGroups = try StackDiscovery.groupedStacks(target: "T1", db: fixture.db, config: fixture.config).map(StackResultGroup.init)
        #expect(result.stackGroups == expectedGroups)

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

    // MARK: - W7-F item 2: mosaic panel deficit ledger, wired end-to-end
    //
    // `MosaicBalanceTests` already pins the pure `MosaicBalance` logic
    // against bare `Panel` fixtures with no `Database` involved at all --
    // these two tests instead prove the PLUMBING: a real scanned two-panel
    // library actually produces `result.panelDeficits`/
    // `.mosaicBalanceNextAction` through `ProjectReportQuery.run`, not just
    // through hand-built `Panel` values.

    @Test("A real two-panel scan (A=5h/B=2.9h) wires panelDeficits and a mosaic-balance next action end-to-end")
    func panelDeficitsWiredThroughFromRealScan() throws {
        let fixture = try ProjectReportQueryFixture.make()
        defer { fixture.cleanup() }

        // Cluster "A" (10 deg away from "B", well past the 1deg fallback
        // join-threshold with no WCS scale on record): 3 frames x 6000s =
        // 5h, more frames than "B" so it deterministically gets label "A"
        // (FieldGeometry.panels labels by frameCount descending).
        for index in 0..<3 {
            try fixture.writeFITSLight(
                "sessions/MOS/2026-01-10/lights/a\(index).fit", exptime: 6000,
                raDeg: 10.0 + Double(index) * 0.001, decDeg: 0.0
            )
        }
        // Cluster "B": 2 frames x 5220s = 2.9h.
        for index in 0..<2 {
            try fixture.writeFITSLight(
                "sessions/MOS/2026-01-10/lights/b\(index).fit", exptime: 5220,
                raDeg: 20.0 + Double(index) * 0.001, decDeg: 0.0
            )
        }
        try fixture.scan()

        let result = try ProjectReportQuery(db: fixture.db, config: fixture.config).run(target: "MOS")

        #expect(result.panelReport.panels.count == 2)
        #expect(result.panelDeficits.count == 2)

        let deficitByLabel = Dictionary(uniqueKeysWithValues: result.panelDeficits.map { ($0.panel.label, $0.deficitSeconds) })
        #expect(deficitByLabel["A"] == 0)
        #expect(abs((deficitByLabel["B"] ?? -1) - 2.1 * 3600) < 1)

        let nextAction = try #require(result.mosaicBalanceNextAction)
        guard case let .balanceMosaicPanels(worstPanelLabel, deficitHours) = nextAction.kind else {
            Issue.record("expected .balanceMosaicPanels, got \(nextAction.kind)")
            return
        }
        #expect(worstPanelLabel == "B")
        #expect(abs(deficitHours - 2.1) < 0.01)
    }

    @Test("A real two-panel scan with balanced integration wires an empty deficit ledger and no next action")
    func balancedPanelsWireNoMosaicBalanceNextAction() throws {
        let fixture = try ProjectReportQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/BALMOS/2026-01-10/lights/a0.fit", exptime: 3000, raDeg: 10.0, decDeg: 0.0)
        try fixture.writeFITSLight("sessions/BALMOS/2026-01-10/lights/b0.fit", exptime: 3000, raDeg: 20.0, decDeg: 0.0)
        try fixture.scan()

        let result = try ProjectReportQuery(db: fixture.db, config: fixture.config).run(target: "BALMOS")

        #expect(result.panelReport.panels.count == 2)
        #expect(result.panelDeficits.allSatisfy { $0.deficitSeconds == 0 })
        #expect(result.mosaicBalanceNextAction == nil)
    }
}
