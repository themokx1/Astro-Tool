import AstroCore
import CryptoKit
import Foundation
import Testing
@testable import AstroApplication

@Suite("First-success journey safety")
struct FirstSuccessJourneyTests {
    private struct ManifestEntry: Equatable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifest(of root: URL) throws -> [ManifestEntry] {
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )?.compactMap { $0 as? URL } ?? []
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            return ManifestEntry(
                path: String(url.path.dropFirst(root.path.count + 1)),
                bytes: Int64(values.fileSize ?? 0),
                sha256: try DuplicateFinder.sha256Hash(of: url)
            )
        }
        .sorted { $0.path < $1.path }
    }

    @Test("Create plus first project capture copies and verifies while source stays bit-identical")
    func fullJourneyLeavesSourceUnchanged() throws {
        let parent = try temporaryDirectory("first-success-library")
        let source = try temporaryDirectory("first-success-source")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: source)
        }
        let sourceFiles: [(String, FrameRole, String)] = [
            ("lights/light-01.fit", .light, "light pixels"),
            ("calibration/flat-01.fit", .flat, "flat pixels"),
            ("calibration/dark-01.fit", .dark, "dark pixels"),
            ("calibration/bias-01.fit", .bias, "bias pixels"),
        ]
        for (relative, _, contents) in sourceFiles {
            let url = source.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let sourceBefore = try manifest(of: source)

        let library = parent.appendingPathComponent("My Astro Library", isDirectory: true)
        _ = try LibraryCreationCommand(root: library, accessMode: .mutationEnabled).create()
        let database = try Database(path: parent.appendingPathComponent("journey.sqlite").path)
        let session = SessionCreationCommand(
            root: library,
            db: database,
            accessMode: .mutationEnabled,
            indexedFolders: []
        )
        let draft = CaptureGroupDraft(
            slug: "first-capture",
            displayName: "First capture",
            sensorMode: .osc,
            signalMode: .broadband
        )
        let receipt = try session.create(
            catalogRaw: "M31",
            nameRaw: "Andromeda Galaxy",
            date: "2026-08-20",
            catalogTarget: nil,
            capture: draft
        )
        let target = receipt.targetFolder
        let items = sourceFiles.map { relative, role, _ in
            let url = source.appendingPathComponent(relative)
            return CaptureImportItem(
                sourceURL: url,
                relativeSourcePath: relative,
                fileName: url.lastPathComponent,
                role: role,
                sizeBytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            )
        }

        let importReceipt = try CaptureImportCommand.copy(
            items: items,
            root: library,
            accessMode: .mutationEnabled,
            target: target,
            date: "2026-08-20",
            slug: "first-capture"
        )

        #expect(importReceipt.copied.count == 4)
        #expect(importReceipt.failed.isEmpty)
        #expect(importReceipt.skippedCollisions.isEmpty)
        #expect(try manifest(of: source) == sourceBefore)
        for copied in importReceipt.copied {
            #expect(copied.sha256 == (try DuplicateFinder.sha256Hash(of: copied.sourceURL)))
            #expect(copied.sha256 == (try DuplicateFinder.sha256Hash(of: copied.destinationURL)))
        }

        let second = try CaptureImportCommand.copy(
            items: items,
            root: library,
            accessMode: .mutationEnabled,
            target: target,
            date: "2026-08-20",
            slug: "first-capture"
        )
        #expect(second.copied.isEmpty)
        #expect(second.skippedCollisions.count == 4)
        #expect(try manifest(of: source) == sourceBefore)
    }

    @Test("Skipping the combined import leaves only the empty library scaffold")
    func skippedImportCreatesNoProjectNightOrCapture() throws {
        let parent = try temporaryDirectory("first-success-skip")
        defer { try? FileManager.default.removeItem(at: parent) }
        let library = parent.appendingPathComponent("Empty Library", isDirectory: true)

        _ = try LibraryCreationCommand(root: library, accessMode: .mutationEnabled).create()

        let sessions = try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("sessions").path)
        #expect(sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("sessions/M31").path))
    }

    // MARK: - v5 flow fixes, item 3: cancelling mid-import used to leave
    // real session/capture folders on disk while the completion screen said
    // "No project or capture was created". These two tests pin down the
    // ENGINE-level truth the UI-layer fix (FirstSuccessOnboardingStore
    // .createdStructure) depends on: "Create Structure" really does leave a
    // folder tree behind when the user cancels before copying, and
    // `SessionCreationCommand.undo` really does remove it again when asked.

    @Test("Cancelling the import after Create Structure leaves the created folders on disk")
    func cancelAfterCreateStructureLeavesFoldersOnDisk() throws {
        let parent = try temporaryDirectory("first-success-cancel")
        defer { try? FileManager.default.removeItem(at: parent) }
        let library = parent.appendingPathComponent("Cancel Library", isDirectory: true)
        _ = try LibraryCreationCommand(root: library, accessMode: .mutationEnabled).create()
        let database = try Database(path: parent.appendingPathComponent("cancel.sqlite").path)
        let session = SessionCreationCommand(root: library, db: database, accessMode: .mutationEnabled, indexedFolders: [])
        let draft = CaptureGroupDraft(slug: "first-capture", displayName: "First capture", sensorMode: .osc, signalMode: .broadband)

        // "Create Structure" -- the wizard's destination step -- runs and
        // succeeds, exactly as it would right before the user backs out of
        // COPYING PHOTOS (never calling `CaptureImportCommand.copy` at all).
        let receipt = try session.create(
            catalogRaw: "M31", nameRaw: "Andromeda Galaxy", date: "2026-08-20", catalogTarget: nil, capture: draft
        )

        let captureDir = library.appendingPathComponent(
            "sessions/\(receipt.targetFolder)/2026-08-20/captures/first-capture"
        )
        #expect(FileManager.default.fileExists(atPath: captureDir.path))
        for role in ["lights", "flats", "darks", "biases"] {
            #expect(FileManager.default.fileExists(atPath: captureDir.appendingPathComponent(role).path))
        }
    }

    @Test("Undoing after Create Structure removes exactly what it created, nothing more")
    func undoAfterCreateStructureRemovesTheFolders() throws {
        let parent = try temporaryDirectory("first-success-undo")
        defer { try? FileManager.default.removeItem(at: parent) }
        let library = parent.appendingPathComponent("Undo Library", isDirectory: true)
        _ = try LibraryCreationCommand(root: library, accessMode: .mutationEnabled).create()
        let database = try Database(path: parent.appendingPathComponent("undo.sqlite").path)
        let session = SessionCreationCommand(root: library, db: database, accessMode: .mutationEnabled, indexedFolders: [])
        let draft = CaptureGroupDraft(slug: "first-capture", displayName: "First capture", sensorMode: .osc, signalMode: .broadband)

        let receipt = try session.create(
            catalogRaw: "M31", nameRaw: "Andromeda Galaxy", date: "2026-08-20", catalogTarget: nil, capture: draft
        )
        let sessionDateDir = library.appendingPathComponent("sessions/\(receipt.targetFolder)/2026-08-20")
        #expect(FileManager.default.fileExists(atPath: sessionDateDir.path))

        try session.undo(receipt)

        #expect(!FileManager.default.fileExists(atPath: sessionDateDir.path))
        // `undo` only ever removes what THIS receipt's own `create()` call
        // reported as `undoableURLs` -- the date directory and everything
        // under it. The target-level folder it sat inside is not part of
        // that receipt (a second night could still be added under the same
        // target), so it is left behind, empty.
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("sessions/\(receipt.targetFolder)").path))
        let dateEntries = try FileManager.default.contentsOfDirectory(
            atPath: library.appendingPathComponent("sessions/\(receipt.targetFolder)").path
        )
        #expect(dateEntries.isEmpty)
    }
}
