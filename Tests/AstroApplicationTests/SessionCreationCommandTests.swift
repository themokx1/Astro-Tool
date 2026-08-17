@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func sessionCreationTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-creation-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// One shared on-disk `Database` per test root -- mirrors
/// `SessionConversionCommandTests`' own fixture: multiple `SessionCreationCommand`
/// instances (different `accessMode`s) in the same test must see the SAME
/// capture-group rows, the way two V2 windows against the same open library
/// would.
private func sessionCreationDatabase(at root: URL) throws -> Database {
    try Database(path: root.appendingPathComponent("index.sqlite").path)
}

@Suite("SessionCreationCommand")
struct SessionCreationCommandTests {
    @Test("Preview in read-only mode is still available and matches what create() would produce")
    func previewIsAvailableReadOnlyAndMatchesCreate() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let readOnly = SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: [])

        let preview = try readOnly.preview(
            catalogRaw: "IC 1396", nameRaw: "Elephant's Trunk", date: "2026-08-11", catalogTarget: nil, capture: nil
        )
        #expect(preview.targetFolder == "IC_1396_Elephants_Trunk")
        #expect(!preview.sessionAlreadyExists)
        #expect(preview.existingCaptures.isEmpty)
        #expect(preview.relativePaths.contains("sessions/IC_1396_Elephants_Trunk/2026-08-11/lights"))
        #expect(preview.relativePaths.contains("sessions/IC_1396_Elephants_Trunk/2026-08-11/README.txt"))
        #expect(preview.relativePaths.contains("stacks/IC_1396_Elephants_Trunk/2026-08-11"))
        #expect(preview.relativePaths.contains("processed/IC_1396_Elephants_Trunk/2026-08-11"))

        // Same engine, actually applied through a writable command -- the
        // preview above must have described exactly this.
        let writable = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let receipt = try writable.create(
            catalogRaw: "IC 1396", nameRaw: "Elephant's Trunk", date: "2026-08-11", catalogTarget: nil, capture: nil
        )
        #expect(receipt.targetFolder == preview.targetFolder)
        #expect(receipt.sessionWasCreated)
        #expect(receipt.captureGroupID == nil)
        for relativePath in preview.relativePaths {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        }

        let secondPreview = try readOnly.preview(
            catalogRaw: "IC 1396", nameRaw: "Elephant's Trunk", date: "2026-08-11", catalogTarget: nil, capture: nil
        )
        #expect(secondPreview.sessionAlreadyExists)
    }

    @Test("create() in read-only mode throws before touching disk")
    func createReadOnlyThrowsBeforeTouchingDisk() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: [])

        #expect(throws: LibraryMutationError.readOnly) {
            _ = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions").path))
    }

    @Test("undo() removes exactly the empty session it created, never calibration_library")
    func undoRemovesEmptySessionButNotCalibrationLibrary() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let receipt = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)

        try command.undo(receipt)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("stacks/M1_Crab_Nebula/2026-08-11").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("processed/M1_Crab_Nebula/2026-08-11").path))
        // Shared library scaffolding must survive undo untouched.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("calibration_library/darks").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("calibration_library/flats").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("calibration_library/biases").path))
    }

    @Test("undo() refuses once a light frame lands in the session, and removes nothing")
    func undoRefusesOnceContentArrives() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let receipt = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)

        let lightsDir = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/lights")
        try Data("not a real FITS file".utf8).write(to: lightsDir.appendingPathComponent("light1.fit"))

        #expect(throws: SessionCreationUndoError.self) {
            try command.undo(receipt)
        }
        // Refusing must not have removed anything else either -- the whole
        // check runs before any removal.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/flats").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/README.txt").path))
    }

    @Test("undo() refuses once the README has been edited by the user")
    func undoRefusesOnceReadmeIsEdited() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let receipt = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)

        let readmeURL = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/README.txt")
        try Data("edited by the user\n".utf8).write(to: readmeURL)

        #expect(throws: SessionCreationUndoError.self) {
            try command.undo(receipt)
        }
        #expect(FileManager.default.fileExists(atPath: readmeURL.path))
    }

    @Test("undo() in read-only mode throws before touching disk")
    func undoReadOnlyThrowsBeforeTouchingDisk() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let writable = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let receipt = try writable.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)

        let readOnly = SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: [])
        #expect(throws: LibraryMutationError.readOnly) {
            try readOnly.undo(receipt)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11").path))
    }

    @Test("preview() surfaces the same AstroError.invalidInput create() would for an empty-after-sanitize target")
    func previewSurfacesInvalidInputForEmptyTarget() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: [])

        #expect(throws: AstroError.self) {
            _ = try command.preview(catalogRaw: "!!!", nameRaw: "///", date: "2026-08-11", catalogTarget: nil, capture: nil)
        }
    }

    @Test("preview() surfaces the same AstroError.invalidInput create() would for a non-canonical date")
    func previewSurfacesInvalidInputForBadDate() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: [])

        #expect(throws: AstroError.self) {
            _ = try command.preview(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11-2", catalogTarget: nil, capture: nil)
        }
    }

    // MARK: - W3-10: captures

    private func makeDraft(slug: String, filterModel: String) -> CaptureGroupDraft {
        CaptureGroupDraft(
            slug: slug, displayName: "\(filterModel) capture", sensorMode: .osc, signalMode: .dualBand,
            filterManufacturer: "SVBONY", filterModel: filterModel
        )
    }

    @Test("A brand-new session can be created with an initial capture, at the engine's own capture path")
    func createsNewSessionWithInitialCapture() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let draft = makeDraft(slug: "sv220-nb", filterModel: "SV220")

        let preview = try command.preview(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: draft
        )
        #expect(preview.relativePaths.contains("sessions/M1_Crab_Nebula/2026-08-11/captures/sv220-nb/lights"))

        let receipt = try command.create(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: draft
        )
        #expect(receipt.sessionWasCreated)
        #expect(receipt.captureGroupID != nil)
        #expect(receipt.captureSlug == "sv220-nb")
        for relativePath in preview.relativePaths {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        }
        #expect(try db.captureGroups(target: "M1_Crab_Nebula", date: "2026-08-11").map(\.slug) == ["sv220-nb"])
    }

    /// The owner-stated core scenario: a night with 2-3 captures under
    /// different filters. Adding the second capture to the same night must
    /// not fail on "folder already exists" and must not duplicate the
    /// session skeleton (no second README, no second `lights/` at the
    /// session level).
    @Test("Two captures the same night, different filters, both created with no collision")
    func twoCapturesSameNightDifferentFiltersBothCreated() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let first = makeDraft(slug: "sv220-nb", filterModel: "SV220")

        let firstReceipt = try command.create(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: first
        )
        #expect(firstReceipt.sessionWasCreated)

        // The session date directory now exists -- preview must reflect
        // that a second capture is the only valid next step, and list
        // exactly what's already there.
        let midPreview = try command.preview(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil
        )
        #expect(midPreview.sessionAlreadyExists)
        #expect(midPreview.existingCaptures.map(\.slug) == ["sv220-nb"])
        #expect(midPreview.relativePaths.isEmpty)

        let second = makeDraft(slug: "l-extreme", filterModel: "L-eXtreme")
        let secondPreview = try command.preview(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: second
        )
        #expect(secondPreview.relativePaths.contains("sessions/M1_Crab_Nebula/2026-08-11/captures/l-extreme/lights"))
        // No "already exists" collision, and no re-attempt at the classic
        // session-level lights/README -- the base session isn't part of
        // this preview at all.
        #expect(!secondPreview.relativePaths.contains(where: { $0.hasSuffix("README.txt") }))

        let secondReceipt = try command.create(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: second
        )
        #expect(!secondReceipt.sessionWasCreated)
        #expect(secondReceipt.captureGroupID != nil)
        #expect(secondReceipt.captureGroupID != firstReceipt.captureGroupID)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/captures/sv220-nb/lights").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/captures/l-extreme/lights").path))
        // Exactly one classic session-level README -- never duplicated.
        let readmeCount = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11").path))?
            .filter { $0 == "README.txt" }.count ?? 0
        #expect(readmeCount == 1)

        let groups = try db.captureGroups(target: "M1_Crab_Nebula", date: "2026-08-11")
        #expect(Set(groups.map(\.slug)) == Set(["sv220-nb", "l-extreme"]))
    }

    @Test("create() without a capture for an already-existing session throws AstroError.invalidInput")
    func createWithoutCaptureForExistingSessionThrows() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        _ = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)

        #expect(throws: AstroError.self) {
            _ = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: nil)
        }
    }

    @Test("undo() of a capture added to an existing session removes only that capture, not the session or sibling captures")
    func undoCaptureOnlyRemovesThatCapture() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let first = makeDraft(slug: "sv220-nb", filterModel: "SV220")
        _ = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: first)

        let second = makeDraft(slug: "l-extreme", filterModel: "L-eXtreme")
        let secondReceipt = try command.create(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: second
        )

        try command.undo(secondReceipt)

        let fm = FileManager.default
        // The undone capture is gone...
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/captures/l-extreme").path))
        // ...but the session, its README, and the FIRST capture survive.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/README.txt").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/captures/sv220-nb/lights").path))
        // The shared `captures/` parent survives too (still holds the first
        // capture) -- never forced empty just because one sibling was
        // removed.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/captures").path))

        let remaining = try db.captureGroups(target: "M1_Crab_Nebula", date: "2026-08-11")
        #expect(remaining.map(\.slug) == ["sv220-nb"])
    }

    @Test("undo() of the only capture in a session also removes the now-empty captures/ parent")
    func undoOfOnlyCaptureRemovesEmptyCapturesParent() throws {
        let root = try sessionCreationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try sessionCreationDatabase(at: root)
        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let draft = makeDraft(slug: "sv220-nb", filterModel: "SV220")
        let receipt = try command.create(catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11", catalogTarget: nil, capture: draft)

        try command.undo(receipt)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11").path))
        #expect(try db.captureGroups(target: "M1_Crab_Nebula", date: "2026-08-11").isEmpty)
    }
}
