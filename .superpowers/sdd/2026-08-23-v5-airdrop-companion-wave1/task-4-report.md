# Task 4 Report: Mac export/import experience

## RED/GREEN evidence

### RED

- Added `MobileSyncStoreTests` and `MobileSyncSurfaceTests` before the store and view existed.
- The first focused invocation was blocked before compilation because SwiftPM's default compiler module cache was outside the writable sandbox. Re-running with `CLANG_MODULE_CACHE_PATH=/tmp/astrotool-clang-module-cache` reached the intended compile/test cycle and exposed the missing store API and, later, the stale-cancellation test timing seam.
- The cancellation test initially reproduced the important race: a preview result could win if cancellation happened before the async operation had started. The test now yields once to establish the in-flight boundary, and the generation token prevents stale results from replacing the cancelled phase.

### GREEN

Final focused results:

```text
swift test --filter MobileSyncStoreTests
Test run with 7 tests in 1 suite passed.

swift test --filter MobileSyncSurfaceTests
Test run with 3 tests in 1 suite passed.

swift test --filter MobileSync
Test run with 10 tests in 2 suites passed.
```

Final full verification:

```text
swift test --no-parallel
Test run with 3437 tests in 218 suites passed after 96.489 seconds.
```

`git diff --check` and localization extraction are clean. The localization extractor reports only the existing seven allowlisted domain terms (`AstroTool`, `FWHM`, `OK`, `Light`, `Flat`, `Dark`, `Bias`).

## Implementation

- Added `@MainActor @Observable MobileSyncStore` with injected identity, snapshot, package export/import, and destination-preparation seams.
- The store owns only presentation state, confirmation gates, stale-operation generation, and the one-time QR value for the active export. Preview/cancel remains read-only; identity creation is called only after explicit confirmation.
- Implemented the state flow `idle → previewing → ready → exporting → exported`, plus cancellation, fail-closed errors, and `importing → importPreviewReady`. Incoming previews authenticate and expose counts/change count without applying anything.
- Added the allowlisted metadata snapshot provider using Task 2's `MobileSnapshotComposer`, the existing metadata actor, query-derived usable-frame integration totals, and optional briefing revisions. No paths, filenames, image bytes, FITS material, or database objects enter the package.
- Added native SwiftUI Mac presentation with the continuous Mac → sealed package → iPhone rail, understand/review/send sections, exact counts, snapshot time, encrypted size when known, no-overwrite wording, AirDrop guidance, and Core Image QR rendering with a quiet zone and nearest-neighbor scaling.
- Added `fileExporter`/`fileImporter` with `.astroMobile`. The exporter placeholder has a unique app-owned marker and is removed only when that exact marker is present before the package service performs exclusive publication.
- Added entry points in the main V2 toolbar, Settings (“iPhone Sync” / “iPhone szinkron”), and the Night Briefing export row. Existing PDF, PDF+PNG, and PNG actions remain unchanged and separate.
- Added English/Hungarian localization resources and pinned identifiers for open, safety, export, import, identity confirmation, summary confirmation, cancel, QR, and retry/error.

## Accessibility/localization proof

- Uses system fonts and the existing Astro type/token treatments; counts use monospaced digits, while explanatory text remains Dynamic Type-compatible.
- Controls retain keyboard-default action behavior and minimum native button sizing; the QR has a descriptive VoiceOver label without exposing the key text.
- Accessibility identifiers are pinned in the surface tests. Safety and QR copy are localized in both resource tables, including the exact English safety promise and natural Hungarian equivalents.
- The visible-copy surface test rejects forbidden implementation vocabulary (`schema`, `manifest`, `symmetric key`, `payload`, `staging`) while preserving the user-facing language.

## Visual self-critique

The sheet is intentionally quiet: one raised summary/review treatment, one recessed safety rail, and a single high-contrast QR block. The rail keeps “Original photos” anchored on the Mac side across states. The remaining refinement opportunity is visual QA at very large Dynamic Type sizes and in a narrow sheet; the layout uses adaptive grids and flexible text, but a rendered screenshot pass would be the next useful check.

## Concerns

- AirDrop remains user-initiated as required; the app creates the package and explains how to share it, but does not claim an automatic transfer.
- Task 7 change application is deliberately absent. Incoming previews stop before any library mutation.
- The default Settings/toolbar path uses the live metadata actor when one is open; a newly opened library still follows the existing app scan/preparation lifecycle before its typed records are available.

## Review follow-up (round 1)

- SwiftUI export writes now reject `WriteConfiguration.existingFile` before a Replace request can write a placeholder. The persistent destination token lives on `MobileSyncStore`, and the coordinator only removes its exact marker; Task 3 remains the exclusive publisher. A regression confirms an existing package sentinel is unchanged.
- Import is wired from file selection through a retained task, security-scoped access lifetime, one-time-code entry, authenticated preview, package ID/size/count/change display, and no apply action.
- Preview/import/export tasks use store-owned task handles. Preview/import cancellation invalidates stale results; export cancellation records a late published manifest and QR rather than losing the unlock code. Reset and dismiss invalidate late work and clear transient QR state.
- Confirmations now carry and compare a nonoptional snapshot token containing snapshot ID, revision, timestamp, summary (including checklist count), and library ID. The preview also fails closed if provider identity and snapshot identity diverge.
- Task 3 export returns its actual published `MobilePackageManifest`; the store maps its package ID, creation time, and encrypted byte count without inventing metadata. A transport regression checks the returned fields against the written manifest.
- Live metadata revisions are deterministic and nonzero for populated metadata, and the same provider is threaded through root, Settings, and Night Briefing entry points. Freshness and checklist counts are visible in the review.
- QR failure no longer shows a decorative symbol: it presents an error and retry, with a four-module quiet zone at the chosen scale. English/Hungarian tables cover every new key; Hungarian sync copy uses plain terms such as `képsorozat`, `megfigyelési terv`, and `ellenőrzőlista`.

Follow-up verification:

```text
swift test --filter MobileSyncStoreTests              # 10 tests passed
swift test --filter MobileSyncSurfaceTests            # 4 tests passed
swift test --filter exportReturnsPublishedManifestMetadata # passed
swift test --filter LocalizationCoverageTests         # 15 tests passed
git diff --check                                      # clean
```

Final full-suite verification after the follow-up changes:

```text
swift test --no-parallel
Test run with 3442 tests in 218 suites passed after 95.863 seconds.
```

## Review follow-up (round 2), Phase 1 root-cause evidence

The failing publication path was reproduced before implementation changes:

```text
swift test --filter exporterPlaceholderReproducesDestinationFailure
✘ An exporter-created empty final path currently blocks the exclusive package publication
  error = The destination already exists.
```

This is the exact boundary failure: a zero-byte file at the final package URL is treated as an occupied destination, so Task 3's `renameatx_np(..., RENAME_EXCL)` correctly refuses publication. The existing fresh destination round-trip passes when no placeholder is present.

The required Foundation probe was added as `replacementDirectoryProbeDoesNotGuess`. On this macOS 26.5 test runtime, `FileManager.url(for: .itemReplacementDirectory, appropriateFor: <absent final URL>, create: true)` returned a private replacement directory while `finalExists=false`; it did not itself materialize the final path. The separately reproduced failing condition is the SwiftUI exporter-created empty final path. This distinguishes the Foundation staging-directory lookup from the exporter placeholder write and avoids claiming an unobserved API behavior.

Data-flow evidence: `MobilePackageService.export` → `SystemStagingDirectoryProvider.replacementDirectory` → private staging write → `publishExclusively` → `renameatx_np(RENAME_EXCL)`. The failure occurs only after the final URL has already been materialized, and the destination bytes are never replaced. No implementation change was made before this evidence and the red regression were recorded.

## Review follow-up (round 2), Phase 2 RED/GREEN

The root-cause fix anchors system staging to the already-existing destination parent, validates that parent without creating the final name, and retains the existing private `mkdtemp`/`openat`/0700 staging and same-volume exclusive rename path. The transport regressions prove a fresh destination remains absent until publication, a round trip succeeds, the injected volume-local provider remains supported, and a zero-byte exporter placeholder is reported as occupied without changing its bytes.

Lifecycle follow-up adds an explicit `.finishing` phase. Cancelling an in-flight export no longer presents idle while encryption/publication continues; Cancel, dismiss, and reset are disabled during that phase, and a late success keeps the actual manifest metadata and one-time QR. Import cancellation invalidates stale results and discards any late authenticated staging. Incoming failures retain source/code only for an incoming retry; retry re-enters incoming preview, and cancel/done/dismiss clear the source and code. Exporter failures now surface a localized choose-new-name recovery message, while user cancellation remains silent.

The metadata revision is a deterministic FNV digest over the complete typed metadata inputs used by the snapshot (including mutable record fields, frame decisions, integration totals, annotations, and briefings), constrained to a nonzero value. The review shows both an absolute timestamp and a localized relative freshness phrase. Store fallback/error strings are explicitly present in both localization tables; the coverage extractor reports zero missing keys.

Focused verification after Phase 2:

```text
swift test --filter MobileSyncStoreTests          # 13 tests passed
swift test --filter MobileSyncSurfaceTests        # 4 tests passed
swift test --filter MobilePackageServiceTests     # 37 tests passed
swift test --filter LocalizationCoverageTests     # 15 tests passed
git diff --check                                  # clean
```

Final full verification after Phase 2:

```text
swift test --no-parallel
Test run with 3448 tests in 218 suites passed after 100.311 seconds.
```

## Review follow-up (round 3), Phase 1 root-cause evidence

The previously flaky cancellation test was run 20 consecutive times with:

```text
for i in {1..20}; do swift test --filter cancellationWinsOverStaleAsyncResult; done
20/20 passed; no hang reproduced in this run.
```

Code tracing still exposed two deterministic lifecycle defects before any fix:

- `MobileSyncStore.cancel()` returns from the `.exporting` branch before calling `operationTask.cancel()`. It only flips `cancellationRequested`, while `MobilePackageService.export` had no cancellation checkpoint and its exclusive rename could proceed after a user cancellation. Thus the flag was presentation-only and could not stop pre-publication work.
- Incoming preview cleanup is launched with an untracked `Task` from `discardIncomingPreview()`. The store can enter idle or begin a new preview before the actor discard finishes, so a same-package immediate re-preview can observe stale staged state. The late-import guard also needed to await discard after an authenticated result arrived for a cancelled operation.

Additional evidence: the Foundation probe asserted `finalExists == false`, turning a platform observation into a platform-specific contract even though the production parent-anchor test is the normative security test. The exporter adapter returned a `Date` created by Task 3 before JSON encoding, while the persisted manifest is decoded at JSON date precision; the equality happened to pass for current dates but was not a canonical API guarantee. The view retained `importSource` and plaintext `importCode` independently from the store, so Done/cancel/dismiss could clear store state while leaving those controls populated.

## Review follow-up (round 3), Phase 2 RED/GREEN

The cancellation regression was first made red with a publication pause: cancelling the store task previously allowed the package export closure to finish, leaving the phase exported, a QR payload, and a destination. The incoming discard regression was likewise made red by holding the discard callback: a second preview could begin before the first staged package had been discarded. The Foundation replacement-directory check was changed to an observational, platform-tolerant probe that only logs the observed final-path state and cleans its own temporary fixture; the existing-parent-anchor test remains the normative publication guarantee.

The green implementation now propagates `Task` cancellation through the store's `operationTask`, checks at Task 3 preparation and immediately before exclusive publication, and lets the private staging `defer` remove cancelled work. Cancellation before publication returns to idle without a destination, QR, or key; cancellation after the atomic rename remains in the finishing/exported path and preserves the published manifest and QR. The view disables interactive dismissal while exporting/finishing and uses explicit localized progress titles, including the finishing safety rail.

Incoming preview cleanup is tracked by `discardTask` and serialized before idle or re-preview. The store owns the discard lifecycle, while the view has one reset helper that clears the security-scoped source and plaintext code on done, cancel, dismiss, and successful preview; the fallback code entry is a `SecureField`. Export results now return the manifest after the same JSON round trip that is written to disk, so `createdAt` and byte metadata are canonical.

Focused and repeated verification after Phase 2:

```text
swift test --filter cancellationBeforePublicationStopsExport                 # passed
swift test --filter cancellationBeforeExclusivePublicationLeavesNoDestination # passed
swift test --filter incomingDiscardIsSerializedBeforeRepreview                # passed
swift test --filter MobileSyncStoreTests                                      # 15 tests passed
swift test --filter MobileSyncSurfaceTests                                    # 4 tests passed
swift test --filter MobilePackageServiceTests                                 # 38 tests passed
swift test --filter LocalizationCoverageTests                                 # 15 tests passed
for i in {1..20}; do swift test --filter cancellationBeforePublicationStopsExport; done # 20/20 passed
for i in {1..20}; do swift test --filter incomingDiscardIsSerializedBeforeRepreview; done # 20/20 passed
git diff --check                                                              # clean
```

Final full-suite verification after round 3:

```text
swift test --no-parallel
Test run with 3451 tests in 218 suites passed after 94.572 seconds.
```
