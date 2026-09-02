import AstroCore
import Foundation
import Testing
@testable import AstroApplication

@Suite("Safe AstroTool library creation")
struct LibraryCreationCommandTests {
    private func makeParent() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-library-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Preview reports canonical missing paths without creating the library")
    func previewIsReadOnly() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Astro Photos", isDirectory: true)

        let preview = try LibraryCreationCommand(root: root, accessMode: .readOnly).preview()

        #expect(preview.root == root)
        #expect(preview.missingRelativePaths == WriteGuard.libraryScaffoldRelativePaths)
        #expect(preview.existingRelativePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Read-only mode refuses before creating anything")
    func readOnlyRefusesCreation() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Astro Photos", isDirectory: true)
        let command = LibraryCreationCommand(root: root, accessMode: .readOnly)

        #expect(throws: LibraryMutationError.readOnly) {
            try command.create()
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Mutation mode creates only missing paths and is idempotent")
    func createsMissingPathsIdempotently() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Astro Photos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sentinel = root.appendingPathComponent("sessions/keep.fit")
        try Data("source-owned".utf8).write(to: sentinel)
        let command = LibraryCreationCommand(root: root, accessMode: .mutationEnabled)

        let first = try command.create()
        #expect(first.existingRelativePaths == ["sessions"])
        #expect(first.createdRelativePaths == Array(WriteGuard.libraryScaffoldRelativePaths.dropFirst()))
        #expect(try Data(contentsOf: sentinel) == Data("source-owned".utf8))

        let second = try command.create()
        #expect(second.createdRelativePaths.isEmpty)
        #expect(second.existingRelativePaths == WriteGuard.libraryScaffoldRelativePaths)
        #expect(try Data(contentsOf: sentinel) == Data("source-owned".utf8))
    }

    // MARK: - v5 flow fixes, item 4: the guided first-success journey's own
    // "What will be created on my Mac?" disclosure now renders this exact
    // `preview()` call's own paths instead of three static sentences --
    // this pins down the guarantee that promise depends on: what preview()
    // lists is exactly what create() then does, for both the missing AND
    // the already-there halves.

    @Test("preview() promises exactly the paths create() then delivers, missing and already-there alike")
    func previewPromisesExactlyWhatCreateDelivers() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Astro Photos", isDirectory: true)
        // One path pre-exists, same as a real "point this at a folder I
        // already partly set up" case -- so the preview has something real
        // to report on both sides of the missing/already-there split.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("stacks", isDirectory: true),
            withIntermediateDirectories: true
        )

        let preview = try LibraryCreationCommand(root: root, accessMode: .readOnly).preview()
        let receipt = try LibraryCreationCommand(root: root, accessMode: .mutationEnabled).create()

        #expect(preview.existingRelativePaths == ["stacks"])
        #expect(receipt.existingRelativePaths == preview.existingRelativePaths)
        #expect(Set(receipt.createdRelativePaths) == Set(preview.missingRelativePaths))
        for relativePath in preview.missingRelativePaths {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        }
    }
}
