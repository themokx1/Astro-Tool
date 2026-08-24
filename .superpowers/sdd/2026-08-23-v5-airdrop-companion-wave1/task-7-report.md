# Task 7 — Encrypted return leg review-round-2 closure

## Outcome

The authenticated return path now previews the complete typed result before a separate final confirmation, then enters an explicit applying phase that cannot be cancelled or dismissed mid-apply. Only the three allowlisted checklist, note, and field-note commands run, and production commands write the briefing revision store and metadata project-annotation store used by the forward snapshot composer.

Snapshot revisions are persisted monotonic values (including identical and acknowledgement-only compositions). Sent forward bases are durable, bounded history rather than a single last ID, and the phone exporter rejects an existing destination before writing. Return duplicate IDs reach typed preview; forward envelopes remain strict. Effective chronology selects the latest record before validating it, so a malformed latest edit cannot fall back to an older edit. Receipt IDs and cumulative ledger data are bounded.

## Security and durability

- The opaque authenticated package capability remains the only production authority for return envelope, package ID, and fingerprint; raw envelope preview/apply seams were removed.
- Production domain writes use `NightBriefingRevisionStore` and `MetadataStore.projectAnnotation`, with expected-revision checks and atomic revision-file/database writes. The fixture sidecar retains rollback-safe write-before-memory behavior but is not selected by production construction.
- Ledger writes remain durable before in-memory replacement. Partial receipt errors carry exact applied/resolved IDs and resulting revisions, including receipt-store failure after a command.
- Mac and iPhone destination writers reject existing files. Phone queue pruning remains exact acknowledged-ID pruning after the durable forward snapshot commit.

## UI / localization

- Mac shows applicable, conflict, already-applied, superseded, duplicate, and rejected counts with reasons, human target names, both values/timestamps, resolution pickers, an applying progress phase, and honest receipt totals.
- Mac apply errors are handled explicitly; the store retains the failure state and does not acknowledge the phone package on failure.
- New round-2 Mac strings have EN/HU entries. The localization audit reports only the repository's existing seven explicit brand/domain allowlist keys.
- iPhone return export continues to preserve queued changes through cancellation/failure and rejects overwrite through `FileDocument.WriteConfiguration.existingFile`.

## Verification evidence

- `swift test --filter 'MobileChangeImporterTests|MobileSyncStoreTests|MobilePackageServiceTests'` — passed, 66 tests in 2 suites.
- `swift test` — passed, 3,466 tests in 219 suites.
- `git diff --check` — clean.
- `swift scripts/extract-localizable-strings.swift --missing` — only the existing allowlist remains: AstroTool, Bias, Dark, FWHM, Flat, Light, OK.
- `xcodebuild -project AstroTool.xcodeproj -scheme AstroTool -destination platform=macOS -derivedDataPath /tmp/astro-v5-round2 build` — BUILD SUCCEEDED.

## External gate / concern

The official iOS simulator/device runtime gate remains external and unclaimed; this environment does not provide a usable iOS destination. Mac SwiftPM and the checked-in `AstroTool` macOS scheme are the verified checks.
