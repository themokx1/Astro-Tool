import Foundation

struct V2FixtureLibrary {
    let container: URL
    let root: URL
    let externalFile: URL

    let exposure5: URL
    let exposure30: URL
    let exposure120: URL
    let exposure300: URL
    let nestedFile: URL

    static func make(fileManager: FileManager = .default) throws -> Self {
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("AstroToolV2Fixture-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let externalDirectory = container.appendingPathComponent("External", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: externalDirectory, withIntermediateDirectories: true)

        let exposure5 = root.appendingPathComponent("IC1396/5s.fit")
        let exposure30 = root.appendingPathComponent("IC1396/30s.fit")
        let exposure120 = root.appendingPathComponent("IC1396/120s.fit")
        let exposure300 = root.appendingPathComponent("IC1396/300s.fit")
        let nestedFile = root.appendingPathComponent("IC1396/Nested/session.txt")
        for (url, content) in [
            (exposure5, "IC1396 synthetic 5 second placeholder"),
            (exposure30, "IC1396 synthetic 30 second placeholder"),
            (exposure120, "IC1396 synthetic 120 second placeholder"),
            (exposure300, "IC1396 synthetic 300 second placeholder"),
            (nestedFile, "nested synthetic fixture"),
        ] {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        }

        let appMetadata = root.appendingPathComponent(".astro_tool/state.json")
        let backupMetadata = root.appendingPathComponent(".astro_tool_backup/state.json")
        try fileManager.createDirectory(
            at: appMetadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: backupMetadata.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("app-owned metadata".utf8).write(to: appMetadata)
        try Data("backup metadata".utf8).write(to: backupMetadata)

        let externalFile = externalDirectory.appendingPathComponent("outside.fit")
        try Data("external synthetic fixture".utf8).write(to: externalFile)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("external-link.fit"),
            withDestinationURL: externalFile
        )

        return Self(
            container: container,
            root: root,
            externalFile: externalFile,
            exposure5: exposure5,
            exposure30: exposure30,
            exposure120: exposure120,
            exposure300: exposure300,
            nestedFile: nestedFile
        )
    }

    func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: container)
    }
}
