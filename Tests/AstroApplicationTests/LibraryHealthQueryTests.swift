@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct LibraryHealthQueryTests {
    @Test("Health summary separates actionable calibration issues")
    func fixtureHealthSummary() async throws {
        let snapshot = try await LibraryHealthQuery.fixture().snapshot()

        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.calibrationIssues == 2)
        #expect(snapshot.items.contains { $0.category == .flat && $0.severity == .warning })
        #expect(snapshot.isReadOnly)
    }

    @Test("Production health reads the external index without touching source files")
    func productionIndexSnapshot() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroHealth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroHealthSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroHealthCaches-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: caches) }
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: storage.indexDatabase.path)
        try db.exec("CREATE TABLE files(path TEXT, target TEXT, session_date TEXT, role TEXT, area TEXT, missing INTEGER);")
        try db.exec("INSERT INTO files VALUES('light.fit','IC_1396','2026-08-08','light','sessions',0);")

        let snapshot = try await LibraryHealthQuery(indexDatabaseForTesting: storage.indexDatabase).snapshot()
        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.calibrationIssues == 1)
        #expect(snapshot.isReadOnly)
    }
}
