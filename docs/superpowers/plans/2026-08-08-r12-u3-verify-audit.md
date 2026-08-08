# R12 U3 Verify/Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make verify results persistent and correctly classified, expose full hash coverage/baselining, make audit diffs configuration-aware, and show quarantine state without touching library files.

**Architecture:** `FixityVerifier` owns classification and baseline hashing, `Database` owns run/coverage queries, `AuditDiff` owns comparable-category rules, and `AppState` only composes persisted audit/verify state for SwiftUI. CLI and app consume the same AstroCore APIs.

**Tech Stack:** Swift 6, Swift Testing, SQLite, SwiftUI, Foundation SHA-256 implementation already used by `DuplicateFinder`.

## Global Constraints

- macOS 14 minimum; no new dependency.
- AstroCore remains network-free.
- Baseline may update `.astro_tool/astrotool.sqlite`, but never image bytes, names, locations, mtimes, or sizes.
- New JSON fields are additive and old payloads remain decodable.
- Preserve the pre-existing uncommitted `FixityVerifier.swift` work and validate it before extension.
- Every task follows red → green → full relevant regression.

---

### Task 1: Complete fixity status classification

**Files:**
- Modify: `Sources/AstroCore/Audit/FixityVerifier.swift`
- Test: `Tests/AstroCoreTests/FixityVerifierTests.swift`
- Modify: `Sources/astrotool/Commands.swift`

**Interfaces:**
- Produces: `FileStatus.modifiedInPlace(oldHash:newHash:)`
- Produces: `Summary.modifiedInPlace: Int`
- Preserves: exit code 5 iff `summary.contentChanged > 0`

- [ ] **Step 1: Add failing tests for same-size/new-mtime and read-error severity**

```swift
@Test func fixityVerifierClassifiesSameSizeNewMtimeAsModifiedInPlace() throws {
    let fixture = try FixityFixture.make(contents: Data("AAAA".utf8))
    try fixture.seedCurrentHash()
    try Data("BBBB".utf8).write(to: fixture.fileURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: fixture.record.mtime + 10)], ofItemAtPath: fixture.fileURL.path)
    let result = try #require(FixityVerifier.verify(db: fixture.db, config: fixture.config).first)
    guard case .modifiedInPlace = result.status else { Issue.record("expected modifiedInPlace"); return }
}

@Test func fixityReadErrorFindingIsSuspicious() throws {
    let result = FixityVerifier.FileResult(file: fixtureFile(), status: .readError("denied"))
    #expect(FixityVerifier.findings(from: [result]).first?.severity == .suspicious)
}
```

- [ ] **Step 2: Run the focused tests and confirm the old behavior fails**

Run: `swift test --filter FixityVerifierTests`

Expected before implementation: missing enum/count behavior or severity mismatch; after the user's partial work it may compile but must expose any missing assertions.

- [ ] **Step 3: Finish all exhaustive switches and CLI summary text**

Update `cmdVerify` human output to include `helyben módosult \(summary.modifiedInPlace)`, keep `readErrors` separate, and ensure JSON naturally encodes the new additive field.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter FixityVerifierTests`

Expected: all fixity classification tests pass.

### Task 2: Add baseline coverage and CLI mode

**Files:**
- Modify: `Sources/AstroCore/Audit/FixityVerifier.swift`
- Modify: `Sources/AstroCore/DB/Database.swift`
- Modify: `Sources/astrotool/Commands.swift`
- Modify: `Sources/astrotool/main.swift`
- Test: `Tests/AstroCoreTests/FixityVerifierTests.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

**Interfaces:**
- Produces: `FixityVerifier.Coverage(tracked:hashed:unhashed:percent:)`
- Produces: `FixityVerifier.coverage(db:target:path:) throws -> Coverage`
- Consumes existing: `FixityVerifier.baseline(...)`
- CLI: `verify --baseline [--target T] [--path P] [--json]`

- [ ] **Step 1: Add failing baseline and coverage tests**

```swift
@Test func baselineHashesOnlyPreviouslyUnhashedFilesAndIsIdempotent() throws {
    let fixture = try baselineFixture(hashedCount: 1, unhashedCount: 2)
    let before = try FixityVerifier.coverage(db: fixture.db)
    #expect((before.tracked, before.hashed, before.unhashed) == (3, 1, 2))
    let first = try FixityVerifier.baseline(db: fixture.db, config: fixture.config)
    #expect(first.hashed == 2)
    #expect(try FixityVerifier.baseline(db: fixture.db, config: fixture.config).hashed == 0)
    #expect(try FixityVerifier.coverage(db: fixture.db).hashed == 3)
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter FixityVerifierTests`

- [ ] **Step 3: Implement one database count query and the Coverage value**

Use non-missing files as denominator and normalize target/path filters identically for `countTrackedFiles`, `countHashedFiles`, `eligibleFiles`, and `baselineEligibleFiles`.

```swift
public struct Coverage: Codable, Equatable, Sendable {
    public let tracked: Int
    public let hashed: Int
    public var unhashed: Int { max(0, tracked - hashed) }
    public var percent: Double { tracked == 0 ? 0 : Double(hashed) * 100 / Double(tracked) }
}
```

- [ ] **Step 4: Add failing CLI smoke tests**

Test human and JSON baseline output, mutual exclusion with `--sample`, an empty library, and a second idempotent run.

- [ ] **Step 5: Implement `--baseline` parsing and output**

Reject `--baseline --sample`; print hashed/error/coverage summary; use ordinary error exit for read failures and never exit 5 without a confirmed mismatch.

- [ ] **Step 6: Run focused suites**

Run: `swift test --filter FixityVerifierTests && swift test --filter CLISmokeTests`

### Task 3: Persist verify state independently from audit state

**Files:**
- Modify: `Sources/AstroCore/DB/Database.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/AuditPage.swift`
- Test: `Tests/AstroCoreTests/DatabaseTests.swift`
- Test: `Tests/AstroCoreTests/FixityVerifierTests.swift`

**Interfaces:**
- Produces: `Database.runSummary(id:) throws -> RunSummary?`
- Produces app state: `lastVerifyDate`, `lastVerifySummary`, `verifyFindings`
- Maintains `findings` as deduplicated audit + verify union

- [ ] **Step 1: Add failing DB round-trip tests for verify run metadata**

Persist a verify run, finish it, and assert `lastRunID(kind: "verify")`, date, findings, and checked/summary metadata can be restored without running verify again.

- [ ] **Step 2: Store verify summary in run config JSON using an additive envelope**

```swift
private struct VerifyRunConfig: Codable {
    let astroConfig: AstroConfig
    let samplePercent: Int?
    let summary: FixityVerifier.Summary
}
```

Older runs containing a plain `AstroConfig` must decode with `summary == nil` rather than fail.

- [ ] **Step 3: Add an AppState composition helper**

```swift
private func composeAuditFindings(audit: [Finding], verify: [Finding]) -> [Finding] {
    var seen = Set<String>()
    return (audit + verify).filter { seen.insert("\($0.category)|\($0.path)|\($0.message)").inserted }
}
```

Use it in `openRoot`, `runAudit`, and `runVerify`; never replace the other run kind's evidence.

- [ ] **Step 4: Correct clean/no-audit derivation**

`isEverythingClean` requires `lastRunID != nil`; verify-only mode shows `n/a · nincs audit` tiles while still listing verify findings.

- [ ] **Step 5: Run build and focused tests**

Run: `swift build && swift test --filter FixityVerifierTests`

### Task 4: Make audit diff duplicate-configuration aware

**Files:**
- Modify: `Sources/AstroCore/Audit/AuditEngine.swift`
- Modify: `Sources/AstroCore/Audit/AuditDiff.swift`
- Modify: `Sources/AstroCore/DB/Database.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/AuditPage.swift`
- Test: `Tests/AstroCoreTests/AuditDiffTests.swift`
- Test: `Tests/AstroCoreTests/AuditTests.swift`

**Interfaces:**
- Produces: `AuditRunConfig(astroConfig:includeDuplicates:)`
- Produces: `AuditDiff.Result.omittedCategories: [String]`

- [ ] **Step 1: Add failing tests for different includeDuplicates values**

```swift
@Test func auditDiffOmitsDuplicateCategoriesWhenRunSettingsDiffer() {
    let result = AuditDiff.compute(previous: previous, current: current,
        config: config, previousIncludedDuplicates: true, currentIncludedDuplicates: false)
    #expect(result.omittedCategories.contains("duplicate-content"))
    #expect(result.newGroups.allSatisfy { !$0.key.category.hasPrefix("duplicate") })
}
```

- [ ] **Step 2: Persist and decode `AuditRunConfig`**

Fallback for legacy plain `AstroConfig` is `includeDuplicates == nil`, which triggers conservative duplicate omission and UI explanation.

- [ ] **Step 3: Apply category comparability before grouping/counting**

Filter both previous and current findings with the same omitted-category set before computing new/resolved/unchanged counts.

- [ ] **Step 4: Show partial-diff caption in AuditPage**

Render `A duplikátumok kimaradtak: a két audit eltérő beállítással futott.` only when `omittedCategories` is non-empty.

- [ ] **Step 5: Run audit suites**

Run: `swift test --filter AuditDiffTests && swift test --filter AuditTests`

### Task 5: Verify UI coverage/baseline flow

**Files:**
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/VerifyConfirmationSheet.swift`
- Modify: `Sources/AstroToolApp/Views/AuditPage.swift`

**Interfaces:**
- Produces app actions: `loadVerifyCoverage()`, `runVerifyBaseline()`
- Consumes: `FixityVerifier.Coverage`

- [ ] **Step 1: Add observable coverage and baseline result state**

Use one load method and one operation method. Baseline completion refreshes coverage, but does not automatically run verify or overwrite prior verify evidence.

- [ ] **Step 2: Redesign the confirmation sheet around explicit choices**

Show `N fájlnak van ellenőrző-összege M-ből (X%)`, buttons `Ellenőrzés` and `Hiányzó összegek pótlása`, plus the existing sample option. Disable baseline when `unhashed == 0`.

- [ ] **Step 3: Add last verify status row**

Render date, checked count, confirmed differences, suspicious count, and coverage. Missing legacy summary renders the date and `összegzés nem elérhető`, never invented zeros.

- [ ] **Step 4: Build the app target**

Run: `swift build --target AstroToolApp`

### Task 6: Add quarantine summary

**Files:**
- Create: `Sources/AstroCore/Audit/QuarantineSummary.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/Views/AuditPage.swift`
- Test: `Tests/AstroCoreTests/QuarantineSummaryTests.swift`

**Interfaces:**
- Produces: `QuarantineSummary.inspect(root:config:) throws -> QuarantineState`

- [ ] **Step 1: Add failing filesystem tests**

Cover missing directory, two timestamp batch directories with nested files, oldest date, total bytes, and an unreadable entry that does not invent a clean state.

- [ ] **Step 2: Implement read-only directory aggregation**

```swift
public struct QuarantineState: Codable, Equatable, Sendable {
    public let fileCount: Int
    public let batchCount: Int
    public let totalBytes: Int64
    public let oldestBatch: Date?
}
```

- [ ] **Step 3: Load it with cleanup data and render the row**

Show size, batch count, oldest batch, and `Megnyitás Finderben`; do not add empty/delete actions.

- [ ] **Step 4: Run quarantine tests and app build**

Run: `swift test --filter QuarantineSummaryTests && swift build --target AstroToolApp`

### Task 7: U3 documentation and verification gate

**Files:**
- Modify: `Sources/astrotool/Commands.swift`
- Modify: `docs/cli.html`
- Modify: `docs/features.html`
- Modify: `PLAN-R12.md`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift`

- [ ] **Step 1: Align usage/docs with status and baseline semantics**

Document `modified-in-place`, suspicious read errors, coverage, and `verify --baseline`; remove text claiming verify checks every indexed file before a full baseline exists.

- [ ] **Step 2: Run contradiction searches**

Run: `rg -n "minden indexelt|content-changed|verify-read-error|--baseline" Sources docs README.md`

- [ ] **Step 3: Run the full test suite**

Run: `swift test`

Expected: 0 failures.

- [ ] **Step 4: Verify diff and commit only U3 files**

Run: `git diff --check && git status --short`

Commit: `git commit -m "fix: R12-U3 verify és audit konzisztencia"`
