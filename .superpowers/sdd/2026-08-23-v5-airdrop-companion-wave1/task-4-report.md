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
