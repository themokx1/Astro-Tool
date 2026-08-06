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

    func expectDir(_ relativePath: String) {
        var isDir: ObjCBool = false
        let path = root.appendingPathComponent(relativePath).path
        #expect(fm.fileExists(atPath: path, isDirectory: &isDir), "expected directory at \(relativePath)")
        #expect(isDir.boolValue)
    }

    let sessionDir = root.appendingPathComponent("sessions/M31/2026-01-01", isDirectory: true)
    for sub in ["lights", "flats", "darks", "biases"] {
        expectDir("sessions/M31/2026-01-01/\(sub)")
    }

    let readmeURL = sessionDir.appendingPathComponent("README.txt")
    #expect(fm.fileExists(atPath: readmeURL.path))
    let contents = try String(contentsOf: readmeURL, encoding: .utf8)
    #expect(contents == "hello session")

    // Full tree per the real add_new_session.sh: stacks/<T>/<D>,
    // processed/<T>/<D>, plus the ensured calibration_library subdirs.
    expectDir("stacks/M31/2026-01-01")
    expectDir("processed/M31/2026-01-01")
    expectDir("calibration_library/darks")
    expectDir("calibration_library/flats")
    expectDir("calibration_library/biases")

    // 4 session role dirs + README + stacks date dir + processed date dir
    // + 3 calibration_library subdirs = 10.
    #expect(created.count == 10)
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

/// T6/B4's `SessionNoteStore` writes under `.astro_tool/notes/` -- no
/// `WriteGuard` change was needed for it, since `writeToolFile` already
/// allows any relative path under `toolDir`; this test pins that down
/// explicitly for the new landing spot, the same way `writeToolFileWritesUnderAstroToolDir`
/// pins it down for `reports/`.
@Test func writeToolFileAllowsSessionNotesPath() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let data = Data("Bortle: 5\n".utf8)
    let url = try guardian.writeToolFile(relativePath: "notes/M31-2026-01-01.txt", data: data)

    let expected = root.appendingPathComponent(".astro_tool/notes/M31-2026-01-01.txt")
    #expect(url.standardizedFileURL.path == expected.standardizedFileURL.path)
    #expect(try Data(contentsOf: url) == data)
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

// MARK: - linkCalibrationFile

private func inode(_ url: URL) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

@Test func linkCalibrationFileCreatesHardLinkWithSameInode() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("calibration_library/darks/300sec_-10deg", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("master_dark.fit")
    try Data("master dark content".utf8).write(to: sourceURL)

    let destURL = try guardian.linkCalibrationFile(
        sourceRelative: "calibration_library/darks/300sec_-10deg/master_dark.fit",
        destDirRelative: "sessions/T1/2026-01-10/darks"
    )

    let unwrapped = try #require(destURL)
    #expect(unwrapped.standardizedFileURL.path == root.appendingPathComponent("sessions/T1/2026-01-10/darks/master_dark.fit").standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: unwrapped.path))
    #expect(try inode(unwrapped) == inode(sourceURL))
    #expect(try Data(contentsOf: unwrapped) == Data("master dark content".utf8))
}

@Test func linkCalibrationFileReturnsNilWhenDestinationExistsAndLeavesItUntouched() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("calibration_library/biases", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("master_bias.fit")
    try Data("master bias content".utf8).write(to: sourceURL)

    let destDir = root.appendingPathComponent("sessions/T1/2026-01-10/biases", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let destURL = destDir.appendingPathComponent("master_bias.fit")
    try Data("original session content".utf8).write(to: destURL)

    let result = try guardian.linkCalibrationFile(
        sourceRelative: "calibration_library/biases/master_bias.fit",
        destDirRelative: "sessions/T1/2026-01-10/biases"
    )

    #expect(result == nil)
    #expect(try Data(contentsOf: destURL) == Data("original session content".utf8))
    #expect(try Data(contentsOf: sourceURL) == Data("master bias content".utf8))
}

@Test func linkCalibrationFileRejectsSourceOutsideCalibrationLibrary() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let strayDir = root.appendingPathComponent("sessions/x/y/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: strayDir.appendingPathComponent("a.fit"))

    #expect(throws: AstroError.self) {
        try guardian.linkCalibrationFile(
            sourceRelative: "sessions/x/y/lights/a.fit",
            destDirRelative: "sessions/x/y/darks"
        )
    }

    #expect(throws: AstroError.self) {
        try guardian.linkCalibrationFile(
            sourceRelative: "../evil",
            destDirRelative: "sessions/x/y/darks"
        )
    }
}

@Test func linkCalibrationFileRejectsDestDirOutsideAllowedPattern() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("calibration_library/darks/60sec_-10deg", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("m.fit")
    try Data("x".utf8).write(to: sourceURL)
    let sourceRelative = "calibration_library/darks/60sec_-10deg/m.fit"

    #expect(throws: AstroError.self) {
        try guardian.linkCalibrationFile(sourceRelative: sourceRelative, destDirRelative: "sessions/t/d/lights")
    }
    #expect(throws: AstroError.self) {
        try guardian.linkCalibrationFile(sourceRelative: sourceRelative, destDirRelative: "stacks/t/d/darks")
    }
    #expect(throws: AstroError.self) {
        try guardian.linkCalibrationFile(sourceRelative: sourceRelative, destDirRelative: "sessions/t/d/../../evil/darks")
    }

    // Nothing was ever created under a bogus destination.
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
}

@Test func linkCalibrationFileCreatesMissingDestDir() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("calibration_library/flats", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: sourceDir.appendingPathComponent("flat_master.fit"))

    let destURL = try guardian.linkCalibrationFile(
        sourceRelative: "calibration_library/flats/flat_master.fit",
        destDirRelative: "sessions/T1/2026-01-10/flats"
    )

    #expect(destURL != nil)
    var isDir: ObjCBool = false
    let destDirPath = root.appendingPathComponent("sessions/T1/2026-01-10/flats").path
    #expect(FileManager.default.fileExists(atPath: destDirPath, isDirectory: &isDir))
    #expect(isDir.boolValue)
}

// MARK: - linkStackListFile (R7-B4)

@Test func linkStackListFileCreatesHardLinkWithSameInode() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("sessions/T1/2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("light_0001.fit")
    try Data("light frame content".utf8).write(to: sourceURL)

    let destURL = try guardian.linkStackListFile(
        sourceRelative: "sessions/T1/2026-01-10/lights/light_0001.fit",
        destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/lights"
    )

    let unwrapped = try #require(destURL)
    #expect(
        unwrapped.standardizedFileURL.path
            == root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights/light_0001.fit").standardizedFileURL.path
    )
    #expect(FileManager.default.fileExists(atPath: unwrapped.path))
    #expect(try inode(unwrapped) == inode(sourceURL))
    #expect(try Data(contentsOf: unwrapped) == Data("light frame content".utf8))
}

@Test func linkStackListFileReturnsNilWhenDestinationExistsAndLeavesItUntouched() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("sessions/T1/2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("light_0001.fit")
    try Data("light frame content".utf8).write(to: sourceURL)

    let destDir = root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    let destURL = destDir.appendingPathComponent("light_0001.fit")
    try Data("already linked from an earlier export".utf8).write(to: destURL)

    let result = try guardian.linkStackListFile(
        sourceRelative: "sessions/T1/2026-01-10/lights/light_0001.fit",
        destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/lights"
    )

    #expect(result == nil)
    #expect(try Data(contentsOf: destURL) == Data("already linked from an earlier export".utf8))
    #expect(try Data(contentsOf: sourceURL) == Data("light frame content".utf8))
}

@Test func linkStackListFileRejectsSourceOutsideSessions() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let strayDir = root.appendingPathComponent("calibration_library/darks/300sec_-10deg", isDirectory: true)
    try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: strayDir.appendingPathComponent("master.fit"))

    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(
            sourceRelative: "calibration_library/darks/300sec_-10deg/master.fit",
            destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/lights"
        )
    }

    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(
            sourceRelative: "../evil",
            destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/lights"
        )
    }
}

@Test func linkStackListFileRejectsDestDirOutsideAllowedPattern() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("sessions/T1/2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    let sourceURL = sourceDir.appendingPathComponent("light_0001.fit")
    try Data("x".utf8).write(to: sourceURL)
    let sourceRelative = "sessions/T1/2026-01-10/lights/light_0001.fit"

    // Wrong role directory name.
    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(sourceRelative: sourceRelative, destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/rejects")
    }
    // Missing slug component entirely.
    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(sourceRelative: sourceRelative, destDirRelative: ".astro_tool/stacklists/lights")
    }
    // Outside .astro_tool altogether.
    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(sourceRelative: sourceRelative, destDirRelative: "sessions/T1/2026-01-10/lights")
    }
    // Traversal attempt inside the slug component.
    #expect(throws: AstroError.self) {
        try guardian.linkStackListFile(sourceRelative: sourceRelative, destDirRelative: ".astro_tool/stacklists/../../evil/lights")
    }

    // Nothing was ever created under a bogus destination.
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
}

@Test func linkStackListFileCreatesMissingDestDir() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let guardian = WriteGuard(root: root)

    let sourceDir = root.appendingPathComponent("sessions/T1/2026-01-10/lights", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: sourceDir.appendingPathComponent("light_0001.fit"))

    let destURL = try guardian.linkStackListFile(
        sourceRelative: "sessions/T1/2026-01-10/lights/light_0001.fit",
        destDirRelative: ".astro_tool/stacklists/T1-2026-01-10/lights"
    )

    #expect(destURL != nil)
    var isDir: ObjCBool = false
    let destDirPath = root.appendingPathComponent(".astro_tool/stacklists/T1-2026-01-10/lights").path
    #expect(FileManager.default.fileExists(atPath: destDirPath, isDirectory: &isDir))
    #expect(isDir.boolValue)
}
