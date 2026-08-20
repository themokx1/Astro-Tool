@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct V1StoreSnapshotterTests {
    @Test("Snapshot includes committed WAL rows and leaves the V1 store unchanged")
    func snapshotIncludesWALWithoutWritingSource() async throws {
        let fixture = try V1DatabaseFixture.make()
        defer { fixture.remove() }
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        let before = try V1SourceManifest.capture(directory: fixture.storeDirectory)

        let snapshot = try await V1StoreSnapshotter.snapshotReadOnly(
            sourceDirectory: fixture.storeDirectory
        )
        defer { snapshot.remove() }

        let snapshotDatabase = try SQLiteDB(readOnlyPath: snapshot.databaseURL.path)
        var tags: [String] = []
        try snapshotDatabase.query("SELECT tag FROM tags ORDER BY tag;") { row in
            if let tag = row.string(0) { tags.append(tag) }
        }
        #expect(tags == ["goal:10h"])
        #expect(try Data(contentsOf: snapshot.auxiliaryDirectory
            .appendingPathComponent("notes/IC_1396-2026-08-08.txt"))
            == Data("Bortle: 4\nSeeing: jó\n".utf8))
        #expect(try V1SourceManifest.capture(directory: fixture.storeDirectory) == before)
        #expect(!snapshot.directory.path.hasPrefix(fixture.storeDirectory.path + "/"))
    }

    @Test("Source mutation during snapshot is detected and no snapshot is returned")
    func sourceMutationIsRejected() async throws {
        let fixture = try V1DatabaseFixture.make()
        defer { fixture.remove() }
        let newNoteURL = fixture.storeDirectory.appendingPathComponent("notes/new.txt")

        await #expect(throws: V1StoreSnapshotError.sourceChanged) {
            _ = try await V1StoreSnapshotter.snapshotReadOnly(
                sourceDirectory: fixture.storeDirectory,
                beforeFinalManifest: {
                    try Data("changed\n".utf8).write(to: newNoteURL)
                }
            )
        }
    }

    @Test("Symbolic links in legacy metadata are rejected instead of followed")
    func symbolicLinkIsRejected() async throws {
        let fixture = try V1DatabaseFixture.make()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.storeDirectory.appendingPathComponent("notes/link.txt"),
            withDestinationURL: outside
        )

        await #expect(throws: V1StoreSnapshotError.symbolicLink("notes/link.txt")) {
            _ = try await V1StoreSnapshotter.snapshotReadOnly(
                sourceDirectory: fixture.storeDirectory
            )
        }
    }
}
