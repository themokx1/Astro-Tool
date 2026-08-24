# Task 7 — encrypted return leg review-round-4 replacement

## Outcome

The Mac return path now accepts only `MobileAuthenticatedReturnPackage`, an opaque capability minted by `MobilePackageService` after package authentication and return-shape validation. Raw envelope preview/apply and the caller-supplied command factory are internal test seams; the public mutating importer is constructed only with the production domain store. The importer has one narrow typed batch operation and no generic execute or begin/end hooks.

Each briefing batch writes checklist/note changes, a single monotonic revision, `savedAt = max(existing, phone changes)`, and its change-ID markers in the same immutable revision. The production bridge uses a process-wide revision compare-and-set: a stale phone batch cannot overwrite an intervening Mac revision, and a same-ID concurrent/relaunch retry returns the already-written result without duplicating a field note. Project annotation text, monotonic revision, and mobile markers are updated in one `BEGIN IMMEDIATE` SQLite transaction; schema version 10 adds the persisted marker column.

The separate receipt ledger is now an acknowledgement summary only. Its applied/resolved sets are normalized disjoint, bounded at 10,000 combined IDs, library-bound, and encoded-size preflighted before mutation. Ledger write failure returns an honest partial receipt; replay safety remains with the atomic domain markers. Duplicate IDs are rejected before target supersession. Batches keep global phone chronology by first atomic owner while retaining the required one-revision-per-briefing grouping.

Forward snapshots persist the exact acknowledgement IDs sent with each published base. Only an authenticated return based on that exact base prunes those summary acknowledgements. Revision allocation, package publication, and sent-base association are serialized by a process-wide publication reservation, enforcing the `<= 1_000_000_000` revision bound and preventing an old window from publishing after a newer allocation. A capability-commit failure after a successful domain batch explicitly reports that the reviewed changes were saved and preserves the receipt for recovery.

## UI / localization / accessibility

- The retained capability is applied only after final confirmation; successful apply clears the retained capability and stale result state.
- Partial receipt and post-command capability-commit failure both retain exact totals/receipt and provide recovery guidance instead of claiming no change happened.
- EN/HU entries cover the applying, failed-return, partial, conflict, duplicate, and result strings. Return controls retain their `v5.mobile-sync.return.*` identifiers and existing accessibility labels/hints.

## Verification evidence

- Focused `MobileChangeImporterTests` — 17 tests in 1 suite passed, including production atomic batching, CAS, concurrent same-ID retry, collision classification, and cross-owner chronology.
- Focused `NightBriefingRevisionStoreTests` — 5 tests in 1 suite passed, including stale CAS rejection.
- Focused `MobileSyncStoreTests` — 22 tests in 1 suite passed, including sent-base acknowledgement evidence, cross-window publication reservation, and post-command commit-failure recovery.
- Full `swift test` — passed: 3,480 tests in 219 suites.
- `xcodegen generate` — regenerated the checked-in project without project-file changes.
- `xcodebuild build -quiet -project AstroTool.xcodeproj -scheme AstroTool -destination platform=macOS -derivedDataPath /tmp/astro-v5-task7-round4-deriveddata` — exited 0 (Xcode destination/build-number warnings plus an unrelated existing `PlanningStore` `nonisolated(unsafe)` warning).
- `swift scripts/extract-localizable-strings.swift --missing` — reports only the documented intentional brand/domain terms: `AstroTool`, `Bias`, `Dark`, `FWHM`, `Flat`, `Light`, and `OK` (7 of 1,079 keys); no return-leg string is missing.
- `git diff --check` — clean.

## External gate / concern

The official iOS simulator/device runtime gate remains external and unclaimed. The local SwiftPM suites and real macOS `AstroTool` scheme build are the verification performed here.
