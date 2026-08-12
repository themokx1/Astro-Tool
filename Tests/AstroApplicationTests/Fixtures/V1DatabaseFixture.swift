import AstroCore
import Foundation

struct V1DatabaseFixture {
    let root: URL
    let storeDirectory: URL
    let databaseURL: URL
    let database: SQLiteDB

    static func make() throws -> V1DatabaseFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-V1Import-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent(".astro_tool", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("conversions/conversion-1", isDirectory: true),
            withIntermediateDirectories: true
        )
        let databaseURL = store.appendingPathComponent("astrotool.sqlite")
        let database = try SQLiteDB(path: databaseURL.path)
        try database.exec("PRAGMA wal_autocheckpoint=0;")
        try database.exec("""
        CREATE TABLE schema_version(version INTEGER NOT NULL);
        INSERT INTO schema_version(version) VALUES (12);
        CREATE TABLE tags(
          id INTEGER PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL,
          session_date TEXT, tag TEXT NOT NULL
        );
        """)
        try database.run(
            "INSERT INTO tags(kind, target, session_date, tag) VALUES (?, ?, ?, ?);",
            bind: [.text("target"), .text("IC_1396"), .null, .text("goal:10h")]
        )

        try Data("Bortle: 4\nSeeing: jó\n".utf8).write(
            to: store.appendingPathComponent("notes/IC_1396-2026-08-08.txt")
        )
        try Data("{\"site\":{\"name\":\"Teszt égbolt\"}}\n".utf8).write(
            to: store.appendingPathComponent("config.json")
        )
        try Data("{\"status\":\"applied\",\"id\":\"conversion-1\"}\n".utf8).write(
            to: store.appendingPathComponent("conversions/conversion-1/receipt.json")
        )
        return V1DatabaseFixture(
            root: root,
            storeDirectory: store,
            databaseURL: databaseURL,
            database: database
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
