# R12 U4 Publishing/Goals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry filter-specific acquisition goals consistently through project state, planning, reports, editing, readiness, and AstroBin export.

**Architecture:** `FilterGoalQueries.merge` remains the sole goal/integration source. `ProjectState` transports its result, Planner consumes the largest relevant deficit, export/report modules render that shared model, and SwiftUI only edits or explains it.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, CSV/HTML exporters in AstroCore, existing SQLite tag model.

## Global Constraints

- No destructive library writes.
- `ProjectState.filterGoals` is additive and old JSON decodes to `[]`.
- Numeric CSV fields use POSIX decimal dots.
- Existing overall goals retain their meaning; filter goals supplement rather than silently replace them.
- Export warnings never suppress output unless the existing format contract already requires failure.

---

### Task 1: Correct AstroBin grouping per filter

**Files:**
- Modify: `Sources/AstroCore/Export/AcquisitionExport.swift`
- Test: `Tests/AstroCoreTests/AcquisitionExportTests.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

**Interfaces:**
- Group key: `(sessionDate: String, filter: String, nominalExposure: Double)`
- Preserves: `AcquisitionExport.unmappedAstrobinFilters(...)`

- [ ] **Step 1: Add a failing multi-filter export test**

```swift
@Test func astrobinSeparatesSameExposureSessionByFilter() throws {
    let fixture = try AcquisitionExportFixture.make()
    try fixture.addLight(date: "2026-01-01", filter: "Ha", exptime: 300)
    try fixture.addLight(date: "2026-01-01", filter: "OIII", exptime: 300)
    var config = fixture.config
    config.astrobin.filterIDs = ["ha": 11, "oiii": 22]
    let csv = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: config)
    #expect(csv.contains(",11,"))
    #expect(csv.contains(",22,"))
    #expect(csv.split(separator: "\n").count == 3)
}
```

- [ ] **Step 2: Run and verify the dominant-filter behavior fails**

Run: `swift test --filter AcquisitionExportTests`

- [ ] **Step 3: Replace dominant-filter aggregation with filter-key aggregation**

Normalize only mapping lookup keys (`trimmed.lowercased()`); retain raw filter text in diagnostic output. Filterless frames stay in their existing blank/sentinel behavior.

- [ ] **Step 4: Add CLI warning name assertions and run tests**

Run: `swift test --filter AcquisitionExportTests && swift test --filter CLISmokeTests`

### Task 2: Add filter goals to ProjectState and project phase

**Files:**
- Modify: `Sources/AstroCore/Stats/ProjectStatus.swift`
- Test: `Tests/AstroCoreTests/ProjectStatusTests.swift`
- Test: `Tests/AstroCoreTests/FilterGoalQueriesTests.swift`

**Interfaces:**
- Produces: `ProjectState.filterGoals: [FilterIntegration]`
- Produces helpers: `effectiveGoalSeconds`, `largestFilterDeficitSeconds`

- [ ] **Step 1: Add failing compatibility and behavior tests**

```swift
@Test func projectWithOnlyOutstandingFilterGoalIsCollecting() throws {
    let state = try projectState(tags: ["goal:Ha:6h"], integration: ["Ha": 3600])
    #expect(state.phase == .collecting)
    #expect(state.filterGoals.first?.missingSeconds == 5 * 3600)
    #expect(state.todos.contains { $0.contains("Ha") && $0.contains("5") })
}

@Test func oldProjectStateJSONDefaultsFilterGoalsToEmpty() throws {
    let decoded = try JSONDecoder().decode(ProjectState.self, from: legacyJSON)
    #expect(decoded.filterGoals.isEmpty)
}
```

- [ ] **Step 2: Run project tests and confirm failure**

Run: `swift test --filter ProjectStatusTests`

- [ ] **Step 3: Merge filter data once in `buildState`**

Use existing stats filter breakdown + tag goals. Set collecting when overall goal is short, any filter goal is short, or the existing low/no-stack rule applies. Add one deterministic todo per outstanding filter, sorted case-insensitively.

- [ ] **Step 4: Run project/filter tests**

Run: `swift test --filter ProjectStatusTests && swift test --filter FilterGoalQueriesTests`

### Task 3: Make Planner score filter-goal aware

**Files:**
- Modify: `Sources/AstroCore/Sky/Planner.swift`
- Test: `Tests/AstroCoreTests/PlannerTests.swift`
- Modify: `Sources/AstroToolApp/Views/TonightPage.swift`

**Interfaces:**
- Consumes: `TargetPlan.filterGoals`
- Score need: `max(overallMissingHours ?? 0, largestFilterMissingHours ?? 0)`; fallback `1.0` only when neither goal type exists.

- [ ] **Step 1: Add failing ranking tests**

Create two equally visible targets, one complete overall but missing 8h Ha, one with no goal. Assert the filter-deficit target ranks first and receives nonzero missing need.

- [ ] **Step 2: Run planner tests**

Run: `swift test --filter PlannerTests`

- [ ] **Step 3: Pass filter goals into `score` and expose fallback captions**

```swift
private static func score(usableIntegrationSeconds: Double, goalSeconds: Double?,
                          filterGoals: [FilterIntegration], visibleHours: Double,
                          moonInterferes: Bool) -> Double
```

The app `Cél`/`Hiányzik` cell falls back to filter-goal totals only when the overall value is nil and labels the popover/caption `szűrőcélok összege`.

- [ ] **Step 4: Run planner tests and app build**

Run: `swift test --filter PlannerTests && swift build --target AstroToolApp`

### Task 4: Make GoalEdit explicit and safe

**Files:**
- Modify: `Sources/AstroToolApp/Views/GoalEditSheet.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroCore/Scan/GoalTag.swift`
- Test: `Tests/AstroCoreTests/GoalTagTests.swift`

**Interfaces:**
- Produces: normalized validation helper for one filter goal name
- App action saves overall + filter goals in one Task/operation

- [ ] **Step 1: Add failing domain validation tests**

Assert blank filter, case-insensitive duplicate (`Ha`/`ha`), nonpositive hours, and valid new `SII` behavior.

- [ ] **Step 2: Run GoalTag tests**

Run: `swift test --filter GoalTagTests`

- [ ] **Step 3: Separate sheet draft state from persisted state**

Use `overallHours: Double?`, not an implicit 10h default. New filter rows have explicit name/hours and inline validation. Save button remains disabled while any row is invalid.

- [ ] **Step 4: Add the two-level delete confirmation**

When filter goals exist, present `Csak az összcél törlése` and `Minden cél törlése`; without them, retain a single overall delete.

- [ ] **Step 5: Bundle DB writes and refresh**

Avoid a public `beginOperation` call per row. One AppState method performs all tag changes serially in a detached task, then reloads project/filter/plan data once.

- [ ] **Step 6: Run tests and app build**

Run: `swift test --filter GoalTagTests && swift build --target AstroToolApp`

### Task 5: Add filter tables to reports and honor `--out`

**Files:**
- Modify: `Sources/AstroCore/Export/TargetReport.swift`
- Modify: `Sources/AstroCore/Export/NightReport.swift`
- Modify: `Sources/astrotool/Commands.swift`
- Test: `Tests/AstroCoreTests/TargetReportTests.swift`
- Test: `Tests/AstroCoreTests/NightReportTests.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

**Interfaces:**
- Target report uses project-wide merged filter goals.
- Night report uses date-scoped `FilterBreakdownQueries` only.

- [ ] **Step 1: Add failing report HTML tests**

Assert escaped filter names, target goal/missing columns, and that a different date's filter never appears in NightReport.

- [ ] **Step 2: Run report tests**

Run: `swift test --filter TargetReportTests && swift test --filter NightReportTests`

- [ ] **Step 3: Render deterministic tables**

Sort filters case-insensitively, display `n/a` for absent goals, and use existing `ReportStyle`/HTML escaping helpers.

- [ ] **Step 4: Add failing explicit output-path smoke tests**

For both commands, pass a temp file path outside root and assert that exact file is written while the default reports directory remains unused.

- [ ] **Step 5: Fix command output routing and run suites**

Run: `swift test --filter TargetReportTests && swift test --filter NightReportTests && swift test --filter CLISmokeTests`

### Task 6: Surface unmapped filters in settings and app export

**Files:**
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/Settings/AstroBinSettingsView.swift`
- Modify: `Sources/AstroCore/Config/AstroConfig.swift`
- Test: `Tests/AstroCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces: `usedUnmappedAstroBinFilters: [String]`
- Mapping lookup is trimmed/case-insensitive.

- [ ] **Step 1: Add failing mapping normalization tests**

Assert config mapping key ` ha ` covers library filter `Ha`, and duplicate normalized keys decode deterministically.

- [ ] **Step 2: Implement one normalization helper used by export/settings**

Do not normalize persisted display text destructively; normalize at lookup/save uniqueness boundary.

- [ ] **Step 3: Add settings suggestions and named toast**

Settings lists only currently used unmapped filters with an `ID megadása` row. App export success may proceed, but toast includes `Nincs AstroBin ID: Ha, OIII`.

- [ ] **Step 4: Run config tests and app build**

Run: `swift test --filter ConfigTests && swift build --target AstroToolApp`

### Task 7: Add publishing readiness model and UI

**Files:**
- Create: `Sources/AstroCore/Stats/PublishingReadiness.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/OverviewSegment.swift`
- Test: `Tests/AstroCoreTests/PublishingReadinessTests.swift`

**Interfaces:**
- Produces: `PublishingReadiness.evaluate(project:unmappedFilters:hasProcessedOutput:)`
- Produces additive `Issue` enum cases with stable raw values.

- [ ] **Step 1: Add failing pure-model tests**

Cover collecting, outstanding filter goal, unmapped filter, missing processed output, and fully ready. Assert multiple issues coexist and deterministic order.

- [ ] **Step 2: Implement the pure readiness evaluator**

No DB or filesystem access inside the evaluator. AppState gathers inputs from existing project state, stack discovery, and unmapped-filter query.

- [ ] **Step 3: Render a nonblocking status row**

Each issue deep-links to the existing Goal, Settings, Stacks, or processing section. Keep Export enabled; caption explicitly says `Figyelmeztetés, nem tiltás`.

- [ ] **Step 4: Run tests and app build**

Run: `swift test --filter PublishingReadinessTests && swift build --target AstroToolApp`

### Task 8: U4 documentation and verification gate

**Files:**
- Modify: `docs/features.html`
- Modify: `docs/cli.html`
- Modify: `CHANGELOG.md`
- Modify: `PLAN-R12.md`

- [ ] **Step 1: Document per-filter AstroBin rows, goal fallback, reports, and readiness**

- [ ] **Step 2: Search for dominant-filter and old goal wording**

Run: `rg -n "domináns szűrő|filter goal|szűrőcél|AstroBin" Sources docs README.md`

- [ ] **Step 3: Run the full test suite**

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 4: Verify diff and commit only U4 files**

Run: `git diff --check && git status --short`

Commit: `git commit -m "fix: R12-U4 publikálás és szűrőcélok"`
