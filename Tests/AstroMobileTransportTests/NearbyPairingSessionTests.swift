import AstroMobileDomain
import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport

@Suite struct NearbyPairingSessionTests {

    // MARK: - Happy path: first pairing

    @Test func bothSidesFirstPairingDeriveTheSameCodeAndNeitherReturnsBeforeBothConfirm() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        // establish() must be running concurrently BEFORE shortAuthenticationCode
        // is awaited — the code is only resolved from inside the handshake
        // establish() drives, so nothing else could ever unblock the getter.
        let bothEstablished = ManagedAtomicBool()
        let macTask = Task<NearbyPairingOutcome, Error> {
            let outcome = try await macSession.establish()
            bothEstablished.markTrue()
            return outcome
        }
        let phoneTask = Task<NearbyPairingOutcome, Error> {
            let outcome = try await phoneSession.establish()
            bothEstablished.markTrue()
            return outcome
        }

        async let macCode = macSession.shortAuthenticationCode
        async let phoneCode = phoneSession.shortAuthenticationCode
        let (resolvedMacCode, resolvedPhoneCode) = try await (macCode, phoneCode)

        #expect(resolvedMacCode == resolvedPhoneCode)
        #expect(resolvedMacCode.count == 6)
        #expect(resolvedMacCode.allSatisfy { $0.isNumber })

        // Neither establish() call may have returned yet: both are still
        // waiting on a local confirmation at this point.
        try await Task.sleep(for: .milliseconds(50))
        #expect(bothEstablished.value == false)

        await macSession.confirmPairing()
        await phoneSession.confirmPairing()

        let mac = try await macTask.value
        let phone = try await phoneTask.value
        #expect(mac.wasFirstPairing)
        #expect(phone.wasFirstPairing)
        #expect(mac.peer.deviceID == phoneIdentity.deviceID)
        #expect(phone.peer.deviceID == macIdentity.deviceID)

        #expect(try macStore.trustedPeers().map(\.deviceID) == [phoneIdentity.deviceID])
        #expect(try phoneStore.trustedPeers().map(\.deviceID) == [macIdentity.deviceID])
    }

    /// Multi-Mac disambiguation (fix item 3): the peer's `.hello`-supplied
    /// display name must already be readable by the time the pairing code
    /// itself resolves, so a "Pairing with: <name>" label can be shown
    /// alongside the code before the user confirms it -- not just after
    /// `establish()` returns, which is too late (the confirmation UI is
    /// exactly what needs the name).
    @Test func peerDisplayNameIsAvailableAsSoonAsTheShortAuthenticationCodeResolves() async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        async let macEstablish = macSession.establish()
        async let phoneEstablish = phoneSession.establish()

        _ = try await macSession.shortAuthenticationCode
        _ = try await phoneSession.shortAuthenticationCode

        // Each side already knows the OTHER's display name at this point --
        // before either has confirmed, let alone before establish() returns.
        #expect(await macSession.peerDisplayName == "Zoltán iPhone")
        #expect(await phoneSession.peerDisplayName == "Zoltán Macje")

        await macSession.confirmPairing()
        await phoneSession.confirmPairing()
        _ = try await macEstablish
        _ = try await phoneEstablish
    }

    // MARK: - MITM: substituted ephemeral keys fail signature verification

    @Test func mitmSubstitutedEphemeralKeysFailSignatureVerificationAndProduceDivergentLocalCodes() async throws {
        // Two independent "real" pairs, talking through a relay that forwards
        // `.hello` untouched (so both sides see the TRUE peer identity key)
        // but swaps the ephemeral key inside `.keyExchange` for a freshly
        // generated one it made up itself. The relay cannot produce a valid
        // signature over that substituted key under the true peer's identity
        // signing key (it never had that private key), so each side's
        // signature check on the incoming `.keyExchange` must fail closed —
        // the whole point of authenticating the ephemeral exchange.
        //
        // Signature verification runs BEFORE the transcript hash / SAS is
        // ever derived, so this is the stronger property: the handshake
        // never reaches a point where the two sides could even compare a
        // SAS. (Had the implementation instead derived the SAS first, the
        // two sides' codes would necessarily differ too, since each side's
        // transcript would incorporate a different substituted ephemeral
        // key — but that comparison never becomes relevant here.)
        let (aRaw, relayToA) = InMemoryDuplexConnection.makePair()
        let (bRaw, relayToB) = InMemoryDuplexConnection.makePair()

        let aStore = InMemoryDeviceIdentityStore()
        let bStore = InMemoryDeviceIdentityStore()
        let aIdentity = try aStore.loadOrCreateOwnIdentity(displayName: "Victim A")
        let bIdentity = try bStore.loadOrCreateOwnIdentity(displayName: "Victim B")

        let aSession = NearbyPairingSession(role: .listener, identity: aIdentity, trustStore: aStore, connection: aRaw)
        let bSession = NearbyPairingSession(role: .initiator, identity: bIdentity, trustStore: bStore, connection: bRaw)

        let relayTask = Task {
            await Self.runKeyExchangeSubstitutingRelay(sideA: relayToA, sideB: relayToB)
        }

        async let aResult: Result<NearbyPairingOutcome, Error> = Self.awaitOutcome(aSession)
        async let bResult: Result<NearbyPairingOutcome, Error> = Self.awaitOutcome(bSession)

        let (resultA, resultB) = await (aResult, bResult)
        relayTask.cancel()

        guard case .failure(let errorA) = resultA, case .failure(let errorB) = resultB else {
            Issue.record("expected both sides to fail closed on a substituted ephemeral key")
            return
        }
        #expect(errorA as? NearbyTransportError == .signatureVerificationFailed)
        #expect(errorB as? NearbyTransportError == .signatureVerificationFailed)

        // Neither side ever stored a peer — the handshake never reached a
        // trusted state.
        #expect(try aStore.trustedPeers().isEmpty)
        #expect(try bStore.trustedPeers().isEmpty)
    }

    /// Relays `.hello` frames untouched in both directions, but on a
    /// `.keyExchange` frame it substitutes a freshly generated ephemeral
    /// public key (independently per direction) while forwarding the
    /// original — now-mismatched — signature and other fields unchanged.
    private static func runKeyExchangeSubstitutingRelay(sideA: InMemoryDuplexConnection, sideB: InMemoryDuplexConnection) async {
        async let aToB: Void = relayOneDirectionSubstitutingKeyExchange(from: sideA, to: sideB)
        async let bToA: Void = relayOneDirectionSubstitutingKeyExchange(from: sideB, to: sideA)
        _ = await (aToB, bToA)
    }

    private static func relayOneDirectionSubstitutingKeyExchange(from: InMemoryDuplexConnection, to: InMemoryDuplexConnection) async {
        while !Task.isCancelled {
            guard let frame = try? await from.receive() else { return }
            if frame.kind == .keyExchange, let message = try? NearbySessionMessage(frame: frame), case .keyExchange(let exchange) = message {
                let substituteEphemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                let tampered = NearbyKeyExchangeMessage(
                    ephemeralPublicKey: substituteEphemeral,
                    sessionIDContribution: exchange.sessionIDContribution,
                    identitySignature: exchange.identitySignature
                )
                guard let tamperedFrame = try? NearbySessionMessage.keyExchange(tampered).encodedFrame() else { return }
                _ = try? await to.send(tamperedFrame)
            } else {
                _ = try? await to.send(frame)
            }
        }
    }

    // MARK: - MITM: tampered sessionIDContribution fails signature verification

    /// Hardening regression test: `sessionIDContribution` used to travel
    /// alongside the signed transcript without itself being signed, so an
    /// on-path attacker could tamper it in a relayed `.keyExchange` (silently
    /// changing the derived `sessionID` both sides agree on) without
    /// touching anything the known-peer/first-pairing signature check
    /// actually covered. Each side now signs its OWN `sessionIDContribution`
    /// as part of its transcript digest, so a relay that forwards the
    /// ephemeral key and signature untouched but flips a byte of
    /// `sessionIDContribution` must now fail signature verification exactly
    /// like a substituted ephemeral key does.
    @Test func tamperedSessionIDContributionOnRelayedKeyExchangeFailsSignatureVerification() async throws {
        let (aRaw, relayToA) = InMemoryDuplexConnection.makePair()
        let (bRaw, relayToB) = InMemoryDuplexConnection.makePair()

        let aStore = InMemoryDeviceIdentityStore()
        let bStore = InMemoryDeviceIdentityStore()
        let aIdentity = try aStore.loadOrCreateOwnIdentity(displayName: "Victim A")
        let bIdentity = try bStore.loadOrCreateOwnIdentity(displayName: "Victim B")

        let aSession = NearbyPairingSession(role: .listener, identity: aIdentity, trustStore: aStore, connection: aRaw)
        let bSession = NearbyPairingSession(role: .initiator, identity: bIdentity, trustStore: bStore, connection: bRaw)

        let relayTask = Task {
            await Self.runSessionIDContributionTamperingRelay(sideA: relayToA, sideB: relayToB)
        }

        async let aResult: Result<NearbyPairingOutcome, Error> = Self.awaitOutcome(aSession)
        async let bResult: Result<NearbyPairingOutcome, Error> = Self.awaitOutcome(bSession)

        let (resultA, resultB) = await (aResult, bResult)
        relayTask.cancel()

        guard case .failure(let errorA) = resultA, case .failure(let errorB) = resultB else {
            Issue.record("expected both sides to fail closed on a tampered sessionIDContribution")
            return
        }
        #expect(errorA as? NearbyTransportError == .signatureVerificationFailed)
        #expect(errorB as? NearbyTransportError == .signatureVerificationFailed)

        #expect(try aStore.trustedPeers().isEmpty)
        #expect(try bStore.trustedPeers().isEmpty)
    }

    private static func runSessionIDContributionTamperingRelay(sideA: InMemoryDuplexConnection, sideB: InMemoryDuplexConnection) async {
        async let aToB: Void = relayOneDirectionTamperingSessionIDContribution(from: sideA, to: sideB)
        async let bToA: Void = relayOneDirectionTamperingSessionIDContribution(from: sideB, to: sideA)
        _ = await (aToB, bToA)
    }

    /// Relays `.hello` and `.keyExchange` frames untouched EXCEPT for one
    /// flipped byte of `sessionIDContribution` — the ephemeral key and
    /// signature are forwarded exactly as sent, so this isolates the
    /// hardening's own coverage from the pre-existing ephemeral-key-swap
    /// test above.
    private static func relayOneDirectionTamperingSessionIDContribution(from: InMemoryDuplexConnection, to: InMemoryDuplexConnection) async {
        while !Task.isCancelled {
            guard let frame = try? await from.receive() else { return }
            if frame.kind == .keyExchange, let message = try? NearbySessionMessage(frame: frame), case .keyExchange(let exchange) = message {
                var tamperedContribution = exchange.sessionIDContribution
                tamperedContribution[tamperedContribution.startIndex] ^= 0xFF
                let tampered = NearbyKeyExchangeMessage(
                    ephemeralPublicKey: exchange.ephemeralPublicKey,
                    sessionIDContribution: tamperedContribution,
                    identitySignature: exchange.identitySignature
                )
                guard let tamperedFrame = try? NearbySessionMessage.keyExchange(tampered).encodedFrame() else { return }
                _ = try? await to.send(tamperedFrame)
            } else {
                _ = try? await to.send(frame)
            }
        }
    }

    private static func awaitOutcome(_ session: NearbyPairingSession) async -> Result<NearbyPairingOutcome, Error> {
        // Auto-confirm in the background in case the handshake somehow
        // reaches the SAS-suspend point (it should not, in the MITM case,
        // because signature verification aborts before that).
        let confirmTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await session.confirmPairing()
        }
        defer { confirmTask.cancel() }
        do {
            return .success(try await session.establish())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Rejection

    @Test func rejectionByEitherSideAbortsBothSidesAndStoresNothing() async throws {
        try await assertRejectionAbortsBothSides(macRejects: true)
        try await assertRejectionAbortsBothSides(macRejects: false)
    }

    private func assertRejectionAbortsBothSides(macRejects: Bool) async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Mac")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Phone")

        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        // establish() must already be running before shortAuthenticationCode
        // is awaited, for the same reason as above.
        let macTask = Task<NearbyPairingOutcome, Error> { try await macSession.establish() }
        let phoneTask = Task<NearbyPairingOutcome, Error> { try await phoneSession.establish() }

        _ = try? await macSession.shortAuthenticationCode
        _ = try? await phoneSession.shortAuthenticationCode

        if macRejects {
            await macSession.rejectPairing()
            await phoneSession.confirmPairing()
        } else {
            await macSession.confirmPairing()
            await phoneSession.rejectPairing()
        }

        let mac: Result<NearbyPairingOutcome, Error>
        do { mac = .success(try await macTask.value) } catch { mac = .failure(error) }
        let phone: Result<NearbyPairingOutcome, Error>
        do { phone = .success(try await phoneTask.value) } catch { phone = .failure(error) }

        guard case .failure = mac, case .failure = phone else {
            Issue.record("expected both sides to fail when either side rejects")
            return
        }
        #expect(try macStore.trustedPeers().isEmpty)
        #expect(try phoneStore.trustedPeers().isEmpty)
    }

    // MARK: - Known-peer path: second session

    @Test func secondSessionBetweenTheSameStoresSkipsSASAndReportsNotFirstPairing() async throws {
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Mac")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Phone")

        try await pairOnce(macIdentity: macIdentity, macStore: macStore, phoneIdentity: phoneIdentity, phoneStore: phoneStore)

        // Second session, same stores now hold each other as trusted peers.
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        async let macOutcome = macSession.establish()
        async let phoneOutcome = phoneSession.establish()
        let (mac, phone) = try await (macOutcome, phoneOutcome)

        #expect(mac.wasFirstPairing == false)
        #expect(phone.wasFirstPairing == false)

        await #expect(throws: NearbyTransportError.shortAuthenticationCodeUnavailable) {
            _ = try await macSession.shortAuthenticationCode
        }
        await #expect(throws: NearbyTransportError.shortAuthenticationCodeUnavailable) {
            _ = try await phoneSession.shortAuthenticationCode
        }
    }

    @Test func tamperedStoredPeerKeyThrowsPeerIdentityChanged() async throws {
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Mac")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Phone")

        try await pairOnce(macIdentity: macIdentity, macStore: macStore, phoneIdentity: phoneIdentity, phoneStore: phoneStore)

        // Overwrite what the Mac believes the phone's public key is.
        let tamperedPhonePeer = MobilePeerIdentity(
            deviceID: phoneIdentity.deviceID,
            signingPublicKeyRawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            displayName: "Phone"
        )
        macStore.forceOverwriteTrustedPeer(tamperedPhonePeer)

        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        async let phoneResult: Result<NearbyPairingOutcome, Error> = {
            do { return .success(try await phoneSession.establish()) } catch { return .failure(error) }
        }()

        await #expect(throws: NearbyTransportError.peerIdentityChanged(phoneIdentity.deviceID)) {
            _ = try await macSession.establish()
        }
        _ = await phoneResult
    }

    /// The recovery path for the permanent dead end above: once BOTH sides
    /// forget the stale peer (`removeTrustedPeer`, the store-level action
    /// the Mac's "Forget this iPhone and pair again" / the iPhone's "Forget
    /// this Mac and pair again" UI each call locally), the exact same two
    /// identities can pair again from scratch — a fresh first pairing with a
    /// new SAS code, not another `peerIdentityChanged`.
    ///
    /// Both sides must forget, not just the one that observed
    /// `peerIdentityChanged`: `NearbyPairingSession` decides "known peer" vs
    /// "first pairing" unilaterally from its OWN trust store. If only the
    /// side that saw the failure forgets, the next attempt is asymmetric —
    /// that side runs the first-pairing message flow (SAS + `.pairingConfirm`
    /// exchange) while the still-trusting other side runs the known-peer
    /// flow (no `.pairingConfirm` at all) and the first-pairing side hangs
    /// waiting for a confirm frame that never arrives, until the handshake
    /// timeout. This is exactly why the recovery UI exists on BOTH ends
    /// (fix item 1b/1c) rather than only on whichever device happened to
    /// detect the mismatch.
    @Test func forgettingTheStalePeerOnBothSidesAfterIdentityChangedAllowsAFreshPairing() async throws {
        let macStore = InMemoryDeviceIdentityStore()
        let phoneStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Mac")
        let phoneIdentity = try phoneStore.loadOrCreateOwnIdentity(displayName: "Phone")

        try await pairOnce(macIdentity: macIdentity, macStore: macStore, phoneIdentity: phoneIdentity, phoneStore: phoneStore)

        let tamperedPhonePeer = MobilePeerIdentity(
            deviceID: phoneIdentity.deviceID,
            signingPublicKeyRawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            displayName: "Phone"
        )
        macStore.forceOverwriteTrustedPeer(tamperedPhonePeer)

        let (failingMacConnection, failingPhoneConnection) = InMemoryDuplexConnection.makePair()
        let failingMacSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: failingMacConnection)
        let failingPhoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: failingPhoneConnection)
        async let failingPhoneResult: Result<NearbyPairingOutcome, Error> = {
            do { return .success(try await failingPhoneSession.establish()) } catch { return .failure(error) }
        }()
        await #expect(throws: NearbyTransportError.peerIdentityChanged(phoneIdentity.deviceID)) {
            _ = try await failingMacSession.establish()
        }
        _ = await failingPhoneResult

        // Recovery: forget the stale peer on BOTH ends (mirrors the Mac's
        // and the iPhone's own "Forget … and pair again" actions, each
        // calling `NearbySyncCoordinator`/`NearbyPhoneSyncSession
        // .forgetPeer(deviceID:)` locally).
        try macStore.removeTrustedPeer(deviceID: phoneIdentity.deviceID)
        try phoneStore.removeTrustedPeer(deviceID: macIdentity.deviceID)
        #expect(try macStore.trustedPeers().isEmpty)
        #expect(try phoneStore.trustedPeers().isEmpty)

        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        let macTask = Task<NearbyPairingOutcome, Error> { try await macSession.establish() }
        let phoneTask = Task<NearbyPairingOutcome, Error> { try await phoneSession.establish() }

        _ = try await macSession.shortAuthenticationCode
        _ = try await phoneSession.shortAuthenticationCode
        await macSession.confirmPairing()
        await phoneSession.confirmPairing()

        let macOutcome = try await macTask.value
        let phoneOutcome = try await phoneTask.value
        #expect(macOutcome.wasFirstPairing)
        #expect(phoneOutcome.wasFirstPairing)
        #expect(try macStore.trustedPeers().first?.signingPublicKeyRawRepresentation == phoneIdentity.publicIdentity.signingPublicKeyRawRepresentation)
    }

    // MARK: - Timeout

    @Test func establishTimesOutWhenThePeerNeverAnswers() async throws {
        let (macConnection, _phoneConnectionKeptAliveButUnused) = InMemoryDuplexConnection.makePair()
        _ = _phoneConnectionKeptAliveButUnused
        let macStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macStore.loadOrCreateOwnIdentity(displayName: "Mac")

        // Generous relative to the near-instant in-memory send/receive this
        // handshake actually does, so the test stays robust under CPU
        // contention on shared CI hardware while still finishing quickly.
        let macSession = NearbyPairingSession(
            role: .listener,
            identity: macIdentity,
            trustStore: macStore,
            connection: macConnection,
            timeout: .milliseconds(400)
        )

        await #expect(throws: NearbyTransportError.handshakeTimeout) {
            _ = try await macSession.establish()
        }
    }

    // MARK: - Helpers

    private func pairOnce(
        macIdentity: MobileDeviceIdentity,
        macStore: InMemoryDeviceIdentityStore,
        phoneIdentity: MobileDeviceIdentity,
        phoneStore: InMemoryDeviceIdentityStore
    ) async throws {
        let (macConnection, phoneConnection) = InMemoryDuplexConnection.makePair()
        let macSession = NearbyPairingSession(role: .listener, identity: macIdentity, trustStore: macStore, connection: macConnection)
        let phoneSession = NearbyPairingSession(role: .initiator, identity: phoneIdentity, trustStore: phoneStore, connection: phoneConnection)

        let macTask = Task<NearbyPairingOutcome, Error> { try await macSession.establish() }
        let phoneTask = Task<NearbyPairingOutcome, Error> { try await phoneSession.establish() }

        _ = try await macSession.shortAuthenticationCode
        _ = try await phoneSession.shortAuthenticationCode
        await macSession.confirmPairing()
        await phoneSession.confirmPairing()

        _ = try await macTask.value
        _ = try await phoneTask.value
    }
}

/// A tiny lock-guarded flag for asserting "not yet true" mid-test without
/// data races, since `Bool` alone is not safely shared across the
/// concurrently-running `async let` tasks above.
private final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func markTrue() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private extension InMemoryDeviceIdentityStore {
    /// Test-only seam: bypasses `storeTrustedPeer`'s `peerIdentityChanged`
    /// guard to simulate an already-corrupted trust store (e.g. from a bug
    /// or a downgrade) for the `peerIdentityChanged` detection test.
    func forceOverwriteTrustedPeer(_ peer: MobilePeerIdentity) {
        var peers = (try? trustedPeers()) ?? []
        peers.removeAll { $0.deviceID == peer.deviceID }
        peers.append(peer)
        corruptPeersData(try! MobileJSON.encoder.encode(peers))
    }
}
