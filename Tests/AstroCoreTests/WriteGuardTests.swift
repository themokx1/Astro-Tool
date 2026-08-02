import Foundation
import Testing
@testable import AstroCore

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-writeguard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func createSessionTreeCreatesExpectedSubdirsAndReadme() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardian = WriteGuard(root: root)
    let created = try guardian.createSessionTree(target: "M31", dateDir: "2026-01-01", readme: "hello session")

    let fm = FileManager.default
    let sessionDir = root.appendingPathComponent("sessions/M31/2026-01-01", isDirectory: true)
    for sub in ["lights", "flats", "darks", "biases"] {
        var isDir: ObjCBool = false
        let path = sessionDir.appendingPathComponent(sub).path
        #expect(fm.fileExists(atPath: path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    let readmeURL = sessionDir.appendingPathComponent("README.txt")
    #expect(fm.fileExists(atPath: readmeURL.path))
    let contents = try String(contentsOf: readmeURL, encoding: .utf8)
    #expect(contents == "hello session")

    #expect(created.count == 5)
    for url in created {
        #expect(fm.fileExists(atPath: url.path))
    }
}

@Test func createSessionTreeThrowsOnExistingDateDir() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let guardian = WriteGuard(root: root)
    try guardian.createSessionTree(target: "M31", dateDir: "2026-01-01", readme: "first")

    do {
        try guardian.createSessionTree(target: "M31", dateDir: "2026-01-01", readme: "second")
        Issue.record("expected writeForbidden to be thrown")
    } catch let AstroError.writeForbidden(path) {
        #expect(!path.isEmpty)
    } catch {
        Issue.record("expected AstroError.writeForbidden, got \(error)")
    }
}

@Test func createSessionTreeRejectsInvalidComponents() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    #expect(throws: AstroError.self) {
        try guardian.createSessionTree(target: "M31/evil", dateDir: "2026-01-01", readme: "x")
    }
    #expect(throws: AstroError.self) {
        try guardian.createSessionTree(target: "M31", dateDir: "..", readme: "x")
    }
    #expect(throws: AstroError.self) {
        try guardian.createSessionTree(target: "", dateDir: "2026-01-01", readme: "x")
    }
    #expect(throws: AstroError.self) {
        try guardian.createSessionTree(target: "M31", dateDir: "", readme: "x")
    }
}

@Test func writeToolFileWritesUnderAstroToolDir() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let data = Data("{\"a\":1}".utf8)
    let url = try guardian.writeToolFile(relativePath: "reports/x.json", data: data)

    let expected = root.appendingPathComponent(".astro_tool/reports/x.json")
    #expect(url.standardizedFileURL.path == expected.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == data)
}

@Test func writeToolFileAllowsOverwriteOfExistingFile() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    _ = try guardian.writeToolFile(relativePath: "state.json", data: Data("first".utf8))
    let url = try guardian.writeToolFile(relativePath: "state.json", data: Data("second".utf8))

    #expect(try Data(contentsOf: url) == Data("second".utf8))
}

@Test func writeToolFileRejectsPathTraversal() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    #expect(throws: AstroError.self) {
        try guardian.writeToolFile(relativePath: "../evil.txt", data: Data("x".utf8))
    }
    #expect(throws: AstroError.self) {
        try guardian.writeToolFile(relativePath: "reports/../../evil.txt", data: Data("x".utf8))
    }

    let evilPath = root.appendingPathComponent("evil.txt")
    #expect(!FileManager.default.fileExists(atPath: evilPath.path))
}

@Test func writeToolFileRejectsAbsolutePath() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    #expect(throws: AstroError.self) {
        try guardian.writeToolFile(relativePath: "/etc/evil.txt", data: Data("x".utf8))
    }
}

@Test func toolDirIsRootDotAstroTool() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    #expect(guardian.toolDir.standardizedFileURL.path == root.appendingPathComponent(".astro_tool").standardizedFileURL.path)
}

// MARK: - Permission errors reclassified as accessDenied

@Test func createSessionTreeThrowsAccessDeniedForReadOnlyRoot() throws {
    let root = try makeTempRoot()
    defer {
        // Restore write permission before the temp-dir cleanup, and before
        // any other test can reuse a directory that's still 555.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)

    let guardian = WriteGuard(root: root)
    do {
        try guardian.createSessionTree(target: "M31", dateDir: "2026-01-01", readme: "hello")
        Issue.record("expected AstroError.accessDenied for a read-only root")
    } catch let AstroError.accessDenied(path) {
        #expect(!path.isEmpty)
    } catch {
        Issue.record("expected AstroError.accessDenied, got \(error)")
    }
}
