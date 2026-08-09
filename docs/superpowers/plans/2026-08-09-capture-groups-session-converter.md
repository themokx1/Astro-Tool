# Capture Groups and Single-Session Converter Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add first-class capture groups beneath a target/date session, per-file and bulk classification, cohort-correct quality/reporting, and a transparent one-session-at-a-time logical/physical converter with rollback; publish and install v0.15.0.

**Architecture:** Keep the existing target/date session as the aggregate boundary and add capture groups through additive SQLite tables plus a path/assignment resolver. Canonical new folders use `sessions/<target>/<date>/captures/<slug>/{lights,flats,darks,biases}` with mirrored stack/processed paths, while legacy layouts remain readable. Conversion is split into a pure planner and a strictly scoped executor routed through `WriteGuard`; the SwiftUI wizard renders the exact plan before any apply.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI/macOS, SQLite, XCTest, existing AstroCore/AstroToolApp/astrotool targets, GitHub Actions release workflow.

---

## Task 1: Capture domain types and path recognition

**Files:**
- Create: `Sources/AstroCore/Capture/CaptureModels.swift`
- Modify: `Sources/AstroCore/Scan/PathClassifier.swift`
- Modify: `Tests/AstroCoreTests/PathClassifierTests.swift`
- Create: `Tests/AstroCoreTests/CaptureModelsTests.swift`

1. Add failing tests for `SensorMode`, `SignalMode`, `CaptureGroupRecord`, `ResolvedCaptureMetadata`, and stable user-facing labels.
2. Add failing path tests for canonical `captures/<slug>/<role>/...`, legacy `lights_<label>`/`flats_<label>`, classic direct role folders, stack/processed capture subfolders, and malformed paths.
3. Run the focused tests and confirm failure.
4. Implement the additive types and extend `PathInfo` with optional `captureSlug` and `legacyCaptureLabel` defaults.
5. Extend `PathClassifier` without changing classification of classic paths.
6. Run focused tests, then existing path/type tests.
7. Commit: `feat: model capture groups and paths`.

## Task 2: SQLite v11 schema and capture DAOs

**Files:**
- Modify: `Sources/AstroCore/DB/Database.swift`
- Modify: `Tests/AstroCoreTests/DatabaseTests.swift`
- Create: `Tests/AstroCoreTests/CaptureDatabaseTests.swift`

1. Add migration tests proving v10 data survives and v11 creates `capture_groups`, `capture_sources`, and `file_capture_assignments` with foreign keys/indexes.
2. Add failing CRUD tests for group create/update/list/delete constraints, source-prefix uniqueness, file assignment/upsert/clear, and bulk lookup.
3. Add tests that group deletion is blocked or safely cascades only tool-owned metadata according to the chosen DAO contract, never files.
4. Run focused tests and confirm failure.
5. Add schema v11 migration and Codable/Sendable record mappings.
6. Implement locked DAO methods and deterministic ordering.
7. Run focused tests and `DatabaseTests`.
8. Commit: `feat: persist capture groups and assignments`.

## Task 3: Capture metadata resolver and legacy compatibility

**Files:**
- Create: `Sources/AstroCore/Capture/CaptureResolver.swift`
- Create: `Tests/AstroCoreTests/CaptureResolverTests.swift`
- Modify: `Sources/AstroCore/FITS/FITSReader.swift` only if a normalized Bayer/header accessor is required

1. Add failing tests for precedence: file override → group → FITS → path inference → unknown.
2. Cover OSC inference from `BAYERPAT`, mono fallback, blank `FILTER`, conflicting manual/header filter, canonical source mapping, legacy source mapping, and implicit default group.
3. Add bulk-resolution performance-oriented tests that prove one preloaded lookup can resolve many files without per-row DAO queries.
4. Run focused tests and confirm failure.
5. Implement `CaptureResolver`, source provenance, confidence, and conflict markers.
6. Ensure resolver reads only and never mutates headers or folders.
7. Run focused tests.
8. Commit: `feat: resolve capture metadata with provenance`.

## Task 4: Correct raw-light recognition for ASIAIR Stacked files

**Files:**
- Modify: `Sources/AstroCore/Stats/FrameSet.swift`
- Modify: `Tests/AstroCoreTests/FrameSetTests.swift`

1. Add failing tests proving `Stacked2_...fit` and `Stacked12_...fit` under `lights/` are derivatives/artifacts, while normal `Light_...fit` remains usable.
2. Confirm the focused test fails against the current implementation.
3. Reuse or align with `StackDiscovery`'s ASIAIR stacked-prefix recognition without creating divergent heuristics.
4. Run focused tests plus stack discovery tests.
5. Commit: `fix: exclude ASIAIR stack outputs from raw lights`.

## Task 5: Capture-group summaries and aggregate session stats

**Files:**
- Create: `Sources/AstroCore/Capture/CaptureQueries.swift`
- Create: `Tests/AstroCoreTests/CaptureQueriesTests.swift`
- Modify: `Sources/AstroCore/Stats/SessionStats.swift`
- Modify: `Tests/AstroCoreTests/SessionStatsTests.swift`

1. Add failing fixture tests for two explicit groups plus an implicit/unassigned bucket.
2. Verify per-group frame count, exposure breakdown, integration, cameras, filters, artifacts, and calibration counts.
3. Verify the session total equals the sum of usable group totals and excludes `Stacked*` derivatives.
4. Verify classic sessions with no explicit groups keep their previous numbers.
5. Implement `CaptureGroupSummary` queries using bulk-resolved metadata.
6. Add additive capture summary access without breaking existing Codable payloads.
7. Run focused tests and existing stats/filter tests.
8. Commit: `feat: summarize sessions by capture group`.

## Task 6: Additive capture-tree creation

**Files:**
- Modify: `Sources/AstroCore/WriteGuard.swift`
- Create: `Sources/AstroCore/Capture/CaptureManager.swift`
- Modify: `Sources/AstroCore/NewSession/SessionCreator.swift`
- Modify: `Tests/AstroCoreTests/WriteGuardTests.swift`
- Modify: `Tests/AstroCoreTests/SessionCreatorTests.swift`
- Create: `Tests/AstroCoreTests/CaptureManagerTests.swift`

1. Add failing tests for creating one capture under an existing exact target/date session.
2. Assert the method creates only the canonical session/stack/processed capture directories, validates every component, and never overwrites files.
3. Test optional initial capture creation during a new session while preserving the old no-capture API.
4. Run tests and confirm failure.
5. Add narrowly scoped `WriteGuard.createCaptureTree` and `CaptureManager` orchestration with DB persistence.
6. Update README generation only for newly created capture-aware sessions; never rewrite an existing README.
7. Run focused tests.
8. Commit: `feat: create capture-aware session trees`.

## Task 7: Pure single-session conversion planner

**Files:**
- Create: `Sources/AstroCore/Capture/SessionConversionPlanner.swift`
- Create: `Tests/AstroCoreTests/SessionConversionPlannerTests.swift`
- Add fixture helpers to: `Tests/AstroCoreTests/Fixtures.swift`

1. Define Codable plan types: scope, mode, detected cluster, proposed group, assignment, directory creation, move, unchanged item, ambiguity, conflict, summary, and source fingerprint.
2. Add failing tests for exact one-target/one-date scoping and rejection of out-of-scope paths.
3. Add the IC 1396-shaped fixture: `lights_osc` 30 s, classic lights 120/300 s, two `Stacked*`, filterless flats, stack/processed hints.
4. Verify the suggested preview separates OSC 30 s, keeps 120/300 s together as an editable unknown-filter group, identifies both `Stacked*` artifacts, and leaves ambiguous flats unresolved.
5. Test classic, already canonical, mixed-exposure-in-one-folder, destination-conflict, filename-hint, and zero-file sessions.
6. Run tests and confirm failure.
7. Implement the pure planner with no filesystem writes.
8. Add human-language summary strings and exact from/to plan rows.
9. Run focused tests.
10. Commit: `feat: plan transparent session conversions`.

## Task 8: Conversion apply, receipt, and rollback

**Files:**
- Create: `Sources/AstroCore/Capture/SessionConversionExecutor.swift`
- Modify: `Sources/AstroCore/WriteGuard.swift`
- Create: `Tests/AstroCoreTests/SessionConversionExecutorTests.swift`
- Modify: `Tests/AstroCoreTests/WriteGuardTests.swift`

1. Add failing tests for logical-only apply: database metadata changes, no library file moves, plan/receipt persistence under `.astro_tool/conversions`.
2. Add failing physical-mode tests for directory creation, exact moves, no overwrite, preflight destination conflict, stale source fingerprint, and target/date containment.
3. Inject a mid-apply failure and assert automatic reverse-order rollback restores every moved file.
4. Test explicit rollback success and rollback blocking when a destination/back-path conflict appears later.
5. Run tests and confirm failure.
6. Extend `WriteGuard` with conversion-specific, exact-scope move operations; keep all library writes centralized.
7. Implement executor preflight, plan serialization, apply, rollback, receipt, and DB transaction boundaries.
8. Ensure no source directory is deleted even when emptied.
9. Run focused tests and write-guard tests.
10. Commit: `feat: apply and roll back session conversions`.

## Task 9: Cohort-correct rating and quality

**Files:**
- Modify: `Sources/AstroCore/Rate/Rater.swift`
- Modify: `Sources/AstroCore/Rate/OutlierBreakdown.swift`
- Modify: `Sources/AstroCore/Stats/SessionQuality.swift`
- Modify: `Tests/AstroCoreTests/RateTests.swift`
- Modify: `Tests/AstroCoreTests/SessionQualityTests.swift`
- Modify: `Tests/AstroCoreTests/OutlierBreakdownTests.swift` if present, otherwise add coverage to `RateTests.swift`

1. Add failing tests with identical date/exposure but two groups/filters/setups and strongly different FWHM distributions.
2. Prove scoring and breakdown medians stay inside the correct cohort.
3. Add per-capture quality summary tests and verify heterogeneous sessions do not claim one misleading FWHM.
4. Run tests and confirm failure.
5. Add a Codable cohort descriptor to `FrameScore` with backward-compatible defaults.
6. Use the same group key in `Rater` and `OutlierBreakdown`.
7. Implement capture-quality summaries while preserving classic single-group behavior.
8. Run focused and full rate/quality tests.
9. Commit: `feat: rate frames within capture cohorts`.

## Task 10: Capture-aware stack lists, calibration, and reports

**Files:**
- Modify: `Sources/AstroCore/Export/StackList.swift`
- Modify: `Sources/AstroCore/Stats/StackDiscovery.swift`
- Modify: `Sources/AstroCore/Calib/SessionMatcher.swift`
- Modify: `Sources/AstroCore/Export/NightReport.swift`
- Modify: `Sources/AstroCore/Export/TargetReport.swift`
- Modify: `Tests/AstroCoreTests/StackListTests.swift`
- Modify: `Tests/AstroCoreTests/StackDiscoveryTests.swift`
- Modify: `Tests/AstroCoreTests/SessionMatcherTests.swift`
- Modify: `Tests/AstroCoreTests/NightReportTests.swift`
- Modify: `Tests/AstroCoreTests/TargetReportTests.swift`

1. Add failing tests for selecting/exporting one capture group and the full session.
2. Add stack/processed assignment and mirrored canonical-path recognition tests.
3. Add calibration tests using resolved filter/group context while allowing compatible shared masters.
4. Add report tests for aggregate total plus separate capture sections and links.
5. Verify mixed-exposure stacks list the full breakdown instead of one false sublength.
6. Run tests and confirm failure.
7. Implement optional capture scoping across stack, calibration, and report APIs.
8. Keep old call signatures through defaulted arguments/overloads.
9. Run focused tests.
10. Commit: `feat: report and prepare stacks by capture group`.

## Task 11: Capture-aware audit rules

**Files:**
- Create: `Sources/AstroCore/Audit/CaptureRules.swift`
- Modify: `Sources/AstroCore/Audit/AuditEngine.swift`
- Create: `Tests/AstroCoreTests/CaptureAuditTests.swift`
- Modify: `Tests/AstroCoreTests/AuditTests.swift`

1. Add failing tests for unassigned lights, legacy role-label folders, missing filter on NB groups, manual/header conflicts, heterogeneous setup, unassigned artifacts, misleading mixed-exposure stack names, and ambiguous flats.
2. Verify findings explain provenance and suggest review/conversion, never automatic move.
3. Verify classic implicit sessions do not receive noisy false positives.
4. Run tests and confirm failure.
5. Implement capture rules and add them to default audit ordering.
6. Run focused audit tests.
7. Commit: `feat: audit capture classification gaps`.

## Task 12: CLI commands and JSON contracts

**Files:**
- Modify: `Sources/astrotool/Commands.swift`
- Modify: `Sources/astrotool/ArgParser.swift`
- Modify: `Sources/astrotool/main.swift`
- Modify: `Tests/AstroCoreTests/CLISmokeTests.swift`

1. Add failing smoke tests for capture list/create/assign and conversion plan/apply/rollback.
2. Assert converter commands require exact target/date or a concrete plan/conversion ID and expose no all-library apply.
3. Assert JSON uses the existing schema envelope and plan output contains exact paths, counts, warnings, and mode.
4. Run tests and confirm failure.
5. Implement CLI routing and human-readable output.
6. Add explicit confirmation/plan requirements for physical apply.
7. Run CLI smoke tests.
8. Commit: `feat: expose capture workflows in cli`.

## Task 13: App state and capture-group creation UI

**Files:**
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/NewSessionSheet.swift`
- Create: `Sources/AstroToolApp/Views/CaptureGroupSheet.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetailPage.swift` only if navigation state needs extension

1. Read and apply the frontend-design skill before editing views.
2. Add AppState load/create/update/delete/assign operations with toast/error handling and targeted refresh.
3. Add optional first-capture controls to New Session with concise presets.
4. Add `Gyűjtés hozzáadása…` sheet for an existing session with sensor mode, signal mode, filter manufacturer/model/name, slug preview, and notes.
5. Replace the flat session detail band with a legible expandable capture hierarchy while preserving current session actions and metrics.
6. Surface aggregate totals and per-group totals without displaying one aggregate FWHM for heterogeneous groups.
7. Build the app target to catch SwiftUI type-checking regressions.
8. Commit: `feat: manage capture groups in the app`.

## Task 14: Per-file and bulk classification UI

**Files:**
- Modify: `Sources/AstroToolApp/Views/TargetDetail/QualitySegment.swift`
- Modify: `Sources/AstroToolApp/Views/FrameReviewSheet.swift`
- Create: `Sources/AstroToolApp/Views/CaptureAssignmentSheet.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`

1. Change frame-table selection to a multi-selection set while retaining one-row preview/review behavior.
2. Add capture/filter/provenance/cohort columns and capture filter controls.
3. Add assignment scopes: current file, selected files, folder, exposure cohort, matching session files.
4. Render a before/after count and changed fields before apply.
5. Add row action and batch action entry points, plus clear-override support.
6. Refresh quality/session/report-derived state after assignment.
7. Build and run relevant core tests.
8. Commit: `feat: classify capture files individually or in bulk`.

## Task 15: Transparent converter wizard UI

**Files:**
- Create: `Sources/AstroToolApp/Views/SessionConversionSheet.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`

1. Add the row-scoped `Session átalakítása gyűjtésekre…` action.
2. Implement a staged wizard: scan → editable groups/mappings → preview → confirmation/result.
3. Render current tree, detected clusters/ambiguities, and target tree in clearly separated panes.
4. Include the plain-language summary, counts, byte sizes, provenance, exact from/to rows, unchanged items, and blocking conflicts.
5. Default to logical-only mode; make physical organization a clearly described opt-in.
6. Disable apply while blocking conflicts/ambiguities remain.
7. Add progress, cancellation-before-apply, receipt, reveal-in-Finder, and eligible rollback actions.
8. Ensure the wizard can never switch scope to another session mid-plan.
9. Build the app and manually inspect the IC 1396 plan in logical mode without applying it to the real library.
10. Commit: `feat: add transparent single-session converter`.

## Task 16: Documentation, review, full verification, and v0.15.0 release

**Files:**
- Create: `docs/releases/v0.15.0.md`
- Modify: `README.md` if capture/session docs live there
- Modify: `docs/features.html`
- Modify: `docs/cli.html`
- Modify: version sources identified by `rg '0\.14\.0|MARKETING_VERSION|CFBundleShortVersionString'`
- Modify release workflow/scripts only if required by the existing release contract

1. Update user documentation with the hierarchy, OSC-vs-filter distinction, classification workflow, converter safety model, rollback, and CLI examples.
2. Write Hungarian v0.15.0 release notes including the IC 1396-discovered `Stacked*` counting fix.
3. Run `git diff --check` and review every changed file for unrelated edits.
4. Use `superpowers:requesting-code-review` and address verified findings.
5. Use `superpowers:verification-before-completion`; run focused tests, full `swift test`, release build, and packaging checks with writable Swift/Clang cache paths.
6. Inspect the built app's version and smoke-launch it.
7. Commit final docs/version changes.
8. Push `codex/capture-groups`, open a ready PR, wait for CI, and merge only after checks pass.
9. Tag and publish `v0.15.0` with complete release notes and DMG/ZIP assets using the repository's established workflow.
10. Verify the public GitHub release contains the release notes and expected assets.
11. Install the verified app into `/Applications/AstroTool.app`, preserving/replacing the previous installed bundle as the normal release workflow requires.
12. Verify the installed bundle reports v0.15.0 and launches.
