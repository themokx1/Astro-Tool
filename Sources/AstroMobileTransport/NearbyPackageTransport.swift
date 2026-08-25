import AstroMobileDomain
import Foundation

/// Failures specific to carrying a sealed `.astromobile` package over a
/// `NearbySecureChannel`. These are distinct from `MobilePackageError`
/// (which `MobilePackageService` itself throws once a fully assembled,
/// hash-verified package is finally handed to it) and from
/// `NearbyTransportError` (the wire/handshake layer). Every case here means
/// the wire-level chunk stream itself was malformed or violated its own
/// declared shape — the transport fails closed before `MobilePackageService`
/// ever sees a byte of it.
public enum NearbyPackageTransportError: Error, Equatable, Sendable {
    /// A message arrived at a protocol step that did not expect it: a chunk
    /// or `.packageComplete` before any `.packageManifest`, a second
    /// `.packageManifest` mid-transfer, or any other message kind in place
    /// of the one the current step requires.
    case unexpectedMessage
    /// A `.packageManifest` message's own fields were structurally invalid
    /// (a `contentKeyWrapRawRepresentation` that is not exactly 32 bytes, or
    /// a non-positive `totalByteCount`/negative `totalChunkCount`).
    case invalidManifest
    /// The manifest declared a `totalByteCount` larger than
    /// `NearbyFrameCodec.maxPackageStreamBytes`. Rejected immediately, before
    /// a single chunk is read.
    case oversizedPackageStream
    /// The bytes actually received do not match what the manifest declared:
    /// a chunk pushed the running total past `totalByteCount` (or past the
    /// global stream cap), or `.packageComplete` arrived with a running
    /// total short of `totalByteCount`.
    case declaredSizeMismatch
    /// A `.packageChunk` arrived with an index other than the receiver's
    /// next expected index (out of order, skipped, or replayed).
    case chunkOutOfOrder
    /// The SHA-256 of the fully assembled payload does not match the hash
    /// `.packageComplete` carried — the transfer was corrupted in transit.
    case payloadHashMismatch
    /// A local filesystem operation needed to stage the received package
    /// for `MobilePackageService` failed (directory creation or file write).
    case stagingFailed
}

/// Carries the exact sealed `.astromobile` package bytes Wave 1 already
/// validates (`manifest.json` + the encrypted payload file) over an
/// authenticated `NearbySecureChannel`, so a paired Mac and iPhone can sync
/// without AirDrop while every Wave 1 safety gate — hash verification,
/// duplicate-package rejection, envelope/schema validation, size caps —
/// stays in force untouched (plan ruling 1: "package-over-session, not
/// envelope-over-session").
///
/// `send` calls `MobilePackageService.export` into a private, per-call
/// staging directory under `stagingDirectory`, streams the resulting
/// manifest and payload bytes as `.packageManifest` / `.packageChunk` /
/// `.packageComplete` messages, and always deletes that staging directory
/// before returning (success or failure).
///
/// `receive` accepts exactly one `.packageManifest`, then chunks with
/// strictly sequential indexes (enforcing the manifest's own declared byte
/// count and the wire layer's global stream cap as running limits), and
/// only after `.packageComplete`'s hash is verified against the fully
/// assembled bytes does it ever touch disk or call
/// `MobilePackageService.authenticatePreview`/`commitImport` — the exact
/// same two calls the AirDrop import path uses (see
/// `MobileLibraryStore.swift` and `MobileReturnApplicationCoordinator.swift`),
/// so package-internal duplicate/hash/schema handling is never duplicated or
/// bypassed here. Any violation deletes only this transport's own staging
/// copy, sends `.failure(reason: .transferAborted)` best-effort, and throws
/// a typed error — no partial import is ever attempted.
///
/// ## The `pairedDevice` key transport
/// See the doc comment on `PairedDeviceKeyWrapping` in
/// `MobilePackageCrypto.swift` for why this does not (and cannot, without
/// extending `MobileDeviceIdentity`) wrap the content key with Curve25519
/// key agreement to the peer's stored identity key, and for the actual
/// design: a fresh per-transfer AEAD wrap key that travels only inside the
/// `.packageManifest` message, itself only ever sent through
/// `NearbySecureChannel.send` — the already-authenticated channel is this
/// key's entire transport.
public actor NearbyPackageTransport: MobileSyncTransport {
    /// Raw payload bytes per `.packageChunk` message. Chosen so the
    /// message's JSON encoding — the raw bytes base64-inflate by 4/3, plus a
    /// few bytes of JSON structure and the `index` field — sits comfortably
    /// under `NearbySecureChannel.maxPlaintextBytes` (which itself already
    /// backs off from `NearbyFrameCodec.maxFramePayloadBytes` by the AEAD
    /// nonce+tag overhead). 256 KiB raw inflates to roughly 342 KiB base64,
    /// far under the ~1 MiB plaintext ceiling, leaving generous headroom.
    static let chunkByteCount = 256 * 1024

    private let channel: NearbySecureChannel
    private let packageService: MobilePackageService
    private let peer: MobilePeerIdentity
    private let stagingDirectory: URL
    private let onProgress: (@Sendable (Double) -> Void)?

    /// - Parameters:
    ///   - channel: The authenticated post-handshake channel
    ///     `NearbyPairingSession.establish()` produced.
    ///   - packageService: The same `MobilePackageService` instance the
    ///     caller uses for every other package flow, so in-memory duplicate-
    ///     package tracking (`consumedPackageIDs`) is shared rather than
    ///     reset per transfer.
    ///   - peer: The paired peer's identity. Not used for any cryptographic
    ///     wrapping (see `PairedDeviceKeyWrapping`'s doc comment) — kept so
    ///     staging directories are namespaced per peer for easier debugging,
    ///     and as the natural extension point if a future wave adds a real
    ///     agreement key to `MobileDeviceIdentity`.
    ///   - stagingDirectory: A directory this transport owns exclusively.
    ///     Each `send`/`receive` call creates one unique subdirectory here
    ///     and always removes it before returning.
    ///   - onProgress: Optional fraction-complete callback (0...1), invoked
    ///     as chunks are sent or received. No UI consumes this yet (Task 6).
    public init(
        channel: NearbySecureChannel,
        packageService: MobilePackageService,
        peer: MobilePeerIdentity,
        stagingDirectory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.channel = channel
        self.packageService = packageService
        self.peer = peer
        self.stagingDirectory = stagingDirectory
        self.onProgress = onProgress
    }

    // MARK: - Send

    public func send(_ envelope: MobilePackageEnvelope) async throws {
        let fileManager = FileManager.default
        let sessionDirectory = stagingDirectory.appendingPathComponent(
            "send-\(peer.deviceID.uuidString)-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sessionDirectory) }

        let packageDestination = sessionDirectory.appendingPathComponent("package.astromobile", isDirectory: true)
        let wrapping = PairedDeviceKeyWrapping()
        let manifest = try await packageService.export(envelope, to: packageDestination, wrapping: wrapping)

        let manifestData = try Data(contentsOf: packageDestination.appendingPathComponent(MobilePackageService.manifestFileName))
        let payloadData = try Data(contentsOf: packageDestination.appendingPathComponent(MobilePackageService.encryptedPayloadFileName))

        let totalChunkCount = payloadData.isEmpty
            ? 0
            : (payloadData.count + Self.chunkByteCount - 1) / Self.chunkByteCount

        try await channel.send(.packageManifest(NearbyPackageManifestMessage(
            packageID: manifest.packageID,
            manifestJSON: manifestData,
            totalChunkCount: totalChunkCount,
            totalByteCount: Int64(payloadData.count),
            contentKeyWrapRawRepresentation: wrapping.rawRepresentation
        )))

        var offset = 0
        var index = 0
        while offset < payloadData.count {
            let end = min(offset + Self.chunkByteCount, payloadData.count)
            let chunk = payloadData.subdata(in: offset..<end)
            try await channel.send(.packageChunk(NearbyPackageChunkMessage(index: index, bytes: chunk)))
            offset = end
            index += 1
            onProgress?(Double(offset) / Double(max(payloadData.count, 1)))
        }

        try await channel.send(.packageComplete(NearbyPackageCompleteMessage(
            packageID: manifest.packageID,
            sha256Hex: MobilePackageCrypto.sha256Hex(payloadData)
        )))
    }

    // MARK: - Receive

    public func receive() async throws -> MobilePackageEnvelope {
        let manifestMessage = try await expectManifest()

        var buffer = Data()
        buffer.reserveCapacity(min(Int(manifestMessage.totalByteCount), NearbyFrameCodec.maxPackageStreamBytes))
        var expectedIndex = 0

        while true {
            let message = try await channel.receive()
            switch message {
            case .packageChunk(let chunk):
                guard chunk.index == expectedIndex else {
                    await abortReceive()
                    throw NearbyPackageTransportError.chunkOutOfOrder
                }
                let nextByteCount = buffer.count + chunk.bytes.count
                guard Int64(nextByteCount) <= manifestMessage.totalByteCount,
                      nextByteCount <= NearbyFrameCodec.maxPackageStreamBytes else {
                    await abortReceive()
                    throw NearbyPackageTransportError.declaredSizeMismatch
                }
                buffer.append(chunk.bytes)
                expectedIndex += 1
                onProgress?(Double(buffer.count) / Double(max(manifestMessage.totalByteCount, 1)))

            case .packageComplete(let complete):
                guard complete.packageID == manifestMessage.packageID else {
                    await abortReceive()
                    throw NearbyPackageTransportError.unexpectedMessage
                }
                guard Int64(buffer.count) == manifestMessage.totalByteCount else {
                    await abortReceive()
                    throw NearbyPackageTransportError.declaredSizeMismatch
                }
                guard MobilePackageCrypto.sha256Hex(buffer) == complete.sha256Hex else {
                    await abortReceive()
                    throw NearbyPackageTransportError.payloadHashMismatch
                }
                return try await importAssembledPackage(manifestMessage: manifestMessage, payload: buffer)

            default:
                // Includes a second `.packageManifest` mid-transfer, and any
                // other message kind out of place — both fail closed.
                await abortReceive()
                throw NearbyPackageTransportError.unexpectedMessage
            }
        }
    }

    /// The first message of a receive must be a structurally valid
    /// `.packageManifest`. A chunk or completion before any manifest, or any
    /// other message kind, is `.unexpectedMessage`; a manifest whose own
    /// fields are malformed is `.invalidManifest`; a manifest declaring more
    /// bytes than the wire layer's global cap is `.oversizedPackageStream` —
    /// all rejected before a single chunk is ever read.
    private func expectManifest() async throws -> NearbyPackageManifestMessage {
        let message = try await channel.receive()
        guard case .packageManifest(let manifest) = message else {
            await abortReceive()
            throw NearbyPackageTransportError.unexpectedMessage
        }
        guard manifest.contentKeyWrapRawRepresentation.count == 32,
              manifest.totalByteCount > 0,
              manifest.totalChunkCount >= 0,
              manifest.manifestJSON.count <= MobilePackageService.maximumManifestByteCount else {
            await abortReceive()
            throw NearbyPackageTransportError.invalidManifest
        }
        guard manifest.totalByteCount <= Int64(NearbyFrameCodec.maxPackageStreamBytes) else {
            await abortReceive()
            throw NearbyPackageTransportError.oversizedPackageStream
        }
        return manifest
    }

    /// Stages the fully assembled, hash-verified payload as a package
    /// directory `MobilePackageService` can read, then imports it through
    /// exactly the same two calls the AirDrop path uses:
    /// `authenticatePreview` followed by `commitImport`. Any failure —
    /// staging, authentication, or the service's own validation (including
    /// its duplicate-`packageID` rejection, which this deliberately never
    /// bypasses) — removes the staging copy and rethrows untouched.
    private func importAssembledPackage(
        manifestMessage: NearbyPackageManifestMessage,
        payload: Data
    ) async throws -> MobilePackageEnvelope {
        let fileManager = FileManager.default
        let sessionDirectory = stagingDirectory.appendingPathComponent(
            "receive-\(peer.deviceID.uuidString)-\(UUID().uuidString)", isDirectory: true
        )
        let packageDirectory = sessionDirectory.appendingPathComponent("package.astromobile", isDirectory: true)
        do {
            try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        } catch {
            throw NearbyPackageTransportError.stagingFailed
        }
        defer { try? fileManager.removeItem(at: sessionDirectory) }

        do {
            try manifestMessage.manifestJSON.write(to: packageDirectory.appendingPathComponent(MobilePackageService.manifestFileName))
            try payload.write(to: packageDirectory.appendingPathComponent(MobilePackageService.encryptedPayloadFileName))
        } catch {
            await abortReceive()
            throw NearbyPackageTransportError.stagingFailed
        }

        let wrapping: PairedDeviceKeyWrapping
        do {
            wrapping = try PairedDeviceKeyWrapping(rawRepresentation: manifestMessage.contentKeyWrapRawRepresentation)
        } catch {
            await abortReceive()
            throw error
        }

        do {
            let authenticated = try await packageService.authenticatePreview(from: packageDirectory, wrapping: wrapping)
            return try await packageService.commitImport(token: authenticated.token)
        } catch {
            await abortReceive()
            throw error
        }
    }

    /// Best-effort notification to the peer that this side is giving up on
    /// the transfer. Never throws, never masks the real error the caller is
    /// about to throw — a `NearbySecureChannel` that is already unusable
    /// (e.g. the underlying connection just failed) simply drops this.
    private func abortReceive() async {
        try? await channel.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
    }
}
