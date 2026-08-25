import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Suite("Nearby sync coordinator")
struct NearbySyncCoordinatorTests {
    @Test("first pairing happy path: pairing code, forward publish, return preview/apply, one finished terminal")
    func firstPairingHappyPathRoundTrip() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let listener = ScriptedListener(batches: [[macConnection]])
        let coordinator = fixture.makeCoordinator(listener: listener)

        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let changeID = UUID()

        async let phoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: phoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: true,
            buildReturn: { forward in
                MobilePackageEnvelope(
                    purpose: .returnChanges,
                    snapshot: forward,
                    baseSnapshotID: forward.snapshotID,
                    changes: [.noteRevision(.init(
                        changeID: changeID,
                        deviceID: phoneIdentity.deviceID,
                        noteID: fixture.noteID,
                        ownerID: fixture.briefingID.uuidString,
                        baseRevision: fixture.originalRevision,
                        text: "Phone note",
                        createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                    ))],
                    acknowledgedChangeIDs: []
                )
            }
        )

        let events = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var collected: [NearbySyncEvent] = []
        var appliedReceipt: MobileChangeApplicationReceipt?
        for await event in events {
            collected.append(event)
            switch event {
            case .pairingCode:
                await coordinator.confirmPairing()
            case .receivedReturn(let review):
                #expect(review.changePreview.applicable.count == 1)
                let receipt = try await fixture.returnCoordinator.apply(review, resolutions: [:], confirmed: true)
                appliedReceipt = receipt
                await coordinator.reportReturnOutcome(.applied)
            default:
                break
            }
        }

        let phoneOutcome = try await phoneResult
        #expect(phoneOutcome.wasFirstPairing)

        #expect(collected.contains { if case .waitingForPhone = $0 { return true }; return false })
        #expect(collected.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(collected.contains { if case .preparing = $0 { return true }; return false })
        #expect(collected.contains { if case .transferring = $0 { return true }; return false })
        #expect(collected.contains { if case .verifying = $0 { return true }; return false })
        #expect(collected.contains { if case .receivedReturn = $0 { return true }; return false })
        #expect(collected.last.map { if case .finished = $0 { return true }; return false } == true)
        #expect(appliedReceipt?.appliedChangeIDs == [changeID])
        let changed = try #require(await fixture.briefingStore.latest(id: fixture.briefingID))
        #expect(changed.notes == "Phone note")
    }

    @Test("Mac rejecting the pairing code fails closed with no trust stored and no sent-base leak")
    func macRejectsPairingCode() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let listener = ScriptedListener(batches: [[macConnection]])
        let coordinator = fixture.makeCoordinator(listener: listener)

        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        async let phoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: phoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: false,
            buildReturn: { _ in nil }
        )

        let events = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var collected: [NearbySyncEvent] = []
        for await event in events {
            collected.append(event)
            if case .pairingCode = event {
                await coordinator.rejectPairing()
            }
        }

        let phoneOutcome = try? await phoneResult
        #expect(phoneOutcome == nil)

        #expect(collected.last.map {
            if case .failed(.pairingRejected) = $0 { return true }; return false
        } == true)
        #expect(try fixture.macTrustStore.trustedPeers().isEmpty)
        #expect(try phoneIdentityStore.trustedPeers().isEmpty)
        #expect(try fixture.sentBases.loadRecords().isEmpty)
    }

    @Test("a known peer's second session skips the pairing-code event")
    func knownPeerSecondSessionSkipsPairingCode() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (firstMacConnection, firstPhoneConnection) = InMemoryDuplexConnection.makePair()
        let (secondMacConnection, secondPhoneConnection) = InMemoryDuplexConnection.makePair()
        let listener = ScriptedListener(batches: [[firstMacConnection], [secondMacConnection]])
        let coordinator = fixture.makeCoordinator(listener: listener)

        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        // First session: pair, phone sends nothing back so the session ends
        // cleanly at `.finished`.
        async let firstPhoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: firstPhoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: true,
            buildReturn: { _ in nil }
        )
        let firstEvents = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        for await event in firstEvents {
            if case .pairingCode = event { await coordinator.confirmPairing() }
        }
        _ = try await firstPhoneResult

        // Second session between the same two identities: no pairing-code
        // event should ever appear.
        async let secondPhoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: secondPhoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: true,
            buildReturn: { _ in nil }
        )
        let secondEvents = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var secondCollected: [NearbySyncEvent] = []
        for await event in secondEvents { secondCollected.append(event) }
        let secondPhoneOutcome = try await secondPhoneResult

        #expect(!secondPhoneOutcome.wasFirstPairing)
        #expect(!secondCollected.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(secondCollected.last.map { if case .finished = $0 { return true }; return false } == true)
    }

    @Test("a tampered stored peer key fails closed with identityChanged")
    func tamperedStoredPeerKeyFailsClosed() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let listener = ScriptedListener(batches: [[macConnection]])

        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        // Pre-populate the Mac's trust store with a WRONG public key for this
        // exact phone deviceID — simulating a stored identity that no longer
        // matches what the phone now presents.
        try fixture.macTrustStore.storeTrustedPeer(MobilePeerIdentity(
            deviceID: phoneIdentity.deviceID,
            signingPublicKeyRawRepresentation: Data(repeating: 0xAB, count: 32),
            displayName: "Zoltán iPhone"
        ))
        let coordinator = fixture.makeCoordinator(listener: listener)

        async let phoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: phoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: true,
            buildReturn: { _ in nil }
        )

        let events = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var collected: [NearbySyncEvent] = []
        for await event in events { collected.append(event) }
        let phoneOutcome = try? await phoneResult
        #expect(phoneOutcome == nil)

        #expect(!collected.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(collected.last.map {
            if case .failed(.identityChanged) = $0 { return true }; return false
        } == true)
    }

    @Test("stop() during waitingForPhone finishes the stream with exactly one terminal event")
    func stopDuringWaitingForPhoneFinishesCleanly() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let listener = ScriptedListener(batches: [[]])
        let coordinator = fixture.makeCoordinator(listener: listener)

        let events = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first.map { if case .waitingForPhone = $0 { return true }; return false } == true)

        await coordinator.stop()

        var remaining: [NearbySyncEvent] = []
        while let event = await iterator.next() { remaining.append(event) }
        #expect(remaining.count == 1)
        #expect(remaining.first.map { if case .failed(.cancelled) = $0 { return true }; return false } == true)
    }

    @Test("a phone that sends nothing back ends the session at finished, with no receivedReturn event")
    func phoneSendsNothingBackFinishesWithoutReceivedReturn() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let listener = ScriptedListener(batches: [[macConnection]])
        let coordinator = fixture.makeCoordinator(listener: listener)

        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        async let phoneResult: PhoneSessionResult = Self.runPhoneSession(
            connection: phoneConnection,
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            stagingDirectory: fixture.phoneStagingDirectory,
            confirm: true,
            buildReturn: { _ in nil }
        )

        let events = try await coordinator.startAdvertising(confirmedSnapshot: try await fixture.baseSnapshot())
        var collected: [NearbySyncEvent] = []
        for await event in events {
            collected.append(event)
            if case .pairingCode = event { await coordinator.confirmPairing() }
        }
        _ = try await phoneResult

        #expect(!collected.contains { if case .receivedReturn = $0 { return true }; return false })
        #expect(collected.last.map { if case .finished = $0 { return true }; return false } == true)
    }

    // MARK: - Phone-side test double

    private struct PhoneSessionResult {
        let wasFirstPairing: Bool
    }

    /// Drives the phone side of one nearby session using the REAL
    /// `NearbyPairingSession` + `NearbyPackageTransport` stack (never a
    /// fake): pairs (optionally confirming or rejecting), receives the
    /// forward package the Mac coordinator publishes, and — if
    /// `buildReturn` produces one — sends a return package back; otherwise
    /// signals "nothing to return" exactly the way the coordinator's own
    /// `receiveOptionalReturn` seam expects.
    private static func runPhoneSession(
        connection: any NearbyByteConnection,
        identity: MobileDeviceIdentity,
        trustStore: any MobileDeviceIdentityStoring,
        stagingDirectory: URL,
        confirm: Bool,
        buildReturn: @escaping (MobileLibrarySnapshot) -> MobilePackageEnvelope?
    ) async throws -> PhoneSessionResult {
        let session = NearbyPairingSession(role: .initiator, identity: identity, trustStore: trustStore, connection: connection)
        async let outcome = session.establish()
        if let code = try? await session.shortAuthenticationCode {
            _ = code
            if confirm {
                await session.confirmPairing()
            } else {
                await session.rejectPairing()
            }
        }
        let established = try await outcome

        let transport = NearbyPackageTransport(
            channel: established.channel,
            packageService: MobilePackageService(),
            peer: established.peer,
            stagingDirectory: stagingDirectory
        )
        let forwardEnvelope = try await transport.receive()
        guard let forwardSnapshot = forwardEnvelope.snapshot else {
            throw MobilePackageError.invalidEnvelope
        }
        if let returnEnvelope = buildReturn(forwardSnapshot) {
            try await transport.send(returnEnvelope)
        } else {
            try await established.channel.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [])))
        }
        return PhoneSessionResult(wasFirstPairing: established.wasFirstPairing)
    }

    // MARK: - Fixture

    /// A real temp-root library fixture (unique per test — never a fixed
    /// path), mirroring `MobileReturnApplicationCoordinatorTests`' own
    /// note-revision e2e setup: one briefing with one phone-editable note,
    /// a real `MobileReturnApplicationCoordinator.production(...)`, and the
    /// Mac's own in-memory identity/trust store.
    private struct Fixture {
        let root: URL
        let macStagingDirectory: URL
        let phoneStagingDirectory: URL
        let briefingID = UUID()
        let noteID: String
        let originalRevision: Int
        let briefingStore: NightBriefingRevisionStore
        let returnCoordinator: MobileReturnApplicationCoordinator
        let sentBases: MobileSentSnapshotIdentityStore
        /// Points at exactly the file `MobileReturnApplicationCoordinator
        /// .publishForwardSnapshot` itself reads/advances (derived the same
        /// way that coordinator derives it: alongside the sent-base file).
        /// A snapshot's `revision` must match this store's next expected
        /// value or `publishForwardSnapshot` throws `stalePreview` — so
        /// `baseSnapshot()` always asks this store fresh rather than
        /// hardcoding a revision number, which would only be valid for the
        /// FIRST publish in a test that publishes more than once.
        let revisions: MobileSnapshotRevisionStore
        let macTrustStore = InMemoryDeviceIdentityStore()
        let macIdentity: MobileDeviceIdentity
        let libraryID: PortableLibraryID

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nearby-sync-coordinator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            macStagingDirectory = root.appendingPathComponent("mac-staging", isDirectory: true)
            phoneStagingDirectory = root.appendingPathComponent("phone-staging", isDirectory: true)

            let identityStore = PortableLibraryIdentityStore()
            libraryID = try identityStore.preview(root: root).proposedID
            _ = try identityStore.loadOrCreate(root: root, confirmedID: libraryID)
            let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
            briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
            noteID = "briefing-\(briefingID.uuidString.lowercased())"
            let capturedBriefingID = briefingID
            let capturedBriefingStore = briefingStore
            let original = try await capturedBriefingStore.create(NightBriefingDraft(
                id: capturedBriefingID,
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                notes: "Mac note"
            ))
            originalRevision = original.revision

            sentBases = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json"))
            revisions = MobileSnapshotRevisionStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json"))
            let service = MobilePackageService()
            let capturedLibraryID = libraryID
            let capturedNoteID = noteID
            returnCoordinator = try MobileReturnApplicationCoordinator.production(
                rootURL: root,
                packageService: service,
                currentSnapshotProvider: {
                    let latest = try await capturedBriefingStore.latest(id: capturedBriefingID) ?? original
                    return Self.buildSnapshot(libraryID: capturedLibraryID, briefingID: capturedBriefingID, noteID: capturedNoteID, draft: latest)
                }
            )
            macIdentity = try macTrustStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        }

        /// A fresh snapshot with a revision number this fixture's own
        /// `MobileSnapshotRevisionStore` will actually accept for
        /// publication right now — safe to call more than once per test
        /// (each call reserves the next revision in line).
        func baseSnapshot() async throws -> MobileLibrarySnapshot {
            let nextRevision = try await revisions.next()
            return Self.buildSnapshot(
                libraryID: libraryID,
                briefingID: briefingID,
                noteID: noteID,
                revision: nextRevision,
                draft: NightBriefingDraft(id: briefingID, savedAt: Date(timeIntervalSince1970: 1_700_000_000), notes: "Mac note")
            )
        }

        static func buildSnapshot(libraryID: PortableLibraryID, briefingID: UUID, noteID: String, revision: Int = 1, draft: NightBriefingDraft) -> MobileLibrarySnapshot {
            MobileLibrarySnapshot(
                schemaVersion: 1,
                libraryID: libraryID,
                snapshotID: UUID(),
                revision: revision,
                createdAt: draft.savedAt,
                projects: [],
                nights: [],
                captures: [],
                briefings: [.init(
                    id: draft.id,
                    revision: draft.revision,
                    savedAt: draft.savedAt,
                    nightDate: draft.nightDate,
                    readiness: "ready",
                    targets: [],
                    checklist: [],
                    noteID: noteID
                )],
                notes: [.init(
                    id: noteID,
                    scope: .briefing,
                    ownerID: briefingID.uuidString,
                    text: draft.notes,
                    baseRevision: draft.revision,
                    updatedAt: draft.savedAt,
                    isEditableOnPhone: true
                )]
            )
        }

        func makeCoordinator(listener: ScriptedListener) -> NearbySyncCoordinator {
            NearbySyncCoordinator(
                identity: macIdentity,
                trustStore: macTrustStore,
                listenerStart: { try await listener.start() },
                listenerStop: { await listener.stop() },
                stagingDirectory: macStagingDirectory,
                packageService: MobilePackageService(),
                publishForwardSnapshot: { snapshot, destination, wrapping in
                    try await self.returnCoordinator.publishForwardSnapshot(snapshot, to: destination, wrapping: wrapping)
                },
                previewReturn: { source, wrapping in
                    try await self.returnCoordinator.preview(from: source, wrapping: wrapping)
                },
                handshakeTimeout: .seconds(5)
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Test double standing in for `NearbyBonjourListener`: each `start()` call
/// hands out the next scripted batch of connections as a fresh
/// `AsyncStream`, so a test can script exactly which connection(s) arrive on
/// which `startAdvertising` call (including an empty batch — nothing ever
/// connects). `stop()` finishes every stream this double has ever started,
/// mirroring `NearbyBonjourListener.stop()` ending its connection stream.
private final class ScriptedListener: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingBatches: [[any NearbyByteConnection]]
    private var continuations: [AsyncStream<any NearbyByteConnection>.Continuation] = []

    init(batches: [[any NearbyByteConnection]]) {
        self.pendingBatches = batches
    }

    func start() async throws -> AsyncStream<any NearbyByteConnection> {
        let batch: [any NearbyByteConnection] = lock.withLock {
            guard !pendingBatches.isEmpty else { return [] }
            return pendingBatches.removeFirst()
        }
        let (stream, continuation) = AsyncStream<any NearbyByteConnection>.makeStream()
        lock.withLock { continuations.append(continuation) }
        for connection in batch { continuation.yield(connection) }
        return stream
    }

    func stop() async {
        let toFinish: [AsyncStream<any NearbyByteConnection>.Continuation] = lock.withLock {
            let list = continuations
            continuations = []
            return list
        }
        for continuation in toFinish { continuation.finish() }
    }
}
