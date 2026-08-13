@testable import AstroApplication
import AstroCore
import CryptoKit
import Foundation
import Testing

struct CleanupPreviewQueryTests {
    @Test("Cleanup preview is read-only and proposes quarantine rather than deletion")
    func readOnlyQuarantinePreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let database = try Database(path: index.path)
        try database.upsertFile(FileRecord(
            path: "stacks/IC1396/process/r_light.fit", size: 1_048_576, mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other, scannedAt: 0
        ))

        let preview = try await CleanupPreviewQuery(indexDatabaseForTesting: index).snapshot()

        #expect(preview.totalBytes == 1_048_576)
        #expect(preview.groups.first?.paths == ["stacks/IC1396/process/r_light.fit"])
        #expect(preview.groups.first?.action == .quarantine)
        #expect(preview.isReadOnly)
        #expect(!preview.canApply)
    }

    @Test("canApply and isReadOnly track the supplied access mode")
    func canApplyTracksAccessMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let database = try Database(path: index.path)
        try database.upsertFile(FileRecord(
            path: "stacks/IC1396/process/r_light.fit", size: 1_048_576, mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other, scannedAt: 0
        ))

        let readOnly = try await CleanupPreviewQuery(
            indexDatabaseForTesting: index, accessMode: .readOnly
        ).snapshot()
        #expect(readOnly.isReadOnly)
        #expect(!readOnly.canApply)

        let mutationEnabled = try await CleanupPreviewQuery(
            indexDatabaseForTesting: index, accessMode: .mutationEnabled
        ).snapshot()
        #expect(!mutationEnabled.isReadOnly)
        #expect(mutationEnabled.canApply)
    }

    @Test("Building a plan for selected groups follows the quarantine destination scheme")
    func planBuildingFollowsQuarantineScheme() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Library", isDirectory: true)
        let relativePath = "stacks/IC1396/process/r_light.fit"
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data("residue bytes".utf8)
        try content.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let database = try Database(path: index.path)
        try database.upsertFile(FileRecord(
            path: relativePath, size: Int64(content.count), mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other, scannedAt: 0
        ))

        let query = CleanupPreviewQuery(
            indexDatabaseForTesting: index, rootURL: root, accessMode: .mutationEnabled
        )
        let snapshot = try await query.snapshot()
        let category = try #require(snapshot.groups.first?.category)
        let timestamp = Date(timeIntervalSince1970: 1_786_000_000)

        let plan = try query.plan(
            selecting: [category], confirmationToken: "confirm-token", timestamp: timestamp
        )

        #expect(plan.confirmationToken == "confirm-token")
        #expect(plan.totalBytes == Int64(content.count))
        let entry = try #require(plan.entries.first)
        #expect(entry.source == fileURL.standardizedFileURL)
        #expect(entry.destination.path.contains("/.astro_tool/cleanup_quarantine/"))
        #expect(entry.destination.path.hasSuffix(relativePath))
        #expect(entry.fingerprint == SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
    }

    @Test("Building a plan without a library root throws instead of returning an empty plan")
    func planBuildingRequiresLibraryRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        _ = try Database(path: index.path)

        let query = CleanupPreviewQuery(indexDatabaseForTesting: index)

        #expect(throws: CleanupPreviewError.libraryRootUnavailable) {
            try query.plan(selecting: ["anything"], confirmationToken: "confirm")
        }
    }
}
