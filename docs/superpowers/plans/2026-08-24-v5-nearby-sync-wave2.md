# AstroTool V5 Nearby Sync Wave 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the direct Mac↔iPhone nearby sync from the V5 spec — Bonjour discovery, six-digit pairing, persistent device identities, and an encrypted session that carries the exact same `.astromobile` package content Wave 1 already validates — so a user can sync without AirDrop while every Wave 1 safety gate stays in force.

**Architecture:** `AstroMobileTransport` gains three layers that never touch the domain: versioned length-prefixed framing, an authenticated session (persistent Curve25519 identity keys + ephemeral ECDH + six-digit SAS confirmation), and a thin Network-framework Bonjour adapter. The nearby session transports the sealed package payload and manifest bytes — the phone stages them exactly like an AirDrop import, and the Mac receives return packages into the existing public `MobileReturnApplicationCoordinator`. No new apply surface, no new key-handling path: paired transfers use the Wave 1 manifest's `pairedDevice` key mode (content key wrapped to the stored peer public key), so the QR one-time key remains only the unpaired fallback.

**Tech Stack:** Swift 6.2, CryptoKit (Curve25519, ChaChaPoly, HKDF), Network framework (NWListener/NWBrowser, peer-to-peer), SwiftUI, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-23-v5-iphone-companion-design.md` §4.1–4.4, §7.2–7.3, §7.4 (pairedDevice), §12.2 — plus the Wave 1 plan's "Deferred to Wave 2" note.

## Global Constraints (inherited from Wave 1 — all binding)

- The Mac remains the only owner of the library; the phone returns only checklist completions and notes.
- Return application goes exclusively through the public `MobileReturnApplicationCoordinator`; nearby code may not construct importers, domain batches, markers, or sent-base evidence. Package-internal marker paths stay package-internal.
- Export alone never clears the phone queue; only exact acknowledgement IDs in a later authenticated Mac package do.
- No partial import anywhere: unknown peer, wrong code, replayed message, expired session, or hash mismatch aborts with no state change (spec §7.3).
- Both apps must be foregrounded; no background-sync promise, no daemon, no multicast scanning (spec §7.2).
- Multipeer Connectivity is forbidden (deprecated); Network framework only.
- All new user-facing strings ship EN+HU together with `v5.nearby.*` accessibility identifiers; the mobile `message = "…"` audit and the Mac extraction audit must stay green.
- New public API surface must be minimal: session/pairing types are `package` where possible; production entry points are root-bound coordinators mirroring Wave 1's hardening.

## Plan Rulings

1. **Package-over-session, not envelope-over-session.** The `MobileSyncTransport` protocol from Wave 1 is implemented by a `NearbyPackageTransport` whose send/receive convert to/from the sealed package byte pair (`manifest.json` + `encrypted-payload.bin`) via `MobilePackageService`. Rationale: reuses Wave 1's validated crypto, staging, sent-base, and coordinator gates unchanged; the session never introduces a second plaintext path. Cost if wrong: an extra encode/decode per sync, negligible against transfer time.
2. **Trust-on-first-use with SAS.** First pairing derives a six-digit code from the full transcript hash; identities are persisted only after BOTH sides confirm. Later sessions authenticate ephemeral keys with the stored identity keys; an unknown or changed identity is a hard failure with a re-pairing prompt, never silent acceptance.
3. **Key storage is injectable.** A `MobileDeviceIdentityStoring` protocol with a Keychain implementation in production and an in-memory implementation for tests; tests never touch the real Keychain.
4. **The service name is fixed**: `_astrotool-sync._tcp` on both platforms, declared in both Info.plists next to an exact local-network usage description (spec §7.2).

---

## File Map

**Shared transport (new files, `Sources/AstroMobileTransport/`)**
- `NearbyFraming.swift` — versioned, length-prefixed frame codec with hard size caps.
- `NearbySessionMessages.swift` — typed control/payload message enum + Codable wire forms.
- `MobileDeviceIdentity.swift` — persistent identity keys, `MobileDeviceIdentityStoring`, Keychain + in-memory stores.
- `NearbyPairingSession.swift` — handshake state machine: hello → ephemeral exchange → SAS → confirm → traffic keys.
- `NearbySecureChannel.swift` — post-handshake AEAD channel (directional keys, counter nonces, rekey guard, size caps).
- `NearbyConnection.swift` — `NearbyByteConnection` protocol (async send/receive of frames) + in-memory duplex test double.
- `NearbyBonjourTransport.swift` — NWListener/NWBrowser adapter producing `NearbyByteConnection`s.
- `NearbyPackageTransport.swift` — `MobileSyncTransport` conformance: session ⇄ sealed package bytes via `MobilePackageService`.

**Mac (`Sources/AstroApplication/Features/MobileSync/`, `Sources/AstroUI/Features/MobileSync/`)**
- `NearbySyncCoordinator.swift` (AstroApplication) — root-bound production coordinator: advertise, pair, send forward package, receive return package into `MobileReturnApplicationCoordinator.preview/apply`.
- `MobileSyncStore.swift` / `MobileSyncView.swift` (modify) — "iPhone szinkronizálása" nearby flow: pairing sheet with the six-digit code, the §4.3 progress states, result summary.

**iPhone (`Sources/AstroToolMobile/`)**
- `MobileNearbySyncScreen.swift` — pairing + sync UI states from §4.1/§4.3, permission pre-explanation and denial → AirDrop fallback.
- `MobileRootView.swift`, `SyncMobileView.swift` (modify) — entry points ("Kapcsolódás a Macemhez" / nearby button on Sync tab).

**Configuration**
- `project.yml` (modify) — `NSLocalNetworkUsageDescription` + `NSBonjourServices: [_astrotool-sync._tcp]` for both app targets.
- `Package.swift` — no new targets; new files join `AstroMobileTransport`.

**Tests**
- `Tests/AstroMobileTransportTests/NearbyFramingTests.swift`
- `Tests/AstroMobileTransportTests/NearbyPairingSessionTests.swift`
- `Tests/AstroMobileTransportTests/NearbySecureChannelTests.swift`
- `Tests/AstroMobileTransportTests/NearbyPackageTransportTests.swift`
- `Tests/AstroApplicationTests/NearbySyncCoordinatorTests.swift`
- `Tests/AstroUITests/MobileSyncStoreTests.swift` (extend), `Tests/AstroToolMobileTests/` (extend)

---

### Task 1: Frame codec and wire messages

**Files:**
- Create: `Sources/AstroMobileTransport/NearbyFraming.swift`
- Create: `Sources/AstroMobileTransport/NearbySessionMessages.swift`
- Create: `Tests/AstroMobileTransportTests/NearbyFramingTests.swift`

**Interfaces:**
- Produces: `NearbyFrame` (`version: UInt8`, `kind: NearbyFrameKind`, `payload: Data`), `NearbyFrameCodec.encode/decode`, `NearbySessionMessage` (`.hello`, `.keyExchange`, `.pairingConfirm`, `.packageManifest`, `.packageChunk`, `.packageComplete`, `.acknowledgement`, `.failure`), `NearbyTransportError`.
- Hard caps: frame payload ≤ 1 MiB; total package stream ≤ 512 MiB; decode of any oversized/truncated/unknown-version input throws a typed error and consumes nothing.

- [ ] **Step 1: Write failing round-trip, truncation, oversize, and unknown-version tests**

```swift
import Foundation
import Testing
@testable import AstroMobileTransport

@Test func frameRoundTripsAllKinds() throws {
    for kind in NearbyFrameKind.allCases {
        let frame = NearbyFrame(kind: kind, payload: Data("payload".utf8))
        let decoded = try NearbyFrameCodec.decode(NearbyFrameCodec.encode(frame))
        #expect(decoded.frame == frame)
        #expect(decoded.consumedBytes == NearbyFrameCodec.encode(frame).count)
    }
}

@Test func truncatedFrameFailsClosedWithoutConsuming() throws {
    var bytes = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data(repeating: 1, count: 64)))
    bytes.removeLast(8)
    #expect(throws: NearbyTransportError.incompleteFrame) { try NearbyFrameCodec.decode(bytes) }
}

@Test func oversizedDeclaredLengthIsRejectedBeforeAllocation() throws {
    var header = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data()))
    header.replaceSubrange(2..<6, with: withUnsafeBytes(of: UInt32(2_000_000).bigEndian) { Data($0) })
    #expect(throws: NearbyTransportError.frameTooLarge) { try NearbyFrameCodec.decode(header) }
}

@Test func unknownVersionFailsClosed() throws {
    var bytes = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data()))
    bytes[0] = 99
    #expect(throws: NearbyTransportError.unsupportedVersion(99)) { try NearbyFrameCodec.decode(bytes) }
}
```

- [ ] **Step 2: Run and verify failure** — `swift test --no-parallel --filter NearbyFramingTests` → missing-type compile failures.
- [ ] **Step 3: Implement the codec** — big-endian header `[version:1][kind:1][length:4]` + payload; `decode` returns `(frame, consumedBytes)` so a streaming reader can buffer partial input; validate length against `maxFramePayloadBytes = 1_048_576` BEFORE touching the payload bytes; unknown `kind` byte → `.unknownFrameKind`.
- [ ] **Step 4: Implement `NearbySessionMessage`** — every message a small `Codable` struct encoded with `MobileJSON` inside the frame payload; `.packageChunk` carries `index: Int`, `bytes: Data`; `.failure` carries a typed reason string enum, never free text from the peer.
- [ ] **Step 5: Run the suite green** — `swift test --no-parallel --filter NearbyFramingTests`.
- [ ] **Step 6: Commit** — `git add Sources/AstroMobileTransport Tests/AstroMobileTransportTests && git commit -m "feat: add nearby sync frame codec"`.

### Task 2: Device identity and injectable key storage

**Files:**
- Create: `Sources/AstroMobileTransport/MobileDeviceIdentity.swift`
- Create: `Tests/AstroMobileTransportTests/MobileDeviceIdentityTests.swift`

**Interfaces:**
```swift
public struct MobileDeviceIdentity: Sendable {
    public let deviceID: UUID
    public let signingKey: Curve25519.Signing.PrivateKey
    public var publicIdentity: MobilePeerIdentity { get }
}

public struct MobilePeerIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let signingPublicKeyRawRepresentation: Data
    public let displayName: String
}

public protocol MobileDeviceIdentityStoring: Sendable {
    func loadOrCreateOwnIdentity(displayName: String) throws -> MobileDeviceIdentity
    func trustedPeers() throws -> [MobilePeerIdentity]
    func storeTrustedPeer(_ peer: MobilePeerIdentity) throws
    func removeTrustedPeer(deviceID: UUID) throws
}
```
- Production: `KeychainDeviceIdentityStore` (kSecClassGenericPassword items, service `io.github.themokx1.astrotool.nearby`, no iCloud sync attribute). Tests: `InMemoryDeviceIdentityStore`.

- [ ] **Step 1: Failing tests** — own identity is created once and reloaded stably (same deviceID + public key across two `loadOrCreateOwnIdentity` calls on one store); storing a peer with the same deviceID but a DIFFERENT public key throws `NearbyTransportError.peerIdentityChanged` (never silently replaces); `removeTrustedPeer` forgets it. All against `InMemoryDeviceIdentityStore`.
- [ ] **Step 2: Verify failure, then implement.** The Keychain store compiles on both platforms but is exercised only in production; its logic must be a thin serialization shim over the same validation code the in-memory store shares (one internal `validateStore(_:)` helper), so tests of the shared logic cover both.
- [ ] **Step 3: Run green, commit** — `git commit -m "feat: add nearby device identities with injectable storage"`.

### Task 3: Pairing handshake and secure channel

**Files:**
- Create: `Sources/AstroMobileTransport/NearbyPairingSession.swift`
- Create: `Sources/AstroMobileTransport/NearbySecureChannel.swift`
- Create: `Sources/AstroMobileTransport/NearbyConnection.swift`
- Create: `Tests/AstroMobileTransportTests/NearbyPairingSessionTests.swift`
- Create: `Tests/AstroMobileTransportTests/NearbySecureChannelTests.swift`

**Interfaces:**
```swift
public protocol NearbyByteConnection: Sendable {
    func send(_ frame: NearbyFrame) async throws
    func receive() async throws -> NearbyFrame
    func cancel() async
}

public struct NearbyPairingOutcome: Sendable {
    public let channel: NearbySecureChannel
    public let peer: MobilePeerIdentity
    public let wasFirstPairing: Bool
}

public actor NearbyPairingSession {
    public init(role: NearbyRole /* .listener | .initiator */, identity: MobileDeviceIdentity, trustStore: any MobileDeviceIdentityStoring, connection: any NearbyByteConnection)
    /// First pairing: runs hello + ephemeral exchange, then SUSPENDS and
    /// reports the six-digit code via this async sequence before any
    /// traffic key exists. `confirmPairing()` / `rejectPairing()` resume it.
    public var shortAuthenticationCode: String { get async throws }
    public func confirmPairing() async
    public func rejectPairing() async
    public func establish() async throws -> NearbyPairingOutcome
}
```
- SAS derivation: `SHA256(protocolVersion ‖ listenerIdentityPub ‖ initiatorIdentityPub ‖ listenerEphemeralPub ‖ initiatorEphemeralPub ‖ sessionID)` → first 4 bytes big-endian mod 1_000_000, zero-padded to 6 digits. Both sides derive it from their own transcript — a MITM with different ephemerals produces different codes.
- Known-peer sessions: each side signs its ephemeral public key + sessionID with its identity key; the verifier checks against the STORED peer identity; unknown deviceID → first-pairing path, changed key → `peerIdentityChanged`, no fallback.
- Traffic keys: HKDF-SHA256 over the ECDH shared secret with the transcript hash as salt; two directional ChaChaPoly keys (`listener→initiator`, `initiator→listener`); nonces are 12-byte big-endian frame counters per direction; a counter wrap or out-of-order/replayed counter closes the session with a typed error.
- `NearbySecureChannel.send/receive` seal/open `NearbySessionMessage`s; any AEAD failure is terminal for the session.

- [ ] **Step 1: Failing tests with `InMemoryDuplexConnection`** (create in `NearbyConnection.swift` as a `package` test double: two cross-wired `AsyncStream`s):
  - both sides of a first pairing derive the SAME six-digit code, and neither `establish()` returns before both confirmed;
  - a relayed-but-substituted ephemeral key (MITM simulation: swap one keyExchange frame's key for a fresh one) yields DIFFERENT codes on the two sides;
  - reject on either side tears the session down with no stored peer;
  - after confirmation both stores hold the counterpart identity; a second session between the same stores completes with `wasFirstPairing == false` and NO code prompt;
  - a second session where one side's stored key was tampered throws `peerIdentityChanged`;
  - channel: message round trip; one flipped ciphertext byte → terminal error; replayed frame (same counter) → terminal error; oversized message rejected before send.
- [ ] **Step 2: Verify failures, implement handshake + channel.** Keep ALL crypto in CryptoKit; no custom primitives. The pairing actor never exposes traffic keys before `confirmPairing()` on the first-pairing path.
- [ ] **Step 3: Run green** — `swift test --no-parallel --filter NearbyPairing && swift test --no-parallel --filter NearbySecureChannel`.
- [ ] **Step 4: Commit** — `git commit -m "feat: add authenticated nearby pairing and secure channel"`.

### Task 4: Package-over-session transport

**Files:**
- Create: `Sources/AstroMobileTransport/NearbyPackageTransport.swift`
- Create: `Tests/AstroMobileTransportTests/NearbyPackageTransportTests.swift`
- Modify: `Sources/AstroMobileTransport/MobilePackageCrypto.swift` (only if the pairedDevice key wrap needs a helper that does not already exist)

**Interfaces:**
```swift
public actor NearbyPackageTransport: MobileSyncTransport {
    public init(channel: NearbySecureChannel, packageService: MobilePackageService, peer: MobilePeerIdentity, stagingDirectory: URL)
    public func send(_ envelope: MobilePackageEnvelope) async throws
    public func receive() async throws -> MobilePackageEnvelope
}
```
- `send`: export the envelope through `MobilePackageService` into a temporary package using the `pairedDevice` key mode (content key wrapped to the peer's stored public key — reuse the existing `MobilePackageKeyWrapping` seam; if only the QR wrapper exists, add `PairedDeviceKeyWrapping` using Curve25519 key agreement with the stored peer key), then stream `manifest.json` + payload as `.packageManifest`/`.packageChunk`/`.packageComplete` messages with SHA-256 verified on the far side.
- `receive`: write chunks to an app-owned staging package, verify byte count + ciphertext hash against the manifest BEFORE calling `MobilePackageService.importPreview/commit...` exactly the way the AirDrop path does; any mismatch deletes only the staging copy.
- Idempotence: re-receiving a package with an already-committed packageID must surface the existing duplicate-package behavior of `MobilePackageService`, not bypass it.

- [ ] **Step 1: Failing tests** — full envelope round trip over `InMemoryDuplexConnection` + real `MobilePackageService`; a corrupted chunk (one byte) fails closed with staging removed and no envelope surfaced; truncation (missing `.packageComplete`) times out/cancels without partial import; oversized stream aborts at the cap.
- [ ] **Step 2: Implement, run green** — `swift test --no-parallel --filter NearbyPackageTransport`.
- [ ] **Step 3: Commit** — `git commit -m "feat: carry sealed mobile packages over the nearby session"`.

### Task 5: Bonjour adapter

**Files:**
- Create: `Sources/AstroMobileTransport/NearbyBonjourTransport.swift`
- Modify: `project.yml` (both app targets: `NSLocalNetworkUsageDescription` — exact copy: EN "AstroTool uses the local network only to hand the night plan and your checklist notes between your own Mac and iPhone."; `NSBonjourServices: ["_astrotool-sync._tcp"]`)
- Create: `Tests/AstroMobileTransportTests/NearbyBonjourTransportTests.swift`

**Interfaces:**
```swift
public actor NearbyBonjourListener {
    public init(serviceName: String = NearbyBonjour.serviceType)
    public func start() async throws -> AsyncStream<any NearbyByteConnection>
    public func stop() async
}
public actor NearbyBonjourBrowser {
    public func connectToFirstMatch(timeout: Duration) async throws -> any NearbyByteConnection
    public func cancel() async
}
```
- NWListener publishes exactly `_astrotool-sync._tcp` with `includePeerToPeer = true`; NWBrowser filters to that one type; the NWConnection is wrapped into a `NearbyByteConnection` that enforces the Task 1 frame caps while reading.
- Keep this file THIN: no crypto, no retries beyond one connection attempt, no multicast. All logic above lives in Tasks 1–4 and is already tested; here only the loopback path is integration-tested.

- [ ] **Step 1: Failing test** — listener + browser on localhost (`NWParameters.tcp`, loopback): browser connects, one frame each direction round-trips, cancel tears both down. Mark the suite `.enabled(if:)` an environment check so CI/sandboxed runs without local-network entitlement skip it EXPLICITLY (a skip is visible, not silent) — mirror how existing tests gate on environment if any do; otherwise gate on `ProcessInfo.processInfo.environment["ASTRO_SKIP_LOOPBACK"] == nil`.
- [ ] **Step 2: Implement, run** — `swift test --no-parallel --filter NearbyBonjour`, then `xcodegen generate` and verify the generated project diff contains only the two Info.plist additions.
- [ ] **Step 3: Commit** — `git commit -m "feat: publish and discover the AstroTool nearby service"`.

### Task 6: Mac nearby coordinator and UI

**Files:**
- Create: `Sources/AstroApplication/Features/MobileSync/NearbySyncCoordinator.swift`
- Modify: `Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift`
- Modify: `Sources/AstroUI/Features/MobileSync/MobileSyncView.swift`
- Create: `Tests/AstroApplicationTests/NearbySyncCoordinatorTests.swift`
- Modify: `Tests/AstroUITests/MobileSyncStoreTests.swift`, `Tests/AstroUITests/MobileSyncSurfaceTests.swift`

**Interfaces:**
```swift
public actor NearbySyncCoordinator {
    public init(rootURL: URL, displayName: String) throws   // production: real Keychain store + Bonjour listener
    package init(/* injectable seams for tests: identity store, listener, package transport factory, return coordinator */)
    public func startAdvertising() async throws -> AsyncStream<NearbySyncEvent>
    public func confirmPairing() async
    public func rejectPairing() async
    public func stop() async
}
public enum NearbySyncEvent: Sendable {
    case waitingForPhone
    case pairingCode(String)
    case preparing, transferring(progress: Double), verifying
    case receivedReturn(MobileReturnApplicationReview)
    case finished(MobileForwardSnapshotPublication)
    case failed(NearbySyncFailure)   // typed; every case maps to one localized string
}
```
- The coordinator OWNS its `MobileReturnApplicationCoordinator` and forward-snapshot flow the same way the Wave 1 store does; callers cannot inject envelopes/importers (mirror the Task 7.1 hardening — production init takes only `rootURL`/`displayName`).
- A received return package is handed to the EXISTING preview/apply UI path (`MobileSyncStore` presents the same review sheet as an AirDrop import); nearby adds no second apply button.
- UI: the Settings/Briefing "iPhone" area gets the direct sync action with the §4.3 state labels (Mac keresése / Biztonságos kapcsolat / Adatok előkészítése / Átvitel / Ellenőrzés / Kész) as `v5.nearby.state`, the pairing sheet shows the six-digit code as `v5.nearby.code` with the local-network pre-explanation sentence, and interruption offers exactly one "Újrapróbálás" action (spec §4.3). EN+HU for every string.

- [ ] **Step 1: Failing coordinator tests** (injected in-memory transport + fixture library): full forward sync marks the sent base exactly like an AirDrop export; a return received nearby lands as a normal `MobileReturnApplicationReview` and refuses `apply` without confirmation; pairing rejection stores nothing; a failed transfer publishes `failed` and leaves no staging residue; the event stream ends terminal (`finished`/`failed`) exactly once.
- [ ] **Step 2: Failing store/surface tests** — new state labels + identifiers pinned (`v5.nearby.state`, `v5.nearby.code`, `v5.nearby.retry`), the safety sentence stays on screen, and the store transitions `idle → advertising → pairing → syncing → done/failed` without ever skipping the confirmation.
- [ ] **Step 3: Implement coordinator, store extension, view.** No `FileManager` in views; all filesystem work stays in the coordinator/service layer.
- [ ] **Step 4: Run green** — `swift test --no-parallel --filter NearbySync && swift test --no-parallel --filter MobileSync`, plus `swift test --no-parallel --filter LocalizationCoverageTests`.
- [ ] **Step 5: Commit** — `git commit -m "feat: add Mac nearby sync flow"`.

### Task 7: iPhone nearby flow

**Files:**
- Create: `Sources/AstroToolMobile/MobileNearbySyncScreen.swift`
- Modify: `Sources/AstroToolMobile/MobileRootView.swift`, `Sources/AstroToolMobile/SyncMobileView.swift`
- Modify: `Sources/AstroToolMobile/Resources/en.lproj/Localizable.strings`, `hu.lproj/Localizable.strings`
- Modify: `Tests/AstroToolMobileTests/MobileInteractionTests.swift`, `UITests/AstroToolMobileUITests/AstroToolMobileLaunchTests.swift`

**Interfaces:**
- The opening screen's three §4.1 states: "Kapcsolódás a Macemhez" (first use), "Legutóbbi estém megnyitása" (has snapshot), "Csomag fogadása AirDroppal" (fallback) — the nearby screen browses, pairs (same six-digit code UI), then receives the forward package into the EXISTING `MobileLibraryStore` staging/import path and sends the return package from the existing export path. The nearby layer on the phone calls only `stagePackage`/`importCurrentStagedPackage(pairedKey:)`-equivalent and `exportReturnPackage` — no new mutation routes (the interaction-surface scan test must stay green).
- Local-network permission: the pre-explanation sentence appears BEFORE the OS prompt; a denial shows the recovery path (Settings deep link + AirDrop fallback), spec §9.
- All strings EN+HU; identifiers `v5.mobile.nearby.*`; the `message = "…"` audit covers any new outcome messages automatically — write them as `message =` literals so it does.

- [ ] **Step 1: Failing interaction tests** — nearby screen exposes no third mutation route (extend the existing source-scan test's file list); pairing-code screen state machine (browsing → code → confirmed/rejected → transferring → done/failed) as a pure observable store testable without Network.
- [ ] **Step 2: Implement screen + store wiring.**
- [ ] **Step 3: iOS gate** — `xcodegen generate`, then `xcodebuild test -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (unit + UI green). ⚠️ Owner-permission rule: announce before running — it front-runs the Simulator.
- [ ] **Step 4: Commit** — `git commit -m "feat: add iPhone nearby sync screen"`.

### Task 8: Round-trip proof, docs, and Wave 2 gate

**Files:**
- Create: `Tests/AstroApplicationTests/NearbyRoundTripSmokeTests.swift`
- Modify: `docs/first-steps.html`, `docs/en/first-steps.html`, `README.md`, `docs/releases/v5.0.0-prototype.md`
- Modify: `Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift`

- [ ] **Step 1: Deterministic nearby round-trip test** (in-memory connection, real stores, real coordinator): Mac advertises → phone-side session pairs (SAS compared programmatically equal) → forward package lands in a phone-side staging fixture → one checklist + one note change return nearby → Mac preview/apply through the public coordinator → acknowledgement IDs flow back in the next forward package → phone queue clears exactly those IDs. Manifest-compare the fixture library before/after (reuse `MobilePackageSmokeTests`' manifest helper by extracting it to a shared test-support file if needed).
- [ ] **Step 2: Docs** — extend the V5 sections: nearby is the primary path ("iPhone szinkronizálása" button), AirDrop stays the fallback; document the local-network permission and its recovery; extend the `PublicWebsiteSurfaceTests` pins (HU+EN: "helyi hálózat"/"local network", pairing code mention, AirDrop fallback retained).
- [ ] **Step 3: Machine gate** — `swift test --no-parallel`; 3× default-parallel `swift test`; `xcodegen generate` diff empty; `./scripts/check-public-content.sh`; `./scripts/smoke-mobile-package.sh`; macOS + iOS `xcodebuild test` (⚠️ announce first — focus/Simulator); `git diff --check`. Record results in `docs/releases/v5.0.0-prototype.md` under a new Wave 2 section.
- [ ] **Step 4: External gate (unchanged, do not claim)** — two-device Bonjour discovery on a shared Wi-Fi, peer-to-peer without infrastructure, permission-denial recovery, >100 MB interrupted/resumed transfer, and the physical AirDrop + nearby round trip on the owner's iPhone (spec §12.2).
- [ ] **Step 5: Commit** — `git commit -m "feat: complete nearby sync wave 2 machine gate"`.

---

## Self-review notes

- Spec coverage: §4.1 (Task 7), §4.2 summary reuse (existing preview UI, Task 6), §4.3 states (Tasks 6–7), §4.4 (Tasks 4+8 acknowledgement flow), §7.2 (Task 5), §7.3 (Tasks 2–3), §7.4 pairedDevice (Task 4), §9 permission recovery (Task 7), §12.2 automated portion (Tasks 3–5, 8). Preview images (§6.4 / spec order item 7) remain deliberately OUT of this plan — a later, independent plan.
- Type-consistency: `NearbyByteConnection`, `NearbySecureChannel`, `MobilePeerIdentity`, `NearbySyncEvent` names are used identically across Tasks 3–6.
- Every task is SwiftPM-verifiable except Task 5's loopback test (env-gated, visible skip), Task 7's iOS gate and Task 8's full gate (owner-announced).
