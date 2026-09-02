@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

private func newSessionStoreTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("new-session-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func newSessionStoreDatabase(at root: URL) throws -> Database {
    try Database(path: root.appendingPathComponent("index.sqlite").path)
}

@Suite("NewSessionStore")
@MainActor
struct NewSessionStoreTests {
    @Test("A prefilled store's preview target matches the same engine call SessionCreationCommand itself uses")
    func prefilledStorePreviewMatchesCommand() throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let target = try #require(TargetCatalog.all.first { $0.designation == "IC 1396" })
        let prefill = SessionCreationPrefill(
            catalogRaw: "IC 1396", nameRaw: "Elephant's Trunk", catalogTarget: target, displayName: "Elephant's Trunk"
        )
        let store = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: prefill,
            commandFactory: { root, mode, folders in SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders) }
        )

        let command = SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: [])
        let expected = command.resolvedTargetFolder(catalogRaw: "IC 1396", nameRaw: "Elephant's Trunk", catalogTarget: target)
        #expect(store.targetFolderPreview == expected)
        #expect(store.preview?.targetFolder == expected)
    }

    /// Regression test: switching the unprefilled sheet's mode from
    /// "Existing Project" (which sets `catalogTarget`) to "Custom Target"
    /// must not leave that stale `catalogTarget` in effect -- otherwise a
    /// typed custom catalog/name would be silently ignored in favor of
    /// whichever project was picked earlier, since
    /// `SessionCreationCommand.resolvedTargetFolder` always prefers a
    /// non-nil `catalogTarget` over the raw strings.
    @Test("Switching to Custom Target after picking an existing project uses the typed fields, not the stale project")
    func switchingToCustomTargetIgnoresStaleCatalogTarget() throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let store = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil,
            commandFactory: { root, mode, folders in SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders) }
        )

        let project = ProjectRecord(id: UUID(), catalogID: "M1", displayName: "Crab Nebula", phase: .planned)
        store.selectExistingProject(project)
        #expect(store.targetFolderPreview == "M1_Crab_Nebula")

        store.usesExistingProject = false
        store.catalogRaw = "IC 1396"
        store.nameRaw = "Elephant's Trunk"
        store.refreshPreview()

        #expect(store.targetFolderPreview == Sanitizer.makeTarget(catalog: "IC 1396", name: "Elephant's Trunk"))
        #expect(store.targetFolderPreview != "M1_Crab_Nebula")
    }

    @Test("canCreate is false in read-only mode even with a valid preview")
    func canCreateFalseInReadOnlyMode() throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let store = NewSessionStore(
            rootURL: root, accessMode: .readOnly, indexedFolders: [], prefill: nil,
            commandFactory: { root, mode, folders in SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders) }
        )
        store.catalogRaw = "M1"
        store.nameRaw = "Crab Nebula"
        store.refreshPreview()

        #expect(store.preview != nil)
        #expect(!store.canCreate)
        #expect(store.disabledReasonKey != nil)
    }

    // MARK: - W3-10: captures

    @Test("A bare session (capture toggle off) creates no capture-tree paths in the preview")
    func bareSessionPreviewHasNoCapturePaths() throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let store = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil,
            commandFactory: { root, mode, folders in SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders) }
        )
        store.catalogRaw = "M1"
        store.nameRaw = "Crab Nebula"
        store.createsCapture = false
        store.refreshPreview()

        #expect(store.preview?.relativePaths.contains(where: { $0.contains("/captures/") }) == false)
        #expect(store.captureDraft == nil)
    }

    @Test("Once the session already exists, the capture toggle is forced on and cannot be turned off")
    func captureToggleForcedOnOnceSessionExists() throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let factory: NewSessionStore.CommandFactory = { root, mode, folders in
            SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders)
        }
        let store = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil, commandFactory: factory
        )
        store.catalogRaw = "M1"
        store.nameRaw = "Crab Nebula"
        store.captureDisplayName = "First capture"
        store.refreshPreview()
        _ = try SessionCreationCommand(root: root, db: db, accessMode: .mutationEnabled, indexedFolders: []).create(
            catalogRaw: "M1", nameRaw: "Crab Nebula", date: store.dateText, catalogTarget: nil,
            capture: CaptureGroupDraft(slug: "first-capture", displayName: "First capture")
        )

        // A brand-new store re-reading the same now-existing session.
        let secondStore = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil, commandFactory: factory
        )
        secondStore.catalogRaw = "M1"
        secondStore.nameRaw = "Crab Nebula"
        secondStore.dateText = store.dateText
        secondStore.createsCapture = false
        secondStore.refreshPreview()

        #expect(secondStore.preview?.sessionAlreadyExists == true)
        #expect(secondStore.preview?.existingCaptures.map(\.slug) == ["first-capture"])
        // Even with the user's own toggle off, a capture is still required
        // -- `effectiveCreatesCapture` overrides it once the session exists.
        #expect(secondStore.effectiveCreatesCapture)
        #expect(secondStore.captureDraft != nil)
    }

    @Test("The store's own create()/undo() round-trip adds a second capture to an existing session and undoes only that one")
    func storeAddsSecondCaptureAndUndoesOnlyThatOne() async throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        let factory: NewSessionStore.CommandFactory = { root, mode, folders in
            SessionCreationCommand(root: root, db: db, accessMode: mode, indexedFolders: folders)
        }
        let operationHost = OperationHost(center: OperationCenter())

        let firstStore = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil, commandFactory: factory
        )
        firstStore.catalogRaw = "M1"
        firstStore.nameRaw = "Crab Nebula"
        firstStore.captureDisplayName = "SV220 dual-band"
        firstStore.refreshPreview()
        await firstStore.create(operationHost: operationHost)
        await operationHost.settle()
        #expect(firstStore.receipt?.sessionWasCreated == true)

        let secondStore = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil, commandFactory: factory
        )
        secondStore.catalogRaw = "M1"
        secondStore.nameRaw = "Crab Nebula"
        secondStore.dateText = firstStore.dateText
        secondStore.captureDisplayName = "L-eXtreme dual-band"
        secondStore.refreshPreview()
        #expect(secondStore.preview?.sessionAlreadyExists == true)
        #expect(secondStore.preview?.existingCaptures.map(\.slug) == ["sv220_dual-band"])

        await secondStore.create(operationHost: operationHost)
        await operationHost.settle()
        #expect(secondStore.receipt?.sessionWasCreated == false)
        #expect(secondStore.receipt?.captureSlug == "l-extreme_dual-band")

        await secondStore.undo(operationHost: operationHost)
        await operationHost.settle()
        #expect(secondStore.isUndone)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/\(firstStore.dateText)/captures/l-extreme_dual-band").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/\(firstStore.dateText)/captures/sv220_dual-band/lights").path))
    }

    // MARK: - v5 flow fixes, item 2: "Create Structure" used to be able to
    // fail with zero visible feedback -- `command.create(...)`'s own
    // failure runs INSIDE `operationHost.run`'s detached task, so it was
    // only ever announced by a toast on a layer mounted behind the modal
    // wizard's sheet, never reaching this store at all.

    @Test("A failed create surfaces its failure on the store instead of leaving receipt == nil with no explanation")
    func failedCreateSurfacesCreateErrorMessage() async throws {
        let root = try newSessionStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try newSessionStoreDatabase(at: root)
        // The store itself is `.mutationEnabled` (so `canCreate` passes),
        // but the factory hands back a command permanently pinned to
        // `.readOnly` -- deterministically forcing `command.create(...)` to
        // throw `LibraryMutationError.readOnly` deep inside `operationHost
        // .run`'s own work closure, the exact failure shape this fix has to
        // surface.
        let factory: NewSessionStore.CommandFactory = { root, _, folders in
            SessionCreationCommand(root: root, db: db, accessMode: .readOnly, indexedFolders: folders)
        }
        let operationHost = OperationHost(center: OperationCenter())

        let store = NewSessionStore(
            rootURL: root, accessMode: .mutationEnabled, indexedFolders: [], prefill: nil, commandFactory: factory
        )
        store.catalogRaw = "M1"
        store.nameRaw = "Crab Nebula"
        store.refreshPreview()
        #expect(store.canCreate)

        await store.create(operationHost: operationHost)
        await operationHost.settle()

        #expect(store.receipt == nil)
        #expect(store.createErrorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula").path))

        // Editing a field again (the user trying something different)
        // clears the stale failure banner instead of leaving it stuck next
        // to a freshly recomputed preview.
        store.nameRaw = "Crab Nebula II"
        store.refreshPreview()
        #expect(store.createErrorMessage == nil)
    }

    // MARK: - v5 library-switch fixes, item 4: `createErrorMessage` was
    // added for the capture-import wizard, but `NewSessionView`'s OWN sheet
    // still relied on the `OperationHost` toast -- which renders on a layer
    // mounted BEHIND this sheet, so a failed "Create Session" looked like a
    // no-op there too. This repo has no SwiftUI rendering harness (see
    // `V2HonestSurfacesTests`' doc comment), so the view half is pinned the
    // established way: a literal source-text assertion.

    @Test("NewSessionView's own sheet renders createErrorMessage inline, next to its other validation messages")
    func newSessionViewRendersCreateErrorMessageInline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NewSessionStoreTests.swift -> AstroUITests/
            .deletingLastPathComponent() // AstroUITests -> Tests/
            .deletingLastPathComponent() // Tests -> repository root
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Library/NewSessionView.swift"),
            encoding: .utf8
        )
        // Only the VIEW half: the store half declares and assigns the
        // property and always would match a naive whole-file grep.
        let split = try #require(source.range(of: "public struct NewSessionView"))
        let viewSource = source[split.lowerBound...]
        #expect(viewSource.contains("store.createErrorMessage"))
        #expect(viewSource.contains(#"accessibilityIdentifier("v2.new-session.create-error")"#))
    }
}
