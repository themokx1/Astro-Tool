# AstroTool V2 Workflow and Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the complete Project → Night → Series → Frame → Result experience and migrate every V1 capability into the new native UI without losing CLI or report behavior.

**Architecture:** Add durable V2 identities and metadata in the app-owned metadata store, derive read-only facts from AstroCore's index, and expose each workflow through immutable application snapshots and focused feature stores. Port features as vertical slices; keep the V1 shell until the parity table and safety suite are fully green.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI Charts, SQLite, AstroCore query engines, XCUITest.

---

## Task 1: Add durable Project, Night, Series, Frame and Result metadata

**Files:**
- Create: `Sources/AstroApplication/Domain/LibraryObjects.swift`
- Create: `Sources/AstroApplication/Persistence/MetadataStore.swift`
- Create: `Sources/AstroApplication/Persistence/MetadataSchema.swift`
- Create: `Tests/AstroApplicationTests/MetadataStoreTests.swift`

- [ ] **Step 1: Write failing round-trip and migration tests**

```swift
@Test func metadataRoundTripsStableIdentityAndLineage() async throws {
    let store = try MetadataStore.temporary()
    let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
    try await store.save(project)
    let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
    try await store.save(night)
    let series = SeriesRecord(id: UUID(), projectID: project.id, nightID: night.id, exposureSeconds: 120, filterName: "SV220")
    try await store.save(series)
    #expect(try await store.project(id: project.id) == project)
    #expect(try await store.series(id: series.id) == series)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter MetadataStoreTests`

Expected: compile failure.

- [ ] **Step 3: Implement schema and records**

Define stable UUID records for `ProjectRecord`, `NightRecord`, `SeriesRecord`, `FrameDecisionRecord`, `ResultRecord`, `LineageEdgeRecord`, `ReviewStateRecord`, and `MutationJournalRecord`. Use language-neutral enum raw values. Enable SQLite foreign keys and transactions.

- [ ] **Step 4: Run GREEN**

Run: `swift test --no-parallel --filter MetadataStoreTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Domain Sources/AstroApplication/Persistence Tests/AstroApplicationTests/MetadataStoreTests.swift && git commit -m "feat: persist V2 workflow identities and lineage"`

## Task 2: Import V1 human-authored metadata without modifying V1

**Files:**
- Create: `Sources/AstroApplication/Persistence/V1StoreSnapshotter.swift`
- Create: `Sources/AstroApplication/Persistence/V1MetadataImporter.swift`
- Create: `Tests/AstroApplicationTests/V1MetadataImporterTests.swift`
- Create: `Tests/AstroApplicationTests/V1StoreSnapshotterTests.swift`
- Create: `Tests/AstroApplicationTests/Fixtures/V1DatabaseFixture.swift`

- [ ] **Step 1: Write failing import tests**

```swift
@Test func importCopiesHumanDataAndLeavesV1BytesUntouched() async throws {
    let fixture = try V1DatabaseFixture.make()
    let before = try Data(contentsOf: fixture.databaseURL)
    let snapshot = try await V1StoreSnapshotter.snapshotReadOnly(sourceDirectory: fixture.storeDirectory)
    let destination = try MetadataStore.temporary()
    let summary = try await V1MetadataImporter.importReadOnly(from: snapshot, into: destination)
    #expect(summary.tags > 0)
    #expect(summary.captureGroups > 0)
    #expect(summary.verdicts > 0)
    #expect(try Data(contentsOf: fixture.databaseURL) == before)
    #expect(summary.sessionNotes > 0)
    #expect(try await V1MetadataImporter.importReadOnly(from: snapshot, into: destination).inserted == 0)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter V1MetadataImporterTests`

Expected: compile failure.

- [ ] **Step 3: Implement idempotent read-only import**

Create a consistent SQLite snapshot with SQLite's backup API so committed WAL pages are included; copying only `astrotool.sqlite` is forbidden. Preserve a manifest of the V1 source directory before and after snapshotting. From the immutable snapshot import tags, human session notes and `.astro_tool/notes`, verdicts re-keyed through relative file paths, filter profiles, capture groups/sources/assignments, acknowledgements, user setup/site/config values and legacy conversion/quarantine receipts into typed V2 records. Sensor measurement/history is imported only as explicitly labeled legacy measurement. Emit an `ImportSummary`. Never reuse V1 integer file/group IDs, and rebuild files, FITS metadata, ratings, findings, runs and search caches from a read-only scan.

- [ ] **Step 4: Run GREEN and manifest guard**

Run: `swift test --no-parallel --filter V1StoreSnapshotterTests && swift test --no-parallel --filter V1MetadataImporterTests && swift test --no-parallel --filter LibraryManifestTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Persistence/V1MetadataImporter.swift Tests/AstroApplicationTests && git commit -m "feat: import V1 metadata without touching source data"`

## Task 3: Deliver Projects and canonical catalog creation

**Files:**
- Create: `Sources/AstroApplication/Features/Projects/ProjectsQuery.swift`
- Create: `Sources/AstroUI/Features/Projects/ProjectsStore.swift`
- Create: `Sources/AstroUI/Features/Projects/ProjectsView.swift`
- Create: `Sources/AstroUI/Features/Projects/ProjectDetailView.swift`
- Create: `Sources/AstroUI/Features/Projects/NewProjectView.swift`
- Create: `Tests/AstroApplicationTests/ProjectsQueryTests.swift`
- Create: `Tests/AstroUITests/ProjectsStoreTests.swift`

- [ ] **Step 1: Write failing snapshot tests**

```swift
@Test func catalogSearchPreventsDuplicateElephantTrunkProjects() async throws {
    let query = ProjectsQuery.fixture(existingCatalogID: "IC 1396")
    let matches = try await query.searchCatalog("elefántormány")
    #expect(matches.first?.catalogID == "IC 1396")
    #expect(matches.first?.existingProjectID != nil)
}

@Test func projectSnapshotExplainsNextAction() async throws {
    let snapshot = try await ProjectsQuery.fixture().project(id: .fixture)
    #expect(!snapshot.nextAction.title.isEmpty)
    #expect(snapshot.series.allSatisfy { $0.projectID == snapshot.id })
}
```

- [ ] **Step 2: Run RED, then implement minimal query/store/views**

Run: `swift test --no-parallel --filter ProjectsQueryTests`

Implement catalog search using `TargetCatalog.search`, canonical folder preview, setup/FOV selection, surface-brightness-based integration recommendation, existing-project redirect, list/grid choice, progress and next action.

- [ ] **Step 3: Run GREEN and UI smoke**

Run: `swift test --no-parallel --filter Projects && xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS' -only-testing:AstroToolUITests/ProjectsFlowTests`

Expected: catalog number, English and Hungarian name resolve to the same project.

- [ ] **Step 4: Commit**

Run: `git add Sources/AstroApplication/Features/Projects Sources/AstroUI/Features/Projects Tests && git commit -m "feat: deliver canonical V2 projects"`

## Task 4: Deliver true Nights and the Night Ribbon

**Files:**
- Create: `Sources/AstroApplication/Features/Nights/NightsQuery.swift`
- Create: `Sources/AstroApplication/Features/Nights/NightRibbonModel.swift`
- Create: `Sources/AstroUI/Features/Nights/NightsStore.swift`
- Create: `Sources/AstroUI/Features/Nights/NightsView.swift`
- Create: `Sources/AstroUI/Features/Nights/NightDetailView.swift`
- Create: `Sources/AstroUI/Components/NightRibbonView.swift`
- Create: `Tests/AstroApplicationTests/NightRibbonModelTests.swift`
- Create: `Tests/AstroUITests/NightsStoreTests.swift`

- [ ] **Step 1: Write failing aggregation tests**

```swift
@Test func oneCalendarNightAggregatesMultipleProjectsAndSeries() async throws {
    let night = try await NightsQuery.ic1396AndM42Fixture().night(localDate: "2026-08-08")
    #expect(night.projects.count == 2)
    #expect(night.series.map(\.exposureSeconds).contains(30))
    #expect(night.series.map(\.exposureSeconds).contains(120))
}

@Test func ribbonHasAccessibleSummaryAndOrderedEvents() {
    let ribbon = NightRibbonModel.fixture()
    #expect(!ribbon.accessibilitySummary.isEmpty)
    #expect(ribbon.events == ribbon.events.sorted { $0.start < $1.start })
}
```

- [ ] **Step 2: Run RED, implement and run GREEN**

Run: `swift test --no-parallel --filter NightRibbonModelTests`

Use AstroCore `NightsQueries`, `SessionTimeline`, `NightHealth`, `SunMoon`, `SkyTrack` and acquisition data. Draw twilight, darkness, Moon, target altitude, actual series, gaps and events. Supply a table/text alternative.

- [ ] **Step 3: Commit**

Run: `git add Sources/AstroApplication/Features/Nights Sources/AstroUI/Features/Nights Sources/AstroUI/Components Tests && git commit -m "feat: introduce true nights and Night Ribbon"`

## Task 5: Deliver Series Inspector and dedicated frame Review workspace

**Files:**
- Create: `Sources/AstroApplication/Features/Review/ReviewQuery.swift`
- Create: `Sources/AstroApplication/Features/Review/ReviewCommands.swift`
- Create: `Sources/AstroUI/Features/Review/ReviewStore.swift`
- Create: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift`
- Create: `Sources/AstroUI/Inspector/SeriesInspector.swift`
- Create: `Sources/AstroUI/Inspector/FrameInspector.swift`
- Create: `Tests/AstroApplicationTests/ReviewQueryTests.swift`
- Create: `Tests/AstroUITests/ReviewStoreTests.swift`

- [ ] **Step 1: Write failing IC 1396 series tests**

```swift
@Test func IC1396SplitsFiveThirtyOneTwentyAndThreeHundredSecondSeries() async throws {
    let review = try await ReviewQuery.ic1396Fixture().snapshot()
    #expect(Set(review.series.map(\.exposureSeconds)) == [5, 30, 120, 300])
    #expect(review.series.first { $0.exposureSeconds == 120 }?.filterName == "SV220")
    #expect(review.series.first { $0.exposureSeconds == 300 }?.filterName == "SV220")
}

@Test func rejectDoesNotMoveAndArchiveRequiresSeparatePlan() async throws {
    let fixture = ReviewQuery.ic1396Fixture()
    let before = try await fixture.manifest()
    try await fixture.commands.reject(frameID: 1)
    #expect(try await fixture.manifest() == before)
    #expect(try await fixture.commands.archivePlan(frameID: 1) != nil)
}
```

- [ ] **Step 2: Run RED, implement and run GREEN**

Run: `swift test --no-parallel --filter ReviewQueryTests`

Series grouping keys are setup, sensor mode, passband/filter, nominal exposure, gain, offset and binning. Quality percentiles compare frames only inside the series. The workspace uses large preview, filmstrip, distribution, keyboard accept/reject, multi-select editing, provenance, and a separate archive action routed through `LibraryMutationAuthorizer`.

- [ ] **Step 3: Reproduce the previous Quality crash fixture**

Run: `xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS' -only-testing:AstroToolUITests/ReviewCrashRegressionTests`

Expected: opening review/quality for IC 1396 does not crash.

- [ ] **Step 4: Commit**

Run: `git add Sources/AstroApplication/Features/Review Sources/AstroUI/Features/Review Sources/AstroUI/Inspector Tests && git commit -m "feat: deliver series aware frame review"`

## Task 6: Deliver Planning with FOV ranking and magnitude-relative goal time

**Files:**
- Create: `Sources/AstroApplication/Features/Planning/IntegrationTimeModel.swift`
- Create: `Sources/AstroApplication/Features/Planning/PlanningQuery.swift`
- Create: `Sources/AstroUI/Features/Planning/PlanningStore.swift`
- Create: `Sources/AstroUI/Features/Planning/PlanningView.swift`
- Create: `Tests/AstroApplicationTests/IntegrationTimeModelTests.swift`
- Create: `Tests/AstroApplicationTests/PlanningQueryTests.swift`

- [ ] **Step 1: Write failing physical-model and FOV tests**

```swift
@Test func baselineIsTenHoursAtReferenceConditions() {
    let input = IntegrationTimeInput(targetSurfaceBrightness: 22, skySurfaceBrightness: 21, focalRatio: 5, systemEfficiency: 1, passbandFactor: 1, samplingFactor: 1)
    #expect(IntegrationTimeModel.hours(input) == 10)
}

@Test func oneMagnitudeFainterRequiresAboutSixPointThreeTimesMoreTime() {
    let bright = IntegrationTimeModel.hours(.reference(targetSurfaceBrightness: 22))
    let faint = IntegrationTimeModel.hours(.reference(targetSurfaceBrightness: 23))
    #expect(abs(faint / bright - pow(10, 0.8)) < 0.01)
}

@Test func tinyObjectsRankBehindCompositionSizedTargetsAtTwoHundredMillimeters() async throws {
    let result = try await PlanningQuery.fixture(focalLength: 200).recommendations()
    #expect(result.first!.frameCoverage > result.last!.frameCoverage)
    #expect(result.last!.fit == .tooSmall)
}
```

- [ ] **Step 2: Run RED, implement formula and composition ranking**

Run: `swift test --no-parallel --filter IntegrationTimeModelTests && swift test --no-parallel --filter PlanningQueryTests`

Implement the approved formula, explicit source/confidence, separate point-source fallback, setup presets with user-defined zoom range, and ranking penalty for tiny frame coverage even if an object technically fits.

- [ ] **Step 3: Run GREEN and commit**

Run: `swift test --no-parallel --filter Planning && git add Sources/AstroApplication/Features/Planning Sources/AstroUI/Features/Planning Tests && git commit -m "feat: rebuild V2 planning and exposure goals"`

## Task 7: Deliver Library Health, calibration and one-session converter

**Files:**
- Create: `Sources/AstroApplication/Features/Library/LibraryHealthQuery.swift`
- Create: `Sources/AstroApplication/Features/Library/ConversionUseCase.swift`
- Create: `Sources/AstroUI/Features/Library/LibraryView.swift`
- Create: `Sources/AstroUI/Features/Library/HealthView.swift`
- Create: `Sources/AstroUI/Features/Library/ConversionWorkspace.swift`
- Create: `Tests/AstroApplicationTests/LibraryHealthQueryTests.swift`
- Create: `Tests/AstroApplicationTests/ConversionUseCaseTests.swift`

- [ ] **Step 1: Write failing health/conversion tests**

```swift
@Test func converterIsScopedToExactlyOneSessionAndDefaultsLogical() async throws {
    let useCase = ConversionUseCase.fixture()
    let plan = try await useCase.plan(sessionID: .ic1396)
    #expect(plan.scope.sessionCount == 1)
    #expect(plan.mode == .logical)
    #expect(plan.moves.isEmpty)
    #expect(plan.proposedSeries.map(\.exposureSeconds).sorted() == [5, 30, 120, 300])
}
```

- [ ] **Step 2: Run RED, implement unified health and converter**

Run: `swift test --no-parallel --filter LibraryHealthQueryTests && swift test --no-parallel --filter ConversionUseCaseTests`

Compose AstroCore calibration, audit, fixity, duplicates, cleanup, storage and converter APIs. Preserve exact preview, ambiguity decisions, no-overwrite, receipt and rollback. Logical conversion writes only metadata; physical conversion uses the shared mutation authorizer.

- [ ] **Step 3: Run GREEN and commit**

Run: `swift test --no-parallel --filter Library && swift test --no-parallel --filter SessionConversion && git add Sources/AstroApplication/Features/Library Sources/AstroUI/Features/Library Tests && git commit -m "feat: unify V2 library health and conversion"`

## Task 8: Deliver Results, stack lineage, reports and Insights

**Files:**
- Create: `Sources/AstroApplication/Features/Results/ResultsQuery.swift`
- Create: `Sources/AstroApplication/Features/Insights/InsightsQuery.swift`
- Create: `Sources/AstroUI/Features/Results/ResultsView.swift`
- Create: `Sources/AstroUI/Features/Insights/InsightsView.swift`
- Create: `Tests/AstroApplicationTests/ResultsQueryTests.swift`
- Create: `Tests/AstroApplicationTests/InsightsQueryTests.swift`

- [ ] **Step 1: Write failing lineage and dashboard tests**

```swift
@Test func resultLineageNamesInputsCalibrationSoftwareAndParent() async throws {
    let result = try await ResultsQuery.fixture().result(id: .final)
    #expect(!result.inputSeriesIDs.isEmpty)
    #expect(!result.calibrationAssetIDs.isEmpty)
    #expect(result.softwareVersion != nil)
    #expect(result.parentResultID != nil)
}

@Test func insightsAnswerWhenAndHowLong() async throws {
    let dashboard = try await InsightsQuery.fixture().snapshot(range: .year(2026))
    #expect(dashboard.totalIntegrationSeconds > 0)
    #expect(!dashboard.byMonth.isEmpty)
    #expect(!dashboard.byProject.isEmpty)
    #expect(!dashboard.accessibleSummary.isEmpty)
}
```

- [ ] **Step 2: Run RED, implement with existing AstroCore queries**

Run: `swift test --no-parallel --filter ResultsQueryTests && swift test --no-parallel --filter InsightsQueryTests`

Expose stack discovery, preparation, reports, exports, publishing readiness and result lineage. Insights answer when, hours, projects, efficiency, FWHM/background/focus, setup/filter mix, reject reasons and calibration health; every chart has text/table alternative.

- [ ] **Step 3: Run GREEN and commit**

Run: `swift test --no-parallel --filter Results && swift test --no-parallel --filter Insights && git add Sources/AstroApplication/Features/Results Sources/AstroApplication/Features/Insights Sources/AstroUI/Features/Results Sources/AstroUI/Features/Insights Tests && git commit -m "feat: add V2 results lineage and insights"`

## Task 9: Consolidate Settings, filters, equipment and optional guidance

**Files:**
- Create: `Sources/AstroUI/Settings/V2SettingsView.swift`
- Create: `Sources/AstroUI/Settings/GeneralSettingsView.swift`
- Create: `Sources/AstroUI/Settings/LibrariesSettingsView.swift`
- Create: `Sources/AstroUI/Settings/PlanningSettingsView.swift`
- Create: `Sources/AstroUI/Settings/EquipmentEvaluationSettingsView.swift`
- Create: `Sources/AstroUI/Settings/IntegrationsSupportSettingsView.swift`
- Create: `Tests/AstroUITests/V2SettingsTests.swift`
- Modify: `Sources/AstroToolApp/AstroToolApp.swift`

- [ ] **Step 1: Write failing settings tests**

```swift
@Test func filterCanBeCreatedInSettingsAndInlineFromSeriesInspector() async throws {
    let store = SettingsStore.fixture()
    let filter = try await store.createFilter(manufacturer: "SVBONY", model: "SV220", passband: .dualBand)
    #expect(store.filters.contains(filter))
    let inspector = SeriesInspectorStore.fixture(settings: store)
    #expect(inspector.filterChoices.contains(filter))
}
```

- [ ] **Step 2: Run RED, implement five panes and inline add flow**

Run: `swift test --no-parallel --filter V2SettingsTests`

Use five stable panes: General; Libraries & Safety; Planning; Equipment & Evaluation; Integrations & Support. Preserve every V1 setting. Optional contextual prompts offer `Beállítás` and `Most nem`. No personal defaults.

- [ ] **Step 3: Run GREEN and commit**

Run: `swift test --no-parallel --filter V2SettingsTests && swift build --target AstroToolApp && git add Sources/AstroUI/Settings Sources/AstroToolApp/AstroToolApp.swift Tests/AstroUITests && git commit -m "feat: consolidate V2 settings and equipment"`

## Task 10: Close feature parity and remove the V1 shell

**Files:**
- Create: `docs/superpowers/reviews/v2-feature-parity.csv`
- Create: `Tests/AstroCoreTests/V2FeatureParityTests.swift`
- Modify: `Sources/AstroToolApp/AstroToolApp.swift`
- Remove after green only: `Sources/AstroToolApp/AppState.swift`, `Sources/AstroToolApp/AppState+Support.swift`, superseded files under `Sources/AstroToolApp/Views/`

- [ ] **Step 1: Create the complete parity matrix and failing guard**

The CSV has one row for every V1 route/workflow: V2 route, use case, permission mode, unit test, UI test, CLI/report parity, accessibility state, empty/error state. The test fails for any blank cell or any remaining V1-only default route.

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter V2FeatureParityTests`

Expected: FAIL until every row is complete.

- [ ] **Step 3: Close every blank row test-first**

Run the named focused test on each row, implement the missing adapter/view/state, then update that row only after the test passes.

- [ ] **Step 4: Make V2 the sole production shell and remove superseded UI**

Keep AstroCore and CLI behavior. Remove `AppState.shared`, navigation NotificationCenter, V1 route default, old giant pages and duplicate settings only after the guard is green.

- [ ] **Step 5: Run the full parity gate**

Run: `swift test --no-parallel && xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS' && swift build --target AstroToolApp && git diff --check`

Expected: all tests PASS; no production V1 shell remains; image manifest fixtures are bit-identical for read-only workflows.

- [ ] **Step 6: Commit**

Run: `git add -A && git commit -m "refactor: complete the AstroTool V2 workflow migration"`
