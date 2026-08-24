# Task 7 — Safe return changes and Mac conflict preview

## RED / GREEN evidence

- Added first importer tests before the implementation for matching revisions, conflicts, blank notes, duplicate IDs, unknown targets, cross-device queues, confirmation, and command isolation.
- RED was observed as the missing `MobileChangeImporter` API; after implementation the focused suite passes (6 tests).
- Added mobile-store fixture coverage for return export queue retention and acknowledgement pruning. The iOS target cannot execute in this environment because Xcode reports no iOS destinations / the iOS 26.5 platform is not installed.

## Schemas and semantics

- `MobileChangeImportPreview` has deterministic sorted applicable, conflict, duplicate, already-applied, and rejected records.
- `MobileChangeConflict` carries typed Mac/phone checklist values or note texts, timestamps, target name, and recommended resolution. Note conflicts recommend `keepBothAsFieldNote`.
- `MobileRejectedChange` records localized-domain reasons including unknown target, blank note, cross-device queue, malformed record, and limits.
- `MobileChangeApplicationRecord`/`MobileChangeApplicationReceipt` binds library ID, source package ID/fingerprint, applied change IDs, and resulting revisions. `MobileChangeReceiptStore` writes bounded JSON atomically in app-owned metadata.

## Security and atomicity

- The importer accepts only an envelope with a metadata snapshot matching the expected library and base snapshot, rejects acknowledgement IDs on the return leg, checks one device queue, validates limits/revisions/timestamps/targets before commands, and never receives a path, file handle, database object, `WriteGuard`, or generic closure.
- Preview does not invoke commands. Apply requires final confirmation and revalidates the exact source fingerprint and snapshot identity. Each durable command is recorded only after success; a later failure returns an explicit partial receipt instead of claiming all-or-nothing success.
- iPhone return export is encrypted through the existing one-time-key package service and leaves its queue unchanged. Phone imports reject envelopes containing return changes and prune only acknowledged IDs that match the local queue, atomically with the forward snapshot state write.

## UI / flow

- Mac store now exposes typed return preview, explicit conflict resolutions, final-confirmation apply, and receipt state. The Sync surface reports applicable/conflicting/already-handled/rejected counts and states checklist/notes-only safety, Mac review requirement, and no automatic/cloud sync.
- iPhone store exposes `exportReturnPackage`/`exportQueuedChanges`; the result includes package identity and one-time QR payload while preserving all queued changes until a later authenticated acknowledgement snapshot.

## Verification

- `swift test --filter MobileChangeImporterTests` — passed, 6 tests.
- `swift test --filter LocalizationCoverageTests` — passed, 15 tests.
- `swift test --skip-build` — passed, 3,459 tests in 219 suites.
- `xcodebuild -project AstroTool.xcodeproj -scheme AstroToolApp -destination platform=macOS ... build` — BUILD SUCCEEDED.
- `git diff --check` — clean.
- Mobile/iOS Xcode gate: blocked externally. `AstroToolMobile` has no usable destination; Xcode reports iOS 26.5 is not installed / no simulator destination. No iOS success is claimed.

## Remaining concern / external gate

The authenticated package-service compatibility preview still exposes only its summary and incoming change list; production wiring from a retained authenticated return capability into the typed `MobileChangeImportPreview` should be completed when the iOS/Xcode gate and final package-direction schema are available. The direct store API and fixture journey cover the safety boundary without retaining decrypted package material.
