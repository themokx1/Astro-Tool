# Task 5 Report — iOS target, atomic store, and document import

## RED / GREEN evidence

RED was established before app sources existed: the new `AstroToolMobileTests` store contract and iOS XcodeGen graph were added, `xcodegen generate` initially rejected the missing app source directory, and the first generated-target build could not compile because the target sources were intentionally absent. The graph was then completed with the app, unit-test, UI-test, package dependencies, and document metadata.

GREEN evidence available on this host:

```text
xcodegen generate                                      # generated AstroTool.xcodeproj
swiftc -swift-version 6 -typecheck ...                # domain + transport + mobile app sources: passed
swift test --no-parallel                               # 3452 tests in 218 suites passed
git diff --check                                       # passed
```

The required iOS build/test commands could not execute on this host. `xcodebuild` resolves the local package graph but reports that the iOS 26.5 SDK is not installed. The installed simulator inventory contains iOS 26.4 devices (including iPhone 17 Pro) and older runtimes; CoreSimulator therefore cannot satisfy this package's iOS 26 deployment build. No simulator UI or focused iOS XCTest result is claimed.

## Target and signing evidence

- Scheme: `AstroToolMobile`.
- Targets: `AstroToolMobile`, `AstroToolMobileTests`, `AstroToolMobileUITests`.
- Deployment: macOS 26 remains unchanged; iOS 26 is added.
- Package dependencies are limited to `AstroMobileDomain` and `AstroMobileTransport`; no macOS UI/application target is linked.
- No development team, paid capability, CloudKit, Network.framework, or background entitlement is declared. `CODE_SIGNING_ALLOWED = NO` and the existing identity/manual settings allow simulator builds without a team. A physical device requires the user's own Personal Team selection in Xcode.
- `Info.plist` declares `.astromobile` as an exported package/content document type, the matching filename/MIME tags, and a plain-English camera purpose string.

## Implementation

- `MobileLibraryStore` is an injected-root actor with stable per-install device ID, last-good active snapshot, append-only typed queue, consumed-package receipts, and recovery state.
- Snapshot, queue, device ID, and receipts are stored under Application Support. Writes use operation-private sibling files, exclusive creation, complete writes, `fsync`, close, JSON decode/semantic validation, and atomic rename. Existing active bytes are never removed before validated replacement.
- Recovery preserves valid state when the other file is corrupt and reports `.invalidSnapshot` or `.invalidQueue` without deleting user data.
- Imports parse the exact `astrotool-mobile-key:v1:` payload, preview/authenticate through `MobilePackageService`, require a snapshot/current schema, reject cross-library and non-increasing revisions, preserve the queue, install atomically, and persist package receipts. App-owned staging copies are no-follow checked, private, and removed only by the store's staging seam.
- Only checklist completion and note revision changes can be appended. Unknown records, non-editable notes, duplicate changes, and no-op edits fail closed; the active snapshot remains unchanged.
- The app shell handles security-scoped document intake, clears the unlock text on background/success/failure, and presents the exact English empty-state safety promise plus Hungarian equivalents. The shell remains intentionally smaller than Task 6's full tabs.

## Localization and accessibility

English and Hungarian tables include the empty state, AirDrop guidance, safety promise, package unlock, and queue/library labels. The shell uses Dynamic Type-compatible system text, VoiceOver header/accessibility labels, native controls, and high-contrast system materials. The UI-test target includes English empty-state and Hungarian launch checks with fixture launch arguments.

## Atomicity / threat self-review

- Original files and incoming source URLs never enter persisted mobile state; source security-scoped access is released immediately after the app-owned copy completes.
- Symlinked package roots/children and unexpected package members are rejected before staging. The transport service performs the authenticated package and schema validation.
- Failed decode, wrong key, replay receipt, cross-library package, downgrade, and failed atomic write leave the previous snapshot and queue untouched.
- Remaining concern: iOS unit/UI execution and runtime QR-camera validation require an installed iOS 26.5 SDK/runtime and were not available in this environment. The next device gate should run the focused store suite plus English/Hungarian launch journeys on an iOS 26 simulator or Personal-Team device.
