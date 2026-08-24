# Task 7 — encrypted return leg review-round-5 closure

## Outcome

The normal Mac return route now goes through `MobileReturnApplicationCoordinator`. Its public review value contains only a private session identity; the coordinator retains the authenticated package capability, reloads published sent-base evidence, and borrows the live service capability immediately before applying. Discarded or copied review values fail closed. Legacy package/import seams remain solely for hermetic UI fixtures without a production root.

Normal briefing and project editors now compare the revision they loaded in their durable store transaction. A stale Mac editor reports a conflict and reloads instead of replacing a phone revision or its mobile evidence.

Return receipts and sent-base records use a process lock plus an advisory sidecar file lock, reload inside each mutation, bound encoded input before decoding, and bound output before persistence. Forward evidence progresses from recoverable `pending` to authorizing `published`; only a published base can be returned against, and authenticated completion consumes that base and prunes its linked receipt acknowledgements.

Domain markers now bind change ID, owner, normalized payload fingerprint, and result revision in the same briefing revision or SQLite annotation transaction as the actual mutation. The production bridge scans all mobile-editable owners before a batch and fails closed on cross-owner/payload disagreement or legacy bare marker authority. Project marker JSON decode failure is a corrupt record, never an empty marker set. Return preview excludes duplicate collisions before chronology; owner batch chronology is ordered by each owner's effective last phone edit while retaining one atomic revision per briefing.

The iPhone return exporter tracks a generation and cancellable task, checks cancellation after the async export before publishing the key, presents disabled/progress/cancel states, clears on background/disappearance, and removes its placeholder only after checking retained filesystem identity. The mobile localization extractor now audits both target source trees against their own EN/HU tables. Return controls/results use the required `v5.mobile-sync.return.*` IDs and VoiceOver labels, hints, and values.

## Verification evidence

- Full `swift test` completed successfully.
- Focused Task 7 regressions: 83 tests in 6 suites passed, covering the public coordinator/copy-discard refusal, ordinary Mac CAS saves, receipt pruning, pending publication, chronology/collision handling, and localization coverage.
- `swift scripts/extract-localizable-strings.swift --missing` reports only the five existing astronomy-term allowlist entries (`Bias`, `Dark`, `FWHM`, `Flat`, `Light`); `--missing-en` reports 0 missing target entries.
- `xcodegen generate` completed and regenerated the Xcode project.
- Real macOS `AstroTool` build completed: `xcodebuild build -quiet -project AstroTool.xcodeproj -scheme AstroTool -destination platform=macOS -derivedDataPath /tmp/astro-v5-task7-round5-macos CODE_SIGNING_ALLOWED=NO` (existing compiler warnings only).
- `git diff --check` is clean.

## External gates / concern

The official iOS runtime gate is not claimed. The attempted static iOS build cannot start on this host because Xcode does not have the iOS 26.5 platform installed (`Any iOS Device` is ineligible); this is recorded separately from the successful SwiftPM and macOS checks.
