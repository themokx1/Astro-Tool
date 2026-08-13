@testable import AstroApplication
import AstroCore
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
}
