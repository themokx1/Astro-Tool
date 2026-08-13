# V2 Workspace Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A V2 Projects → Night → Series → Frame → Result munkalánc legyen natív, kattintható, táblázatos és valódi műveletekkel használható, majd ugyanez a munkafelületi minta terjedjen ki a V1 fő workflow-ira.

**Architecture:** A meglévő `MetadataStore` és feature query/store réteg marad az adatforrás. A SwiftUI nézetek selection-alapú `Table` és route-alapú detail workspace-ek lesznek; a műveletek meglévő Application use-case-ekhez kapcsolódnak, fizikai fájlművelet csak authorizer/preview útvonalon jelenhet meg.

**Tech Stack:** Swift 6, SwiftUI macOS 14+, Observation, Swift Testing, SQLite, NavigationSplitView, Table, inspector.

---

### Task 1: Project table and stable selection

**Files:**
- Modify: `Sources/AstroUI/Features/Projects/ProjectsStore.swift`
- Modify: `Sources/AstroUI/Features/Projects/ProjectsView.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`
- Test: `Tests/AstroUITests/ProjectsStoreTests.swift`
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Write a failing store test proving project rows expose night count, usable integration, usable/excluded frames and latest date.
- [ ] Run `swift test --disable-sandbox --no-parallel --filter ProjectsStoreTests` and verify the new expectation fails.
- [ ] Add a `ProjectWorkspaceRow` projection and preserve `selectedProjectID` across reloads.
- [ ] Write a failing surface test requiring `Table`, sortable columns, selection, double-click and row/context actions.
- [ ] Replace the project card list with the native table and route selection to the project workspace.
- [ ] Run focused tests and `swift build --disable-sandbox --target AstroToolApp`.
- [ ] Commit `feat: turn V2 projects into a native workspace table` and push.

### Task 2: Dedicated project workspace

**Files:**
- Create: `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift`
- Modify: `Sources/AstroUI/Features/Projects/ProjectsView.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Write a failing surface test requiring acquisition breadcrumb, Overview/Nights/Series/Results/Notes tabs and toolbar actions.
- [ ] Run the focused test and verify it fails for missing workspace.
- [ ] Move `ProjectAcquisitionDetail` into a dedicated workspace with stable selected tab.
- [ ] Connect Review and Results; expose only safe report/export/Finder actions with real callbacks.
- [ ] Verify focused tests and app build.
- [ ] Commit `feat: add the dedicated V2 project workspace` and push.

### Task 3: Project nights table and night navigation

**Files:**
- Modify: `Sources/AstroApplication/Features/Projects/ProjectsQuery.swift`
- Modify: `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift`
- Modify: `Sources/AstroUI/Features/Nights/NightsStore.swift`
- Modify: `Sources/AstroUI/Features/Nights/NightsView.swift`
- Test: `Tests/AstroApplicationTests/ProjectsQueryTests.swift`
- Test: `Tests/AstroUITests/NightsStoreTests.swift`

- [ ] Write failing tests for latest date, series count, usable/excluded totals and project-linked night selection.
- [ ] Implement the query projection without reading source files directly.
- [ ] Replace project night cards with a selectable Table and primary double-click action.
- [ ] Route the selected row to Nights and preserve selection.
- [ ] Add toolbar/context actions for Review, project open and conversion preview.
- [ ] Verify, commit `feat: connect V2 project nights to night workspaces`, and push.

### Task 4: Series table and series workspace

**Files:**
- Create: `Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift`
- Modify: `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift`
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift`
- Test: `Tests/AstroUITests/ReviewStoreTests.swift`
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Write failing tests for series selection and sensor/passband/filter/exposure/setup metadata.
- [ ] Build a sortable Series Table with selection, double-click and context menu.
- [ ] Build the acquisition-breadcrumb series detail with metadata and frame counts.
- [ ] Connect Review at selected-series scope and Results at project scope.
- [ ] Verify, commit `feat: add V2 series workspaces`, and push.

### Task 5: Frame table actions

**Files:**
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift`
- Modify: `Sources/AstroUI/Features/Review/ReviewStore.swift`
- Modify: `Sources/AstroUI/Inspector/FrameInspector.swift`
- Test: `Tests/AstroUITests/ReviewStoreTests.swift`

- [ ] Write failing tests for selection-preserving Accept, Reset, Reject and archive-preview commands.
- [ ] Replace the frame list with a native multi-selection Table and sortable status/path columns.
- [ ] Add toolbar and row context menus using the same command functions.
- [ ] Keep archive as preview unless the mutation authorizer returns an approved journaled plan.
- [ ] Verify, commit `feat: make V2 frame review a working table`, and push.

### Task 6: Results and export actions

**Files:**
- Modify: `Sources/AstroUI/Features/Results/ResultsView.swift`
- Modify: `Sources/AstroApplication/Features/Results/ResultsQuery.swift`
- Test: `Tests/AstroApplicationTests/ResultsQueryTests.swift`
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Write failing tests for result lineage rows, source series and export/open actions.
- [ ] Add a Results Table plus result detail inspector.
- [ ] Connect open, Finder and existing safe report/export actions.
- [ ] Verify, commit `feat: complete V2 results workspace actions`, and push.

### Task 7: Remaining V1 workspace parity

**Files:**
- Modify: `Sources/AstroUI/Features/Library/HealthView.swift`
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift`
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift`
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv`
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Add RED surface tests for audit history/actions, calibration table/actions and Planning row actions.
- [ ] Implement native tables and real callbacks for already-supported use-cases.
- [ ] Update each parity CSV row only when its test and UI action are real; retain explicit gaps for unsafe/unimplemented mutations.
- [ ] Run the full suite, commit `feat: close V2 workspace parity gaps`, and push.

### Task 8: Release-ready verification and beta

**Files:**
- Modify: `Sources/AstroCore/Product/ProductInfo.swift`
- Modify: `Tests/AstroCoreTests/ProductInfoTests.swift`
- Modify: `docs/releases/v2.0.0.md`

- [ ] Bump beta channel/build and write concrete release notes.
- [ ] Run `swift test --disable-sandbox --no-parallel --quiet`; require zero failures.
- [ ] Run metadata/public-content checks and `git diff --check`.
- [ ] Commit `build: prepare V2 workspace parity beta` and push.
- [ ] Run `ASTROTOOL_DISABLE_SWIFTPM_SANDBOX=1 ./build.sh`.
- [ ] Verify checksums, codesign and universal architectures.
- [ ] Install with `scripts/install-local.sh`, preserving the previous app.
- [ ] Publish and verify a GitHub prerelease with DMG, CLI ZIP and checksums.
