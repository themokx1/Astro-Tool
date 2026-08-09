# Session Converter Live Snapshot Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one-session conversion plan from current on-disk state, keep post-preview stale protection, and expose capture actions consistently on every session surface.

**Architecture:** The DB-backed planner performs three exact scoped `LibraryScanner` synchronizations before reading records, so planner and executor fingerprint the same live files without a whole-library scan. SwiftUI keeps one shared `SessionActionMenu`; pages supply row-scoped callbacks and sheets instead of duplicating menu labels or behavior.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/macOS 14+, SQLite, existing `LibraryScanner`, `SessionConversionPlanner`, `SessionConversionSheet` and `CaptureGroupSheet`.

## Global Constraints

- Never run conversion apply or physical moves on the real IC 1396 library during automated verification.
- A pre-plan targeted scan may update only AstroTool's SQLite index; it must not alter image files.
- A source change after preview must still fail fingerprint validation.
- Every action remains scoped to one exact target/date session.
- Implement on `codex/v0.15.1-session-converter-fix` and release as v0.15.1.

---

### Task 1: Plan from a live exact-session snapshot

**Files:**
- Modify: `Tests/AstroCoreTests/SessionConversionExecutorTests.swift`
- Modify: `Tests/AstroCoreTests/ScannerTests.swift`
- Modify: `Sources/AstroCore/Capture/SessionConversionPlanner.swift`
- Modify: `Sources/AstroCore/Capture/SessionConversionExecutor.swift`
- Modify: `Sources/AstroCore/Scan/Scanner.swift`

**Interfaces:**
- Consumes: `LibraryScanner.scan(subpath:refreshMeta:progress:)`, `Database.markMissing(pathsNotIn:underSubpath:)`.
- Produces: `SessionConversionPlanner.refreshScope(scope:db:config:)` invoked by the DB-backed `plan` overload.

- [ ] **Step 1: Write the failing regression test**

Add a test that scans two lights, deletes one and modifies the other before planning, then asserts that the plan contains one current file and applies successfully:

```swift
@Test func plannerRefreshesItsExactScopeBeforeFingerprinting() throws {
    let fixture = try ExecutorFixture.make(frameCount: 2)
    defer { fixture.cleanup() }
    let lights = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights")
    try FileManager.default.removeItem(at: lights.appendingPathComponent("light2.fit"))
    let handle = try FileHandle(forWritingTo: lights.appendingPathComponent("light1.fit"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("changed-before-plan".utf8))
    try handle.close()

    let plan = try fixture.plan(mode: .logicalOnly)
    #expect(plan.sourceFingerprint.fileCount == 1)
    #expect(try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db).status == .applied)
}
```

- [ ] **Step 2: Run RED**

Run:

```bash
swift test --disable-sandbox --no-parallel --filter plannerRefreshesItsExactScopeBeforeFingerprinting
```

Expected: FAIL because the planner still fingerprints the two stale DB rows and apply rejects it.

- [ ] **Step 3: Implement minimal scoped refresh**

At the start of the DB-backed planner overload, refresh these exact relative paths:

```swift
let paths = ["sessions", "stacks", "processed"].map {
    "\($0)/\(target)/\(date)"
}
for path in paths {
    let url = root.appendingPathComponent(path, isDirectory: true)
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try scanner.scan(subpath: path)
    } else {
        try db.markMissing(pathsNotIn: [], underSubpath: path)
    }
}
```

Keep the pure `plan(scope:files:...)` overload unchanged. Expand the stale error text to identify a post-preview external change and request a refreshed preview.

- [ ] **Step 4: Run GREEN and stale-safety regression**

Run:

```bash
swift test --disable-sandbox --no-parallel --filter 'SessionConversion'
```

Expected: the new test and the existing `applyRejectsStaleSourceFingerprint` both PASS.

- [ ] **Step 4a: Align scanner and executor symlink semantics**

Real-library validation revealed four dangling Siril work-tree symlinks: the
scanner indexed the links' own 586 bytes while the executor fingerprints only
regular files. Add a failing scanner test, then skip symbolic links during
directory walking. Keep the existing hard-link inode/nlink behavior unchanged.

- [ ] **Step 5: Commit**

```bash
git add -- Tests/AstroCoreTests/SessionConversionExecutorTests.swift Tests/AstroCoreTests/ScannerTests.swift Sources/AstroCore/Capture/SessionConversionPlanner.swift Sources/AstroCore/Capture/SessionConversionExecutor.swift Sources/AstroCore/Scan/Scanner.swift
git commit -m "fix: refresh session before conversion planning"
```

### Task 2: Expose capture actions on every session menu

**Files:**
- Create: `Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift`
- Modify: `Sources/AstroToolApp/Views/SharedComponents.swift`
- Modify: `Sources/AstroToolApp/Views/AllTargetsPage.swift`
- Modify: `Sources/AstroToolApp/Views/NightsPage.swift`
- Modify: `Sources/AstroToolApp/Views/PreviousNightPage.swift`
- Modify: `Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift`

**Interfaces:**
- Produces: `SessionActionMenu.onCreateCapture` and `SessionActionMenu.onConvertSession` closures.
- Each page maps both closures to a `LinkingSession(target:date:)` state and presents `CaptureGroupSheet` / `SessionConversionSheet`.

- [ ] **Step 1: Write the failing surface test**

Create these source-level regression assertions (the repository root is three
parents above `#filePath`):

```swift
@Suite("CaptureWorkflowSurface") struct CaptureWorkflowSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func everySessionSurfaceExposesCaptureAndConversionSheets() throws {
        let pages = [
            "Sources/AstroToolApp/Views/AllTargetsPage.swift",
            "Sources/AstroToolApp/Views/NightsPage.swift",
            "Sources/AstroToolApp/Views/PreviousNightPage.swift",
            "Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift",
        ]
        for page in pages {
            let text = try source(page)
            #expect(text.contains("onCreateCapture:"), Comment(rawValue: page))
            #expect(text.contains("onConvertSession:"), Comment(rawValue: page))
            #expect(text.contains("CaptureGroupSheet("), Comment(rawValue: page))
            #expect(text.contains("SessionConversionSheet("), Comment(rawValue: page))
        }
        let shared = try source("Sources/AstroToolApp/Views/SharedComponents.swift")
        #expect(shared.components(separatedBy: "Új capture-gyűjtés…").count == 2)
        #expect(shared.components(separatedBy: "Session átalakítása gyűjtésekre…").count == 2)
    }
}
```

- [ ] **Step 2: Run RED**

Run:

```bash
swift test --disable-sandbox --no-parallel --filter CaptureWorkflowSurface
```

Expected: FAIL because AllTargets, Nights and PreviousNight do not yet bind the callbacks/sheets.

- [ ] **Step 3: Implement shared callbacks and row-scoped sheets**

Add to `SessionActionMenu`:

```swift
var onCreateCapture: (() -> Void)?
var onConvertSession: (() -> Void)?
```

Render the two buttons after a divider when callbacks are non-nil. Add `@State` session IDs, `.sheet(item:)` presenters and callback arguments in every consumer. Remove the two duplicated buttons from `SessionsSegment` after passing its callbacks into the shared builder.

- [ ] **Step 4: Run GREEN and app build**

Run:

```bash
swift test --disable-sandbox --no-parallel --filter CaptureWorkflowSurface
swift build --disable-sandbox --product AstroToolApp
```

Expected: PASS and app build exit 0.

- [ ] **Step 5: Commit**

```bash
git add -- Tests/AstroCoreTests/CaptureWorkflowSurfaceTests.swift Sources/AstroToolApp/Views/SharedComponents.swift Sources/AstroToolApp/Views/AllTargetsPage.swift Sources/AstroToolApp/Views/NightsPage.swift Sources/AstroToolApp/Views/PreviousNightPage.swift Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift
git commit -m "fix: expose capture actions on session menus"
```

### Task 3: Verify, document and release v0.15.1

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `Sources/astrotool/main.swift`
- Modify: `build.sh`
- Create: `docs/releases/v0.15.1.md`

**Interfaces:**
- Produces: signed `AstroTool.app`, `AstroTool.dmg`, `astrotool.zip`, GitHub release v0.15.1.

- [ ] **Step 1: Validate the real session read-only**

Run a v0.15.1 CLI `session-convert plan` only. Compare its `sourceFingerprint.fileCount`, bytes and latest mtime with a direct read-only filesystem aggregate. Do not invoke apply.

- [ ] **Step 2: Update version and release notes**

Set CLI/build version to `0.15.1`. Document the stale-index root cause, targeted exact-session refresh, retained post-preview safety and consistent menu access.

- [ ] **Step 3: Run complete verification**

Run:

```bash
swift test --disable-sandbox --no-parallel
swift build --disable-sandbox --product AstroToolApp
./build.sh
codesign --verify --deep --strict build/AstroTool.app
hdiutil verify build/AstroTool.dmg
```

- [ ] **Step 4: Commit, push, PR, merge and tag**

Stage only named v0.15.1 files, commit, push `codex/v0.15.1-session-converter-fix`, create one ready PR to `main`, merge after checks, tag merged main as `v0.15.1`, and wait for the Release workflow.

- [ ] **Step 5: Install and smoke**

Install the verified app to `/Applications/AstroTool.app`, verify bundle/CLI version 0.15.1 and code signature, launch it, and confirm the process stays running.
