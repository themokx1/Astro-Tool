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

/// A lock-protected `Int` box for the `progress`/`shouldCancel` test
/// closures above -- both are `@Sendable` (matching `CaptureImportCommand
/// .copy`'s own parameter types), so a bare captured `var` cannot compile
/// even though `copy(...)` only ever calls them synchronously, one at a
/// time, from its own loop.
private final class ProcessedCountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func set(_ newValue: Int) { lock.withLock { _value = newValue } }
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

    @Test("Cancelling after the first file keeps that copy instead of discarding the whole receipt")
    func cancelAfterFirstFileKeepsAPartialReceipt() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        let firstSource = try captureImportSourceFile(named: "IMG_0001.CR3", contents: "light one")
        defer { try? FileManager.default.removeItem(at: firstSource.deletingLastPathComponent()) }
        let secondSource = try captureImportSourceFile(named: "IMG_0002.CR3", contents: "light two")
        defer { try? FileManager.default.removeItem(at: secondSource.deletingLastPathComponent()) }

        let items = [
            CaptureImportItem(sourceURL: firstSource, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 9),
            CaptureImportItem(sourceURL: secondSource, relativeSourcePath: "IMG_0002.CR3", fileName: "IMG_0002.CR3", role: .light, sizeBytes: 9),
        ]

        // Cancels once the first item has already been processed -- the
        // real shape a cooperative `Task.isCancelled` check produces: the
        // in-flight item finishes, the NEXT loop iteration sees the
        // cancellation. `copy(...)` calls both `progress`/`shouldCancel`
        // synchronously and sequentially from within its own loop (never
        // concurrently), but both closures are declared `@Sendable`, so the
        // shared counter needs a lock-protected box rather than a bare `var`.
        let processedCount = ProcessedCountBox()
        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc",
            progress: { completed, _ in processedCount.set(completed) },
            shouldCancel: { processedCount.value >= 1 }
        )

        #expect(receipt.wasCancelled)
        #expect(receipt.copied.count == 1, "the first file's verified copy must survive the cancellation, not be discarded")
        #expect(receipt.copied.first?.sourceURL == firstSource)
        #expect(receipt.failed.isEmpty)
        #expect(receipt.skippedCollisions.isEmpty)

        // The first file's copy is really on disk, not just claimed in the receipt.
        let firstDestURL = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0001.CR3")
        #expect(try String(contentsOf: firstDestURL, encoding: .utf8) == "light one")
        // The second file was never even attempted.
        let secondDestURL = root.appendingPathComponent("sessions/IC1396/2026-08-16/captures/r8-osc/lights/IMG_0002.CR3")
        #expect(!FileManager.default.fileExists(atPath: secondDestURL.path))
    }

    /// v5 flow review, I8: a `CancellationError` raised from INSIDE the loop
    /// (a hasher or a `WriteGuard` step that checks `Task.isCancelled`) used
    /// to land in the per-file catch and be recorded as a FAILED file with a
    /// Foundation "cancelled" string -- reporting the stop the user asked
    /// for as if a file had been lost.
    @Test("A CancellationError thrown by a nested step is a cancellation, not a failed file")
    func nestedCancellationErrorIsTreatedAsCancellation() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        let firstSource = try captureImportSourceFile(named: "IMG_0001.CR3", contents: "light one")
        defer { try? FileManager.default.removeItem(at: firstSource.deletingLastPathComponent()) }
        let secondSource = try captureImportSourceFile(named: "IMG_0002.CR3", contents: "light two")
        defer { try? FileManager.default.removeItem(at: secondSource.deletingLastPathComponent()) }

        let items = [
            CaptureImportItem(sourceURL: firstSource, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 9),
            CaptureImportItem(sourceURL: secondSource, relativeSourcePath: "IMG_0002.CR3", fileName: "IMG_0002.CR3", role: .light, sizeBytes: 9),
        ]

        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc",
            hash: { url in
                guard url.lastPathComponent != "IMG_0002.CR3" else { throw CancellationError() }
                return try DuplicateFinder.sha256Hash(of: url)
            }
        )

        #expect(receipt.wasCancelled)
        #expect(receipt.copied.count == 1, "everything verified before the stop still counts")
        #expect(receipt.failed.isEmpty, "a cancellation is not a failed file")
    }

    @Test("A completed (non-cancelled) copy reports wasCancelled == false")
    func completedCopyIsNotFlaggedCancelled() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")
        let source = try captureImportSourceFile(named: "IMG_0001.CR3")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let items = [CaptureImportItem(sourceURL: source, relativeSourcePath: "IMG_0001.CR3", fileName: "IMG_0001.CR3", role: .light, sizeBytes: 9)]

        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc"
        )

        #expect(!receipt.wasCancelled)
        #expect(receipt.copied.count == 1)
    }

    @Test("A failure caused by an AstroError carries it alongside a real English reason, not a raw enum dump")
    func failureCarriesAstroErrorAlongsideReadableReason() throws {
        let root = try captureImportTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDestinationCaptureTree(root: root, target: "IC1396", date: "2026-08-16", slug: "r8-osc")

        // A source URL that was never created -- `WriteGuard.copyCaptureFile`
        // throws `AstroError.pathNotFound(path:)` for exactly this shape,
        // the deterministic way to reach `copy(...)`'s generic `catch`
        // block with a real `AstroError` without racing a real file delete.
        let missingSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).cr3")
        let items = [
            CaptureImportItem(sourceURL: missingSource, relativeSourcePath: "missing.cr3", fileName: "missing.cr3", role: .light, sizeBytes: 9),
        ]

        let receipt = try CaptureImportCommand.copy(
            items: items, root: root, accessMode: .mutationEnabled, target: "IC1396", date: "2026-08-16", slug: "r8-osc"
        )

        #expect(receipt.failed.count == 1)
        let failure = try #require(receipt.failed.first)
        #expect(failure.astroError == .pathNotFound(path: missingSource.path))
        #expect(failure.reason.contains(missingSource.path))
        // W6 fix (item 6) regression: this used to be `String(describing:
        // AstroError.pathNotFound(path: "..."))`, i.e. the raw case name
        // reaching the receipt UI verbatim.
        #expect(!failure.reason.contains("pathNotFound"), "reason must be a readable sentence, not a raw enum dump")
    }

    @Test("A non-copyable role's rejection message is English source text, not the hardcoded Hungarian sentence it used to be")
    func nonCopyableRoleRejectionIsEnglish() {
        do {
            _ = try CaptureImportCommand.destinationRelativePath(
                target: "IC1396", date: "2026-08-16", slug: "r8-osc", role: .master, fileName: "master_light.fits"
            )
            Issue.record("expected destinationRelativePath to throw for a non-copyable role")
        } catch let AstroError.invalidInput(message) {
            #expect(message.contains("master"))
            #expect(message.contains("cannot be copied"))
            #expect(!message.contains("szerep"), "the role-rejection message leaked Hungarian text into the English source string")
        } catch {
            Issue.record("expected AstroError.invalidInput, got \(error)")
        }
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
