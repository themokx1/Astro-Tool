import Foundation
import Testing
@testable import AstroCore

private func makeQuarantineRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-quarantine-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func missingQuarantineDirectoryReportsAnEmptyState() throws {
    let root = try makeQuarantineRoot("missing")
    defer { try? FileManager.default.removeItem(at: root) }

    let state = try QuarantineSummary.inspect(root: root, config: AstroConfig())

    #expect(state == QuarantineState(fileCount: 0, batchCount: 0, totalBytes: 0, oldestBatch: nil))
}

@Test func quarantineSummaryCountsNestedFilesBatchesBytesAndOldestDate() throws {
    let root = try makeQuarantineRoot("aggregate")
    defer { try? FileManager.default.removeItem(at: root) }
    let quarantine = root.appendingPathComponent(".astro_tool/cleanup_quarantine", isDirectory: true)
    let older = quarantine.appendingPathComponent("20260102-030405/a", isDirectory: true)
    let newer = quarantine.appendingPathComponent("20260304-050607/nested/b", isDirectory: true)
    try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
    let hiddenBatch = quarantine.appendingPathComponent(".manual-batch", isDirectory: true)
    try FileManager.default.createDirectory(at: hiddenBatch, withIntermediateDirectories: true)
    try Data(repeating: 0x01, count: 12).write(to: older.appendingPathComponent("one.fit"))
    try Data(repeating: 0x02, count: 30).write(to: newer.appendingPathComponent("two.fit"))
    // Hidden residue is one of cleanup's primary inputs; quarantine totals
    // must not silently omit it.
    try Data(repeating: 0x03, count: 5).write(to: older.appendingPathComponent(".DS_Store"))

    let state = try QuarantineSummary.inspect(root: root, config: AstroConfig())

    #expect(state.fileCount == 3)
    #expect(state.batchCount == 3)
    #expect(state.totalBytes == 47)
    let calendar = Calendar(identifier: .gregorian)
    #expect(calendar.component(.year, from: try #require(state.oldestBatch)) == 2026)
    #expect(calendar.component(.month, from: try #require(state.oldestBatch)) == 1)
}

@Test func unreadableQuarantineEntryThrowsInsteadOfReportingClean() throws {
    let root = try makeQuarantineRoot("unreadable")
    defer { try? FileManager.default.removeItem(at: root) }
    let blocked = root.appendingPathComponent(
        ".astro_tool/cleanup_quarantine/20260102-030405/blocked", isDirectory: true
    )
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data([1]).write(to: blocked.appendingPathComponent("secret.fit"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

    #expect(throws: (any Error).self) {
        _ = try QuarantineSummary.inspect(root: root, config: AstroConfig())
    }
}
