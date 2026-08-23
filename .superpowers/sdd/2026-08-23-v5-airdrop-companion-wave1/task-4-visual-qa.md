# Task 4 visual QA — Mac MobileSync sheet

Status: **ISSUES** — one P2 narrow-width defect found. No product code was changed.

## Scope and method

- Read `task-4-brief.md`, the existing Task 4 report, `MobileSyncView`, `MobileSyncStore`, `NightBriefingView`, the surface tests, and the existing macOS fixture/XCUITest launch conventions.
- Built the app successfully with:

  ```text
  CLANG_MODULE_CACHE_PATH=/tmp/astrotool-clang-module-cache swift build --product AstroToolApp
  ```

- Used a temporary SwiftUI/AppKit render harness with a deterministic typed snapshot and deterministic incoming-package preview fixture. The harness was removed after capture; it was never committed.
- Fresh focused verification:

  ```text
  swift test --filter MobileSyncStoreTests --filter MobileSyncSurfaceTests
  Test run with 19 tests in 2 suites passed.

  swift test --filter LocalizationCoverageTests
  Test run with 15 tests in 1 suite passed.
  ```

- The repository XCUITest command built the app/test runner but could not start UI automation in this environment:

  ```text
  xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool \
    -destination 'platform=macOS' \
    -only-testing:AstroToolUITests/MobileSyncVisualQATests
  Failed to initialize for UI testing: timed out while enabling automation mode.
  ```

  Therefore no live AX tree or system-sized sheet screenshot was available. Static render artifacts below are real SwiftUI view renders at the stated dimensions.

## Rendered artifacts

Artifacts are retained outside the repository under `/tmp/astrotool-v5-visual-qa/`:

- `/tmp/astrotool-v5-visual-qa/mobile-sync-idle.png` — 720×620, English, idle.
- `/tmp/astrotool-v5-visual-qa/mobile-sync-review.png` — 720×620, English, review.
- `/tmp/astrotool-v5-visual-qa/mobile-sync-review-narrow.png` — 420×620, English, review.
- `/tmp/astrotool-v5-visual-qa/mobile-sync-review-accessibility5.png` — 720×620 with `.dynamicTypeSize(.accessibility5)`.
- `/tmp/astrotool-v5-visual-qa/mobile-sync-incoming-package-narrow.png` — 420×620, deterministic incoming preview with a long package UUID.

## Observations

- **Idle / normal:** the Mac → sealed package → iPhone rail is visually clear; “Original photos” stays anchored to the Mac side. Primary and secondary actions are legible and separated.
- **Review / normal:** the summary grid reads cleanly at 720 pt width. The sheet is intentionally scrollable vertically; the lower confirmation/safety controls fall below the captured viewport rather than being horizontally clipped.
- **Narrow / 420 pt:** title/body copy and rail labels wrap without collision. The rail remains understandable, although the middle and phone details become tall multi-line labels as expected.
- **Accessibility size:** the large-text render keeps the rail and summary columns legible without horizontal clipping in the captured top portion. The lower content requires scrolling at this height. This is a static environment render, not a live macOS accessibility-preference run.
- **Contrast / typography:** the dark ground, raised surfaces, muted explanatory text, cyan active rail, and white primary copy remain distinguishable. Counts use compact monospaced styling while explanatory copy remains readable.
- **Localization:** English/Hungarian MobileSync keys, including the exact safety promise and QR explanation, are present; localization coverage passes. Runtime HU screenshot was not possible because the UI automation runner could not start.
- **Accessibility contract:** source inspection confirms pinned identifiers for open/safety/export/import/confirm/cancel/QR/error-retry and a descriptive QR accessibility label. Runtime VoiceOver order could not be inspected because UI automation timed out.
- **Night Briefing:** surface/source checks confirm the existing PDF, PDF+PNG, and PNG actions remain adjacent to a separate “Send to iPhone” action. A rendered four-button screenshot could not be captured because the live XCUITest runner was unavailable.
- **QR:** the source uses nearest-neighbor interpolation, no antialiasing, a high-contrast QR background, and a 48 pt outer quiet-zone padding. The injected export render did not reach the exported phase in the static harness, so QR module alignment was not visually signed off.

## Issue

### P2 — Long incoming package UUID wraps awkwardly at minimum/narrow width

In `/tmp/astrotool-v5-visual-qa/mobile-sync-incoming-package-narrow.png`, the `Package` row at 420 pt places the UUID beside the label and wraps only the final `C` onto a separate line below the label. The value remains technically present but is visually crowded and easy to misread. The incoming package preview should give the value its own flexible/wrapping column or stack the label and UUID at narrow widths.

No other visual defect was found in the rendered states. This QA task leaves product code untouched; the report is the only repository change.
