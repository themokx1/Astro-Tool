import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-directorylister-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// R11 fix: `DirectoryLister.walk` used to follow directory symlinks (a
/// symlink loop -- a link back at an ancestor, or at itself -- recurses
/// forever) and let a vanished-between-list-and-stat entry's `resourceValues`
/// throw and abort the whole listing. Both are fixed the same way
/// `LibraryScanner.walk` already handles them: request `.isSymbolicLinkKey`
/// and skip symlinks before recursing, and turn a failed `resourceValues`
/// into a skip rather than a thrown error.
@Test func listDirectoriesDoesNotRecurseForeverThroughASelfReferencingSymlinkLoop() throws {
    let root = try makeTempDir("loop")
    defer { try? FileManager.default.removeItem(at: root) }

    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

    // A symlink inside `real` pointing back at `real` itself -- following it
    // would recurse forever (real/loop/loop/loop/...).
    let loopLink = real.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(atPath: loopLink.path, withDestinationPath: real.path)

    let directories = try DirectoryLister.listDirectories(root: root, config: AstroConfig())

    // Must terminate (the test itself times out / hangs if it doesn't) and
    // must never have descended into the symlink.
    #expect(directories.contains("real"))
    #expect(!directories.contains { $0.hasSuffix("loop") })
}

@Test func listDirectoriesDoesNotRecurseForeverThroughATwoHopSymlinkLoop() throws {
    let root = try makeTempDir("loop2")
    defer { try? FileManager.default.removeItem(at: root) }

    let a = root.appendingPathComponent("a", isDirectory: true)
    let b = a.appendingPathComponent("b", isDirectory: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

    // b/back-to-a -> a, a two-hop cycle: a/b/back-to-a/b/back-to-a/...
    let backLink = b.appendingPathComponent("back-to-a")
    try FileManager.default.createSymbolicLink(atPath: backLink.path, withDestinationPath: a.path)

    let directories = try DirectoryLister.listDirectories(root: root, config: AstroConfig())

    #expect(directories.contains("a"))
    #expect(directories.contains("a/b"))
    #expect(!directories.contains { $0.hasSuffix("back-to-a") })
}

@Test func listDirectoriesSkipsADanglingSymlinkInsteadOfAbortingTheWholeListing() throws {
    let root = try makeTempDir("dangling")
    defer { try? FileManager.default.removeItem(at: root) }

    let kept = root.appendingPathComponent("kept", isDirectory: true)
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)

    let dangling = root.appendingPathComponent("dangling-link")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path,
        withDestinationPath: root.appendingPathComponent("does-not-exist").path
    )

    let directories = try DirectoryLister.listDirectories(root: root, config: AstroConfig())

    #expect(directories.contains("kept"))
    #expect(!directories.contains("dangling-link"))
}
