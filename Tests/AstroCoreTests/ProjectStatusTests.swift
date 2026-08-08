import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-project-status-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database` -- mirrors
/// `StatsTests.swift`'s `StatsFixture`, kept minimal per scenario.
private struct ProjectStatusFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> ProjectStatusFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return ProjectStatusFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITSLight(_ relativePath: String, exptime: Double?, filter: String? = nil) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    func writeReadme(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "session notes\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

@Test func projectWithOnlyOutstandingFilterGoalIsCollecting() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/FilterTarget/2026-01-10/lights/ha.fit",
        exptime: 3600,
        filter: "Ha"
    )
    try fixture.writeReadme("sessions/FilterTarget/2026-01-10/README.txt")
    try fixture.scan()
    try fixture.db.addTag(TagRecord(
        kind: "target", target: "FilterTarget", sessionDate: nil, tag: "goal:Ha=6h"
    ))

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let state = try #require(projects.first { $0.target == "FilterTarget" })
    let ha = try #require(state.filterGoals.first { $0.filter == "Ha" })
    #expect(state.phase == .collecting)
    #expect(ha.missingSeconds == 18_000.0)
    #expect(state.largestFilterDeficitSeconds == 18_000.0)
    #expect(state.effectiveGoalSeconds == 21_600.0)
    #expect(state.todos.contains { $0.contains("5.0") && $0.contains("Ha") })
}

@Test func oldProjectStateJSONDefaultsFilterGoalsToEmpty() throws {
    let data = Data(#"{"target":"T1","displayName":"T1","phase":"gyujtes","usableIntegrationSeconds":0,"todos":[]}"#.utf8)
    let state = try JSONDecoder().decode(ProjectState.self, from: data)
    #expect(state.filterGoals.isEmpty)
    #expect(state.effectiveGoalSeconds == nil)
    #expect(state.largestFilterDeficitSeconds == nil)
}

// MARK: - Phase reachability

@Test func projectStatusCollectingWhenUsableBelowGoal() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 1800)
    try fixture.writeReadme("sessions/T1/2026-01-10/README.txt")
    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "target", target: "T1", sessionDate: nil, tag: "goal:6h"))

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t1 = try #require(projects.first { $0.target == "T1" })
    #expect(t1.phase == .collecting)
    #expect(t1.goalSeconds == 21600.0)
    #expect(t1.missingSeconds == 19800.0)
}

@Test func projectStatusCollectingWhenNoGoalNoStackAndBelowDefaultThreshold() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    // 30 min, well under the 2h default collecting threshold, no stack.
    try fixture.writeFITSLight("sessions/T2/2026-01-10/lights/l1.fit", exptime: 1800)
    try fixture.writeReadme("sessions/T2/2026-01-10/README.txt")
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t2 = try #require(projects.first { $0.target == "T2" })
    #expect(t2.phase == .collecting)
    #expect(t2.goalSeconds == nil)
    #expect(t2.missingSeconds == nil)
}

@Test func projectStatusReadyToStackWhenSessionUncoveredAndNoGoal() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    // Above the default 2h collecting threshold and no goal -> data
    // collection looks done for now, but nothing has been stacked.
    try fixture.writeFITSLight("sessions/T3/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/T3/2026-01-10/README.txt")
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t3 = try #require(projects.first { $0.target == "T3" })
    #expect(t3.phase == .readyToStack)
    #expect(t3.todos.contains("készíts stacket: T3/2026-01-10"))
}

@Test func projectStatusStackedWhenStackCoversSessionButNoProcessed() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T4/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/T4/2026-01-10/README.txt")
    try fixture.writeFITSLight("stacks/T4/2026-01-10/stack.fit", exptime: nil)
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t4 = try #require(projects.first { $0.target == "T4" })
    #expect(t4.phase == .stacked)
    #expect(t4.todos.contains("dolgozd fel: stacks/T4/2026-01-10"))
}

@Test func projectStatusDoneWhenProcessedCoversStackCoversSession() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T5/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/T5/2026-01-10/README.txt")
    try fixture.writeFITSLight("stacks/T5/2026-01-10/stack.fit", exptime: nil)
    try fixture.writeReadme("processed/T5/2026-01-10/final.txt")
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t5 = try #require(projects.first { $0.target == "T5" })
    #expect(t5.phase == .done)
    #expect(t5.latestSessionDate == "2026-01-10")
    #expect(t5.latestStackDate == "2026-01-10")
    #expect(t5.latestProcessedDate == "2026-01-10")
}

// MARK: - R8-1: StackDiscovery stack-evidence union

@Test func projectStatusCountsDiscoveredStackOutsideStacksAreaAsStackEvidence() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T9/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/T9/2026-01-10/README.txt")
    // A finished (ASIAIR-named) stack sitting loose in the session's own
    // folder -- NOT under stacks/T9/2026-01-10/ at all. A plain
    // `area == .stacks` scan would never see this; `StackDiscovery` finds
    // it by filename alone, and `ProjectStatusQueries` must union its date
    // into stack-evidence so T9 doesn't stay stuck in "stackelheto".
    try fixture.writeFITSLight("sessions/T9/2026-01-10/T9_050x60sec_3000s_result.fit", exptime: nil)
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t9 = try #require(projects.first { $0.target == "T9" })
    #expect(t9.phase == .stacked)
    #expect(t9.latestStackDate == "2026-01-10")
    #expect(!t9.todos.contains { $0.hasPrefix("készíts stacket") })
}

// MARK: - _hibas exclusion

@Test func projectStatusIgnoresHibasSessionInPhaseButMentionsItInTodos() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    // Real session fully processed -> would be "done" on its own.
    try fixture.writeFITSLight("sessions/T6/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/T6/2026-01-10/README.txt")
    try fixture.writeFITSLight("stacks/T6/2026-01-10/stack.fit", exptime: nil)
    try fixture.writeReadme("processed/T6/2026-01-10/final.txt")
    // A later _hibas night that was thrown out -- should NOT drag the
    // target back into "readyToStack"/"collecting", and should NOT itself
    // need a stack/readme todo, but should still show up as excluded.
    try fixture.writeFITSLight("sessions/T6/2026-02-01-hibas/lights/l2.fit", exptime: 3600)
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t6 = try #require(projects.first { $0.target == "T6" })
    #expect(t6.phase == .done)
    #expect(!t6.todos.contains { $0.contains("2026-02-01-hibas") && $0.hasPrefix("készíts stacket") })
    #expect(t6.todos.contains("kizárt session: 2026-02-01-hibas (hibas)"))
}

// MARK: - Todo strings

@Test func projectStatusTodoTextForMissingReadme() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    // No README written for this session.
    try fixture.writeFITSLight("sessions/T7/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.scan()

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t7 = try #require(projects.first { $0.target == "T7" })
    #expect(t7.todos.contains("nincs README: T7/2026-01-10"))
}

@Test func projectStatusTodoTextForMissingGoalHours() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T8/2026-01-10/lights/l1.fit", exptime: 3600 * 2)
    try fixture.writeReadme("sessions/T8/2026-01-10/README.txt")
    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "target", target: "T8", sessionDate: nil, tag: "goal:6h"))

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let t8 = try #require(projects.first { $0.target == "T8" })
    #expect(t8.todos.contains("hiányzik még 4.0 óra a célhoz (goal:6h)"))
}

// MARK: - Sort order

@Test func projectStatusSortsActionableBeforeDoneThenByMissingHoursDescending() throws {
    let fixture = try ProjectStatusFixture.make()
    defer { fixture.cleanup() }

    // "Done" target -- should sort last.
    try fixture.writeFITSLight("sessions/A_Done/2026-01-10/lights/l1.fit", exptime: 3600 * 3)
    try fixture.writeReadme("sessions/A_Done/2026-01-10/README.txt")
    try fixture.writeFITSLight("stacks/A_Done/2026-01-10/stack.fit", exptime: nil)
    try fixture.writeReadme("processed/A_Done/2026-01-10/final.txt")

    // Collecting, 5h missing.
    try fixture.writeFITSLight("sessions/B_BigGap/2026-01-10/lights/l1.fit", exptime: 3600)
    try fixture.writeReadme("sessions/B_BigGap/2026-01-10/README.txt")

    // Collecting, 1h missing.
    try fixture.writeFITSLight("sessions/C_SmallGap/2026-01-10/lights/l1.fit", exptime: 3600 * 5)
    try fixture.writeReadme("sessions/C_SmallGap/2026-01-10/README.txt")

    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "target", target: "B_BigGap", sessionDate: nil, tag: "goal:6h"))
    try fixture.db.addTag(TagRecord(kind: "target", target: "C_SmallGap", sessionDate: nil, tag: "goal:6h"))

    let projects = try ProjectStatusQueries.projects(db: fixture.db, config: fixture.config)
    let names = projects.map(\.target)
    let doneIndex = try #require(names.firstIndex(of: "A_Done"))
    let bigGapIndex = try #require(names.firstIndex(of: "B_BigGap"))
    let smallGapIndex = try #require(names.firstIndex(of: "C_SmallGap"))

    #expect(bigGapIndex < smallGapIndex)
    #expect(smallGapIndex < doneIndex)
}
