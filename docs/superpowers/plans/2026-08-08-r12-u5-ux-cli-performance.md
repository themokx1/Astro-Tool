# R12 U5 UX/CLI/Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining R12 terminology, navigation, calibration, percentile, plan-export, migration, triage, CLI, documentation, and Nights-query performance gaps without broad refactoring.

**Architecture:** Small UI fixes reuse shared `TDFormat` and shared menus; new CLI behavior calls existing AstroCore models; performance work introduces one reusable library snapshot rather than caches; migration work stays inside Database; triage additions reuse `SessionActionMenu` and existing session state.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/AppKit, SQLite, existing HTML documentation.

## Global Constraints

- No new third-party dependency.
- No automatic move/delete/write of image files.
- AstroCore remains network-free.
- Do not turn U5 into an `AppState` or UI architecture rewrite.
- Hungarian strings use the existing terminology and `TDFormat` conventions.
- CLI JSON remains additive/backward-compatible.

---

### Task 1: Unify formatting, terminology, glossary anchors, and menus

**Files:**
- Modify: `Sources/AstroToolApp/Views/TargetDetail/QualitySegment.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/OverviewSegment.swift`
- Modify: `Sources/AstroToolApp/Views/TrendsPage.swift`
- Modify: `Sources/AstroToolApp/Views/AuditPage.swift`
- Modify: `Sources/AstroToolApp/Views/SharedComponents.swift`
- Modify: `Sources/AstroToolApp/Views/GlossarySheet.swift`
- Modify: `Sources/AstroToolApp/Views/Commands.swift`
- Modify: `docs/features.html`

**Interfaces:**
- Extends: `MetricInfoButton.Metric` with optional `glossaryTerm: String?`
- Reuses: `TDFormat.missingTile`, `TDFormat.missingCell`, `TDFormat.bytes`

- [ ] **Step 1: Add focused format/helper tests where the value is pure**

Move any still-private byte formatter needed for equality tests into `TDFormat`, then assert byte and missing representations once rather than snapshotting whole views.

- [ ] **Step 2: Replace literal inconsistencies**

Replace batch reject `n/a`, flat summary em dash, `e⁻/s/□″`, and Audit private byte output with the canonical helpers/`e⁻/s/″²`.

- [ ] **Step 3: Add optional glossary navigation**

Metric info rows with `glossaryTerm` render a `Fogalomtárban` action that opens the existing glossary and selects/scrolls to that term; rows without it remain unchanged.

- [ ] **Step 4: Correct menu visibility and names**

Show `Előző éjszaka` only when its sidebar condition is true and rename `Szenzor` to `Szenzor-profilok` everywhere.

- [ ] **Step 5: Build the app**

Run: `swift build --target AstroToolApp`

### Task 2: Add calibration shopping list CLI

**Files:**
- Modify: `Sources/astrotool/Commands.swift`
- Modify: `Sources/astrotool/main.swift`
- Modify: `Sources/AstroCore/Calib/CalibShoppingList.swift`
- Test: `Tests/AstroCoreTests/CalibShoppingListTests.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

**Interfaces:**
- CLI: `calib --shopping [--date YYYY-MM-DD] [--site NAME] [--json]`
- Produces additive JSON envelope fields: `night`, `site`, `items`

- [ ] **Step 1: Add failing CLI smoke tests**

Cover default date, explicit date, named site, unknown site, JSON schema envelope, empty list, and mutual compatibility with existing `calib --health/--flats` flags.

- [ ] **Step 2: Run smoke tests and verify unknown flag failure**

Run: `swift test --filter CLISmokeTests`

- [ ] **Step 3: Implement flag parsing and shared calculation**

Resolve plan/date/site with `Planner` and calibration coverage with `CalibAnalyzer`, then call `CalibShoppingList.build`. Reject incompatible mode flags instead of silently picking one.

- [ ] **Step 4: Make human output date-specific**

Header: `Kalibrációs bevásárlólista — <night> éjszakájára` and include selected site name only when explicitly/configurably known.

- [ ] **Step 5: Run focused suites**

Run: `swift test --filter CalibShoppingListTests && swift test --filter CLISmokeTests`

### Task 3: Carry affected sessions through calibration needs

**Files:**
- Modify: `Sources/AstroCore/Calib/CalibAnalyzer.swift`
- Modify: `Sources/AstroCore/Calib/CalibLinker.swift`
- Modify: `Sources/AstroToolApp/Views/CalibrationPage.swift`
- Modify: `Sources/AstroToolApp/Views/SettingsWindow.swift`
- Test: `Tests/AstroCoreTests/CalibTests.swift`
- Test: `Tests/AstroCoreTests/CalibLinkerTests.swift`

**Interfaces:**
- Adds: `CalibNeed.sessions: [SessionKey]` with legacy decode default `[]`
- `SessionKey` is stable `(target,date)` and sorted deterministically.

- [ ] **Step 1: Add failing affected-session tests**

One flat need shared by two same-setup sessions must contain both keys; unrelated target/date must not appear. Old JSON without sessions decodes.

- [ ] **Step 2: Populate sessions during need grouping**

Deduplicate by target/date and sort by date then target. Do not re-query the DB from SwiftUI.

- [ ] **Step 3: Route Linkelés to the intended session**

One session opens directly; multiple sessions present an explicit picker. No sessions shows an explanatory disabled state.

- [ ] **Step 4: Add Settings deep-link and action wording sweep**

All to-do strings become imperative and the Calibration page opens Settings on the Calibration tab.

- [ ] **Step 5: Run calibration suites and app build**

Run: `swift test --filter CalibTests && swift test --filter CalibLinkerTests && swift build --target AstroToolApp`

### Task 4: Implement midrank percentiles and low-sample state

**Files:**
- Modify: `Sources/AstroCore/Stats/LibraryPercentiles.swift`
- Modify: `Sources/AstroToolApp/Views/SharedComponents.swift`
- Modify: `Sources/AstroToolApp/Views/PreviousNightPage.swift`
- Test: `Tests/AstroCoreTests/LibraryPercentilesTests.swift`

**Interfaces:**
- Adds to result: `sampleCount: Int`, `isLowSample: Bool`
- Midrank: average of zero-based first/last positions for equal values.

- [ ] **Step 1: Add failing tie and low-sample tests**

```swift
@Test func equalValuesReceiveTheSameMidrankBand() throws {
    let values = [1.0, 1.0, 1.0, 4.0, 5.0, 6.0]
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false))
    #expect(result.percentile == 20)
    #expect(result.band != .worst)
}

@Test func fewerThanSixValuesIsLowSample() throws {
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: [1,2,3], higherIsBetter: false))
    #expect(result.isLowSample)
}
```

- [ ] **Step 2: Run tests and confirm current ranking fails**

Run: `swift test --filter LibraryPercentilesTests`

- [ ] **Step 3: Implement midrank without changing metric direction**

Calculate ties before applying `higherIsBetter`; all equal values return the same percentile and band.

- [ ] **Step 4: Render low-sample state and triage dot**

Below 6 values use neutral color and caption `kevés adat (N/6)`. Previous Night uses the same `PercentileDot` component as Nights/Session rows.

- [ ] **Step 5: Run tests and app build**

Run: `swift test --filter LibraryPercentilesTests && swift build --target AstroToolApp`

### Task 5: Extend plan CSV and error reporting

**Files:**
- Modify: `Sources/AstroCore/Export/PlanExport.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/TonightPage.swift`
- Modify: `Sources/astrotool/Commands.swift`
- Test: `Tests/AstroCoreTests/PlanExportTests.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

**Interfaces:**
- Adds columns: `night`, `filter`, `filter_missing_hours`, `missing_hours`
- Keeps numeric formatting locale-independent.

- [ ] **Step 1: Add failing exact-header and row tests**

Assert additive header order, raw recommended filter, decimal dot under Hungarian locale, blank missing values, and correct night.

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter PlanExportTests`

- [ ] **Step 3: Extend PlanExport from TargetPlan fields**

Never parse the human chip (`Ha (-6,2h)`); use `filterAdvice.recommendedFilter` and numeric missing seconds directly.

- [ ] **Step 4: Fix save panel and activity error path**

Default filename is `terv-<night>.csv`. On write error call the same `reportError`/activity log path as other exports; do not only assign `lastError`.

- [ ] **Step 5: Run plan/CLI tests and app build**

Run: `swift test --filter PlanExportTests && swift test --filter CLISmokeTests && swift build --target AstroToolApp`

### Task 6: Remove O(sessions × files) Nights filtering

**Files:**
- Modify: `Sources/AstroCore/Stats/NightsQueries.swift`
- Modify: `Sources/AstroCore/Stats/FilterBreakdown.swift`
- Test: `Tests/AstroCoreTests/NightsQueriesTests.swift`
- Test: `Tests/AstroCoreTests/FilterBreakdownTests.swift`

**Interfaces:**
- Adds internal snapshot overload consuming `[FileRecord]` and `[Int64: FITSMetaRecord]`
- Public `FilterBreakdownQueries` API remains source-compatible.

- [ ] **Step 1: Add a query-count/performance regression hook**

Add test-only DB statement counting or a `FilterBreakdownQueries.compute(target:date:files:meta:)` pure overload; assert `allNights` fetches the library snapshot once and produces existing results.

- [ ] **Step 2: Capture expected behavior with current Nights tests**

Run: `swift test --filter NightsQueriesTests`

- [ ] **Step 3: Pre-group one snapshot by session key**

```swift
let filesBySession = Dictionary(grouping: sessionFiles) { SessionKey(target: $0.target!, date: $0.sessionDate!) }
```

Compute breakdown from each bucket, not from repeated `db.allFiles` calls.

- [ ] **Step 4: Run all Nights/filter/trend tests**

Run: `swift test --filter NightsQueriesTests && swift test --filter FilterBreakdownTests && swift test --filter TrendQueriesTests`

### Task 7: Make v10 migration transactional and resumable

**Files:**
- Modify: `Sources/AstroCore/DB/Database.swift`
- Test: `Tests/AstroCoreTests/DatabaseTests.swift`

**Interfaces:**
- Adds private helpers: `tableExists(_:)`, `columnExists(table:column:)`
- Migration version changes only after all v10 DDL/data steps succeed.

- [ ] **Step 1: Add failing interrupted migration test**

Create a v9 fixture with one v10 column/table already present but schema version still 9. Opening the DB twice must finish once, preserve data, and produce no duplicate-column error.

- [ ] **Step 2: Run migration tests**

Run: `swift test --filter DatabaseTests`

- [ ] **Step 3: Wrap v10 migration in transaction and guard each additive step**

Use `BEGIN IMMEDIATE`; rollback on any error; set schema version last. Guards make a previously partial external state resumable.

- [ ] **Step 4: Run all migration/config tests**

Run: `swift test --filter DatabaseTests && swift test --filter ConfigTests`

### Task 8: Complete triage cards and session navigation

**Files:**
- Modify: `Sources/AstroToolApp/Views/PreviousNightPage.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift`
- Modify: `Sources/AstroToolApp/Views/SharedComponents.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Test: `Tests/AstroCoreTests/SessionStatsTests.swift`

**Interfaces:**
- Reuses: `SessionActionMenu`, `SessionDetail.hasReadme`, `SessionDetail.hasConflict`
- Adds no second session menu implementation.

- [ ] **Step 1: Derive card header count from displayed cards**

Use `previousNightCards.count`, not raw changed-session keys. Show note icon, conflict warning, and a `Jegyzet…` action from the shared menu.

- [ ] **Step 2: Explain disabled review**

When no scored/reviewable frames exist, render caption `Előbb pontozd a session light frame-jeit.` beside the disabled button.

- [ ] **Step 3: Rebuild cards after cancelled batch rating**

Use `defer`/completion path that calls the existing card rebuild even when Task cancellation prevents score application; never claim rating success.

- [ ] **Step 4: Add README conflict icon to SessionsSegment**

Reuse `hasConflict` and the same tooltip as NightsPage.

- [ ] **Step 5: Build app and run session tests**

Run: `swift test --filter SessionStatsTests && swift build --target AstroToolApp`

### Task 9: Complete CLI usage and documentation sweep

**Files:**
- Modify: `Sources/astrotool/Commands.swift`
- Modify: `docs/cli.html`
- Modify: `docs/features.html`
- Modify: `CHANGELOG.md`
- Modify: `PLAN-R12.md`

- [ ] **Step 1: Add `--site` to plan/night-info usage and shopping docs**

- [ ] **Step 2: Document R11 T6/T7/T8 and current Help menu**

Use current source strings and command behavior; do not copy stale plan wording.

- [ ] **Step 3: Run terminology contradiction searches**

Run: `rg -n "e⁻/s/□|Szenzor</|minden indexelt|calib --shopping|Előző éjszaka" Sources docs README.md`

- [ ] **Step 4: Run full verification**

Run: `swift test && swift build --target AstroToolApp && git diff --check`

Expected: all tests/build pass and no diff-format errors.

- [ ] **Step 5: Commit only U5 files**

Commit: `git commit -m "fix: R12-U5 UX CLI és teljesítmény sweep"`
