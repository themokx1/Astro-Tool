import AstroMobileDomain
import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport

@Suite struct MobileDeviceIdentityTests {

    // MARK: - Own identity lifecycle

    @Test func ownIdentityIsCreatedOnceAndReloadedStably() throws {
        let store = InMemoryDeviceIdentityStore()

        let first = try store.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let second = try store.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")

        #expect(first.deviceID == second.deviceID)
        #expect(first.signingKey.rawRepresentation == second.signingKey.rawRepresentation)
        #expect(first.publicIdentity.signingPublicKeyRawRepresentation == second.publicIdentity.signingPublicKeyRawRepresentation)
    }

    @Test func ownIdentityDisplayNameUpdatesOnReloadWithoutChangingKeyMaterial() throws {
        let store = InMemoryDeviceIdentityStore()

        let first = try store.loadOrCreateOwnIdentity(displayName: "Original Name")
        let second = try store.loadOrCreateOwnIdentity(displayName: "Renamed Mac")

        #expect(first.deviceID == second.deviceID)
        #expect(first.signingKey.rawRepresentation == second.signingKey.rawRepresentation)
        #expect(second.publicIdentity.displayName == "Renamed Mac")
        #expect(second.publicIdentity.deviceID == first.deviceID)
    }

    @Test func publicIdentityVerifiesASignatureMadeWithTheMatchingPrivateKey() throws {
        let store = InMemoryDeviceIdentityStore()
        let identity = try store.loadOrCreateOwnIdentity(displayName: "Sanity Check Device")

        let message = Data("nearby-sync-sanity-check".utf8)
        let signature = try identity.signingKey.signature(for: message)

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicIdentity.signingPublicKeyRawRepresentation)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    // MARK: - Trusted peers

    @Test func storingAndReloadingTrustedPeersRoundTrips() throws {
        let store = InMemoryDeviceIdentityStore()
        let peerA = makePeer(displayName: "iPhone A")
        let peerB = makePeer(displayName: "iPhone B")

        try store.storeTrustedPeer(peerA)
        try store.storeTrustedPeer(peerB)

        let peers = try store.trustedPeers()
        #expect(Set(peers.map(\.deviceID)) == Set([peerA.deviceID, peerB.deviceID]))
        #expect(peers.contains(peerA))
        #expect(peers.contains(peerB))
    }

    @Test func storingATrustedPeerWithAChangedPublicKeyThrowsAndDoesNotReplaceIt() throws {
        let store = InMemoryDeviceIdentityStore()
        let deviceID = UUID()
        let original = makePeer(deviceID: deviceID, displayName: "iPhone")
        try store.storeTrustedPeer(original)

        let tampered = MobilePeerIdentity(
            deviceID: deviceID,
            signingPublicKeyRawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            displayName: "iPhone"
        )

        #expect(throws: NearbyTransportError.peerIdentityChanged(deviceID)) {
            try store.storeTrustedPeer(tampered)
        }

        let peers = try store.trustedPeers()
        #expect(peers == [original])
    }

    @Test func storingATrustedPeerWithTheSameKeyAndANewDisplayNameUpdatesTheName() throws {
        let store = InMemoryDeviceIdentityStore()
        let deviceID = UUID()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let original = MobilePeerIdentity(deviceID: deviceID, signingPublicKeyRawRepresentation: key, displayName: "Old Name")
        try store.storeTrustedPeer(original)

        let renamed = MobilePeerIdentity(deviceID: deviceID, signingPublicKeyRawRepresentation: key, displayName: "New Name")
        try store.storeTrustedPeer(renamed)

        let peers = try store.trustedPeers()
        #expect(peers == [renamed])
    }

    @Test func removingATrustedPeerForgetsIt() throws {
        let store = InMemoryDeviceIdentityStore()
        let peer = makePeer(displayName: "iPhone")
        try store.storeTrustedPeer(peer)

        try store.removeTrustedPeer(deviceID: peer.deviceID)

        #expect(try store.trustedPeers().isEmpty)
    }

    @Test func removingAnUnknownPeerIsANoOp() throws {
        let store = InMemoryDeviceIdentityStore()
        try store.removeTrustedPeer(deviceID: UUID())
        #expect(try store.trustedPeers().isEmpty)
    }

    @Test func storingAPeerWithAWrongLengthPublicKeyIsRejected() throws {
        let store = InMemoryDeviceIdentityStore()
        let malformed = MobilePeerIdentity(
            deviceID: UUID(),
            signingPublicKeyRawRepresentation: Data(repeating: 7, count: 16),
            displayName: "Bad Key"
        )

        #expect(throws: NearbyTransportError.identityStoreCorrupted) {
            try store.storeTrustedPeer(malformed)
        }
        #expect(try store.trustedPeers().isEmpty)
    }

    // MARK: - Codable round trip

    @Test func mobilePeerIdentityRoundTripsThroughMobileJSON() throws {
        let peer = makePeer(displayName: "Round Trip iPhone")
        let encoded = try MobileJSON.encoder.encode(peer)
        let decoded = try MobileJSON.decoder.decode(MobilePeerIdentity.self, from: encoded)
        #expect(decoded == peer)
    }

    // MARK: - Fail-closed on corrupted persisted bytes

    @Test func malformedPersistedOwnIdentityBytesFailClosed() throws {
        let store = InMemoryDeviceIdentityStore()
        store.corruptOwnIdentityData(Data("not json at all".utf8))

        #expect(throws: NearbyTransportError.identityStoreCorrupted) {
            try store.loadOrCreateOwnIdentity(displayName: "Anything")
        }
    }

    @Test func malformedPersistedPeerListBytesFailClosed() throws {
        let store = InMemoryDeviceIdentityStore()
        store.corruptPeersData(Data("also not json".utf8))

        #expect(throws: NearbyTransportError.identityStoreCorrupted) {
            try store.trustedPeers()
        }
    }

    // MARK: - Helpers

    private func makePeer(deviceID: UUID = UUID(), displayName: String) -> MobilePeerIdentity {
        MobilePeerIdentity(
            deviceID: deviceID,
            signingPublicKeyRawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            displayName: displayName
        )
    }
}
