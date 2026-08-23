import Foundation
import Testing
@testable import AstroCore

@Test func portableIdentityCreationNeverOverwrites() throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardrail = WriteGuard(root: root)
    let id = UUID()
    let path = try guardrail.createPortableLibraryIdentity(id.uuidString)

    #expect(path.path == root.appendingPathComponent(".astro_tool/mobile/library-id").path)
    #expect(try String(contentsOf: path, encoding: .utf8) == id.uuidString)
    #expect(throws: AstroError.self) {
        try guardrail.createPortableLibraryIdentity(UUID().uuidString)
    }
}

@Test func portableIdentityCreationRejectsMalformedAndConflictingExistingValues() throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardrail = WriteGuard(root: root)
    #expect(throws: AstroError.self) {
        try guardrail.createPortableLibraryIdentity("not-a-uuid")
    }

    let id = UUID()
    let path = try guardrail.createPortableLibraryIdentity(id.uuidString)
    let before = try Data(contentsOf: path)
    _ = try guardrail.createPortableLibraryIdentity(id.uuidString.lowercased())
    #expect(try Data(contentsOf: path) == before)
}

@Test func concurrentCreationOfTheSameIdentityReturnsTheExistingPathToEveryCaller() async throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardrail = WriteGuard(root: root)
    let id = UUID()
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<16 {
            group.addTask {
                (try? guardrail.createPortableLibraryIdentity(id.uuidString)) != nil
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    #expect(successes == 16)
}

@Test func concurrentCreationOfDifferentIdentitiesNeverOverwritesTheWinner() async throws {
    let root = try temporaryLibraryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardrail = WriteGuard(root: root)
    let ids = (0..<16).map { _ in UUID() }
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for id in ids {
            group.addTask {
                (try? guardrail.createPortableLibraryIdentity(id.uuidString)) != nil
            }
        }
        var count = 0
        for await success in group where success { count += 1 }
        return count
    }
    #expect(successes == 1)
}

private func temporaryLibraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "astro-tool-portable-id-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
