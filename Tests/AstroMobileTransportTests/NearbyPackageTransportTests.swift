import AstroMobileDomain
import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport

@Suite struct NearbyPackageTransportTests {

    // MARK: - Happy path

    @Test func roundTripDeliversNonemptyEnvelope() async throws {
        let macRoot = try TemporaryStagingDirectory()
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()

        let macTransport = NearbyPackageTransport(
            channel: mac.channel, packageService: MobilePackageService(), peer: mac.peer, stagingDirectory: macRoot.url
        )
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        let envelope = Self.makeNonemptyEnvelope()
        try await macTransport.send(envelope)
        let received = try await phoneTransport.receive()

        #expect(received == envelope)
    }

    // MARK: - Corruption

    @Test func corruptedChunkByteFailsClosedWithNoImport() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        let exported = try await Self.exportPackageBytes(envelope: Self.makeNonemptyEnvelope())
        try await Self.driveManualTransfer(channel: mac.channel, exported: exported) { _, bytes in
            bytes[bytes.startIndex] ^= 0xFF
        }

        await #expect(throws: NearbyPackageTransportError.payloadHashMismatch) {
            _ = try await phoneTransport.receive()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: phoneRoot.url.path).isEmpty)
    }

    // MARK: - Truncation

    @Test func missingCompleteAbortsWithoutPartialImport() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        let exported = try await Self.exportPackageBytes(envelope: Self.makeNonemptyEnvelope())
        let totalChunkCount = Self.chunkCount(for: exported.payloadData.count)
        try await mac.channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: exported.manifest.packageID,
            manifestJSON: exported.manifestData,
            totalChunkCount: totalChunkCount,
            totalByteCount: Int64(exported.payloadData.count),
            contentKeyWrapRawRepresentation: exported.wrapping.rawRepresentation
        )))
        // The sender stops here — never sends `.packageComplete` — and its
        // connection goes away, exactly like an app being backgrounded or a
        // network drop mid-transfer.
        await mac.connection.cancel()

        await #expect(throws: NearbyTransportError.connectionClosed) {
            _ = try await phoneTransport.receive()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: phoneRoot.url.path).isEmpty)
    }

    // MARK: - Declared-size violation

    @Test func chunksExceedingDeclaredTotalFailClosed() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        let exported = try await Self.exportPackageBytes(envelope: Self.makeNonemptyEnvelope())
        let totalChunkCount = Self.chunkCount(for: exported.payloadData.count)
        try await mac.channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: exported.manifest.packageID,
            manifestJSON: exported.manifestData,
            totalChunkCount: totalChunkCount,
            totalByteCount: Int64(exported.payloadData.count),
            contentKeyWrapRawRepresentation: exported.wrapping.rawRepresentation
        )))
        try await Self.sendChunks(channel: mac.channel, payload: exported.payloadData)
        // One more chunk than the manifest declared: pushes the running
        // total past `totalByteCount`.
        try await mac.channel.send(.packageChunk(NearbyPackageChunkMessage(
            index: totalChunkCount, bytes: Data(repeating: 7, count: 16)
        )))

        await #expect(throws: NearbyPackageTransportError.declaredSizeMismatch) {
            _ = try await phoneTransport.receive()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: phoneRoot.url.path).isEmpty)
    }

    // MARK: - Out-of-order chunk index

    @Test func outOfOrderChunkIndexFailsClosed() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        // A payload big enough to span at least two chunks so there is a
        // real ordering to violate.
        let envelope = Self.makeNonemptyEnvelope(noteText: String(repeating: "n", count: NearbyPackageTransport.chunkByteCount))
        let exported = try await Self.exportPackageBytes(envelope: envelope)
        #expect(exported.payloadData.count > NearbyPackageTransport.chunkByteCount)

        let totalChunkCount = Self.chunkCount(for: exported.payloadData.count)
        try await mac.channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: exported.manifest.packageID,
            manifestJSON: exported.manifestData,
            totalChunkCount: totalChunkCount,
            totalByteCount: Int64(exported.payloadData.count),
            contentKeyWrapRawRepresentation: exported.wrapping.rawRepresentation
        )))
        // Send index 1 (the second chunk) before index 0 ever arrives.
        let secondChunkStart = NearbyPackageTransport.chunkByteCount
        let secondChunkEnd = min(secondChunkStart * 2, exported.payloadData.count)
        let secondChunk = exported.payloadData.subdata(in: secondChunkStart..<secondChunkEnd)
        try await mac.channel.send(.packageChunk(NearbyPackageChunkMessage(index: 1, bytes: secondChunk)))

        await #expect(throws: NearbyPackageTransportError.chunkOutOfOrder) {
            _ = try await phoneTransport.receive()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: phoneRoot.url.path).isEmpty)
    }

    // MARK: - Oversized manifest total

    @Test func oversizedManifestTotalIsRejectedAtManifestTime() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: MobilePackageService(), peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        try await mac.channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: UUID(),
            manifestJSON: Data("{}".utf8),
            totalChunkCount: 1,
            totalByteCount: Int64(NearbyFrameCodec.maxPackageStreamBytes) + 1,
            contentKeyWrapRawRepresentation: Data(repeating: 1, count: 32)
        )))

        await #expect(throws: NearbyPackageTransportError.oversizedPackageStream) {
            _ = try await phoneTransport.receive()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: phoneRoot.url.path).isEmpty)
    }

    // MARK: - Sender cleanup

    @Test func senderStagingDirectoryIsEmptyAfterSend() async throws {
        let macRoot = try TemporaryStagingDirectory()
        let (mac, _) = try await Self.pair()
        let macTransport = NearbyPackageTransport(
            channel: mac.channel, packageService: MobilePackageService(), peer: mac.peer, stagingDirectory: macRoot.url
        )

        try await macTransport.send(Self.makeNonemptyEnvelope())

        #expect(try FileManager.default.contentsOfDirectory(atPath: macRoot.url.path).isEmpty)
    }

    // MARK: - Duplicate handling surfaces the service's own rejection

    @Test func reReceivingACommittedPackageSurfacesTheServicesDuplicateRejection() async throws {
        let phoneRoot = try TemporaryStagingDirectory()
        let (mac, phone) = try await Self.pair()
        let sharedPackageService = MobilePackageService()
        let phoneTransport = NearbyPackageTransport(
            channel: phone.channel, packageService: sharedPackageService, peer: phone.peer, stagingDirectory: phoneRoot.url
        )

        let envelope = Self.makeNonemptyEnvelope()
        let exported = try await Self.exportPackageBytes(envelope: envelope)

        // First delivery of this exact packageID: replay it manually twice
        // over the same already-paired channel/service, mirroring a sender
        // that (for whatever reason) sends the identical package again.
        try await Self.driveManualTransfer(channel: mac.channel, exported: exported)
        let first = try await phoneTransport.receive()
        #expect(first == envelope)

        try await Self.driveManualTransfer(channel: mac.channel, exported: exported)
        await #expect(throws: MobilePackageError.duplicatePackageID) {
            _ = try await phoneTransport.receive()
        }
    }

    // MARK: - Test fixtures and helpers

    private struct PairedSide {
        let channel: NearbySecureChannel
        let peer: MobilePeerIdentity
        let connection: InMemoryDuplexConnection
    }

    private static func pair() async throws -> (mac: PairedSide, phone: PairedSide) {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        let macTask = Task<NearbyPairingOutcome, Error> { try await macSession.establish() }
        let phoneTask = Task<NearbyPairingOutcome, Error> { try await phoneSession.establish() }

        _ = try await macSession.shortAuthenticationCode
        _ = try await phoneSession.shortAuthenticationCode
        await macSession.confirmPairing()
        await phoneSession.confirmPairing()

        let mac = try await macTask.value
        let phone = try await phoneTask.value

        return (
            PairedSide(channel: mac.channel, peer: mac.peer, connection: macConnection),
            PairedSide(channel: phone.channel, peer: phone.peer, connection: phoneConnection)
        )
    }

    private static func makeNonemptyEnvelope(noteText: String = "updated on the phone") -> MobilePackageEnvelope {
        let projectID = UUID()
        let briefingID = UUID()
        let noteID = "briefing-note"
        let itemID = "checklist-item"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: UUID()),
            snapshotID: UUID(),
            revision: 1,
            createdAt: now,
            projects: [MobileProject(id: projectID, displayName: "M31", catalogID: "M31", phase: "collecting", integrationSeconds: 120, goalHours: nil)],
            nights: [],
            captures: [],
            briefings: [MobileBriefing(
                id: briefingID,
                revision: 1,
                savedAt: now,
                nightDate: nil,
                readiness: "ready",
                targets: [],
                checklist: [MobileChecklistSection(
                    id: "setup",
                    title: "Setup",
                    items: [MobileChecklistItem(id: itemID, title: "Focus", explanation: nil, isCompleted: false, baseRevision: 0)]
                )],
                noteID: noteID
            )],
            notes: [MobileNote(
                id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: noteText,
                baseRevision: 0, updatedAt: now, isEditableOnPhone: true
            )]
        )

        return MobilePackageEnvelope(
            purpose: .forwardSnapshot,
            snapshot: snapshot,
            changes: [
                .checklistCompletion(ChecklistCompletionChange(
                    changeID: UUID(), deviceID: UUID(), briefingID: briefingID, itemID: itemID,
                    baseRevision: 0, isCompleted: true, createdAt: now
                )),
                .noteRevision(NoteRevisionChange(
                    changeID: UUID(), deviceID: UUID(), noteID: noteID, ownerID: briefingID.uuidString,
                    baseRevision: 0, text: noteText, createdAt: now
                )),
            ],
            acknowledgedChangeIDs: [UUID()]
        )
    }

    private struct ExportedPackage {
        let manifest: MobilePackageManifest
        let manifestData: Data
        let payloadData: Data
        let wrapping: PairedDeviceKeyWrapping
    }

    private static func exportPackageBytes(envelope: MobilePackageEnvelope) async throws -> ExportedPackage {
        let root = try TemporaryStagingDirectory()
        let destination = root.url.appendingPathComponent("package.astromobile", isDirectory: true)
        let wrapping = PairedDeviceKeyWrapping()
        let manifest = try await MobilePackageService().export(envelope, to: destination, wrapping: wrapping)
        let manifestData = try Data(contentsOf: destination.appendingPathComponent(MobilePackageService.manifestFileName))
        let payloadData = try Data(contentsOf: destination.appendingPathComponent(MobilePackageService.encryptedPayloadFileName))
        return ExportedPackage(manifest: manifest, manifestData: manifestData, payloadData: payloadData, wrapping: wrapping)
    }

    private static func chunkCount(for byteCount: Int) -> Int {
        byteCount.isMultiple(of: NearbyPackageTransport.chunkByteCount) && byteCount > 0
            ? byteCount / NearbyPackageTransport.chunkByteCount
            : (byteCount + NearbyPackageTransport.chunkByteCount - 1) / NearbyPackageTransport.chunkByteCount
    }

    private static func sendChunks(
        channel: NearbySecureChannel,
        payload: Data,
        corrupt: ((Int, inout Data) -> Void)? = nil
    ) async throws {
        var offset = 0
        var index = 0
        while offset < payload.count {
            let end = min(offset + NearbyPackageTransport.chunkByteCount, payload.count)
            var chunk = payload.subdata(in: offset..<end)
            corrupt?(index, &chunk)
            try await channel.send(.packageChunk(NearbyPackageChunkMessage(index: index, bytes: chunk)))
            offset = end
            index += 1
        }
    }

    /// Drives a full, well-formed manifest → chunks → complete sequence
    /// directly over an already-established channel, mirroring exactly what
    /// `NearbyPackageTransport.send` would send, with an optional per-chunk
    /// mutation applied after the fact (to model in-flight corruption that
    /// the AEAD channel itself would not have introduced).
    private static func driveManualTransfer(
        channel: NearbySecureChannel,
        exported: ExportedPackage,
        corrupt: ((Int, inout Data) -> Void)? = nil
    ) async throws {
        let totalChunkCount = chunkCount(for: exported.payloadData.count)
        try await channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: exported.manifest.packageID,
            manifestJSON: exported.manifestData,
            totalChunkCount: totalChunkCount,
            totalByteCount: Int64(exported.payloadData.count),
            contentKeyWrapRawRepresentation: exported.wrapping.rawRepresentation
        )))
        try await sendChunks(channel: channel, payload: exported.payloadData, corrupt: corrupt)
        try await channel.send(.packageComplete(NearbyPackageCompleteMessage(
            packageID: exported.manifest.packageID,
            sha256Hex: MobilePackageCrypto.sha256Hex(exported.payloadData)
        )))
    }
}

/// Unique-per-use, auto-cleaned scratch directory for these tests. Never a
/// fixed path: every instance gets its own UUID-named subdirectory under the
/// system temporary directory, removed on deinit.
private struct TemporaryStagingDirectory: ~Copyable {
    let url: URL

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroMobileTransport-NearbyPackage-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
