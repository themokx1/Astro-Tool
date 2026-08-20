import Foundation
import Testing
@testable import AstroCore

private func archiveRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-frame-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func archivePlannerPreservesClassicNestedSubpath() throws {
    let plan = try FrameArchivePlanner.plan(
        sourceRelative: "sessions/M31/2026-01-01/lights/Review/a.fit", mode: .archive
    )
    #expect(plan.destinationRelative == "sessions/M31/2026-01-01/lights/archive/Review/a.fit")
    #expect(plan.target == "M31")
    #expect(plan.date == "2026-01-01")
}

@Test func archivePlannerSupportsCaptureTreeAndRestore() throws {
    let archived = try FrameArchivePlanner.plan(
        sourceRelative: "sessions/IC_1396/2026-08-08/captures/sv220/lights/a.fit",
        mode: .archive
    )
    #expect(archived.destinationRelative == "sessions/IC_1396/2026-08-08/captures/sv220/lights/archive/a.fit")
    let restored = try FrameArchivePlanner.plan(sourceRelative: archived.destinationRelative, mode: .restore)
    #expect(restored.destinationRelative == archived.sourceRelative)
}

@Test func archivePlannerRejectsEscapeAndNonLightPaths() {
    #expect(throws: AstroError.self) {
        _ = try FrameArchivePlanner.plan(
            sourceRelative: "sessions/M31/2026-01-01/lights/../../M42/a.fit", mode: .archive
        )
    }
    #expect(throws: AstroError.self) {
        _ = try FrameArchivePlanner.plan(
            sourceRelative: "sessions/M31/2026-01-01/flats/a.fit", mode: .archive
        )
    }
}

@Test func archiveExecutorMovesFileAndPreservesDatabaseIdentityAndMetadata() throws {
    let root = try archiveRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(path: ":memory:")
    let sourcePath = "sessions/M31/2026-01-01/lights/a.fit"
    let sourceURL = root.appendingPathComponent(sourcePath)
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("raw".utf8).write(to: sourceURL)

    let fileID = try db.upsertFile(FileRecord(
        path: sourcePath, size: 3, mtime: 1, ext: "fit", kind: "fits",
        area: .sessions, target: "M31", sessionDate: "2026-01-01", role: .light,
        scannedAt: 1
    ))
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 300, filter: "Ha"))
    try db.setUserVerdict(fileID: fileID, accepted: false, source: "app")

    let plan = try FrameArchivePlanner.plan(sourceRelative: sourcePath, mode: .archive)
    let updated = try FrameArchiveExecutor.apply(plan: plan, root: root, db: db)

    #expect(updated.id == fileID)
    #expect(updated.path == plan.destinationRelative)
    #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(try Data(contentsOf: root.appendingPathComponent(plan.destinationRelative)) == Data("raw".utf8))
    #expect(try db.fitsMeta(fileID: fileID)?.exptime == 300)
    #expect(try db.userVerdict(fileID: fileID)?.accepted == false)

    let restore = try FrameArchivePlanner.plan(sourceRelative: updated.path, mode: .restore)
    let restored = try FrameArchiveExecutor.apply(plan: restore, root: root, db: db)
    #expect(restored.id == fileID)
    #expect(restored.path == sourcePath)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(try db.userVerdict(fileID: fileID)?.accepted == false)
}

@Test func archiveMoveNeverOverwritesExistingDestination() throws {
    let root = try archiveRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourcePath = "sessions/M31/2026-01-01/lights/a.fit"
    let plan = try FrameArchivePlanner.plan(sourceRelative: sourcePath, mode: .archive)
    let source = root.appendingPathComponent(sourcePath)
    let destination = root.appendingPathComponent(plan.destinationRelative)
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    try Data("keep".utf8).write(to: destination)

    #expect(throws: AstroError.self) { try WriteGuard(root: root).moveArchivedFrame(plan) }
    #expect(try Data(contentsOf: source) == Data("source".utf8))
    #expect(try Data(contentsOf: destination) == Data("keep".utf8))
}

@Test func archiveMoveRejectsDestinationSymlinkEscapingLibraryRoot() throws {
    let root = try archiveRoot()
    let outside = try archiveRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let sourcePath = "sessions/M31/2026-01-01/lights/a.fit"
    let plan = try FrameArchivePlanner.plan(sourceRelative: sourcePath, mode: .archive)
    let source = root.appendingPathComponent(sourcePath)
    let archiveLink = source.deletingLastPathComponent().appendingPathComponent("archive")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: archiveLink, withDestinationURL: outside)

    #expect(throws: AstroError.self) { try WriteGuard(root: root).moveArchivedFrame(plan) }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("a.fit").path))
}

@Test func archiveExecutorRollsFilesystemBackWhenDatabaseDestinationConflicts() throws {
    let root = try archiveRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(path: ":memory:")
    let sourcePath = "sessions/M31/2026-01-01/lights/a.fit"
    let plan = try FrameArchivePlanner.plan(sourceRelative: sourcePath, mode: .archive)
    let sourceURL = root.appendingPathComponent(sourcePath)
    let destinationURL = root.appendingPathComponent(plan.destinationRelative)
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("raw".utf8).write(to: sourceURL)

    let sourceID = try db.upsertFile(FileRecord(
        path: sourcePath, size: 3, mtime: 1, ext: "fit", kind: "fits",
        area: .sessions, target: "M31", sessionDate: "2026-01-01", role: .light, scannedAt: 1
    ))
    _ = try db.upsertFile(FileRecord(
        path: plan.destinationRelative, size: 9, mtime: 1, ext: "fit", kind: "fits",
        area: .sessions, target: "M31", sessionDate: "2026-01-01", role: .light, scannedAt: 1
    ))

    #expect(throws: AstroError.self) {
        _ = try FrameArchiveExecutor.apply(plan: plan, root: root, db: db)
    }
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(!FileManager.default.fileExists(atPath: destinationURL.deletingLastPathComponent().path))
    #expect(try db.file(path: sourcePath)?.id == sourceID)
}
