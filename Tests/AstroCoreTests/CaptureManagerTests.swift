import Foundation
import Testing
@testable import AstroCore

private func captureManagerRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-capture-manager-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func captureManagerCreatesTreeAndDatabaseGroupForOneExistingSession() throws {
    let root = try captureManagerRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try WriteGuard(root: root).createSessionTree(
        target: "IC_1396", dateDir: "2026-08-08", readme: "keep"
    )
    let db = try Database(path: ":memory:")
    let draft = CaptureGroupDraft(
        slug: "osc-30s",
        displayName: "OSC 30 s",
        sensorMode: .osc,
        signalMode: .broadband
    )

    let result = try CaptureManager.create(
        root: root,
        db: db,
        target: "IC_1396",
        date: "2026-08-08",
        draft: draft,
        now: Date(timeIntervalSince1970: 123)
    )

    #expect(result.group.id != nil)
    #expect(result.group.createdAt == 123)
    #expect(result.createdURLs.count == 6)
    #expect(try db.captureGroup(
        target: "IC_1396", date: "2026-08-08", slug: "osc-30s"
    ) == result.group)
}

@Test func captureManagerRejectsDuplicateAndInvalidSlugWithoutChangingExistingFiles() throws {
    let root = try captureManagerRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try WriteGuard(root: root).createSessionTree(
        target: "IC_1396", dateDir: "2026-08-08", readme: "keep"
    )
    let db = try Database(path: ":memory:")
    let draft = CaptureGroupDraft(
        slug: "osc",
        displayName: "OSC",
        sensorMode: .osc,
        signalMode: .broadband
    )
    _ = try CaptureManager.create(
        root: root, db: db, target: "IC_1396", date: "2026-08-08", draft: draft
    )
    let sentinel = root.appendingPathComponent(
        "sessions/IC_1396/2026-08-08/captures/osc/lights/raw.fit"
    )
    try Data("raw".utf8).write(to: sentinel)

    #expect(throws: AstroError.self) {
        try CaptureManager.create(
            root: root, db: db, target: "IC_1396", date: "2026-08-08", draft: draft
        )
    }
    #expect(throws: AstroError.self) {
        try CaptureManager.create(
            root: root,
            db: db,
            target: "IC_1396",
            date: "2026-08-08",
            draft: CaptureGroupDraft(slug: "bad slug", displayName: "Bad")
        )
    }
    #expect(try Data(contentsOf: sentinel) == Data("raw".utf8))
    #expect(try db.captureGroups(target: "IC_1396", date: "2026-08-08").count == 1)
}
