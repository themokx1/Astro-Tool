import AstroMobileDomain
import Foundation
import Testing
@testable import AstroMobileTransport

/// `NearbyPhoneSyncSession` is the phone-side counterpart of
/// `NearbySyncCoordinator` (`Sources/AstroApplication/Features/MobileSync/
/// NearbySyncCoordinator.swift`), but `AstroMobileTransportTests` cannot
/// import `AstroApplication` (`Package.swift` only lets `AstroApplication`
/// depend on `AstroMobileTransport`, never the reverse), so — mirroring how
/// `NearbySyncCoordinatorTests` drives a REAL `NearbyPairingSession` +
/// `NearbyPackageTransport` phone-shaped double against the real Mac
/// coordinator — these tests drive a real Mac-shaped double
/// (`Self.runMacSide`, built from the exact same primitives) against the
/// real `NearbyPhoneSyncSession` under test.
@Suite("Nearby phone sync session")
struct NearbyPhoneSyncSessionTests {

    @Test("first pairing happy path: matching codes, forward package staged with the right key, return package sent and received")
    func firstPairingHappyPathRoundTrip() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let macStaging = try TemporaryDirectory()
        let phoneStaging = try TemporaryDirectory()
        let returnStaging = try TemporaryDirectory()

        async let macResult = Self.runMacSide(
            connection: macConnection,
            identity: macIdentity,
            trustStore: macStore,
            stagingDirectory: macStaging.url,
            confirm: true,
            forwardEnvelope: Self.makeForwardEnvelope(revision: 7)
        )

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in phoneConnection },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(5)
        )

        var collected: [NearbyPhoneSyncState] = []
        var phoneCode: String?
        for await state in await phoneSession.run(handleForwardPackage: { directory, wrapping in
            try Self.assertContainsPackageFiles(directory)
            let received = try await MobilePackageService().authenticatePreview(from: directory, wrapping: wrapping)
            #expect(received.preview.snapshotSummary.projectCount == 1)
            return try await Self.exportReturnPackage(root: returnStaging.url)
        }) {
            collected.append(state)
            if case .pairingCode(let code) = state {
                phoneCode = code
                await phoneSession.confirmPairing()
            }
        }

        let mac = try await macResult

        #expect(collected.first == .searching)
        #expect(collected.contains(.connecting))
        #expect(collected.contains(.receiving))
        #expect(collected.contains(.staged))
        #expect(collected.contains(.sendingReturn))
        #expect(collected.last == .finished)
        #expect(mac.wasFirstPairing)
        let macCode = try #require(mac.shortAuthenticationCode)
        #expect(try #require(phoneCode) == macCode)
        #expect(mac.receivedReturn != nil)

        #expect(try phoneStore.trustedPeers().count == 1)
        #expect(try macStore.trustedPeers().count == 1)
    }

    @Test("no return path: the phone's empty acknowledgement finishes the Mac side cleanly")
    func noReturnPathAcknowledges() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let macStaging = try TemporaryDirectory()
        let phoneStaging = try TemporaryDirectory()

        async let macResult = Self.runMacSide(
            connection: macConnection,
            identity: macIdentity,
            trustStore: macStore,
            stagingDirectory: macStaging.url,
            confirm: true,
            forwardEnvelope: Self.makeForwardEnvelope(revision: 1)
        )

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in phoneConnection },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(5)
        )

        var collected: [NearbyPhoneSyncState] = []
        for await state in await phoneSession.run(handleForwardPackage: { _, _ in
            nil
        }) {
            collected.append(state)
            if case .pairingCode = state { await phoneSession.confirmPairing() }
        }

        let mac = try await macResult
        #expect(collected.last == .finished)
        #expect(!collected.contains(.sendingReturn))
        #expect(mac.receivedReturn == nil)
    }

    @Test("the phone rejecting the pairing code fails closed on both sides with no trust stored")
    func phoneRejectingPairingCodeFailsClosed() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let macStaging = try TemporaryDirectory()
        let phoneStaging = try TemporaryDirectory()

        async let macResult: NearbySyncCoordinatorTestMacResult? = try? await Self.runMacSide(
            connection: macConnection,
            identity: macIdentity,
            trustStore: macStore,
            stagingDirectory: macStaging.url,
            confirm: true,
            forwardEnvelope: Self.makeForwardEnvelope(revision: 1)
        )

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in phoneConnection },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(5)
        )

        var collected: [NearbyPhoneSyncState] = []
        for await state in await phoneSession.run(handleForwardPackage: { _, _ in nil }) {
            collected.append(state)
            if case .pairingCode = state { await phoneSession.rejectPairing() }
        }

        _ = await macResult
        #expect(collected.last == .failed(.pairingRejected))
        #expect(try phoneStore.trustedPeers().isEmpty)
        #expect(try macStore.trustedPeers().isEmpty)
    }

    @Test("a Mac identity that no longer matches what this iPhone trusts is a hard failure with no code prompt")
    func identityChangedIsHardFailure() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        // The iPhone already trusts this Mac's deviceID under a DIFFERENT
        // key — simulating a changed or cloned Mac identity.
        try phoneStore.storeTrustedPeer(MobilePeerIdentity(
            deviceID: macIdentity.deviceID,
            signingPublicKeyRawRepresentation: Data(repeating: 7, count: 32),
            displayName: "Zoltán Macje"
        ))

        async let macOutcome: NearbyPairingOutcome? = try? await NearbyPairingSession(
            role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection, timeout: .seconds(5)
        ).establish()

        let phoneStaging = try TemporaryDirectory()
        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in phoneConnection },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(5)
        )

        var collected: [NearbyPhoneSyncState] = []
        for await state in await phoneSession.run(handleForwardPackage: { _, _ in nil }) {
            collected.append(state)
        }
        _ = await macOutcome

        #expect(collected.last == .failed(.identityChanged(deviceID: macIdentity.deviceID)))
        #expect(!collected.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(try phoneStore.trustedPeers().count == 1)

        // Recovery: "Forget this Mac and pair again" on the iPhone's own
        // failed screen removes exactly the offending deviceID and reports
        // its last known display name for that action's label.
        #expect(await phoneSession.trustedPeerDisplayName(deviceID: macIdentity.deviceID) == "Zoltán Macje")
        try await phoneSession.forgetPeer(deviceID: macIdentity.deviceID)
        #expect(try phoneStore.trustedPeers().isEmpty)
        #expect(await phoneSession.trustedPeerDisplayName(deviceID: macIdentity.deviceID) == nil)
    }

    @Test("a connection drop mid-transfer fails closed with no residue left in the phone's staging area")
    func midTransferDropFailsClosedWithoutResidue() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let phoneStaging = try TemporaryDirectory()

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in phoneConnection },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(5)
        )

        let driveTask = Task { () throws -> Void in
            let session = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection, timeout: .seconds(5))
            async let outcome = session.establish()
            _ = try await session.shortAuthenticationCode
            await session.confirmPairing()
            let channel = try await outcome.channel
            // Send a well-formed manifest, then vanish before `.packageComplete`
            // — exactly like a network drop or the Mac app being backgrounded
            // mid-transfer.
            try await channel.send(.packageManifest(NearbyPackageManifestMessage(
                packageID: UUID(),
                manifestJSON: Data("{}".utf8),
                totalChunkCount: 1,
                totalByteCount: 64,
                contentKeyWrapRawRepresentation: Data(repeating: 1, count: 32)
            )))
            await macConnection.cancel()
        }

        var collected: [NearbyPhoneSyncState] = []
        for await state in await phoneSession.run(handleForwardPackage: { _, _ in nil }) {
            collected.append(state)
            if case .pairingCode = state { await phoneSession.confirmPairing() }
        }
        try await driveTask.value

        #expect(collected.last == .failed(.transferFailed))
        let residue = try FileManager.default.contentsOfDirectory(atPath: phoneStaging.url.path)
        #expect(residue.isEmpty)
    }

    @Test("cancel while still searching ends the stream with exactly one failed(.cancelled) state")
    func cancelFromSearchingEndsCancelled() async throws {
        let phoneStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")
        let phoneStaging = try TemporaryDirectory()

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneStore,
            connect: { _ in
                // Never resolves on its own — only cancellation ends this.
                try await Task.sleep(for: .seconds(3600))
                fatalError("connect() should have been cancelled before this point")
            },
            packageService: MobilePackageService(),
            stagingDirectory: phoneStaging.url,
            timeout: .seconds(30)
        )

        let consumeTask = Task { () async -> [NearbyPhoneSyncState] in
            var collected: [NearbyPhoneSyncState] = []
            for await state in await phoneSession.run(handleForwardPackage: { _, _ in nil }) {
                collected.append(state)
            }
            return collected
        }
        // Give `run` a moment to reach and emit `.searching` before cancelling.
        try await Task.sleep(for: .milliseconds(100))
        await phoneSession.cancel()
        let collected = await consumeTask.value

        #expect(collected == [.searching, .failed(.cancelled)])
    }

    // MARK: - Mac-side test double

    private struct NearbySyncCoordinatorTestMacResult {
        let wasFirstPairing: Bool
        let shortAuthenticationCode: String?
        let receivedReturn: MobilePackageEnvelope?
    }

    /// Drives the Mac side of one nearby session using the REAL
    /// `NearbyPairingSession` + `NearbyPackageTransport` stack (never a
    /// fake), the same way `NearbySyncCoordinator.runSession` actually
    /// does: pair as `.listener`, send the forward package, then wait for
    /// either a return package or the phone's "nothing to return"
    /// acknowledgement.
    private static func runMacSide(
        connection: any NearbyByteConnection,
        identity: MobileDeviceIdentity,
        trustStore: any MobileDeviceIdentityStoring,
        stagingDirectory: URL,
        confirm: Bool,
        forwardEnvelope: MobilePackageEnvelope
    ) async throws -> NearbySyncCoordinatorTestMacResult {
        let session = NearbyPairingSession(role: .listener, identity: identity, trustStore: trustStore, connection: connection, timeout: .seconds(5))
        async let outcome = session.establish()
        var code: String?
        if let sasCode = try? await session.shortAuthenticationCode {
            code = sasCode
            if confirm { await session.confirmPairing() } else { await session.rejectPairing() }
        }
        let established = try await outcome

        let transport = NearbyPackageTransport(
            channel: established.channel,
            packageService: MobilePackageService(),
            peer: established.peer,
            stagingDirectory: stagingDirectory
        )
        try await transport.send(forwardEnvelope)

        let receivedReturn = try await transport.receiveOptionalReturn { directory, wrapping -> MobilePackageEnvelope in
            let service = MobilePackageService()
            let authenticated = try await service.authenticatePreview(from: directory, wrapping: wrapping)
            return try await service.commitImport(token: authenticated.token)
        }

        return NearbySyncCoordinatorTestMacResult(
            wasFirstPairing: established.wasFirstPairing,
            shortAuthenticationCode: code,
            receivedReturn: receivedReturn
        )
    }

    // MARK: - Fixtures

    private static func makeForwardEnvelope(revision: Int) -> MobilePackageEnvelope {
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: UUID()),
            snapshotID: UUID(),
            revision: revision,
            createdAt: now,
            projects: [MobileProject(id: projectID, displayName: "M31", catalogID: "M31", phase: "collecting", integrationSeconds: 60, goalHours: nil)],
            nights: [],
            captures: [],
            briefings: [],
            notes: []
        )
        return MobilePackageEnvelope(purpose: .forwardSnapshot, snapshot: snapshot, changes: [], acknowledgedChangeIDs: [])
    }

    private static func makeReturnSnapshot() -> MobileLibrarySnapshot {
        MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: UUID()),
            snapshotID: UUID(),
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            projects: [],
            nights: [],
            captures: [],
            briefings: [],
            notes: []
        )
    }

    /// Exports a small return-shaped package with a fresh `OneTimePackageKey`
    /// — exactly the wrap type `MobileLibraryStore.exportReturnPackage`
    /// (unmodified) actually uses — then bridges it to a `PairedDeviceKeyWrapping`
    /// built from the same raw bytes, exactly the way production nearby-sync
    /// glue must (see `OneTimePackageKey.rawRepresentation`'s doc comment).
    /// This exercises that bridge end to end, not just in isolation.
    /// `root` is a directory the CALLER keeps alive for as long as the
    /// returned package needs to exist (a function-local `TemporaryDirectory`
    /// here would remove its directory as soon as this function's last use
    /// of it ends — likely before `NearbyPackageTransport.sendStaged` ever
    /// reads the files back).
    private static func exportReturnPackage(root: URL) async throws -> NearbyPhoneReturnPackage {
        let destination = root.appendingPathComponent("return-\(UUID().uuidString).astromobile", isDirectory: true)
        let oneTimeKey = OneTimePackageKey()
        let snapshot = Self.makeReturnSnapshot()
        let manifest = try await MobilePackageService().export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: snapshot, baseSnapshotID: snapshot.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: destination,
            wrapping: oneTimeKey
        )
        let pairedWrapping = try PairedDeviceKeyWrapping(rawRepresentation: oneTimeKey.rawRepresentation)
        return NearbyPhoneReturnPackage(packageDirectory: destination, packageID: manifest.packageID, wrapping: pairedWrapping)
    }

    private static func assertContainsPackageFiles(_ directory: URL) throws {
        let children = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(children == [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName])
    }
}

/// Unique-per-test scratch directory, removed on deinit. Never a fixed path.
private struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroMobileTransport-NearbyPhoneSync-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
