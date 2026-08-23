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
        let root = URL(fileURLWithPath: "/tmp/AstroTool-mobile-sync-test", isDirectory: true)
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
        let expected = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
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
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
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
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, _ in throw MobilePackageError.destinationExists }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        #expect(store.canExport)
        await store.export(to: URL(fileURLWithPath: "/tmp/existing.astroMobile"))
        #expect(store.phase == .failed)
        #expect(store.errorMessage?.localizedCaseInsensitiveContains("already") == true)
        #expect(store.oneTimeQRPayload == nil)
    }

    @Test("A confirmed summary follows the export state machine and reset clears the one-time code")
    func exportStateMachineAndReset() async throws {
        let id = PortableLibraryID(rawValue: UUID())
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
            identityPreview: { _ in PortableIdentityPreview(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, key in
                #expect(!key.qrPayload.isEmpty)
                return MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 64)
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        await store.export(to: URL(fileURLWithPath: "/tmp/new-package.astroMobile"))
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
        await imported.previewIncomingPackage(from: URL(fileURLWithPath: "/tmp/package"), qrPayload: OneTimePackageKey().qrPayload)
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
        await store.previewIncomingPackage(from: URL(fileURLWithPath: "/tmp/package"), qrPayload: OneTimePackageKey().qrPayload)
        #expect(store.phase == .importPreviewReady)
        #expect(store.incomingPreview == imported)
        #expect(store.didApplyIncomingChanges == false)
    }

    @Test("Summary confirmation is bound to the exact displayed snapshot token")
    func exactSnapshotTokenRequired() async throws {
        let id = PortableLibraryID(rawValue: UUID())
        let snapshot = MobileLibrarySnapshot.empty(libraryID: id)
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
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
        let id = PortableLibraryID(rawValue: UUID())
        let gate = SignalGate()
        let store = MobileSyncStore(
            rootURL: URL(fileURLWithPath: "/tmp/library"),
            identityPreview: { _ in .init(proposedID: id, relativePath: "id", alreadyExists: true) },
            snapshotProvider: { _, _ in .empty(libraryID: id) },
            packageExport: { _, _, _ in
                await gate.wait()
                return MobileSyncExportResult(packageID: UUID(), createdAt: Date(), encryptedByteCount: 9)
            }
        )
        await store.preview()
        store.confirmSummary(store.preview!.confirmationToken)
        let task = Task { await store.export(to: URL(fileURLWithPath: "/tmp/new-package.astroMobile")) }
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
            await store.previewIncomingPackage(from: URL(fileURLWithPath: "/tmp/package"), qrPayload: OneTimePackageKey().qrPayload)
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
        let source = URL(fileURLWithPath: "/tmp/package")
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
        let source = URL(fileURLWithPath: "/tmp/package")
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
