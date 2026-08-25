import Foundation
import Testing
@testable import AstroUI
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Suite("V5 Mac mobile sync store")
@MainActor
struct MobileSyncStoreTests {
    @Test("Preview is read-only until identity and exact summary are confirmed")
    func previewRequiresBothConfirmations() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: identity,
            snapshotID: UUID(),
            revision: 4,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [], nights: [], captures: [], briefings: [], notes: []
        )
        let writes = WriteCounter()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: identity, relativePath: ".astro_tool/mobile/library-id", alreadyExists: false) },
            identityCommit: { _, _ in writes.value += 1; return identity },
            snapshotProvider: { _, _ in snapshot },
            packageExport: { _, _, _ in MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 12) }
        )

        await store.preview()
        #expect(store.phase == .ready)
        #expect(writes.value == 0)
        #expect(!store.canExport)

        store.confirmIdentity(identity)
        #expect(writes.value == 1)
        #expect(!store.canExport)
        store.confirmSummary(store.preview!.confirmationToken)
        #expect(store.canExport)
    }

    @Test("A mismatched confirmation fails closed and keeps the package key empty")
    func mismatchedConfirmationsFailClosed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expected = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: expected, relativePath: "id", alreadyExists: false) },
            snapshotProvider: { _, _ in .empty(libraryID: expected) }
        )
        await store.preview()
        store.confirmIdentity(PortableLibraryID(rawValue: UUID()))
        #expect(store.phase == .failed)
        #expect(store.oneTimeQRPayload == nil)
        #expect(!store.canExport)
    }

    @Test("Cancellation invalidates stale preview work")
    func cancellationWinsOverStaleAsyncResult() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in
                try await Task.sleep(for: .milliseconds(40))
                return .empty(libraryID: id)
            }
        )
        let task = Task { await store.preview() }
        await Task.yield()
        store.cancel()
        await task.value
        #expect(store.phase == .idle)
        #expect(store.preview == nil)
    }

    @Test("Export failure and existing destination are visible recovery states")
    func exportFailuresAreVisible() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, _ in throw MobilePackageError.destinationExists }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        #expect(store.canExport)
        await store.export(to: root.appendingPathComponent("existing.astroMobile"))
        #expect(store.phase == .failed)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("already") == true)
        #expect(store.oneTimeQRPayload == nil)
    }

    @Test("A confirmed summary follows the export state machine and reset clears the one-time code")
    func exportStateMachineAndReset() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, key in
                #expect(!key.qrPayload.isEmpty)
                return MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 64)
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        await store.export(to: root.appendingPathComponent("new-package.astroMobile"))
        #expect(store.phase == .exported)
        #expect(store.oneTimeQRPayload != nil)
        store.reset()
        #expect(store.phase == .idle)
        #expect(store.oneTimeQRPayload == nil)
    }

    @Test("Missing libraries and wrong unlock codes fail closed")
    func missingLibraryAndWrongKeyFailClosed() async throws {
        let missing = MobileSyncStore(rootURL: nil)
        await missing.preview()
        #expect(missing.phase == .failed)
        #expect(missing.failure == .missingLibrary)

        let imported = MobileSyncStore(
            rootURL: nil,
            packageImportPreview: { _, _ in throw MobilePackageError.authenticationFailed }
        )
        let missingSource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("package")
        await imported.previewIncomingPackage(from: missingSource, qrPayload: OneTimePackageKey().qrPayload)
        #expect(imported.phase == .failed)
        #expect(imported.failure == .importFailed)
        #expect(imported.incomingPreview == nil)
    }

    @Test("Incoming package preview authenticates without applying changes")
    func incomingPreviewStopsBeforeApply() async throws {
        let imported = MobilePackageImportPreview(
            packageID: UUID(),
            snapshotSummary: .init(projectCount: 2, nightCount: 1, captureCount: 4, briefingCount: 1, noteCount: 2),
            incomingChanges: [],
            encryptedByteCount: 128
        )
        let store = MobileSyncStore(
            rootURL: nil,
            packageImportPreview: { _, _ in imported }
        )
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("package")
        await store.previewIncomingPackage(from: source, qrPayload: OneTimePackageKey().qrPayload)
        #expect(store.phase == .importPreviewReady)
        #expect(store.incomingPreview == imported)
        #expect(store.didApplyIncomingChanges == false)
    }

    @Test("a capability-commit failure truthfully preserves the saved return receipt")
    func returnCommitFailureReportsSavedChanges() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let base = MobileLibrarySnapshot.empty(libraryID: identity)
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            let ids: [UUID]
            switch batch {
            case .briefing(let briefing):
                ids = briefing.mutations.map { mutation in
                    switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let project): ids = project.mutations.map { $0.0.changeID }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: [:])
        }))
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            packageImportCommitReturn: { _ in throw MobilePackageError.duplicatePackageID },
            packageImportDiscardReturn: { package in await packageService.discardAuthenticatedReturn(package) },
            changeImporter: importer,
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)
        await #expect(throws: MobilePackageError.duplicatePackageID) {
            try await store.applyAuthenticatedReturnChanges(confirmed: true)
        }
        #expect(store.appliedChangeReceipt != nil)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("saved") == true)
        #expect(store.phase == .failed)
    }

    @Test("retrying a failed return re-preview never pairs the stale receipt with the fresh preview")
    func retryAfterFailedReturnClearsStaleReceiptFromNewPreview() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let base = MobileLibrarySnapshot.empty(libraryID: identity)
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            let ids: [UUID]
            switch batch {
            case .briefing(let briefing):
                ids = briefing.mutations.map { mutation in
                    switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let project): ids = project.mutations.map { $0.0.changeID }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: [:])
        }))
        // The commit closure always fails, so this store deterministically
        // lands the first attempt in `.failed` with a retained
        // `completedReceipt`-backed appliedChangeReceipt, matching
        // `returnCommitFailureReportsSavedChanges` above.
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            packageImportCommitReturn: { _ in throw MobilePackageError.duplicatePackageID },
            packageImportDiscardReturn: { package in await packageService.discardAuthenticatedReturn(package) },
            changeImporter: importer,
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)
        await #expect(throws: MobilePackageError.duplicatePackageID) {
            try await store.applyAuthenticatedReturnChanges(confirmed: true)
        }
        #expect(store.phase == .failed)
        _ = try #require(store.appliedChangeReceipt)

        // The phone package's staged import was released on the failure path
        // (discardAuthenticatedReturn), so the same source/key can be
        // re-authenticated and re-previewed on retry.
        await store.retry()

        #expect(store.phase == .importPreviewReady)
        #expect(store.changePreview != nil)
        // The fresh preview from retry must never be paired with the
        // previous attempt's receipt: neither the raw receipt field nor the
        // review-banner's disjoint totals may surface stale numbers here.
        #expect(store.appliedChangeReceipt == nil)
        #expect(store.receiptTotals == nil)
        #expect(store.didApplyIncomingChanges == false)
    }

    @Test("successful return is terminal and clears all reusable preview state")
    func successfulReturnClearsPreviewAndBecomesTerminal() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let base = MobileLibrarySnapshot.empty(libraryID: identity)
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let importer = MobileChangeImporter(commands: .init(applyBatch: { _ in .init(appliedChangeIDs: [], resultingRevisions: [:]) }))
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            packageImportCommitReturn: { package in try await packageService.commitAuthenticatedReturn(package) },
            packageImportDiscardReturn: { package in await packageService.discardAuthenticatedReturn(package) },
            changeImporter: importer,
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)
        try await store.applyAuthenticatedReturnChanges(confirmed: true)

        #expect(store.phase == .completed)
        #expect(store.incomingPreview == nil)
        #expect(store.changePreview == nil)
        #expect(store.changeResolutions.isEmpty)
        #expect(store.appliedChangeReceipt != nil)
        #expect(store.appliedChangeTotals == .init())
    }

    @Test("a superseded change is not double-counted as kept on Mac")
    func supersededChangeIsExcludedFromKeptOnMacTotal() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: identity,
            snapshotID: UUID(),
            revision: 2,
            createdAt: savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: 2, savedAt: savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [.init(id: "setup", title: "Setup", items: [.init(id: "focus", title: "Focus", explanation: nil, isCompleted: false, baseRevision: 2)])], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "Base note", baseRevision: 2, updatedAt: savedAt, isEditableOnPhone: true)]
        )
        let deviceID = UUID()
        let olderChangeID = UUID()
        let newerChangeID = UUID()
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [
                    .checklistCompletion(.init(changeID: olderChangeID, deviceID: deviceID, briefingID: briefingID, itemID: "focus", baseRevision: 2, isCompleted: true, createdAt: Date(timeIntervalSince1970: 1_700_000_001))),
                    .checklistCompletion(.init(changeID: newerChangeID, deviceID: deviceID, briefingID: briefingID, itemID: "focus", baseRevision: 2, isCompleted: false, createdAt: Date(timeIntervalSince1970: 1_700_000_002)))
                ],
                acknowledgedChangeIDs: []
            ),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            let ids: [UUID]
            switch batch {
            case .briefing(let briefing):
                ids = briefing.mutations.map { mutation in
                    switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let project): ids = project.mutations.map { $0.0.changeID }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: [:])
        }))
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            packageImportCommitReturn: { package in try await packageService.commitAuthenticatedReturn(package) },
            packageImportDiscardReturn: { package in await packageService.discardAuthenticatedReturn(package) },
            changeImporter: importer,
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)
        #expect(store.changePreview?.superseded == [olderChangeID])
        #expect(store.changePreview?.conflicts.isEmpty == true)

        try await store.applyAuthenticatedReturnChanges(confirmed: true)

        #expect(store.phase == .completed)
        let totals = store.appliedChangeTotals
        #expect(totals.applied == 1)
        #expect(totals.keptOnMac == 0)
        #expect(totals.superseded == 1)
        #expect(totals.applied + totals.keptOnMac + totals.superseded + totals.alreadyHandled + totals.duplicates + totals.rejected == 2)
        let receipt = try #require(store.appliedChangeReceipt)
        #expect(Set(receipt.resolvedChangeIDs).contains(olderChangeID))
    }

    @Test("kept-on-Mac totals still include a real conflict resolution alongside a disjoint superseded count")
    func supersededAndKeepMacConflictAreBothCountedOnceEach() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: identity,
            snapshotID: UUID(),
            revision: 2,
            createdAt: savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: 2, savedAt: savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [.init(id: "setup", title: "Setup", items: [
                .init(id: "focus", title: "Focus", explanation: nil, isCompleted: false, baseRevision: 2),
                .init(id: "aim", title: "Aim", explanation: nil, isCompleted: false, baseRevision: 2)
            ])], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "Base note", baseRevision: 2, updatedAt: savedAt, isEditableOnPhone: true)]
        )
        let deviceID = UUID()
        let olderChangeID = UUID()
        let newerChangeID = UUID()
        let conflictChangeID = UUID()
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [
                    .checklistCompletion(.init(changeID: olderChangeID, deviceID: deviceID, briefingID: briefingID, itemID: "focus", baseRevision: 2, isCompleted: true, createdAt: Date(timeIntervalSince1970: 1_700_000_001))),
                    .checklistCompletion(.init(changeID: newerChangeID, deviceID: deviceID, briefingID: briefingID, itemID: "focus", baseRevision: 2, isCompleted: false, createdAt: Date(timeIntervalSince1970: 1_700_000_002))),
                    .checklistCompletion(.init(changeID: conflictChangeID, deviceID: deviceID, briefingID: briefingID, itemID: "aim", baseRevision: 1, isCompleted: true, createdAt: Date(timeIntervalSince1970: 1_700_000_003)))
                ],
                acknowledgedChangeIDs: []
            ),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            let ids: [UUID]
            switch batch {
            case .briefing(let briefing):
                ids = briefing.mutations.map { mutation in
                    switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let project): ids = project.mutations.map { $0.0.changeID }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: [:])
        }))
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            packageImportCommitReturn: { package in try await packageService.commitAuthenticatedReturn(package) },
            packageImportDiscardReturn: { package in await packageService.discardAuthenticatedReturn(package) },
            changeImporter: importer,
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)
        #expect(store.changePreview?.superseded == [olderChangeID])
        #expect(store.changePreview?.conflicts.map(\.changeID) == [conflictChangeID])
        store.setChangeResolution(.keepMac, for: conflictChangeID)

        try await store.applyAuthenticatedReturnChanges(confirmed: true)

        #expect(store.phase == .completed)
        let totals = store.appliedChangeTotals
        #expect(totals.applied == 1)
        #expect(totals.keptOnMac == 1)
        #expect(totals.superseded == 1)
        #expect(totals.applied + totals.keptOnMac + totals.superseded + totals.alreadyHandled + totals.duplicates + totals.rejected == 3)
        let receipt = try #require(store.appliedChangeReceipt)
        #expect(Set(receipt.resolvedChangeIDs).contains(olderChangeID))
        #expect(Set(receipt.resolvedChangeIDs).contains(conflictChangeID))
    }

    @Test("checklist conflict recommendation is inserted into store state")
    func checklistConflictHasRealDefaultResolution() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: identity,
            snapshotID: UUID(),
            revision: 2,
            createdAt: savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: 2, savedAt: savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [.init(id: "setup", title: "Setup", items: [.init(id: "focus", title: "Focus", explanation: nil, isCompleted: false, baseRevision: 2)])], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "Base note", baseRevision: 2, updatedAt: savedAt, isEditableOnPhone: true)]
        )
        let changeID = UUID()
        let source = root.appendingPathComponent("phone-return.astromobile")
        let key = OneTimePackageKey()
        let packageService = MobilePackageService()
        _ = try await packageService.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [.checklistCompletion(.init(changeID: changeID, deviceID: UUID(), briefingID: briefingID, itemID: "focus", baseRevision: 1, isCompleted: true, createdAt: Date(timeIntervalSince1970: 1_700_000_001)))],
                acknowledgedChangeIDs: []
            ),
            to: source,
            wrapping: key
        )
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent-bases.json"))
        try sentBases.save(snapshotID: base.snapshotID)
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in base },
            packageAuthenticatePreview: { url, scannedKey in try await packageService.authenticatePreview(from: url, wrapping: scannedKey) },
            packageAuthenticatedReturn: { token in try await packageService.authenticatedReturn(token: token) },
            changeImporter: MobileChangeImporter(commands: .init(applyBatch: { _ in .init(appliedChangeIDs: [changeID], resultingRevisions: [:]) })),
            sentSnapshotStore: sentBases
        )

        await store.previewIncomingPackage(from: source, qrPayload: key.qrPayload)

        #expect(store.phase == .importPreviewReady)
        #expect(store.changePreview?.conflicts.map(\.changeID) == [changeID])
        #expect(store.changeResolutions[changeID] == .applyPhone)
    }

    @Test("Summary confirmation is bound to the exact displayed snapshot token")
    func exactSnapshotTokenRequired() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot }
        )
        await store.preview()
        let token = try #require(store.preview?.confirmationToken)
        store.confirmSummary(.init(snapshotID: UUID(), revision: token.revision, createdAt: token.createdAt, summary: token.summary, libraryID: id))
        #expect(store.failure == .summaryMismatch)
        #expect(!store.isSummaryConfirmed)
    }

    @Test("A cancelled export records a late published result and keeps its unlock code")
    func cancellationDoesNotLosePublishedPackage() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let gate = SignalGate()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, _ in
                await gate.wait()
                return MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 9)
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        let task = Task { await store.export(to: root.appendingPathComponent("new-package.astroMobile")) }
        await Task.yield()
        store.cancel()
        #expect(store.phase == .finishing)
        store.reset()
        store.dismiss()
        #expect(store.phase == .finishing)
        gate.open()
        await task.value
        #expect(store.phase == .exported)
        #expect(store.oneTimeQRPayload != nil)
    }

    @Test("Cancelling before publication cancels the export task and leaves no destination or key")
    func cancellationBeforePublicationStopsExport() async throws {
        let id = PortableLibraryID(rawValue: UUID())
        let entered = SignalGate()
        let release = SignalGate()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("cancelled.astromobile")
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, _ in
                entered.open()
                await release.wait()
                try Task.checkCancellation()
                return MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 1)
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        store.startExport(to: destination)
        await entered.wait()
        store.cancel()
        release.open()
        for _ in 0..<100 where store.phase == .finishing {
            await Task.yield()
        }
        #expect(store.phase == .idle)
        #expect(store.oneTimeQRPayload == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A cancelled import discards a late authenticated preview")
    func cancellationDiscardsLateImportPreview() async throws {
        let imported = MobilePackageImportPreview(
            packageID: UUID(),
            snapshotSummary: .init(projectCount: 1, nightCount: 1, captureCount: 1, briefingCount: 0, noteCount: 0),
            incomingChanges: [],
            encryptedByteCount: 32
        )
        let gate = SignalGate()
        let discarded = ValueCounter()
        let store = MobileSyncStore(
            rootURL: nil,
            packageImportPreview: { _, _ in
                await gate.wait()
                return imported
            },
            packageImportDiscard: { packageID in
                if packageID == imported.packageID { discarded.value += 1 }
            }
        )
        let task = Task {
            await store.previewIncomingPackage(from: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true), qrPayload: OneTimePackageKey().qrPayload)
        }
        await Task.yield()
        store.cancel()
        gate.open()
        await task.value
        #expect(store.phase == .idle)
        #expect(store.incomingPreview == nil)
        #expect(discarded.value == 1)
    }

    @Test("Incoming retry repeats the incoming preview context")
    func incomingRetryKeepsIncomingContext() async throws {
        let imported = MobilePackageImportPreview(
            packageID: UUID(),
            snapshotSummary: .init(projectCount: 1, nightCount: 1, captureCount: 1, briefingCount: 0, noteCount: 0),
            incomingChanges: [],
            encryptedByteCount: 32
        )
        let calls = ValueCounter()
        let store = MobileSyncStore(
            rootURL: nil,
            packageImportPreview: { _, _ in
                calls.value += 1
                if calls.value == 1 { throw MobilePackageError.authenticationFailed }
                return imported
            }
        )
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let code = OneTimePackageKey().qrPayload
        await store.previewIncomingPackage(from: source, qrPayload: code)
        #expect(store.phase == .failed)
        await store.retry()
        #expect(store.phase == .importPreviewReady)
        #expect(store.incomingPreview == imported)
        #expect(calls.value == 2)
    }

    @Test("Incoming discard is serialized before the same package is previewed again")
    func incomingDiscardIsSerializedBeforeRepreview() async throws {
        let imported = MobilePackageImportPreview(
            packageID: UUID(),
            snapshotSummary: .init(projectCount: 1, nightCount: 1, captureCount: 1, briefingCount: 0, noteCount: 0),
            incomingChanges: [],
            encryptedByteCount: 32
        )
        let discardEntered = SignalGate()
        let discardRelease = SignalGate()
        let store = MobileSyncStore(
            rootURL: nil,
            packageImportPreview: { _, _ in imported },
            packageImportDiscard: { packageID in
                #expect(packageID == imported.packageID)
                discardEntered.open()
                await discardRelease.wait()
            }
        )
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let code = OneTimePackageKey().qrPayload
        await store.previewIncomingPackage(from: source, qrPayload: code)
        store.cancel()
        #expect(store.phase == .discarding)
        await discardEntered.wait()
        let repreview = Task { await store.previewIncomingPackage(from: source, qrPayload: code) }
        await Task.yield()
        #expect(store.phase == .discarding)
        discardRelease.open()
        await repreview.value
        #expect(store.phase == .importPreviewReady)
        #expect(store.incomingPreview == imported)
    }

    @Test("Metadata revision is stable, nonzero, and changes when content changes")
    func metadataRevisionTracksContent() {
        let projectID = UUID()
        let project = ProjectRecord(id: projectID, catalogID: "m31", displayName: "M31", phase: .planned)
        let base = MobileSyncStore.revisionForTesting(
            projects: [project], nights: [], captures: [], annotations: [], briefings: [], decisions: [], integrationSecondsByCaptureID: [:]
        )
        let same = MobileSyncStore.revisionForTesting(
            projects: [project], nights: [], captures: [], annotations: [], briefings: [], decisions: [], integrationSecondsByCaptureID: [:]
        )
        let changed = MobileSyncStore.revisionForTesting(
            projects: [ProjectRecord(id: projectID, catalogID: "m31", displayName: "M31 revised", phase: .planned)], nights: [], captures: [], annotations: [], briefings: [], decisions: [], integrationSecondsByCaptureID: [:]
        )
        #expect(base > 0)
        #expect(base == same)
        #expect(base != changed)
    }

    @Test("Snapshot revisions remain monotonic across identical and acknowledgement-only compositions")
    func snapshotRevisionPersistsAcrossStoreReload() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await MobileSnapshotRevisionStore(fileURL: root.appendingPathComponent("revision.json")).next()
        let second = try await MobileSnapshotRevisionStore(fileURL: root.appendingPathComponent("revision.json")).next()
        #expect(first > 0)
        #expect(second > first)
    }

    @Test("Snapshot revision allocation serializes independent window stores")
    func snapshotRevisionCoordinatesIndependentStores() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("revision.json")
        let firstStore = MobileSnapshotRevisionStore(fileURL: fileURL)
        let secondStore = MobileSnapshotRevisionStore(fileURL: fileURL)
        let revisions = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { try await firstStore.next() }
            group.addTask { try await secondStore.next() }
            var values: [Int] = []
            for try await revision in group { values.append(revision) }
            return values.sorted()
        }

        #expect(revisions == [1, 2])
    }

    @Test("a publication reservation blocks newer revision allocation until sent-base association finishes")
    func publicationReservationOrdersWindows() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("revision.json")
        let firstStore = MobileSnapshotRevisionStore(fileURL: fileURL)
        let secondStore = MobileSnapshotRevisionStore(fileURL: fileURL)
        let first = try await firstStore.next()
        let reservation = try await firstStore.beginPublication(expectedRevision: first)
        let next = Task { try await secondStore.next() }
        await Task.yield()
        #expect(!next.isCancelled)

        await firstStore.finishPublication(reservation, published: true)
        #expect(try await next.value == first + 1)
    }

    @Test("a stale window cannot reserve an older preview for publication")
    func stalePreviewCannotBeginPublication() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSnapshotRevisionStore(fileURL: root.appendingPathComponent("revision.json"))
        let older = try await store.next()
        _ = try await store.next()

        await #expect(throws: MobileChangeImportError.stalePreview) {
            try await store.beginPublication(expectedRevision: older)
        }
    }

    @Test("Sent snapshot history retains multiple recent bases and is bounded")
    func sentSnapshotHistoryIsBounded() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        let ids = (0..<130).map { _ in UUID() }
        for id in ids.prefix(128) { try store.save(snapshotID: id) }
        #expect(throws: MobileChangeImportError.limitsExceeded) { try store.save(snapshotID: ids[128]) }
        let loaded = try store.load()
        #expect(loaded.count == 128)
        #expect(Set(loaded) == Set(ids.prefix(128)))
    }

    @Test("published sent bases retain the exact acknowledgement set")
    func sentSnapshotAcknowledgementEvidenceRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        let snapshotID = UUID()
        let first = UUID()
        let second = UUID()
        try store.save(snapshotID: snapshotID, acknowledgementIDs: [second, first])

        #expect(try store.loadRecords() == [.init(snapshotID: snapshotID, acknowledgementIDs: [first, second])])
    }

    @Test("pending sent bases do not authorize a return and are reclaimable after publication")
    func sentBasePublicationStateIsDurableAndReclaimable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        let snapshotID = UUID()
        let acknowledgementID = UUID()

        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [acknowledgementID])
        #expect(try store.loadPublishedRecords().isEmpty)
        try store.markPublished(snapshotID: snapshotID)
        #expect(try store.loadPublishedRecords() == [.init(snapshotID: snapshotID, acknowledgementIDs: [acknowledgementID], state: .published)])
        try store.consumePublished(snapshotID: snapshotID)
        #expect(try store.loadRecords().isEmpty)
    }

    @Test("a failed forward export releases its pending sent-base capacity")
    func failedForwardExportDoesNotAuthorizeItsBase() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: identity)
        let sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in .init(proposedID: identity, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            packageExport: { _, _, _ in throw MobilePackageError.stagingFailed },
            sentSnapshotStore: sentBases
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        await store.export(to: root.appendingPathComponent("failed.astromobile"))

        #expect(try sentBases.loadPublishedRecords().isEmpty)
        #expect(try sentBases.loadRecords().isEmpty)
    }

    @Test("Destination preparation never removes an existing package")
    func destinationNoOverwrite() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.astroMobile")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = Data("do not replace".utf8)
        let sentinel = destination.appendingPathComponent("sentinel")
        try original.write(to: sentinel)
        try MobileSyncDestinationCoordinator.removePlaceholder(at: destination, token: UUID().uuidString)
        #expect(try Data(contentsOf: sentinel) == original)
    }

    // MARK: - Nearby sync phase transitions

    /// Note on coverage: `MobileReturnApplicationReview`'s initializer is
    /// `fileprivate` to `MobileReturnApplicationCoordinator.swift` -- by
    /// design, no test anywhere can fabricate one, so a `.receivedReturn`
    /// event carrying a real review cannot be scripted at this store-unit
    /// level. That handoff (`.receivedReturn` -> `phase ==
    /// .importPreviewReady` -> `applyAuthenticatedReturnChanges` ->
    /// `reportReturnOutcome(.applied)`) is instead proven end-to-end by
    /// `NearbySyncCoordinatorTests.firstPairingHappyPathRoundTrip`, which
    /// drives a REAL coordinator+review through the same
    /// `MobileReturnApplicationReview` type. These tests cover every OTHER
    /// event the nearby phase state machine reacts to, plus the
    /// confirm/reject/retry/cancel gating around it.

    @Test("Nearby phase follows a scripted event stream through to done")
    func nearbyPhaseFollowsScriptedEvents() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let capturedSnapshot = SnapshotCapture()
        let (stream, continuation) = AsyncStream<NearbySyncEvent>.makeStream()
        continuation.yield(.waitingForPhone)
        continuation.yield(.pairingCode("123456"))
        continuation.yield(.preparing)
        continuation.yield(.transferring)
        continuation.yield(.verifying)
        continuation.yield(.finished)
        continuation.finish()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            nearbyStartAdvertising: { requestedSnapshot in
                capturedSnapshot.value = requestedSnapshot
                return stream
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        #expect(store.canExport)

        store.startNearbySync()
        #expect(store.nearbyPhase == .advertising)
        try await waitFor(store) { if case .done = $0 { return true }; return false }

        #expect(capturedSnapshot.value?.snapshotID == snapshot.snapshotID)
    }

    @Test("startNearbySync is a no-op until canExport is true")
    func startNearbySyncRequiresConfirmation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let started = ValueCounter()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            nearbyStartAdvertising: { _ in
                started.value += 1
                return AsyncStream { $0.finish() }
            }
        )
        await store.preview()
        // Identity is confirmed (alreadyExists), but the summary is not --
        // canExport is still false.
        #expect(!store.canExport)

        store.startNearbySync()
        await Task.yield()
        #expect(started.value == 0)
        #expect(store.nearbyPhase == .idle)
    }

    @Test("A failure event surfaces as nearbyPhase.failed, and retry only fires from that state")
    func nearbyFailureAndRetryGating() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let startCount = ValueCounter()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            nearbyStartAdvertising: { _ in
                startCount.value += 1
                let (stream, continuation) = AsyncStream<NearbySyncEvent>.makeStream()
                continuation.yield(.failed(.timeout))
                continuation.finish()
                return stream
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)

        // Retry is a no-op before any nearby session ever ran.
        store.retryNearbySync()
        await Task.yield()
        #expect(startCount.value == 0)

        store.startNearbySync()
        try await waitFor(store) { if case .failed(.timeout) = $0 { return true }; return false }
        await waitForCount(startCount, toReach: 1)
        #expect(startCount.value == 1)

        store.retryNearbySync()
        try await waitFor(store) { if case .failed(.timeout) = $0 { return true }; return false }
        await waitForCount(startCount, toReach: 2)
        #expect(startCount.value == 2)
    }

    @Test("confirmNearbyPairing and rejectNearbyPairing only forward while pairing is awaited")
    func nearbyConfirmRejectGating() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let confirmCount = ValueCounter()
        let rejectCount = ValueCounter()
        let (stream, continuation) = AsyncStream<NearbySyncEvent>.makeStream()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            nearbyStartAdvertising: { _ in stream },
            nearbyConfirmPairing: { confirmCount.value += 1 },
            nearbyRejectPairing: { rejectCount.value += 1 }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)

        // Before any pairing code is offered, both are no-ops.
        store.confirmNearbyPairing()
        store.rejectNearbyPairing()
        await Task.yield()
        #expect(confirmCount.value == 0)
        #expect(rejectCount.value == 0)

        store.startNearbySync()
        continuation.yield(.pairingCode("654321"))
        try await waitFor(store) { if case .pairing = $0 { return true }; return false }

        store.confirmNearbyPairing()
        await waitForCount(confirmCount, toReach: 1)
        #expect(confirmCount.value == 1)
        #expect(rejectCount.value == 0)

        continuation.yield(.finished)
        continuation.finish()
        try await waitFor(store) { if case .done = $0 { return true }; return false }

        // Once the session is no longer pairing, reject is a no-op too.
        store.rejectNearbyPairing()
        await Task.yield()
        #expect(rejectCount.value == 0)
    }

    @Test("cancelNearbySync stops the live session and returns to idle")
    func cancelNearbySyncStopsAndResetsToIdle() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let stopCount = ValueCounter()
        let (stream, continuation) = AsyncStream<NearbySyncEvent>.makeStream()
        let store = MobileSyncStore(
            rootURL: root,
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in snapshot },
            nearbyStartAdvertising: { _ in stream },
            nearbyStop: { stopCount.value += 1 }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)

        store.startNearbySync()
        try await waitFor(store) { $0 == .advertising }

        store.cancelNearbySync()
        await waitForCount(stopCount, toReach: 1)
        #expect(stopCount.value == 1)
        #expect(store.nearbyPhase == .idle)
        continuation.finish()
    }

    @MainActor
    private func waitFor(
        _ store: MobileSyncStore,
        _ predicate: (NearbySyncPhase) -> Bool,
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if predicate(store.nearbyPhase) { return }
            await Task.yield()
        }
        Issue.record("nearbyPhase never satisfied the expected predicate; last value: \(store.nearbyPhase)")
    }

    /// `confirmNearbyPairing`/`rejectNearbyPairing`/`cancelNearbySync` each
    /// forward through a fire-and-forget `Task { await ... }` — a single
    /// `Task.yield()` lets that task get SCHEDULED but is not guaranteed to
    /// let it actually RUN TO COMPLETION under load (observed flaky in a
    /// parallel `swift test` run). Poll instead of yielding once.
    private func waitForCount(_ counter: ValueCounter, toReach expected: Int, attempts: Int = 200) async {
        for _ in 0..<attempts {
            if counter.value >= expected { return }
            await Task.yield()
        }
        Issue.record("counter never reached \(expected); last value: \(counter.value)")
    }
}

private final class SnapshotCapture: @unchecked Sendable {
    var value: MobileLibrarySnapshot?
}

private final class WriteCounter: @unchecked Sendable {
    var value = 0
}

private final class ValueCounter: @unchecked Sendable {
    var value = 0
}

private final class SignalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
    func open() {
        lock.lock()
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private extension MobileLibrarySnapshot {
    static func empty(libraryID: PortableLibraryID) -> MobileLibrarySnapshot {
        MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [], nights: [], captures: [], briefings: [], notes: []
        )
    }

    var summary: MobileSnapshotSummary {
        .init(projectCount: projects.count, nightCount: nights.count, captureCount: captures.count, briefingCount: briefings.count, noteCount: notes.count)
    }
}
