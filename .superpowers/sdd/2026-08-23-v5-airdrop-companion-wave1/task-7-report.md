# Task 7.1 — return-path stabilization handoff

## Status

Stopped and committed at the user's request before the mandatory full verification sequence. This is an in-progress stabilization handoff, not a Task 7.1 completion claim and not an official iOS runtime claim.

The current patch closes the principal reviewed return-path failures: production Mac return/export is routed through one root-bound public coordinator; importer, sent-base, raw batch, and fixture injection surfaces are package/internal; a published base is atomically claimed before mutation and is single-use; forward acknowledgement reloads the root ledger; domain markers bind immutable phone intent and are checked under a root-global lock; duplicate/corrupt markers and malformed ledgers fail closed; receipts and sent-base files are bounded; partial receipts exclude speculative resolution; successful UI state is terminal with six disjoint totals; and the iPhone persists a recoverable one-time return key until explicit discard.

The patch also removes unconditional normal briefing/project overwrites in favor of creation/CAS paths, preserves canonical database values under concurrent project saves, and adds real encrypted coordinator/domain/receipt/next-forward acknowledgement coverage.

## Verification actually completed

- Focused coordinator/UI/public-surface run built successfully and ran 37 tests. It initially had one invalid checklist test fixture; the other 36 tests passed, including copied/discarded review refusal, single-claim sent bases, the encrypted real-domain round trip, the competing-package race, terminal state, and the public-surface contract.
- The corrected checklist default-resolution regression was rerun alone and passed.
- The exact 1 MiB receipt-ledger boundary/load-bound regression built and passed: exactly 1,048,576 encoded bytes persist/load; one byte beyond is rejected without replacing the prior file; an oversized on-disk input fails closed.
- Earlier focused runs in this stabilization session passed the domain-marker collision/retry/corruption regressions, malformed-ledger-key regression, strict briefing revision/CAS regressions, project canonical-save regression, coordinator copied/discarded review regression, encrypted real-domain end-to-end regression, partial-receipt regression, and field-note receipt-failure retry regression.
- `git diff --check` completed cleanly immediately before this handoff report update.

## Outstanding before Task 7.1 can be claimed complete

- Re-run the combined focused suites after the corrected fixture; only the corrected test was rerun after that failure.
- Close the remaining normal-writer evidence-injection edge: public briefing/project creation or revision inputs can still carry caller-supplied mobile marker fields. Normal writers should reject mobile evidence on creation and preserve existing durable evidence on CAS updates; the package-only domain bridge needs its own marker-writing path.
- Run all required deterministic verification: full `swift test --no-parallel`, localization/mobile EN/HU parity and dynamic-string audit, repeated parallel `ProjectsStoreTests` proof, `xcodegen generate`, real `AstroTool` macOS build, generated-project diff inspection, and a final `git diff --check`.
- Compile/run the checked-in `AstroToolMobileTests` through the Xcode graph when the platform is available. The official iOS 26.5 runtime gate remains external and unclaimed.
