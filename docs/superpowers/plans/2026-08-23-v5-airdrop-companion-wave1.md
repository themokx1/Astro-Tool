# AstroTool V5 AirDrop Companion Wave 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a real, offline iPhone companion that exchanges a safe mobile-library snapshot, checklist completions, and notes with the Mac through an encrypted `.astromobile` AirDrop document, without CloudKit or a paid Apple Developer membership.

**Architecture:** Add an iOS/macOS `AstroMobileDomain` package target containing a strict allowlisted snapshot and append-only change model. The Mac composes that model from existing queries, encrypts it into a custom document, and imports only checklist/note changes through existing application commands; the iPhone atomically stores the latest valid snapshot and queues the same two change types. This wave deliberately excludes nearby Network/Bonjour sync while defining interfaces that the next wave can implement without changing the domain or UI.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, CryptoKit, UniformTypeIdentifiers, FileDocument/FileWrapper, XCTest/Swift Testing, XcodeGen, macOS 26, iOS 26.

**Spec:** `docs/superpowers/specs/2026-08-23-v5-iphone-companion-design.md`

## Global Constraints

- The Mac remains the only owner of the astrophotography library.
- Never include original image bytes, source paths, filenames, security-scoped bookmarks, or arbitrary FITS headers in a mobile snapshot.
- The iPhone may return only `ChecklistCompletionChange` and `NoteRevisionChange`; there is no generic CRUD or delete command.
- Every import is previewed, checksum-verified, schema-validated, staged, and atomically committed.
- An empty note never means delete; concurrent notes default to keeping both.
- All library-root writes go through `WriteGuard`; SwiftUI views never write library files directly.
- The first prototype must work with an Xcode Personal Team and must not require CloudKit, TestFlight, or background execution.
- All user-visible strings ship in Hungarian and English with VoiceOver identifiers and Dynamic Type-safe layouts.
- Wave 1 transfers through an encrypted `.astromobile` document; Network/Bonjour transport is out of scope for this plan.

---

## File Map

**Shared mobile domain**

- `Sources/AstroMobileDomain/MobileLibraryModels.swift` — strict snapshot records.
- `Sources/AstroMobileDomain/MobileChanges.swift` — only two allowed return commands.
- `Sources/AstroMobileDomain/MobilePackageModels.swift` — schema, manifest, package envelope, import summary.
- `Sources/AstroMobileDomain/MobileSyncTransport.swift` — transport-neutral send/receive contract.
- `Tests/AstroMobileDomainTests/*` — serialization, whitelist, compatibility, and change safety.

**Shared encrypted document transport**

- `Sources/AstroMobileTransport/MobilePackageCrypto.swift` — authenticated encryption and key wrapping.
- `Sources/AstroMobileTransport/MobilePackageService.swift` — cross-platform package staging/export/import.
- `Tests/AstroMobileTransportTests/*` — crypto, tamper, schema, and atomic package tests.

**Mac adapters**

- `Sources/AstroApplication/Features/MobileSync/PortableLibraryIdentityStore.swift` — previewed, stable ID creation through `WriteGuard`.
- `Sources/AstroApplication/Features/MobileSync/MobileSnapshotComposer.swift` — existing records to allowlisted mobile records.
- `Sources/AstroApplication/Features/MobileSync/MobileChangeImporter.swift` — conflict preview and command dispatch.
- `Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift` — Mac presentation state.
- `Sources/AstroUI/Features/MobileSync/MobileSyncView.swift` — export/import preview UI.

**iPhone app**

- `Sources/AstroToolMobile/AstroToolMobileApp.swift` — iOS entry point and document handling.
- `Sources/AstroToolMobile/MobileLibraryStore.swift` — atomic local snapshot plus append-only changes.
- `Sources/AstroToolMobile/MobileRootView.swift` — four-tab shell.
- `Sources/AstroToolMobile/TonightMobileView.swift` — briefing/checklist.
- `Sources/AstroToolMobile/ProjectsMobileView.swift` — project summaries.
- `Sources/AstroToolMobile/BriefingsMobileView.swift` — saved briefings.
- `Sources/AstroToolMobile/SyncMobileView.swift` — document import/export and freshness.
- `Sources/AstroToolMobile/Resources/{en,hu}.lproj/Localizable.strings` — complete mobile copy.
- `UITests/AstroToolMobileUITests/AstroToolMobileLaunchTests.swift` — clean launch and fixture journey.

**Configuration and documentation**

- `Package.swift` — cross-platform targets and tests.
- `project.yml` — iOS app and UI-test targets, custom document type.
- `docs/first-steps.html`, `docs/en/first-steps.html` — Personal Team install and AirDrop workflow.

---

### Task 1: Cross-platform mobile domain and safety whitelist

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AstroMobileDomain/MobileLibraryModels.swift`
- Create: `Sources/AstroMobileDomain/MobileChanges.swift`
- Create: `Sources/AstroMobileDomain/MobilePackageModels.swift`
- Create: `Sources/AstroMobileDomain/MobileSyncTransport.swift`
- Create: `Tests/AstroMobileDomainTests/MobileLibraryModelsTests.swift`
- Create: `Tests/AstroMobileDomainTests/MobileChangesTests.swift`

**Interfaces:**
- Produces: `PortableLibraryID`, `MobileLibrarySnapshot`, `MobileProject`, `MobileNight`, `MobileCapture`, `MobileBriefing`, `MobileChecklistItem`, `MobileNote`, `MobileChange`, `MobilePackageManifest`, and `MobileSyncTransport`.
- The target depends only on Foundation; no URL-valued property and no untyped dictionary is permitted in a public record.

- [ ] **Step 1: Add failing round-trip and forbidden-field tests**

```swift
import Foundation
import Testing
@testable import AstroMobileDomain

@Test func snapshotRoundTripsWithSortedJSON() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    let data = try MobileJSON.encoder.encode(snapshot)
    #expect(try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: data) == snapshot)
}

@Test func encodedSnapshotContainsNoFilesystemMaterial() throws {
    let text = String(decoding: try MobileJSON.encoder.encode(MobileLibrarySnapshot.testValue), as: UTF8.self)
    for forbidden in ["/Users/", "file://", ".fits", "securityScopedBookmark", "SIMPLE  ="] {
        #expect(!text.localizedCaseInsensitiveContains(forbidden))
    }
}

@Test func mobileChangesExposeExactlyTwoKinds() throws {
    #expect(MobileChangeKind.allCases == [.checklistCompletion, .noteRevision])
}

private extension MobileLibrarySnapshot {
    static let testValue = MobileLibrarySnapshot(
        schemaVersion: 1,
        libraryID: PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        revision: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        projects: [], nights: [], captures: [], briefings: [], notes: []
    )
}
```

- [ ] **Step 2: Run the new target tests and confirm the target is missing**

Run: `swift test --filter AstroMobileDomainTests`

Expected: failure because `AstroMobileDomain` and its test target do not exist.

- [ ] **Step 3: Add the package platform and target declarations**

Update `Package.swift` to include `.iOS(.v26)`, the `AstroMobileDomain` library product, and `AstroMobileDomainTests`. Add `AstroMobileDomain` to `AstroApplication` dependencies for the Mac adapters. Keep `AstroMobileDomain` dependency-free except for Foundation.

```swift
.library(name: "AstroMobileDomain", targets: ["AstroMobileDomain"])
// ...
.target(name: "AstroMobileDomain"),
.testTarget(name: "AstroMobileDomainTests", dependencies: ["AstroMobileDomain"]),
```

- [ ] **Step 4: Implement strict value models**

Use explicit properties and public initializers. The root signature is:

```swift
public struct MobileLibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let libraryID: PortableLibraryID
    public let snapshotID: UUID
    public let revision: Int
    public let createdAt: Date
    public let projects: [MobileProject]
    public let nights: [MobileNight]
    public let captures: [MobileCapture]
    public let briefings: [MobileBriefing]
    public let notes: [MobileNote]
}

public struct MobileProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let catalogID: String
    public let phase: String
    public let integrationSeconds: Double
    public let goalHours: Double?
}

public struct MobileNight: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let localDate: String
    public let timeZoneID: String
}

public struct MobileCapture: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let nightID: UUID
    public let displayName: String
    public let filterName: String?
    public let exposureSeconds: Double
    public let integrationSeconds: Double
}

public struct MobileBriefing: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: Int
    public let savedAt: Date
    public let nightDate: Date?
    public let readiness: String
    public let targets: [MobileBriefingTarget]
    public let checklist: [MobileChecklistSection]
    public let noteID: String
}

public struct MobileChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String?
    public let isCompleted: Bool
    public let baseRevision: Int
}

public enum MobileNoteScope: String, Codable, Sendable { case briefing, project, night }
public struct MobileNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let scope: MobileNoteScope
    public let ownerID: String
    public let text: String
    public let baseRevision: Int
    public let updatedAt: Date
    public let isEditableOnPhone: Bool
}

public enum MobileChange: Codable, Equatable, Sendable {
    case checklistCompletion(ChecklistCompletionChange)
    case noteRevision(NoteRevisionChange)
}

public enum MobileChangeKind: String, Codable, CaseIterable, Sendable {
    case checklistCompletion
    case noteRevision
}

public struct ChecklistCompletionChange: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let deviceID: UUID
    public let briefingID: UUID
    public let itemID: String
    public let baseRevision: Int
    public let isCompleted: Bool
    public let createdAt: Date
}

public struct NoteRevisionChange: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let deviceID: UUID
    public let noteID: String
    public let ownerID: String
    public let baseRevision: Int
    public let text: String
    public let createdAt: Date
}

public struct MobilePackageEnvelope: Codable, Equatable, Sendable {
    public let snapshot: MobileLibrarySnapshot?
    public let changes: [MobileChange]
    public let acknowledgedChangeIDs: [UUID]
}

public struct MobileSnapshotSummary: Codable, Equatable, Sendable {
    public let projectCount: Int
    public let nightCount: Int
    public let captureCount: Int
    public let briefingCount: Int
    public let noteCount: Int
}

public struct MobilePackageManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let packageID: UUID
    public let createdAt: Date
    public let encryptedByteCount: Int64
    public let ciphertextSHA256: String
    public let keyMode: MobilePackageKeyMode
    public let wrappedContentKeyBase64: String?
}

public enum MobilePackageKeyMode: String, Codable, Sendable {
    case oneTimeQR
    case pairedDevice
}
```

Define `MobileJSON.encoder`/`decoder` with ISO-8601 dates and sorted keys. Do not add `URL`, `Data`, `[String: String]`, or a raw payload escape hatch.

- [ ] **Step 5: Add transport-neutral contracts**

```swift
public protocol MobileSyncTransport: Sendable {
    func send(_ envelope: MobilePackageEnvelope) async throws
    func receive() async throws -> MobilePackageEnvelope
}
```

The envelope carries typed snapshot/changes before packaging; it never carries a source URL.

- [ ] **Step 6: Run focused and full tests**

Run: `swift test --filter AstroMobileDomainTests && swift test --no-parallel`

Expected: all new tests and the existing 3366-test baseline pass.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/AstroMobileDomain Tests/AstroMobileDomainTests
git commit -m "feat: add safe mobile sync domain"
```

### Task 2: Portable library identity and Mac snapshot composer

**Files:**
- Modify: `Sources/AstroCore/WriteGuard.swift`
- Modify: `Sources/AstroApplication/Features/Briefing/NightBriefingModels.swift`
- Create: `Sources/AstroApplication/Features/MobileSync/PortableLibraryIdentityStore.swift`
- Create: `Sources/AstroApplication/Features/MobileSync/MobileSnapshotComposer.swift`
- Create: `Tests/AstroCoreTests/PortableLibraryIdentityWriteGuardTests.swift`
- Create: `Tests/AstroApplicationTests/NightBriefingMobileCompatibilityTests.swift`
- Create: `Tests/AstroApplicationTests/PortableLibraryIdentityStoreTests.swift`
- Create: `Tests/AstroApplicationTests/MobileSnapshotComposerTests.swift`

**Interfaces:**
- Consumes: Task 1 domain records.
- Produces: `PortableLibraryIdentityStore.preview(root:)`, `loadOrCreate(root:confirmedID:)`, and `MobileSnapshotComposer.compose(input:)`.

- [ ] **Step 1: Write failing identity safety tests**

```swift
@Test func portableIdentityCreationNeverOverwrites() throws {
    let root = try Fixture.library()
    let guardrail = WriteGuard(root: root)
    let id = UUID()
    _ = try guardrail.createPortableLibraryIdentity(id.uuidString)
    #expect(throws: AstroError.self) {
        try guardrail.createPortableLibraryIdentity(UUID().uuidString)
    }
}

@Test func previewPerformsNoWrite() throws {
    let fixture = try Fixture.library()
    let before = try await LibraryManifest.capture(root: fixture.root)
    _ = try PortableLibraryIdentityStore().preview(root: fixture.root)
    #expect(try await LibraryManifest.capture(root: fixture.root) == before)
}
```

- [ ] **Step 2: Verify failures**

Run: `swift test --filter PortableLibraryIdentity`

Expected: failure because the store and `WriteGuard` entry point are absent.

- [ ] **Step 3: Implement the narrow WriteGuard operation**

Write `.astro_tool/mobile/library-id` using `.withoutOverwriting`, validate UUID text before writing, and return an existing equal ID without rewriting. An existing different or malformed value throws; no cleanup or replacement path exists.

```swift
public func createPortableLibraryIdentity(_ uuidString: String) throws -> URL
```

- [ ] **Step 4: Implement preview and confirmed creation**

```swift
public struct PortableIdentityPreview: Equatable, Sendable {
    public let proposedID: PortableLibraryID
    public let relativePath: String
    public let alreadyExists: Bool
}

public func preview(root: URL) throws -> PortableIdentityPreview
public func loadOrCreate(root: URL, confirmedID: PortableLibraryID) throws -> PortableLibraryID
```

Creation must reject a `confirmedID` different from the previewed value supplied by the UI.

- [ ] **Step 5: Add failing composer whitelist tests**

Build metadata fixtures with project, night, series, annotation, briefing, and deliberately sensitive filesystem names. Assert the composed JSON contains the domain values but none of the sensitive names or paths.

- [ ] **Step 6: Make briefing checklist completion backward compatible**

Add `isCompleted: Bool` to `BriefingChecklistItem`, defaulting to `false`. Implement explicit `Codable` decoding with `decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false` so every V4 briefing JSON still opens. Add a fixture containing a V4 checklist item with no completion key and assert it decodes as incomplete.

- [ ] **Step 7: Implement `MobileSnapshotComposer`**

```swift
public struct MobileSnapshotComposer: Sendable {
    public struct Input: Sendable {
        public let libraryID: PortableLibraryID
        public let revision: Int
        public let projects: [ProjectRecord]
        public let nights: [NightRecord]
        public let captures: [SeriesRecord]
        public let annotations: [ProjectAnnotationRecord]
        public let briefings: [NightBriefingDraft]
    }

    public func compose(input: Input, now: Date) throws -> MobileLibrarySnapshot
}
```

Map only explicit display/domain values. Never pass a folder name, root URL, cache URL, bookmark, raw metadata blob, or database object through the public result.

- [ ] **Step 8: Run tests and commit**

Run: `swift test --filter PortableLibraryIdentity && swift test --filter MobileSnapshotComposer`

```bash
git add Sources/AstroCore/WriteGuard.swift Sources/AstroApplication/Features/Briefing/NightBriefingModels.swift Sources/AstroApplication/Features/MobileSync Tests/AstroCoreTests Tests/AstroApplicationTests
git commit -m "feat: compose portable mobile library snapshots"
```

### Task 3: Authenticated encrypted `.astromobile` package

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AstroMobileTransport/MobilePackageCrypto.swift`
- Create: `Sources/AstroMobileTransport/MobilePackageService.swift`
- Create: `Tests/AstroMobileTransportTests/MobilePackageCryptoTests.swift`
- Create: `Tests/AstroMobileTransportTests/MobilePackageServiceTests.swift`

**Interfaces:**
- Consumes: `MobilePackageEnvelope` and `MobilePackageManifest`.
- Produces: `MobilePackageCrypto.seal/open` and `MobilePackageService.export/importPreview/commitImport`.

- [ ] **Step 1: Write crypto and tamper tests**

```swift
@Test func sealedPayloadRoundTrips() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    #expect(try MobilePackageCrypto.open(sealed, using: key) == Data("snapshot".utf8))
}

@Test func oneChangedCiphertextByteIsRejected() throws {
    let key = SymmetricKey(size: .bits256)
    var sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    sealed.ciphertext[0] ^= 1
    #expect(throws: MobilePackageError.self) {
        try MobilePackageCrypto.open(sealed, using: key)
    }
}
```

- [ ] **Step 2: Verify the crypto tests fail**

Run: `swift test --filter MobilePackageCryptoTests`

Expected: missing type failures.

- [ ] **Step 3: Implement package crypto**

Add an `AstroMobileTransport` library target that depends on `AstroMobileDomain`, plus `AstroMobileTransportTests`. Add `AstroMobileTransport` to `AstroApplication` dependencies. Use CryptoKit ChaChaPoly with a random 256-bit content key and random nonce. The public manifest contains only schema version, package ID, encrypted byte count, created time, and SHA-256 of the combined sealed box. Keep key wrapping behind this interface:

```swift
public protocol MobilePackageKeyWrapping: Sendable {
    func wrap(_ key: SymmetricKey) throws -> Data
    func unwrap(_ wrapped: Data) throws -> SymmetricKey
}
```

Define `MobileSealedPayload` as mutable `nonce`, `ciphertext`, and `tag` byte arrays so tamper tests can change each authenticated part. Provide a deterministic in-memory wrapper only to tests and a QR one-time-key wrapper for the Personal Team prototype. `OneTimePackageKey` generates 256 random bits, exposes a versioned Base64URL payload for QR rendering, and reconstructs the symmetric key only after scanning. Persist no plaintext content key in the package.

- [ ] **Step 4: Write failing package staging tests**

Cover valid export/import, wrong key, manifest hash mismatch, schema too new, duplicate package ID, truncated payload, and destination replacement only after complete validation.

- [ ] **Step 5: Implement package service**

```swift
public struct MobilePackageImportPreview: Equatable, Sendable {
    public let packageID: UUID
    public let snapshotSummary: MobileSnapshotSummary
    public let incomingChanges: [MobileChange]
    public let encryptedByteCount: Int64
}

public actor MobilePackageService {
    public func export(_ envelope: MobilePackageEnvelope, to destination: URL, wrapping: MobilePackageKeyWrapping) throws
    public func importPreview(from source: URL, wrapping: MobilePackageKeyWrapping) throws -> MobilePackageImportPreview
    public func commitImport(packageID: UUID) throws -> MobilePackageEnvelope
}
```

Use a temporary sibling package and atomic rename for export. Never overwrite an existing destination. Import decrypts into application-owned staging and never deletes or edits the source document.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter MobilePackage`

```bash
git add Package.swift Sources/AstroMobileTransport Tests/AstroMobileTransportTests
git commit -m "feat: add encrypted AstroTool mobile packages"
```

### Task 4: Mac export/import experience

**Files:**
- Create: `Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift`
- Create: `Sources/AstroUI/Features/MobileSync/MobileSyncView.swift`
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`
- Create: `Tests/AstroUITests/MobileSyncStoreTests.swift`
- Create: `Tests/AstroUITests/MobileSyncSurfaceTests.swift`

**Interfaces:**
- Consumes: identity preview, snapshot composer, and package service.
- Produces: a reusable Mac sheet reachable from Settings and the Briefing export area.

- [ ] **Step 1: Write failing store state-machine tests**

Test `idle → previewing → ready → exporting → exported`, cancellation, existing destination, missing library, read-only identity creation, and corrupt incoming package. Assert export cannot begin until the user confirms the portable identity creation and exact payload summary.

- [ ] **Step 2: Verify tests fail**

Run: `swift test --filter MobileSyncStoreTests`

- [ ] **Step 3: Implement `MobileSyncStore`**

```swift
@MainActor @Observable
public final class MobileSyncStore {
    public enum Phase: Equatable { case idle, previewing, ready, exporting, exported(URL), importing, importReady, failed(String) }
    public private(set) var phase: Phase = .idle
    public private(set) var preview: MobileSnapshotSummary?
    public var includePreviews = false
    public func prepareExport() async
    public func export(to url: URL) async
    public func prepareImport(from url: URL) async
}
```

Inject all filesystem/network services. No `FileManager.default` call belongs in the view or store.

- [ ] **Step 4: Add surface tests before the view**

Pin these strings and identifiers:

- `v5.mobile-sync.open`
- `v5.mobile-sync.safety`
- `v5.mobile-sync.export`
- `v5.mobile-sync.import`
- “Original photos are not transferred. iPhone cannot modify files in the image library.”

- [ ] **Step 5: Implement the Mac sheet and entry points**

Use `fileExporter`/`fileImporter` with the custom `.astromobile` UTType. Show counts, encrypted size, last snapshot time, and the safety statement above the primary action. After export, render the one-time package key as a QR code with Core Image and explain: “After receiving the package, scan this code in AstroTool on your iPhone. The code unlocks this package only.” Never place the plaintext key on the clipboard or in logs. Keep existing Briefing PDF/PNG actions unchanged.

- [ ] **Step 6: Run UI/domain tests and commit**

Run: `swift test --filter MobileSync`

```bash
git add Sources/AstroUI/Features/MobileSync Sources/AstroUI/Settings/V2SettingsView.swift Sources/AstroUI/App/V2RootView.swift Tests/AstroUITests
git commit -m "feat: add Mac mobile package workflow"
```

### Task 5: iOS target, atomic store, and document import

**Files:**
- Modify: `project.yml`
- Create: `Sources/AstroToolMobile/AstroToolMobileApp.swift`
- Create: `Sources/AstroToolMobile/MobileLibraryStore.swift`
- Create: `Sources/AstroToolMobile/MobileRootView.swift`
- Create: `Sources/AstroToolMobile/Resources/en.lproj/Localizable.strings`
- Create: `Sources/AstroToolMobile/Resources/hu.lproj/Localizable.strings`
- Create: `Tests/AstroToolMobileTests/MobileLibraryStoreTests.swift`
- Create: `UITests/AstroToolMobileUITests/AstroToolMobileLaunchTests.swift`

**Interfaces:**
- Consumes: domain models and package importer.
- Produces: `AstroToolMobile` iOS app plus `MobileLibraryStore.activeSnapshot` and `queuedChanges`.

- [ ] **Step 1: Add failing atomic-store tests**

```swift
@Test func failedImportKeepsPreviousSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store
    await #expect(throws: MobilePackageError.self) { try await store.importPackage(fixture.corruptPackageURL) }
    #expect(await store.activeSnapshot?.revision == 1)
}

@Test func noteEditAppendsChangeWithoutMutatingSnapshot() async throws {
    let store = try MobileStoreFixture(snapshotRevision: 1).store
    try await store.editNote(id: "night-note", text: "Dew after midnight")
    #expect(await store.activeSnapshot?.notes.first?.text != "Dew after midnight")
    #expect(await store.queuedChanges.count == 1)
}
```

Create `MobileStoreFixture` in the same test file. It owns a unique temporary Application Support directory, writes an explicit schema-1 snapshot containing the `night-note` record, creates a truncated `corrupt.astromobile`, and removes only that temporary directory in `deinit`.

- [ ] **Step 2: Add the iOS build graph and confirm compilation failure**

Update `project.yml` with iOS 26 deployment, `AstroToolMobile` application, unit test, and UI-test targets. Depend on the local `AstroMobileDomain` and `AstroMobileTransport` products. Declare the `.astromobile` exported UTI as `com.apple.package` plus `public.content`, and add an `NSCameraUsageDescription` that says the camera scans the one-time AstroTool package key. Generate with `xcodegen generate`, then run:

`xcodebuild build -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'generic/platform=iOS Simulator'`

Expected: failure until the app sources exist.

- [ ] **Step 3: Implement the atomic mobile store**

Store `active/snapshot.json`, `changes/queue.json`, and import staging under Application Support. Write new data to staging, fsync/close, validate by decoding again, then replace the active file. Never retain the source AirDrop URL or original package after import.

- [ ] **Step 4: Implement the app entry, QR unlock, and empty state**

Handle `.onOpenURL` by copying the security-scoped document into app-owned staging, then immediately release access. Present a camera-based QR scanner only after a valid locked `.astromobile` document is staged; accept only the exact `astrotool-mobile-key:v1:` prefix and reject reused/package-mismatched keys. Feed the decoded `OneTimePackageKey` to `MobilePackageService.importPreview`. Empty state copy:

- “No AstroTool library on this iPhone yet.”
- “On your Mac, choose iPhone Sync, then send the mobile package with AirDrop.”
- “Original photos stay on your Mac or external drive.”

- [ ] **Step 5: Run store, build, and launch tests**

Run:

```bash
xcodegen generate
xcodebuild test -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AstroToolMobileTests/MobileLibraryStoreTests
```

- [ ] **Step 6: Commit**

```bash
git add project.yml AstroTool.xcodeproj Sources/AstroToolMobile Tests/AstroToolMobileTests UITests/AstroToolMobileUITests
git commit -m "feat: add offline AstroTool iPhone companion"
```

### Task 6: Native iPhone project, briefing, checklist, and sync UI

**Files:**
- Create: `Sources/AstroToolMobile/TonightMobileView.swift`
- Create: `Sources/AstroToolMobile/ProjectsMobileView.swift`
- Create: `Sources/AstroToolMobile/BriefingsMobileView.swift`
- Create: `Sources/AstroToolMobile/SyncMobileView.swift`
- Modify: `Sources/AstroToolMobile/MobileRootView.swift`
- Modify: `Sources/AstroToolMobile/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/AstroToolMobile/Resources/hu.lproj/Localizable.strings`
- Create: `Tests/AstroToolMobileTests/MobileInteractionTests.swift`
- Modify: `UITests/AstroToolMobileUITests/AstroToolMobileLaunchTests.swift`

**Interfaces:**
- Consumes: `MobileLibraryStore` and Task 1 records.
- Produces: four-tab, offline, editable companion UI.

- [ ] **Step 1: Write interaction and surface tests**

Assert checklist toggles append `ChecklistCompletionChange`, note saves append `NoteRevisionChange`, stale snapshots show their timestamp, and no UI string/action contains delete, move, rename, path, Finder, or original-file language.

- [ ] **Step 2: Implement four-tab navigation**

Use `TabView` with **Tonight**, **Projects**, **Briefings**, and **Sync**. The first three read only from the active snapshot. Only checklist buttons and note editor call store mutation methods.

- [ ] **Step 3: Implement field-friendly briefing UI**

Use a minimum 52-point checklist hit area, clear completed state, Dynamic Type without fixed heights, high contrast, and `accessibilityIdentifier` values under `v5.mobile.*`. Show planned times as plans, never promises.

- [ ] **Step 4: Implement project and sync summaries**

Projects show domain names, progress, integrations, and capture summaries without file counts tied to paths. Sync shows last snapshot date, queued change count, package export/import, and the permanent original-photo safety statement.

- [ ] **Step 5: Run unit and iOS UI tests**

```bash
xcodebuild test -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AstroToolMobileTests/MobileInteractionTests
xcodebuild test -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AstroToolMobileUITests
```

Expected: empty launch and imported-fixture journey pass in Hungarian and English.

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroToolMobile Tests/AstroToolMobileTests UITests/AstroToolMobileUITests
git commit -m "feat: add field-ready iPhone companion screens"
```

### Task 7: Safe return changes and Mac conflict preview

**Files:**
- Create: `Sources/AstroApplication/Features/MobileSync/MobileChangeImporter.swift`
- Modify: `Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift`
- Modify: `Sources/AstroUI/Features/MobileSync/MobileSyncView.swift`
- Modify: `Sources/AstroToolMobile/MobileLibraryStore.swift`
- Create: `Tests/AstroApplicationTests/MobileChangeImporterTests.swift`
- Modify: `Tests/AstroUITests/MobileSyncStoreTests.swift`
- Modify: `Tests/AstroToolMobileTests/MobileLibraryStoreTests.swift`

**Interfaces:**
- Consumes: queued `MobileChange` values.
- Produces: `MobileChangeImportPreview`, `MobileChangeResolution`, and idempotent application receipt.

- [ ] **Step 1: Write failing importer tests**

Cover matching revision, Mac-edited checklist conflict, Mac-edited note conflict, empty phone note, duplicate change ID, unknown target ID, and a crafted unsupported change discriminator. Assert the importer cannot invoke any file mutation operation.

- [ ] **Step 2: Define explicit preview and resolution types**

```swift
public enum MobileChangeResolution: Equatable, Sendable {
    case applyPhone
    case keepMac
    case keepBothAsFieldNote
}

public struct MobileChangeImportPreview: Equatable, Sendable {
    public let applicable: [MobileChange]
    public let conflicts: [MobileChangeConflict]
    public let duplicates: [UUID]
    public let rejected: [MobileRejectedChange]
}
```

- [ ] **Step 3: Implement importer using injected commands**

Inject narrow closures/protocols for saving briefing revisions and note revisions. Do not inject `WriteGuard`, `FileManager`, database handles, or a generic execute closure. Record applied change IDs in app-owned metadata so reimport is idempotent.

- [ ] **Step 4: Implement Mac conflict UI**

Show both values and timestamps. Default note conflict to **Keep both as field note**. Empty phone text is rejected as “No text to import,” never interpreted as deletion. Require a final confirmation before applying any return change.

- [ ] **Step 5: Export return package from iPhone**

The Sync tab writes an encrypted `.astromobile` document containing the base snapshot identity and queued changes. Mark changes acknowledged only after a subsequent Mac-generated snapshot lists their IDs as applied; exporting alone never clears the queue.

- [ ] **Step 6: Run round-trip tests and commit**

Run: `swift test --filter MobileChange && swift test --filter MobileSyncStore`

```bash
git add Sources/AstroApplication/Features/MobileSync Sources/AstroUI/Features/MobileSync Sources/AstroToolMobile Tests
git commit -m "feat: round-trip mobile checklist and notes safely"
```

### Task 8: Documentation, localization, and Wave 1 release gate

**Files:**
- Modify: `docs/first-steps.html`
- Modify: `docs/en/first-steps.html`
- Modify: `README.md`
- Modify: `scripts/check-public-content.sh`
- Create: `docs/releases/v5.0.0-prototype.md`
- Create: `scripts/smoke-mobile-package.sh`

**Interfaces:**
- Consumes: the finished Wave 1 Mac and iPhone flows.
- Produces: reproducible Personal Team install instructions and end-to-end release evidence.

- [ ] **Step 1: Extend public-content tests before documentation**

Require Hungarian and English pages to contain the Personal Team seven-day limitation, AirDrop workflow, no-original-photo statement, no-CloudKit statement, and “checklist/notes only” return boundary.

- [ ] **Step 2: Write ordinary-user documentation**

Document Xcode sign-in, selecting the user’s Personal Team, connecting the iPhone, trusting the local build if requested, generating the package on Mac, AirDropping it, importing it, returning changes, and reinstalling after provisioning expiry. Keep developer detail in a collapsed troubleshooting section.

- [ ] **Step 3: Add deterministic smoke script**

`scripts/smoke-mobile-package.sh` must:

1. create a temporary fixture outside the repo;
2. capture its full source manifest;
3. export, decrypt, and import a mobile snapshot;
4. append one checklist and one note change;
5. return and apply both through the importer;
6. compare the source file manifest before/after;
7. fail if any image bytes, path, filename, or unsupported command appears in either package.

- [ ] **Step 4: Run the complete Wave 1 gate**

```bash
swift test --no-parallel
xcodegen generate
xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS'
xcodebuild test -project AstroTool.xcodeproj -scheme AstroToolMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
./scripts/check-public-content.sh
./scripts/smoke-mobile-package.sh
git diff --check
```

Expected: every command exits 0, the smoke script reports an unchanged source manifest, and both app journeys pass.

- [ ] **Step 5: Perform the manual own-device acceptance test**

Install with Personal Team, AirDrop a real metadata-only package with previews disabled, enable Airplane Mode, open the briefing, toggle one checklist item, add one note, AirDrop the return package, approve it on Mac, and verify the source library manifest is unchanged. Record only anonymous counts and pass/fail in `docs/releases/v5.0.0-prototype.md`.

- [ ] **Step 6: Commit**

```bash
git add docs README.md scripts
git commit -m "docs: publish V5 AirDrop prototype workflow"
```

---

## Deferred to Wave 2: Nearby Sync

The next implementation plan adds `NWListener`, `NWBrowser`, Bonjour service discovery, peer-to-peer Wi-Fi, persistent device identity keys, six-digit transcript confirmation, encrypted framing, retry, and the direct **iPhone Sync** button. It implements the existing `MobileSyncTransport` interface and reuses every snapshot, change, conflict, store, and UI type delivered by this plan.
