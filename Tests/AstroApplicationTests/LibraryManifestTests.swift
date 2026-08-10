@testable import AstroApplication
import CryptoKit
import Foundation
import Testing

@Suite("Bit-exact image library manifests")
struct LibraryManifestTests {
    @Test("Repeated captures of an unchanged library are equal and Codable")
    func repeatedCaptureIsEqualAndCodable() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }

        let first = try await LibraryManifest.capture(root: fixture.root)
        let second = try await LibraryManifest.capture(root: fixture.root)

        #expect(first == second)
        let encoded = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(LibraryManifest.self, from: encoded) == first)
    }

    @Test("Content changes alter the manifest even when byte count is unchanged")
    func contentModificationChangesManifest() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let before = try await LibraryManifest.capture(root: fixture.root)
        let original = try Data(contentsOf: fixture.exposure30)
        let replacement = Data(repeating: 0x78, count: original.count)

        try replacement.write(to: fixture.exposure30)
        let after = try await LibraryManifest.capture(root: fixture.root)

        #expect(after != before)
        #expect(after.entries.first { $0.relativePath == "IC1396/30s.fit" }?.size == Int64(original.count))
        #expect(
            after.entries.first { $0.relativePath == "IC1396/30s.fit" }?.sha256
                != before.entries.first { $0.relativePath == "IC1396/30s.fit" }?.sha256
        )
    }

    @Test("Adding, removing, and renaming files alter manifest paths")
    func structuralChangesAlterManifest() async throws {
        let disk = FileManager.default
        let fixture = try V2FixtureLibrary.make(fileManager: disk)
        defer { fixture.remove(fileManager: disk) }
        let initial = try await LibraryManifest.capture(root: fixture.root)
        let added = fixture.root.appendingPathComponent("IC1396/added.fit")

        try Data("added".utf8).write(to: added)
        let afterAdd = try await LibraryManifest.capture(root: fixture.root)
        #expect(afterAdd != initial)
        #expect(afterAdd.entries.contains { $0.relativePath == "IC1396/added.fit" })

        try disk.removeItem(at: fixture.exposure5)
        let afterRemove = try await LibraryManifest.capture(root: fixture.root)
        #expect(afterRemove != afterAdd)
        #expect(!afterRemove.entries.contains { $0.relativePath == "IC1396/5s.fit" })

        let renamed = fixture.root.appendingPathComponent("IC1396/renamed.fit")
        try disk.moveItem(at: fixture.exposure120, to: renamed)
        let afterRename = try await LibraryManifest.capture(root: fixture.root)
        #expect(afterRename != afterRemove)
        #expect(!afterRename.entries.contains { $0.relativePath == "IC1396/120s.fit" })
        #expect(afterRename.entries.contains { $0.relativePath == "IC1396/renamed.fit" })
    }

    @Test("Entries use normalized root-relative paths in lexical order")
    func pathsAreNormalizedAndSorted() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }

        let manifest = try await LibraryManifest.capture(root: fixture.root)
        let paths = manifest.entries.map(\.relativePath)

        #expect(paths == paths.sorted())
        #expect(paths.allSatisfy { !$0.hasPrefix("/") && !$0.contains("//") })
        #expect(paths.contains("IC1396/Nested/session.txt"))
    }

    @Test("Exclusions match only exact top-level path components")
    func exclusionsAreExactAndTopLevel() async throws {
        let disk = FileManager.default
        let fixture = try V2FixtureLibrary.make(fileManager: disk)
        defer { fixture.remove(fileManager: disk) }
        let similarlyNamed = fixture.root.appendingPathComponent(".astro_toolbox/keep.txt")
        let nestedSameName = fixture.root.appendingPathComponent("IC1396/.astro_tool/keep.txt")
        try disk.createDirectory(at: similarlyNamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try disk.createDirectory(at: nestedSameName.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: similarlyNamed)
        try Data("keep nested".utf8).write(to: nestedSameName)

        let manifest = try await LibraryManifest.capture(
            root: fixture.root,
            exclusions: [".astro_tool", ".astro_tool_backup"]
        )
        let paths = manifest.entries.map(\.relativePath)

        #expect(!paths.contains { $0.hasPrefix(".astro_tool/") })
        #expect(!paths.contains { $0.hasPrefix(".astro_tool_backup/") })
        #expect(paths.contains(".astro_toolbox/keep.txt"))
        #expect(paths.contains("IC1396/.astro_tool/keep.txt"))
    }

    @Test("Excluding app metadata does not also exclude its backup")
    func aSingleExclusionRetainsSimilarlyNamedBackup() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }

        let manifest = try await LibraryManifest.capture(
            root: fixture.root,
            exclusions: [".astro_tool"]
        )
        let paths = manifest.entries.map(\.relativePath)

        #expect(!paths.contains(".astro_tool/state.json"))
        #expect(paths.contains(".astro_tool_backup/state.json"))
    }

    @Test("Symbolic links are ignored and never followed outside the library")
    func symlinksAreIgnored() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }

        let manifest = try await LibraryManifest.capture(root: fixture.root)

        #expect(!manifest.entries.contains { $0.relativePath == "external-link.fit" })
        #expect(!manifest.entries.contains { $0.sha256 == sha256(try! Data(contentsOf: fixture.externalFile)) })
    }

    @Test("Capture performs no writes and preserves file modification times")
    func captureIsReadOnly() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let before = try treeSnapshot(root: fixture.root)

        _ = try await LibraryManifest.capture(root: fixture.root)

        #expect(try treeSnapshot(root: fixture.root) == before)
    }

    @Test("Multi-megabyte files are hashed completely")
    func hashesMultiMegabyteFile() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let largeURL = fixture.root.appendingPathComponent("IC1396/large.fit")
        var bytes = Data(count: 5 * 1_024 * 1_024 + 17)
        bytes.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8(truncatingIfNeeded: index &* 31)
            }
        }
        try bytes.write(to: largeURL)

        let manifest = try await LibraryManifest.capture(root: fixture.root)
        let entry = try #require(manifest.entries.first { $0.relativePath == "IC1396/large.fit" })

        #expect(entry.size == Int64(bytes.count))
        #expect(entry.sha256 == sha256(bytes))
    }

    @Test("Missing, non-directory, and symbolic-link roots are typed invalid roots")
    func rejectsInvalidRoots() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }
        let missing = fixture.container.appendingPathComponent("missing")
        let file = fixture.externalFile
        let linkedRoot = fixture.container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.root)

        for invalidRoot in [missing, file, linkedRoot] {
            await #expect(throws: LibraryManifestError.invalidRoot) {
                try await LibraryManifest.capture(root: invalidRoot)
            }
        }
    }

    @Test("A file changing during capture throws a typed unstable-file error")
    func detectsUnstableFiles() async throws {
        let fixture = try V2FixtureLibrary.make()
        defer { fixture.remove() }

        await #expect(throws: LibraryManifestError.unstableFile(relativePath: "IC1396/30s.fit")) {
            try await LibraryManifest.capture(
                root: fixture.root,
                exclusions: [],
                afterHash: { relativePath, url in
                    guard relativePath == "IC1396/30s.fit" else { return }
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("changed".utf8))
                    try handle.close()
                }
            )
        }
    }

    @Test("Replacing an enumerated parent with an external symlink fails closed before hashing")
    func parentSymlinkSwapCannotEscapeRoot() async throws {
        let disk = FileManager.default
        let fixture = try V2FixtureLibrary.make(fileManager: disk)
        defer { fixture.remove(fileManager: disk) }
        let parent = fixture.root.appendingPathComponent("Race", isDirectory: true)
        let displacedParent = fixture.container.appendingPathComponent("DisplacedRace", isDirectory: true)
        let externalParent = fixture.container.appendingPathComponent("ExternalRace", isDirectory: true)
        let target = parent.appendingPathComponent("target.fit")
        let externalTarget = externalParent.appendingPathComponent("target.fit")
        try disk.createDirectory(at: parent, withIntermediateDirectories: true)
        try disk.createDirectory(at: externalParent, withIntermediateDirectories: true)
        try Data("inside library".utf8).write(to: target)
        try Data("external content must never be hashed".utf8).write(to: externalTarget)

        await #expect(throws: LibraryManifestError.unstableFile(relativePath: "Race/target.fit")) {
            try await LibraryManifest.capture(
                root: fixture.root,
                exclusions: [],
                beforeOpen: { relativePath, _ in
                    guard relativePath == "Race/target.fit" else { return }
                    try disk.moveItem(at: parent, to: displacedParent)
                    try disk.createSymbolicLink(at: parent, withDestinationURL: externalParent)
                },
                afterHash: { _, _ in }
            )
        }
    }
}

private struct SnapshotEntry: Equatable {
    let path: String
    let type: FileAttributeType
    let size: UInt64
    let modificationDate: Date?
    let sha256: String?
}

private func treeSnapshot(root: URL) throws -> [SnapshotEntry] {
    let disk = FileManager.default
    guard let enumerator = disk.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else { return [] }
    var snapshot: [SnapshotEntry] = []
    for case let url as URL in enumerator {
        let attributes = try disk.attributesOfItem(atPath: url.path)
        let type = try #require(attributes[.type] as? FileAttributeType)
        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        let contentHash: String?
        if type == .typeRegular {
            contentHash = sha256(try Data(contentsOf: url))
        } else {
            contentHash = nil
        }
        snapshot.append(SnapshotEntry(
            path: relativePath,
            type: type,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            sha256: contentHash
        ))
    }
    return snapshot.sorted { $0.path < $1.path }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
