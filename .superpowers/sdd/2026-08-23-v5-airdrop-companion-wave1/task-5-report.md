# Task 5 Report — iOS target, atomic store, and document import

## RED / GREEN evidence

RED was established before app sources existed: the new `AstroToolMobileTests` store contract and iOS XcodeGen graph were added, `xcodegen generate` initially rejected the missing app source directory, and the first generated-target build could not compile because the target sources were intentionally absent. The graph was then completed with the app, unit-test, UI-test, package dependencies, and document metadata.

GREEN evidence available on this host:

```text
xcodegen generate                                      # generated AstroTool.xcodeproj
xcodebuild build -target AstroToolMobile ...           # iOS 26.5 SDK, arm64+x86_64: BUILD SUCCEEDED
xcodebuild build -target AstroToolMobileTests ...      # Debug/testability, arm64+x86_64: BUILD SUCCEEDED
swift test --no-parallel                               # 3452 tests in 218 suites passed
git diff --check                                       # passed
```

The iOS 26.5 SDK is installed and the direct app and unit-test target builds pass for both simulator architectures. The scheme-level generic destination is unavailable because this host has no iOS 26.5 runtime (only iOS 26.4 and older runtimes), and CoreSimulator rejects the available 26.4 device for this scheme. Consequently no focused iOS XCTest runtime result is claimed; the test bundle itself builds successfully.

## Target and signing evidence

- Scheme: `AstroToolMobile`.
- Targets: `AstroToolMobile`, `AstroToolMobileTests`, `AstroToolMobileUITests`.
- Deployment: macOS 26 remains unchanged; iOS 26 is added.
- Package dependencies are limited to `AstroMobileDomain` and `AstroMobileTransport`; no macOS UI/application target is linked.
- No development team, paid capability, CloudKit, Network.framework, or background entitlement is declared. The iOS target uses Automatic signing with an empty identity/team, and the project contains no global/manual `CODE_SIGNING_ALLOWED = NO`; the CLI-only simulator verification passes `CODE_SIGNING_ALLOWED=NO`. A physical device therefore remains compatible with the user's own Personal Team selection in Xcode.
- `Info.plist` declares `.astromobile` as an exported package/content document type, the matching filename/MIME tags, and a plain-English camera purpose string.

## Implementation

- `MobileLibraryStore` is an injected-root actor with stable per-install device ID, last-good active snapshot, append-only typed queue, consumed-package/key-fingerprint receipts, and explicit recovery state. Corrupt device IDs and receipt mirrors lock all mutations/imports without regeneration, deletion, or silent reset; the UI gives recovery guidance.
- Snapshot, queue, device ID, receipts, and metadata are represented by one durable state document. The writer uses unique operation-private siblings, exclusive create, complete writes, `fsync`, close, exact-byte reopen/decode validation, atomic rename, and parent-directory sync. Once present, the state document is the sole authority, so an import cannot report failure after a snapshot-only commit.
- Recovery preserves valid snapshot/queue/device bytes when another component is corrupt and reports `.invalidSnapshot`, `.invalidQueue`, `.invalidDeviceID`, or `.invalidReceipts` without deleting user data. Tests cover relaunch and byte preservation for mutation attempts.
- Imports parse the exact `astrotool-mobile-key:v1:` payload, preview/authenticate through `MobilePackageService`, validate public manifest/package structure before unlock UI, validate snapshot/library/schema/revision before commit, reject cross-library/non-increasing/over-cap revisions, bind one-time key fingerprints to package IDs, preserve the queue, and install atomically. Valid-import and wrong-key tests reach the transport path.
- App-owned staging copies enumerate hidden entries, enforce exactly the two public children, use no-follow regular-file descriptors and size/link checks, verify copied bytes, and discard only an operation-owned URL whose recorded device/inode identity still matches. Generic public staged-package deletion is no longer exposed.
- Only checklist completion and note revision changes can be appended. Unknown records, non-editable notes, duplicate changes, and no-op edits fail closed; the active snapshot remains unchanged.
- Effective queue values fold earlier queued changes, so repeated note/checklist values are deterministic no-ops rather than UUID-dependent duplicates.
- The unlock flow now uses an AVFoundation camera QR scanner seam as the primary production path. It appears only after public package validation, stops on cancel/background, clears plaintext payload lifetime on exits, and accepts simulator launch-argument injection for tests.
- The app shell handles security-scoped document intake, clears the unlock text on background/success/failure, and presents the exact English empty-state safety promise plus Hungarian equivalents. The shell remains intentionally smaller than Task 6's full tabs.

## Localization and accessibility

English and Hungarian tables include the empty state, AirDrop guidance, safety promise, package unlock, camera errors, and queue/library labels. The shell uses Dynamic Type-compatible system text, VoiceOver header/accessibility labels, stable identifiers for empty/recovery/unlocking/imported/error/action states, native controls, and high-contrast system materials. The UI-test target includes English empty-state and Hungarian launch checks with fixture launch arguments.

## Atomicity / threat self-review

- Original files and incoming source URLs never enter persisted mobile state; source security-scoped access is released immediately after the app-owned copy completes.
- Symlinked package roots/children and unexpected package members are rejected before staging. The transport service performs the authenticated package and schema validation.
- Failed decode, wrong key, replay receipt, cross-library package, downgrade, and failed atomic write leave the previous snapshot and queue untouched; legacy mirrors are not consulted once the state contract exists.
- Remaining concern: iOS unit/UI execution and runtime QR-camera validation require a usable CoreSimulator runtime; the host's iOS 26.4 device is rejected by the scheme while iOS 26.5 has no installed runtime. The next device gate should run the focused store suite plus English/Hungarian launch journeys on an iOS 26.5 simulator or Personal-Team device.

## Fix round 2 — retryable staged update and durable contract

- Existing-library updates are now first-class UI: a newly staged package remains visible above the current library with “Import newer package”, AirDrop/unlock guidance, a primary import action, and an explicit discard action. Staging replacement is serialized inside the store actor, and restart cleanup removes only UUID-named operation-owned staging children.
- Authenticated package previews are peekable through `validatedEnvelope(packageID:)` and remain staged until the durable state document commits. A state-write failure leaves the exact staged preview/source retryable in the same process; service acknowledgement occurs afterward and durable receipts make acknowledgement failure idempotent.
- `state.json` is now the explicit sole authoritative persisted contract once present. Snapshot, queue, receipts, device identity, and key fingerprints are committed together; stale legacy mirrors are not consulted. Initial state creation uses the same durable writer, including checked parent-directory `fsync`.
- Imports enforce an absolute revision ceiling and bounded delta without arithmetic overflow, including first import. Fingerprint receipts validate lowercase SHA-256 shape, unique package mapping, and reload assignment; semantic receipt corruption preserves the snapshot while locking mutations/imports.
- Source staging opens the package root with `O_DIRECTORY|O_NOFOLLOW`, enumerates through the duplicated root descriptor, uses `openat` for fixed children, verifies root identity between reads, validates exact manifest schema/key mode/date/count/hash/canonical wrapped-key data before scanner presentation, and verifies copied payload bytes.
- The scanner is injected through `MobileQRScanner` (including session and payload seam), canonical QR payload validation happens before dismissing the scanner, cancellation clears payload and cancels the import task, and URL replacement is serialized. Dynamic error/prompt keys are rendered through `LocalizedStringKey`; English/Hungarian tables and imported/update fixture identifiers are included.
- Signing keeps Automatic iOS signing with an empty team and inherited identity; `CODE_SIGNING_ALLOWED=NO` is used only on simulator CLI verification, while `CODE_SIGNING_REQUIRED=NO` remains scoped to the macOS app target for existing regression compatibility.
- Regression coverage now includes same-library valid imports, canonical-key malformed packages reaching transport, retry after injected state-write failure, semantically orphaned fingerprint receipts, and absurd revision overflow/cap rejection; the mobile UI test consumes empty/imported fixture launch arguments.

Round-2 verification:

```text
xcodegen generate                                      # passed
xcodebuild build -target AstroToolMobile ...           # BUILD SUCCEEDED, arm64+x86_64, iphonesimulator26.5
xcodebuild build -target AstroToolMobileTests ...      # BUILD SUCCEEDED, arm64+x86_64, testability enabled
swift test --no-parallel                               # 3452 tests in 218 suites passed
git diff --check                                       # passed
```

The focused iOS XCTest invocation was attempted again and remains blocked by CoreSimulator: the available iOS 26.4 device is reported ineligible because the scheme's iOS 26.5 platform/runtime is not installed. No runtime result is claimed.

## Fix round 3 — opaque preview lifecycle and staged-package ownership

- Removed the public `allowExistingPreview` escape hatch. Authentication now returns an opaque `MobilePackagePreviewToken`; the store retries only with the token bound to the exact staged URL identity and key fingerprint. Manifest UUID alone cannot retrieve an authenticated cache, so a forged same-UUID package/key cannot reuse a prior preview.
- `MobileLibraryStore` owns one `currentStagedPackage` and one pending authenticated preview. `receive(source:)` serially discards the prior exact owned child before staging the new one; discard, replacement, authentication failure, cancellation, validation failure, and successful import clear pending material and remove only the recorded device/inode-matching child. The app now passes only the new URL.
- Import ordering is retryable: authentication and envelope validation happen before durable state, the durable state commit precedes service acknowledgement, and a pre-commit write failure retains the opaque authenticated token for a same-process retry. A successful durable commit remains authoritative if acknowledgement fails.
- `state.json` is read first and is authoritative when present; legacy device/snapshot/queue/receipt mirrors are read only for a validated first migration. State validation now covers bounded collection/string sizes, finite/nonnegative numeric values, capture project/night references, briefing/note/checklist relationships, revisions, editability, queue kinds, queue references, and receipt/fingerprint semantics.
- Parent-directory sync failure after atomic rename is exposed as a durability warning rather than a false failed import; all pre-rename failures preserve the old state. The atomic writer keeps unique temps, checked write/fsync/close, exact-byte reopen validation, rename, and post-rename cleanup semantics.
- Scanner invalid/unavailable paths stop and dismiss the camera before showing the localized parent error. Background/cancel paths clear payload and staged bindings; post-import UI refreshes durable state even when task cancellation races the commit.
- iOS signing remains Automatic with an empty `DEVELOPMENT_TEAM`; no iOS manual identity or project-wide no-signing setting is emitted. Existing macOS-only signing fixture settings remain unchanged for regression compatibility.

Round-3 verification (fresh retained logs):

```text
xcodegen generate                                                        # passed
xcodebuild build -target AstroToolMobile -configuration Release ...      # BUILD SUCCEEDED, arm64+x86_64, iphonesimulator26.5
xcodebuild build -target AstroToolMobileTests -configuration Debug ...   # BUILD SUCCEEDED, arm64+x86_64, testability enabled
xcodebuild build -target AstroToolMobileUITests -configuration Debug ... # BUILD SUCCEEDED, arm64+x86_64
swift test --no-parallel                                                 # 3452 tests in 218 suites passed
git diff --check                                                          # passed
```

Retained build/test logs: `/tmp/task5-round3-app.log`, `/tmp/task5-round3-unit.log`, `/tmp/task5-round3-ui.log`, `/tmp/task5-round3-mac-full-final.log`. A focused iOS test-runtime attempt remains unavailable on this host: CoreSimulator reports no matching device and iOS 26.5 is not installed. No runtime pass is claimed.

## Replacement fix — capability, queue, validation, durability, and intake

- Removed the package-ID decrypted-cache operations. `MobilePackagePreviewToken` is now an opaque, service-instance-bound capability; only a token can read, commit, or discard authenticated material, and a committed token is single-use. The compatibility summary preview releases its token immediately. Mac Task 4 uses that summary-only flow and no longer tries to discard a cache by package ID.
- Queue validation now checks typed intrinsic shape, IDs, finite timestamps, UTF-8 sizes, and revisions without requiring the next snapshot to retain the original note/checklist target. New snapshots therefore preserve queued offline edits byte-for-byte as Task 7 conflict candidates, while fresh edits continue to resolve only against the current snapshot.
- Store and transport validation now both enforce unique briefing target/section/item IDs, bounded targets/sections/items/warnings, and the aggregate nested-record limit. Reload locks recovery rather than accepting semantic corruption.
- Every initial-migration and normal state write uses checked file and parent-directory sync. A post-rename parent-sync problem preserves committed state, raises a visible localized durability warning, and carries that warning forward in the authoritative state document on the next successful write.
- `--astrotool-mobile-ui-fixture imported` now builds an isolated, valid persisted mobile snapshot before the app store launches; the UI test exercises real library state plus the update surface. Document-intake failures (including unavailable security scope) now surface a localized recovery action instead of being silently swallowed.

Replacement RED/GREEN evidence:

```text
xcodebuild build -target AstroToolMobileTests ...                 # BUILD SUCCEEDED (arm64 + x86_64)
swift test --filter MobilePackageServiceTests --no-parallel       # 39 tests passed
```

The iOS runtime remains unavailable on this host, so the new iOS store/UI tests are compiled but not claimed as runtime-executed here. The retained concern is unchanged: run the focused mobile unit/UI journeys on an installed iOS 26.5 simulator or a Personal-Team device.

## Replacement fix round 1

- Document intake now always attempts the app-owned copy even when security-scope acquisition reports false; only a successful acquisition is balanced with `stopAccessingSecurityScopedResource`. Errors are surfaced at the root UI with a localized dismiss/retry instruction.
- The import API now accepts only the store's current private staged package. Replacing or discarding staged input clears the matched preview capability, preventing a caller-supplied URL from superseding private staging.
- A `.state-durability` app-owned journal is written and synced as `pending` before every authoritative state replacement (including migration), and overwritten to `clear` only after replacement plus parent sync. Bootstrap treats `pending` as durability uncertainty while keeping valid committed state active.
- Queued changes must now be owned by the authoritative persisted device ID. A decodable foreign-device queue locks recovery rather than being silently accepted.
- The imported fixture root is unique for every process/launch and no longer fabricates a package-update surface; UI coverage checks the real persisted revision/project library state.

Build/test execution after this round is pending renewed tool authorization: the host rejected Xcode execution because the account usage limit was reached. `git diff --check` and staged status should be rerun with the normal build gates once access resumes.
