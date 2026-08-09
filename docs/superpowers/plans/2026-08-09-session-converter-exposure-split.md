# Session Converter Exposure Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate mixed-exposure light sources into distinct capture groups and safely repair an already-converted mixed group.

**Architecture:** Add an exposure partitioning phase between source/group discovery and capture proposal generation. Represent an existing capture-group update explicitly in the serializable plan, then apply and roll it back transactionally alongside new groups and exact per-file assignments.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, SQLite, Swift Package Manager, GitHub Actions.

---

### Task 1: Prove the planner bug and define the split contract

**Files:**
- Modify: `Tests/AstroCoreTests/SessionConversionPlannerTests.swift`

- [ ] **Step 1: Change the IC 1396 regression to require three groups**

Replace the combined 49-frame assertion with explicit `osc-30s`,
`capture-120s`, and `capture-300s` assertions. Require counts 32, 3, and 46,
and require the 300 s artifacts to remain in the 300 s cluster.

- [ ] **Step 2: Add an already-converted mixed-group regression**

Create one existing `capture-120s-300s` record with `OSC`, `dual_band`, and
`SV220`; assign the 120/300 s fixture light IDs to it. Require the dominant
300 s proposal to target that existing ID, the 120 s proposal to be new, and
both drafts to preserve the capture metadata.

- [ ] **Step 3: Run the focused test and verify RED**

Run:
`swift test --filter 'ic1396PreviewSeparates|alreadyConvertedMixedExposure'`

Expected: the first test reports two groups instead of three and the second
cannot find an exposure-specific proposal.

### Task 2: Implement nominal-exposure seed partitioning

**Files:**
- Modify: `Sources/AstroCore/Capture/SessionConversionPlanner.swift`
- Test: `Tests/AstroCoreTests/SessionConversionPlannerTests.swift`

- [ ] **Step 1: Add exposure-aware seed fields and partition helper**

Extend `LightSeed` with whether it reuses an existing group and whether it was
split. Build partitions from the deduped raw light paths keyed by
`NominalExposure.nominal(exptime).description`; attach matching artifacts by
their nominal exposure and all remaining sidecars to the dominant partition.

- [ ] **Step 2: Generate deterministic exposure-specific proposals**

Reuse the existing group only for the largest raw-frame partition. Generate
new slugs by removing trailing exposure tokens from the source group slug and
appending the one-bucket exposure label. Omit directory source mappings when
one prefix feeds multiple capture groups.

- [ ] **Step 3: Preserve capture metadata in split drafts**

When a partition descends from an existing group, copy `sensorMode`,
`signalMode`, `filterManufacturer`, `filterModel`, and `filterName` into both
the retained-group update and new-group draft. Regenerate a concise display
name ending in the partition exposure.

- [ ] **Step 4: Run planner tests and verify GREEN**

Run: `swift test --filter SessionConversionPlannerTests`

Expected: all planner tests pass and the IC 1396 fixture reports three groups.

### Task 3: Persist and roll back existing-group updates

**Files:**
- Modify: `Sources/AstroCore/Capture/SessionConversionPlanner.swift`
- Modify: `Sources/AstroCore/Capture/SessionConversionExecutor.swift`
- Modify: `Sources/AstroCore/DB/Database.swift`
- Modify: `Tests/AstroCoreTests/SessionConversionExecutorTests.swift`

- [ ] **Step 1: Extend the plan and backup models compatibly**

Add optional `existingGroupID` to `ProposedCaptureGroup`. Add optional
`updatedGroupBackups` to `ConversionMetadataBackup` so receipts written by
older versions still decode with `nil`. Add an optional, expected-group-ID
guarded source-removal list to old-plan-compatible conversion plans.

- [ ] **Step 2: Add failing apply/rollback coverage**

Build a two-exposure executor fixture, apply its first plan, edit the combined
group to `OSC / dual_band / SV220`, plan again, then require logical apply to
create one new group and update the retained display name. Roll back and
require the original combined group and assignments to be restored.

- [ ] **Step 3: Verify RED**

Run: `swift test --filter existingMixedGroupSplitApplyAndRollback`

Expected: failure because existing-group proposals are not yet applied.

- [ ] **Step 4: Implement transactional update and restore**

Validate the proposed existing ID, scope, and slug; back up its complete row;
update editable metadata inside the same transaction; restore backups during
rollback after deleting newly created groups and before/alongside restoring
file assignments. Remove a split legacy prefix's coarse source mapping only
when its current group ID and role still match the preview; restore it on
rollback.

- [ ] **Step 5: Verify GREEN**

Run:
`swift test --filter 'SessionConversionPlannerTests|SessionConversionExecutorTests'`

Expected: all focused tests pass.

### Task 4: Make the preview language explicit

**Files:**
- Modify: `Sources/AstroToolApp/Views/CaptureWorkflowSheets.swift`
- Modify: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`

- [ ] **Step 1: Add a surface assertion for existing-group updates**

Require the decision screen source to distinguish a retained/updated group
from a newly created one.

- [ ] **Step 2: Label proposal cards and empty-state text honestly**

Show `Meglévő gyűjtés frissítése` when `existingGroupID` is present and
`Új gyűjtés` otherwise. Change the decision helper text to state that both new
and retained group metadata are editable before apply.

- [ ] **Step 3: Run the surface and focused suites**

Run:
`swift test --filter 'CaptureWorkflowSurface|SessionConversionPlannerTests|SessionConversionExecutorTests'`

Expected: all tests pass.

### Task 5: Document, verify, publish, and install v0.15.2

**Files:**
- Modify: `Sources/astrotool/main.swift`
- Modify: `CHANGELOG.md`
- Create: `docs/releases/v0.15.2.md`

- [ ] **Step 1: Perform read-only validation on the real IC 1396 session**

Run a v0.15.2 `session-convert plan` in logical mode only and verify that the
preview lists separate 120 s and 300 s groups while reporting zero moves. Do
not invoke apply against the real library.

- [ ] **Step 2: Update version and release documentation**

Set the CLI/build version to `0.15.2`. Document the folder-first root cause,
the exposure-aware repair path, metadata inheritance, and rollback behavior.

- [ ] **Step 3: Run final verification**

Run `swift test`, `swift build`, `swift build -c release`, and `./build.sh`.
Verify the app bundle/embedded CLI version and `codesign --verify --deep --strict`.

- [ ] **Step 4: Review and publish**

Inspect the complete diff, commit only the named files, push the branch, open
a ready PR, wait for CI, merge, tag the merged commit `v0.15.2`, and verify the
GitHub release has full notes plus `AstroTool.dmg` and `astrotool.zip`.

- [ ] **Step 5: Install the verified release**

Preserve the old app recoverably, install the packaged `AstroTool.app` into
`/Applications`, update the CLI symlink, verify version/signature, launch the
app, and confirm it remains running.
