import AstroMobileDomain
import CryptoKit
import Foundation
import Security

/// This device's own persistent nearby-sync identity: a stable device ID and
/// a long-lived Curve25519 signing key. The signing key never leaves the
/// store it was created in — it authenticates ephemeral session keys during
/// pairing (spec §7.3) but is never itself transmitted.
public struct MobileDeviceIdentity: Sendable {
    public let deviceID: UUID
    public let signingKey: Curve25519.Signing.PrivateKey
    public let displayName: String

    public init(deviceID: UUID, signingKey: Curve25519.Signing.PrivateKey, displayName: String) {
        self.deviceID = deviceID
        self.signingKey = signingKey
        self.displayName = displayName
    }

    /// The half of this identity that is safe to hand to a peer: the device
    /// ID, the public signing key, and the current display name.
    public var publicIdentity: MobilePeerIdentity {
        MobilePeerIdentity(
            deviceID: deviceID,
            signingPublicKeyRawRepresentation: signingKey.publicKey.rawRepresentation,
            displayName: displayName
        )
    }
}

/// The identity a nearby peer presents and, once trusted, the identity a
/// device's own store persists about that peer. Carries no secret material —
/// only what is safe to exchange and store on both sides.
public struct MobilePeerIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let signingPublicKeyRawRepresentation: Data
    public let displayName: String

    public init(deviceID: UUID, signingPublicKeyRawRepresentation: Data, displayName: String) {
        self.deviceID = deviceID
        self.signingPublicKeyRawRepresentation = signingPublicKeyRawRepresentation
        self.displayName = displayName
    }
}

/// Persists this device's own identity and the peers it has paired with.
///
/// Trust-on-first-use (plan ruling 2): `storeTrustedPeer` never silently
/// replaces a known peer's public key — a changed key for an already-trusted
/// deviceID is a hard failure (`peerIdentityChanged`), never a quiet update.
/// Only the display name may change on an otherwise-matching peer.
public protocol MobileDeviceIdentityStoring: Sendable {
    func loadOrCreateOwnIdentity(displayName: String) throws -> MobileDeviceIdentity
    func trustedPeers() throws -> [MobilePeerIdentity]
    func storeTrustedPeer(_ peer: MobilePeerIdentity) throws
    func removeTrustedPeer(deviceID: UUID) throws
}

/// The wire/persisted shape of `MobileDeviceIdentity`, plus the validation
/// rules `InMemoryDeviceIdentityStore` and `KeychainDeviceIdentityStore` both
/// run — kept in one place so the in-memory store's tests exercise exactly
/// the rules the Keychain store enforces in production.
enum MobileDeviceIdentityStoreLogic {
    /// A Curve25519 raw public (or private) key representation is always
    /// exactly 32 bytes; anything else is malformed input, never a
    /// legitimately different key.
    static let curve25519KeyByteCount = 32

    struct StoredOwnIdentity: Codable {
        let deviceID: UUID
        let signingKeyRawRepresentation: Data
        let displayName: String
    }

    /// Loads the persisted own identity, or creates and persists one if none
    /// exists yet. A reload with a different `displayName` updates the
    /// persisted name but never the deviceID or key material.
    static func loadOrCreateOwnIdentity(
        displayName: String,
        readOwnIdentityData: () throws -> Data?,
        writeOwnIdentityData: (Data) throws -> Void
    ) throws -> MobileDeviceIdentity {
        guard let data = try readOwnIdentityData() else {
            let deviceID = UUID()
            let signingKey = Curve25519.Signing.PrivateKey()
            let stored = StoredOwnIdentity(
                deviceID: deviceID,
                signingKeyRawRepresentation: signingKey.rawRepresentation,
                displayName: displayName
            )
            let encoded = try MobileJSON.encoder.encode(stored)
            try writeOwnIdentityData(encoded)
            return MobileDeviceIdentity(deviceID: deviceID, signingKey: signingKey, displayName: displayName)
        }

        let stored: StoredOwnIdentity
        do {
            stored = try MobileJSON.decoder.decode(StoredOwnIdentity.self, from: data)
        } catch {
            throw NearbyTransportError.identityStoreCorrupted
        }
        guard stored.signingKeyRawRepresentation.count == curve25519KeyByteCount else {
            throw NearbyTransportError.identityStoreCorrupted
        }
        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.signingKeyRawRepresentation)
        } catch {
            throw NearbyTransportError.identityStoreCorrupted
        }

        if stored.displayName != displayName {
            let updated = StoredOwnIdentity(
                deviceID: stored.deviceID,
                signingKeyRawRepresentation: stored.signingKeyRawRepresentation,
                displayName: displayName
            )
            try writeOwnIdentityData(try MobileJSON.encoder.encode(updated))
        }

        return MobileDeviceIdentity(deviceID: stored.deviceID, signingKey: signingKey, displayName: displayName)
    }

    static func trustedPeers(readPeersData: () throws -> Data?) throws -> [MobilePeerIdentity] {
        guard let data = try readPeersData() else { return [] }
        do {
            return try MobileJSON.decoder.decode([MobilePeerIdentity].self, from: data)
        } catch {
            throw NearbyTransportError.identityStoreCorrupted
        }
    }

    /// Validates and persists `peer`. Throws `identityStoreCorrupted` for a
    /// structurally invalid key (wrong byte count), `peerIdentityChanged` for
    /// an already-trusted deviceID whose key does not match, and otherwise
    /// inserts (or updates the display name of) the peer.
    static func storeTrustedPeer(
        _ peer: MobilePeerIdentity,
        readPeersData: () throws -> Data?,
        writePeersData: ([MobilePeerIdentity]) throws -> Void
    ) throws {
        guard peer.signingPublicKeyRawRepresentation.count == curve25519KeyByteCount else {
            throw NearbyTransportError.identityStoreCorrupted
        }

        var peers = try trustedPeers(readPeersData: readPeersData)
        if let index = peers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            guard peers[index].signingPublicKeyRawRepresentation == peer.signingPublicKeyRawRepresentation else {
                throw NearbyTransportError.peerIdentityChanged(peer.deviceID)
            }
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        try writePeersData(peers)
    }

    static func removeTrustedPeer(
        deviceID: UUID,
        readPeersData: () throws -> Data?,
        writePeersData: ([MobilePeerIdentity]) throws -> Void
    ) throws {
        var peers = try trustedPeers(readPeersData: readPeersData)
        peers.removeAll { $0.deviceID == deviceID }
        try writePeersData(peers)
    }
}

/// In-memory `MobileDeviceIdentityStoring` for tests: never touches the
/// Keychain. Runs the exact same validation as `KeychainDeviceIdentityStore`
/// via `MobileDeviceIdentityStoreLogic`.
public final class InMemoryDeviceIdentityStore: MobileDeviceIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var ownIdentityData: Data?
    private var peersData: Data?

    public init() {}

    public func loadOrCreateOwnIdentity(displayName: String) throws -> MobileDeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        return try MobileDeviceIdentityStoreLogic.loadOrCreateOwnIdentity(
            displayName: displayName,
            readOwnIdentityData: { self.ownIdentityData },
            writeOwnIdentityData: { self.ownIdentityData = $0 }
        )
    }

    public func trustedPeers() throws -> [MobilePeerIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return try MobileDeviceIdentityStoreLogic.trustedPeers(readPeersData: { self.peersData })
    }

    public func storeTrustedPeer(_ peer: MobilePeerIdentity) throws {
        lock.lock()
        defer { lock.unlock() }
        try MobileDeviceIdentityStoreLogic.storeTrustedPeer(
            peer,
            readPeersData: { self.peersData },
            writePeersData: { peers in self.peersData = try MobileJSON.encoder.encode(peers) }
        )
    }

    public func removeTrustedPeer(deviceID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try MobileDeviceIdentityStoreLogic.removeTrustedPeer(
            deviceID: deviceID,
            readPeersData: { self.peersData },
            writePeersData: { peers in self.peersData = try MobileJSON.encoder.encode(peers) }
        )
    }

    /// Test-only seam: overwrites the persisted own-identity bytes with
    /// arbitrary data so tests can exercise the "malformed persisted bytes
    /// fail closed" path without a real Keychain. Not public — reachable
    /// only through `@testable import`.
    func corruptOwnIdentityData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        ownIdentityData = data
    }

    /// Test-only seam, peer-list counterpart of `corruptOwnIdentityData`.
    func corruptPeersData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        peersData = data
    }
}

/// Production `MobileDeviceIdentityStoring`: persists the own identity and
/// trusted peers as two Keychain generic-password items. Never synced to
/// iCloud (no `kSecAttrSynchronizable`), accessible once the device has been
/// unlocked at least once since boot.
///
/// Storage shape mirrors `MobileDeviceIdentityStoreLogic`: the own identity
/// is one JSON object under account `"own-identity"`; trusted peers are one
/// JSON array under account `"trusted-peers"`. Every `SecItem` failure is
/// wrapped into `NearbyTransportError.identityStoreCorrupted` — callers never
/// see a raw `OSStatus`.
public final class KeychainDeviceIdentityStore: MobileDeviceIdentityStoring, Sendable {
    private static let service = "io.github.themokx1.astrotool.nearby"
    private static let ownIdentityAccount = "own-identity"
    private static let trustedPeersAccount = "trusted-peers"

    public init() {}

    public func loadOrCreateOwnIdentity(displayName: String) throws -> MobileDeviceIdentity {
        try MobileDeviceIdentityStoreLogic.loadOrCreateOwnIdentity(
            displayName: displayName,
            readOwnIdentityData: { try Self.readItem(account: Self.ownIdentityAccount) },
            writeOwnIdentityData: { try Self.writeItem(account: Self.ownIdentityAccount, data: $0) }
        )
    }

    public func trustedPeers() throws -> [MobilePeerIdentity] {
        try MobileDeviceIdentityStoreLogic.trustedPeers(
            readPeersData: { try Self.readItem(account: Self.trustedPeersAccount) }
        )
    }

    public func storeTrustedPeer(_ peer: MobilePeerIdentity) throws {
        try MobileDeviceIdentityStoreLogic.storeTrustedPeer(
            peer,
            readPeersData: { try Self.readItem(account: Self.trustedPeersAccount) },
            writePeersData: { peers in
                try Self.writeItem(account: Self.trustedPeersAccount, data: try MobileJSON.encoder.encode(peers))
            }
        )
    }

    public func removeTrustedPeer(deviceID: UUID) throws {
        try MobileDeviceIdentityStoreLogic.removeTrustedPeer(
            deviceID: deviceID,
            readPeersData: { try Self.readItem(account: Self.trustedPeersAccount) },
            writePeersData: { peers in
                try Self.writeItem(account: Self.trustedPeersAccount, data: try MobileJSON.encoder.encode(peers))
            }
        )
    }

    // MARK: - SecItem plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readItem(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw NearbyTransportError.identityStoreCorrupted }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw NearbyTransportError.identityStoreCorrupted
        }
    }

    private static func writeItem(account: String, data: Data) throws {
        let query = baseQuery(account: account)
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NearbyTransportError.identityStoreCorrupted }
        default:
            throw NearbyTransportError.identityStoreCorrupted
        }
    }
}
