import Foundation
import Testing
@testable import AstroApplication
@testable import AstroCore
@testable import AstroMobileDomain

@Test func previewPerformsNoWriteAndReturnsStablePath() throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let preview = try PortableLibraryIdentityStore().preview(root: root)
    let after = try FileManager.default.contentsOfDirectory(atPath: root.path)

    #expect(before == after)
    #expect(preview.relativePath == ".astro_tool/mobile/library-id")
    #expect(preview.alreadyExists == false)
    #expect(preview.proposedID.rawValue != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".astro_tool").path) == false)
}

@Test func loadOrCreateRequiresThePreviewedIdentityAndThenIsIdempotent() throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = PortableLibraryIdentityStore()
    let preview = try store.preview(root: root)
    let created = try store.loadOrCreate(root: root, confirmedID: preview.proposedID)
    #expect(created == preview.proposedID)

    let existing = try store.preview(root: root)
    #expect(existing.alreadyExists)
    #expect(existing.proposedID == preview.proposedID)
    #expect(throws: AstroError.self) {
        try store.loadOrCreate(root: root, confirmedID: PortableLibraryID(rawValue: UUID()))
    }
    #expect(try store.loadOrCreate(root: root, confirmedID: existing.proposedID) == preview.proposedID)
}

@Test func loadOrCreateRejectsAConfirmationThatDoesNotMatchAFreshRootPreview() throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = PortableLibraryIdentityStore()
    let preview = try store.preview(root: root)
    let unrelatedID = PortableLibraryID(rawValue: UUID())

    #expect(unrelatedID != preview.proposedID)
    #expect(throws: AstroError.self) {
        try store.loadOrCreate(root: root, confirmedID: unrelatedID)
    }
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(PortableLibraryIdentityStore.relativePath).path
    ) == false)
}

private func temporaryLibraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "astro-tool-portable-id-store-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
