# v0.15.3 Filter Library and Quality Crash Implementation Plan

> **For Codex:** Execute task-by-task with test-driven development. Keep every filesystem mutation inside this worktree until the verified release/install stage.

**Goal:** Make capture-assigned filter metadata authoritative across summaries/reports, add a reusable user filter inventory with inline creation, and eliminate the Quality-tab QuickLook actor-isolation crash.

**Architecture:** Add a v12 `filter_profiles` table and DAO, keep capture rows as historical snapshots, expose one canonical resolved filter label from `CaptureResolver`, and reuse a shared SwiftUI filter picker/editor across every capture editing surface. Move the QuickLook completion bridge out of the main-actor-inferred SwiftUI type into an explicitly nonisolated boundary.

**Tech Stack:** Swift 6, SwiftUI/AppKit, QuickLookThumbnailing, SQLite, Swift Testing, Swift Package Manager, GitHub Actions/releases.

---

### Task 1: Reproduce and lock the two root causes

**Files:**
- Modify: `Tests/AstroCoreTests/AppConcurrencySafetyTests.swift`
- Modify: `Tests/AstroCoreTests/FilterBreakdownTests.swift`
- Test: `Tests/AstroCoreTests/AppConcurrencySafetyTests.swift`
- Test: `Tests/AstroCoreTests/FilterBreakdownTests.swift`

1. Add a failing source/bridge test requiring an explicitly `nonisolated` QuickLook callback boundary.
2. Add a failing filter breakdown test whose FITS header is empty but whose capture group says `SV220`.
3. Run only those tests and confirm both fail for the expected reasons.

### Task 2: Fix the QuickLook actor boundary

**Files:**
- Modify: `Sources/AstroToolApp/Views/ThumbnailCell.swift`
- Test: `Tests/AstroCoreTests/AppConcurrencySafetyTests.swift`

1. Extract a nonisolated QuickLook `CGImage` continuation bridge.
2. Keep `NSImage`, cache access and state updates on `@MainActor`.
3. Run the focused concurrency tests and confirm green.
4. Build the application target under Swift 6 strict concurrency.

### Task 3: Make resolved filter metadata canonical

**Files:**
- Modify: `Sources/AstroCore/Capture/CaptureModels.swift`
- Modify: `Sources/AstroCore/Capture/CaptureResolver.swift`
- Modify: `Sources/AstroCore/Stats/FilterBreakdown.swift`
- Modify: `Sources/AstroCore/Stats/StatsQueries.swift`
- Modify: `Sources/AstroCore/Stats/NightsQueries.swift`
- Modify: `Sources/AstroCore/Export/StackList.swift`
- Test: `Tests/AstroCoreTests/FilterBreakdownTests.swift`
- Test: `Tests/AstroCoreTests/NightsQueriesTests.swift`
- Test: `Tests/AstroCoreTests/StatsTests.swift`

1. Add `ResolvedCaptureMetadata.filterLabel` with one normalization rule.
2. Let public FilterBreakdown load a capture resolver and resolve every usable light.
3. Add resolver input to the snapshot overload used by NightsQueries.
4. Make StatsQueries collect resolved labels rather than raw FITS filter strings.
5. Reuse the same label in stack/export grouping where applicable.
6. Run focused breakdown, stats and nights tests.

### Task 4: Add filter profile schema and core CRUD

**Files:**
- Create: `Sources/AstroCore/Capture/FilterProfile.swift`
- Modify: `Sources/AstroCore/DB/Database.swift`
- Create: `Tests/AstroCoreTests/FilterProfileTests.swift`
- Modify: `Tests/AstroCoreTests/DatabaseTests.swift`
- Modify: `Tests/AstroCoreTests/CaptureDatabaseTests.swift`

1. Write failing v11 → v12 migration and fresh-schema tests.
2. Write failing profile validation, normalized identity, CRUD and ordering tests.
3. Add `schemaSQLv12`, transactional migration and table index.
4. Implement `FilterProfileRecord`, validation and canonical label.
5. Implement all/upsert/delete/discovered-candidate DAO/query functions.
6. Run focused database/profile tests.

### Task 5: Add AppState inventory lifecycle

**Files:**
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

1. Add failing surface assertions for `filterProfiles`, CRUD and discovery loading.
2. Add observable profile and discovered-filter collections.
3. Load inventory with dashboard/root refresh.
4. Implement create/update/delete/import actions with background DB work and main-actor refresh.
5. Run focused surface tests and compile the app target.

### Task 6: Build the reusable filter selector/editor

**Files:**
- Create: `Sources/AstroToolApp/Views/FilterProfileControls.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

1. Add failing surface assertions for saved list, `Szűrő nélkül`, and `Új szűrő…`.
2. Build `FilterProfilePicker` with a stable selection value that supports a historical custom snapshot.
3. Build `FilterProfileEditorSheet` with validation, fénysáv picker, notes and inline-save callback.
4. Ensure saving a new inline profile selects it immediately.
5. Run focused tests and app build.

### Task 7: Add the dedicated Szűrők page

**Files:**
- Create: `Sources/AstroToolApp/Views/FilterProfilesPage.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/SidebarView.swift`
- Modify: `Sources/AstroToolApp/Views/MainShellView.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

1. Add failing navigation/surface assertions.
2. Add `Page.filters`, sidebar row, page routing and title.
3. Implement empty state, saved list, add/edit/delete and confirmation copy.
4. Add discovered-filter import cards, including existing SV220 capture metadata.
5. Run focused tests and app build.

### Task 8: Replace free text on all capture workflows

**Files:**
- Modify: `Sources/AstroToolApp/Views/CaptureWorkflowSheets.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

1. Add failing assertions that all three workflows use `FilterProfilePicker`.
2. Wire CaptureGroupSheet selection to draft snapshot fields and signal mode.
3. Wire CaptureAssignmentSheet exact override to the same picker.
4. Wire SessionConversionSheet proposed groups to the same picker.
5. Preserve imported historical custom values even when no inventory profile matches.
6. Run focused tests and app build.

### Task 9: Add the missing-filter corrective action and report consistency

**Files:**
- Modify: `Sources/AstroToolApp/Views/TargetDetail/OverviewSegment.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetailPage.swift`
- Modify: `Sources/AstroCore/Export/TargetReport.swift`
- Modify: `Tests/AstroCoreTests/TargetReportTests.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

1. Add failing report test showing capture-assigned SV220 in the filter section.
2. Add failing UI surface test for `Szűrő hozzárendelése…`.
3. Present the relevant session group editor from the overview action.
4. Verify the report and app consume the same resolved breakdown.
5. Run focused report/UI tests.

### Task 10: Validate against the real IC 1396 session

**Files:**
- No source changes expected.

1. Run a read-only diagnostic against `/Volumes/images/Astro/.astro_tool/astrotool.sqlite`.
2. Confirm the resolved buckets are 32 unfiltered/unknown, 3 SV220 at 120 s and 46 SV220 at 300 s.
3. Generate a report into a temporary output and confirm SV220 appears in its top filter section.
4. Confirm no library file is moved or edited.

### Task 11: Full verification, version and release notes

**Files:**
- Modify: version metadata files discovered by `rg`.
- Modify/Create: repository release notes/changelog file used by prior releases.

1. Run formatting/build checks if configured.
2. Run full `swift test` and record the exact test count.
3. Run release build/package script and inspect the generated app version.
4. Write Hungarian v0.15.3 release notes covering crash, filter inventory, inline add and resolved reporting.
5. Review the diff for scope, safety and user-owned-file preservation.

### Task 12: Publish and install

**Files:**
- No additional source changes expected.

1. Commit the verified implementation on `codex/v0.15.3-filter-library-quality-crash`.
2. Push the branch and create a ready PR.
3. Merge only after CI is green.
4. Tag and publish v0.15.3 with DMG/ZIP assets and full release notes.
5. Move the previous `/Applications/AstroTool.app` to Trash recoverably.
6. Install the v0.15.3 app, verify its bundle version and launch it.
7. Smoke-test the Minőség tab and the Szűrők page on the real library.

