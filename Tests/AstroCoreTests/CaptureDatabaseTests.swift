import Foundation
import Testing
@testable import AstroCore

private func captureTestFile(path: String, date: String = "2026-08-08") -> FileRecord {
    FileRecord(
        path: path,
        size: 1_024,
        mtime: 1_700_000_000,
        ext: "fit",
        kind: "fits",
        area: .sessions,
        target: "IC_1396",
        sessionDate: date,
        role: .light,
        scannedAt: 1_700_000_100
    )
}

private func captureTestGroup(
    slug: String = "sv220-nb",
    name: String = "SV220 dual-band",
    date: String = "2026-08-08"
) -> CaptureGroupRecord {
    CaptureGroupRecord(
        target: "IC_1396",
        sessionDate: date,
        slug: slug,
        displayName: name,
        sensorMode: .osc,
        signalMode: .dualBand,
        filterManufacturer: "SVBONY",
        filterModel: "SV220",
        createdAt: 100,
        updatedAt: 200
    )
}

@Test func migrateV10ToV11CreatesCaptureTablesAndPreservesFiles() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v10-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v10.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.exec(Database.schemaSQLv7)
        try raw.exec(Database.schemaSQLv8)
        try raw.exec(Database.schemaSQLv9)
        try raw.exec(Database.schemaSQLv10)
        try raw.run("INSERT INTO schema_version(version) VALUES (10);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, scanned_at, missing)
            VALUES ('sessions/IC_1396/2026-08-08/lights/a.fit', 1024, 1, 'fit', 'fits', 'sessions', 'IC_1396', '2026-08-08', 'light', 2, 0);
            """
        )
    }

    let database = try Database(path: path)
    var version: Int64 = 0
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { version = $0.int64(0) ?? 0 }

    #expect(version == 11)
    #expect(try database.allFiles(includeMissing: false).count == 1)
    #expect(try database.captureGroups(target: "IC_1396", date: "2026-08-08").isEmpty)
}

@Test func upsertCaptureGroupInsertsThenUpdatesSameStableRow() throws {
    let database = try Database(path: ":memory:")
    let id = try database.upsertCaptureGroup(captureTestGroup())

    var updated = captureTestGroup(name: "SV220 köd")
    updated.notes = "Hα/OIII"
    updated.updatedAt = 300
    let updatedID = try database.upsertCaptureGroup(updated)
    let fetched = try #require(try database.captureGroup(id: id))

    #expect(updatedID == id)
    #expect(fetched.displayName == "SV220 köd")
    #expect(fetched.notes == "Hα/OIII")
    #expect(fetched.filterManufacturer == "SVBONY")
    #expect(fetched.createdAt == 100)
    #expect(fetched.updatedAt == 300)
}

@Test func captureGroupsAreScopedAndSortedByDisplayName() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertCaptureGroup(captureTestGroup(slug: "sv220", name: "SV220"))
    _ = try database.upsertCaptureGroup(captureTestGroup(slug: "osc", name: "OSC 30 s"))
    _ = try database.upsertCaptureGroup(captureTestGroup(slug: "other-night", name: "Másik", date: "2026-08-09"))

    let groups = try database.captureGroups(target: "IC_1396", date: "2026-08-08")

    #expect(groups.map(\.displayName) == ["OSC 30 s", "SV220"])
    #expect(try database.captureGroup(target: "IC_1396", date: "2026-08-08", slug: "sv220")?.displayName == "SV220")
}

@Test func captureSourceRoundTripsAndCannotBelongToTwoGroups() throws {
    let database = try Database(path: ":memory:")
    let firstID = try database.upsertCaptureGroup(captureTestGroup())
    let secondID = try database.upsertCaptureGroup(captureTestGroup(slug: "osc-30s", name: "OSC 30 s"))
    let path = "sessions/IC_1396/2026-08-08/lights_osc"

    _ = try database.upsertCaptureSource(
        CaptureSourceRecord(captureGroupID: firstID, relativePath: path, role: .light)
    )

    let sources = try database.captureSources(groupID: firstID)
    #expect(sources.count == 1)
    #expect(sources.first?.relativePath == path)
    #expect(sources.first?.role == .light)
    #expect(throws: AstroError.self) {
        try database.upsertCaptureSource(
            CaptureSourceRecord(captureGroupID: secondID, relativePath: path, role: .light)
        )
    }
}

@Test func fileCaptureAssignmentRoundTripsUpdatesAndClears() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(
        captureTestFile(path: "sessions/IC_1396/2026-08-08/lights/a.fit")
    )
    let groupID = try database.upsertCaptureGroup(captureTestGroup())

    try database.upsertFileCaptureAssignment(
        FileCaptureAssignmentRecord(
            fileID: fileID,
            captureGroupID: groupID,
            sensorModeOverride: .osc,
            signalModeOverride: .dualBand,
            filterNameOverride: "SV220",
            assignmentSource: "app",
            assignedAt: 500
        )
    )
    var fetched = try #require(try database.fileCaptureAssignment(fileID: fileID))
    #expect(fetched.filterNameOverride == "SV220")

    fetched.filterNameOverride = "SV220 7 nm"
    fetched.assignedAt = 600
    try database.upsertFileCaptureAssignment(fetched)
    #expect(try database.fileCaptureAssignment(fileID: fileID)?.filterNameOverride == "SV220 7 nm")

    try database.clearFileCaptureAssignment(fileID: fileID)
    #expect(try database.fileCaptureAssignment(fileID: fileID) == nil)
}

@Test func fileCaptureAssignmentBatchReturnsOnlyAssignedIDsAndChunks() throws {
    let database = try Database(path: ":memory:")
    let groupID = try database.upsertCaptureGroup(captureTestGroup())
    var fileIDs: [Int64] = []

    for index in 0..<1_050 {
        let id = try database.upsertFile(
            captureTestFile(path: "sessions/IC_1396/2026-08-08/lights/f\(index).fit")
        )
        fileIDs.append(id)
        if index.isMultiple(of: 2) {
            try database.upsertFileCaptureAssignment(
                FileCaptureAssignmentRecord(fileID: id, captureGroupID: groupID, assignedAt: Double(index))
            )
        }
    }

    let assignments = try database.fileCaptureAssignments(fileIDs: fileIDs)
    #expect(assignments.count == 525)
    #expect(assignments[fileIDs[0]]?.captureGroupID == groupID)
    #expect(assignments[fileIDs[1]] == nil)
    #expect(assignments[fileIDs[1_048]]?.assignedAt == 1_048)
}

@Test func deleteCaptureGroupRemovesOnlyToolMetadataAndKeepsIndexedFile() throws {
    let database = try Database(path: ":memory:")
    let filePath = "sessions/IC_1396/2026-08-08/lights/a.fit"
    let fileID = try database.upsertFile(captureTestFile(path: filePath))
    let groupID = try database.upsertCaptureGroup(captureTestGroup())
    _ = try database.upsertCaptureSource(
        CaptureSourceRecord(
            captureGroupID: groupID,
            relativePath: "sessions/IC_1396/2026-08-08/lights",
            role: .light
        )
    )
    try database.upsertFileCaptureAssignment(
        FileCaptureAssignmentRecord(fileID: fileID, captureGroupID: groupID)
    )

    try database.deleteCaptureGroup(id: groupID)

    #expect(try database.captureGroup(id: groupID) == nil)
    #expect(try database.captureSources(groupID: groupID).isEmpty)
    #expect(try database.fileCaptureAssignment(fileID: fileID) == nil)
    #expect(try database.file(path: filePath) != nil)
}
