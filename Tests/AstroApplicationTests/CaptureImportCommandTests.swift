@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func captureImportTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-import-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func captureImportSourceFile(named name: String, contents: String = "raw bytes") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-import-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

/// Builds `root/sessions/<target>/<date>/captures/<slug>/{lights,...}` via
/// the real engine (`WriteGuard`), the same destination shape
/// `SessionCreationCommand.create` would leave behind -- never a hand-rolled
/// second copy of that tree shape.
@discardableResult
private func makeDestinationCaptureTree(root: URL, target: String, date: String, slug: String) throws -> [URL] {
    let guardian = WriteGuard(root: root)
    _ = try guardian.createSessionTree(target: target, dateDir: date, readme: "x")
    return try guardian.createCaptureTree(target: target, dateDir: date, slug: slug)
}

@Suite("CaptureImportCommand")
struct CaptureImportCommandTests {
    @Test("preview computes the exact destination path per role and flags an existing file as a collision")
    func previewComputesDestinationsAndFlagsCollisions() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        let lightSource = try captureImportSourceFile(named: "IMG_0001.CR3")
        defer { try? FileManager.default.removeItem(at: lightSource.deletingLastPathComponent()) }
        let flatSource = try captureImportSourceFile(named: "flat_0001.fits")
        defer { try? FileManager.default.removeItem(at: flatSource.deletingLastPathComponent()) }

        // Pre-seed a collision: a file already at the flat's destination.
        let flatDestDir = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/flats", isDirectory: true)
        try Data("already here".utf8).write(to: flatDestDir.appendingPathComponent("flat_0001.fits"))

        let items = [
            CaptureImportItem(sourceURL: lightSource, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 9),
            CaptureImportItem(sourceURL: flatSource, relativeSourcePath: "flat_0001.fits", fileName: "flat_0001.fits", role: .flat, sizeBytes: 9),
        ]

        let preview = try CaptureImportCommand.preview(
            items: items, root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc"
        )

        #expect(preview.entries.count == 2)
        let light = try #require(preview.entries.first { $0.sourceURL == lightSource })
        #expect(light.destinationRelativePath == "sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0001.CR3")
        #expect(!light.collides)

        let flat = try #require(preview.entries.first { $0.sourceURL == flatSource })
        #expect(flat.destinationRelativePath == "sessions/IC1396/2026-08-16/captures/r8-osc/flats/flat_0001.fits")
        #expect(flat.collides)
        #expect(preview.collisionCount == 1)
        #expect(preview.totalBytesToCopy == 9, "only the non-colliding light counts toward what will actually copy")
    }

    @Test("copy refuses to write anything in read-only mode")
    func copyRefusesInReadOnlyMode() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")
        let source = try captureImportSourceFile(named: "IMG_0001.CR3")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let items = [CaptureImportItem(sourceURL: source, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 9)]

        #expect(throws: LibraryMutationError.readOnly) {
            try CaptureImportCommand.copy(
                items: items, root: root, accessMode: .readOnly, target: "IC1396", date: "2026-08-16", slug: "r8-osc"
            )
        }
        let destURL = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0001.CR3")
        #expect(!FileManager.default.fileExists(atPath: destURL.path))
    }

    @Test("copy verifies each file with a checksum and never overwrites an existing destination")
    func copyVerifiesAndSkipsCollisions() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        let lightSource = try captureImportSourceFile(named: "IMG_0001.CR3", contents: "light bytes")
        defer { try? FileManager.default.removeItem(at: lightSource.deletingLastPathComponent()) }
        let flatSource = try captureImportSourceFile(named: "flat_0001.fits", contents: "flat bytes")
        defer { try? FileManager.default.removeItem(at: flatSource.deletingLastPathComponent()) }

        let flatDestDir = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/flats", isDirectory: true)
        try Data("already here".utf8).write(to: flatDestDir.appendingPathComponent("flat_0001.fits"))

        let items = [
            CaptureImportItem(sourceURL: lightSource, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 11),
            CaptureImportItem(sourceURL: flatSource, relativeSourcePath: "flat_0001.fits", fileName: "flat_0001.fits", role: .flat, sizeBytes: 10),
        ]

        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc"
        )

        #expect(receipt.copied.count == 1)
        #expect(receipt.copied.first?.sourceURL == lightSource)
        #expect(receipt.copied.first?.sha256 == (try DuplicateFinder.sha256Hash(of: lightSource)))
        #expect(receipt.skippedCollisions == ["sessions/IC1396/2026-08-16/captures/r8-osc/flats/flat_0001.fits"])
        #expect(receipt.failed.isEmpty)

        let destURL = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0001.CR3")
        #expect(try String(contentsOf: destURL, encoding: .utf8) == "light bytes")
        // The collision was never touched.
        #expect(try String(contentsOf: flatDestDir.appendingPathComponent("flat_0001.fits"), encoding: .utf8) == "already here")
        // The source card itself is untouched.
        #expect(FileManager.default.fileExists(atPath: lightSource.path))
    }

    @Test("copy deletes and reports a copy whose checksum disagrees with the source, and keeps processing the rest")
    func copyDeletesAndReportsACorruptedCopy() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        let corruptSource = try captureImportSourceFile(named: "IMG_0001.CR3", contents: "light bytes")
        defer { try? FileManager.default.removeItem(at: corruptSource.deletingLastPathComponent()) }
        let goodSource = try captureImportSourceFile(named: "IMG_0002.CR3", contents: "more light bytes")
        defer { try? FileManager.default.removeItem(at: goodSource.deletingLastPathComponent()) }

        let items = [
            CaptureImportItem(sourceURL: corruptSource, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 11),
            CaptureImportItem(sourceURL: goodSource, relativeSourcePath: "IMG_0002.CR3", fileName: "IMG_0002.CR3", role: .light, sizeBytes: 17),
        ]

        // Injected hasher: disagrees ONLY for `corruptSource`'s own
        // destination, simulating a copy that silently corrupted in transit
        // without needing to race a real file write to prove it.
        let corruptDestinationPath = root
            .appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0001.CR3").path

        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc",
            hash: { url in
                url.path == corruptDestinationPath ? "tampered-hash" : (try DuplicateFinder.sha256Hash(of: url))
            }
        )

        #expect(receipt.copied.count == 1)
        #expect(receipt.copied.first?.sourceURL == goodSource)
        #expect(receipt.failed.count == 1)
        #expect(receipt.failed.first?.sourceURL == corruptSource)

        // The corrupted copy was deleted -- never left behind as a
        // half-trustworthy file.
        #expect(!FileManager.default.fileExists(atPath: corruptDestinationPath))
        // The good file made it through untouched.
        let goodDestURL = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0002.CR3")
        #expect(FileManager.default.fileExists(atPath: goodDestURL.path))
        // Neither source file was touched.
        #expect(FileManager.default.fileExists(atPath: corruptSource.path))
        #expect(FileManager.default.fileExists(atPath: goodSource.path))
    }

    @Test("CaptureImportItem.resolved drops files with neither an override nor a proposed role")
    func resolvedItemsDropUnclassifiedFiles() {
        let classified = DiscoveredCaptureFile(
            sourceURL: URL(fileURLWithPath: "/tmp/a.fits"), relativeSourcePath: "a.fits", fileName: "a.fits",
            ext: "fits", kind: "fits", sizeBytes: 1, proposedRole: .light, captureDate: nil, captureDateSource: nil
        )
        let unclassified = DiscoveredCaptureFile(
            sourceURL: URL(fileURLWithPath: "/tmp/b.cr3"), relativeSourcePath: "b.cr3", fileName: "b.cr3",
            ext: "cr3", kind: "raw", sizeBytes: 1, proposedRole: nil, captureDate: nil, captureDateSource: nil
        )
        let overridden = DiscoveredCaptureFile(
            sourceURL: URL(fileURLWithPath: "/tmp/c.cr3"), relativeSourcePath: "c.cr3", fileName: "c.cr3",
            ext: "cr3", kind: "raw", sizeBytes: 1, proposedRole: nil, captureDate: nil, captureDateSource: nil
        )

        let resolved = CaptureImportItem.resolved(
            from: [classified, unclassified, overridden],
            overrides: [overridden.id: .flat]
        )

        #expect(resolved.map(\.fileName).sorted() == ["a.fits", "c.cr3"])
        #expect(resolved.first { $0.fileName == "c.cr3" }?.role == .flat)
    }
}
