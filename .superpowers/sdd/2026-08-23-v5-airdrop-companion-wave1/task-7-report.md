# Task 7 — Encrypted return leg review-round-1 closure

## Outcome

The phone return document is explicitly `returnChanges`, carries its sent base snapshot identity, and is authenticated into an opaque Mac package capability. The Mac retains that capability only through typed preview and final-confirmation apply; cancellation, failure, and success discard it. Forward snapshots and return documents are separated by purpose, and the phone accepts only forward snapshots with matching acknowledgement IDs.

## RED / GREEN evidence

- Importer tests cover matching revisions, fresh-current-vs-sent-base identity, conflict values/timestamps, blank-note rejection, duplicate/unknown records, whole-queue device validation, chronology/latest effective edit, explicit confirmation, durable replay, configuration failure, and cumulative acknowledgement IDs.
- The importer now calls only three narrow production command types: checklist revision, note revision, and field-note creation. The concrete production command store persists each deterministic change ID and resulting revision atomically and idempotently; missing configuration fails closed.
- The cumulative per-library ledger retains prior package records, applied IDs, deliberate `keepMac` resolutions, superseded IDs, and resulting revisions. Corrupt/empty ledger data is a visible receipt failure rather than an empty ledger.
- iPhone return export uses the system document exporter, preserves the queue through cancellation and export failure, rejects overwrite through the existing destination coordinator, presents a one-time code only in view state, and explains that queued records remain until a later matching forward acknowledgement.

## Security and durability

- Authenticated envelope purpose/base identity are validated before typed classification. Mac preview compares the authenticated sent base identity against the separately persisted last-forward snapshot identity while conflict detection uses a newly composed current Mac snapshot.
- The retained opaque capability is the only authority for the authenticated package ID, envelope, and fingerprint. The legacy summary-only preview seam is internal fixture support; production uses the authenticated capability path.
- Preview performs no domain mutation. Apply requires final confirmation, revalidates the source fingerprint and current snapshot, executes only the allowlisted commands, and commits the cumulative ledger after each successful command. Command IDs make command-success/receipt-failure retries idempotent.
- Phone forward import prunes only exact acknowledged IDs and commits the fresh snapshot plus queue pruning atomically. Return packages cannot enter the forward-import path.
- No photo path, image bytes, generic file operation, database handle, WriteGuard, or cloud/live-sync behavior enters the package/import command boundary.

## UI / localization

- Mac review renders the authenticated typed preview, applicable/conflict/already-handled/superseded/duplicate/rejected counts, human target names, both checklist/note values and timestamps, every valid resolution, note default keep-both, separate final confirmation, success totals, and the no-photo/no-automatic-sync safety copy.
- Mac return messages and resolution/result labels have EN/HU entries; no raw target IDs are displayed in conflict rows.
- iPhone Sync has a real return exporter, ready-to-import state, one-time code, queued count, acknowledgement explanation, and visible error handling while preserving queued changes.

## Verification evidence

- `swift test --filter MobileChangeImporterTests` — passed, 9 tests.
- `swift test --filter MobileSyncStoreTests` — passed, 15 tests.
- `swift test --filter MobileLibraryModelsTests` — passed, 4 tests.
- `swift test --filter 'MobileChangeImporterTests|MobileSyncStoreTests|MobilePackageServiceTests|MobileLibraryModelsTests'` — passed, 68 tests in 2 suites, after the return-envelope key fixture correction.
- `swift test` — passed, 3,464 tests in 219 suites.
- `swift scripts/extract-localizable-strings.swift --missing` — only the existing explicit domain/brand allowlist remains (AstroTool, FWHM, Light/Flat/Dark/Bias, OK).
- `xcodebuild -project AstroTool.xcodeproj -scheme AstroToolApp -destination platform=macOS -derivedDataPath /tmp/astro-v5-round1 build` — BUILD SUCCEEDED during this review round; SwiftPM compilation also succeeded after the final source additions.
- `git diff --check` — clean before commit.
- iOS runtime gate remains external and unclaimed: this environment has no usable iOS destination and reports the iOS 26.5 platform/simulator unavailable.

## External gate / concern

The Mac SwiftPM and macOS app checks are the evidence for this round. An official iOS simulator/device build and UI journey still require the unavailable Xcode iOS runtime; no iOS success is claimed.
