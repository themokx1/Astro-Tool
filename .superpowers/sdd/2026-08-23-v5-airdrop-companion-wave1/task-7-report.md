# Task 7 — Encrypted return leg review-round-3 closure

## Outcome

The authenticated Mac return path retains the opaque package capability, previews typed changes, requires final confirmation, and uses an explicit non-cancellable applying phase. Duplicate change-ID collisions now reject every colliding record before commands. Latest-invalid chronology remains fail-closed.

Production domain commands now write the stores consumed by forward snapshot composition. Briefing checklist/note commands share a batch revision chain, update truthful saved timestamps, and use durable change-ID receipts. Project annotations have an independent persisted revision with compare-and-set semantics; snapshot composition exports that revision rather than the snapshot counter. Field-note timestamps are included in the saved text.

Receipt failure preserves exact partial applied/resolved totals and recovery guidance. Applied/resolved acknowledgement IDs are never silently suffix-truncated; the importer fails closed before mutation at the 10,000 outstanding-ID bound. Sent-base history is bounded without blind eviction and rejects capacity overflow. Forward snapshot publication rejects an older preview after a newer persisted revision exists. iPhone return export cancellation/background lifecycle clears its task/key state while preserving the queued changes.

## UI / localization / accessibility

- Mac renders duplicate, rejected, superseded, conflict, applying, partial-receipt, and result states with stable identifiers; apply errors are handled explicitly.
- Rejection messages are typed by reason and localized in Mac EN/HU resources. New partial/result and duplicate-collision strings are covered.
- Existing code, conflict, result, confirmation, and safety identifiers/labels remain in place; iPhone return export retains overwrite protection and queue-preserving failure behavior.

## Verification evidence

- Focused `MobileChangeImporterTests|MobileSyncStoreTests` — passed, 27 tests in 2 suites.
- Focused `MobileSnapshotComposerTests|MetadataStoreTests` — passed, 41 tests in 2 suites.
- Full `swift test` — passed on the final rerun, 3,467 tests in 219 suites. One earlier parallel run had a pre-existing descriptor-test race; the final rerun passed.
- `git diff --check` — clean before commit.
- `swift scripts/extract-localizable-strings.swift --missing` — existing explicit allowlist only.
- `xcodebuild -project AstroTool.xcodeproj -scheme AstroTool -destination platform=macOS -derivedDataPath /tmp/astro-v5-round3 build` — BUILD SUCCEEDED.

## External gate / concern

The official iOS simulator/device runtime gate remains external and unclaimed. The checked-in `AstroTool` macOS scheme and SwiftPM suites are the verified evidence.
