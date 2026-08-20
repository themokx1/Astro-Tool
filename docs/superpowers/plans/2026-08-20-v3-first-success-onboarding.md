# AstroTool V3 First-Success Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a novice-friendly, reopenable onboarding that creates or opens an AstroTool library and optionally produces the first project/night/capture by verified copy-only import.

**Architecture:** A new onboarding coordinator composes the existing library-open, session-creation, and capture-import stores. A new application command and a narrow `WriteGuard` entry point create only the canonical library scaffold; all copy behavior remains in `CaptureImportCommand`.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, AstroCore `WriteGuard`, AstroApplication commands.

**Spec:** `docs/superpowers/specs/2026-08-20-v3-first-success-onboarding-design.md`

## Global Constraints

- Import is copy-only; source files are never moved, renamed, overwritten, or deleted.
- Existing destination files are skipped, never overwritten.
- Every copied file is verified source-to-destination with SHA-256.
- No standalone delete operation may be introduced.
- Only same-transaction temporary/corrupt output cleanup is allowed.
- Every filesystem write must pass through a dedicated `WriteGuard` API.
- Project + night + capture + import is one optional block.
- Hungarian and English user-facing text must both be complete.

---

### Task 1: Canonical library scaffold command

**Files:**
- Modify: `Sources/AstroCore/WriteGuard.swift`
- Create: `Sources/AstroApplication/Features/Library/LibraryCreationCommand.swift`
- Create: `Tests/AstroApplicationTests/LibraryCreationCommandTests.swift`
- Modify: `Tests/AstroCoreTests/WriteGuardTests.swift`

**Interfaces:**
- Produces: `WriteGuard.libraryScaffoldRelativePaths: [String]`
- Produces: `WriteGuard.createLibraryScaffold() throws -> [URL]`
- Produces: `LibraryCreationPreview`, `LibraryCreationReceipt`, `LibraryCreationCommand.preview()`, and `LibraryCreationCommand.create()`.

- [ ] **Step 1: Write failing scaffold tests**

Test that preview returns exactly `sessions`, `stacks`, `processed`, `calibration_library/darks`, `calibration_library/flats`, `calibration_library/biases`, and `.astro_tool`; read-only creation throws before writing; mutation-enabled creation creates missing paths and reports pre-existing paths separately.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter LibraryCreationCommandTests`

Expected: compile failure because `LibraryCreationCommand` does not exist.

- [ ] **Step 3: Implement the narrow WriteGuard operation**

Add only directory creation APIs. Reject roots that are files, use standardized root-relative path validation, and never remove or overwrite an entry. Return URLs created by this call.

- [ ] **Step 4: Implement the application command**

Use these exact public shapes:

```swift
public struct LibraryCreationPreview: Equatable, Sendable {
    public let root: URL
    public let missingRelativePaths: [String]
    public let existingRelativePaths: [String]
}

public struct LibraryCreationReceipt: Equatable, Sendable {
    public let root: URL
    public let createdRelativePaths: [String]
    public let existingRelativePaths: [String]
}

public struct LibraryCreationCommand: Sendable {
    public init(root: URL, accessMode: LibraryAccessMode)
    public func preview() throws -> LibraryCreationPreview
    public func create() throws -> LibraryCreationReceipt
}
```

- [ ] **Step 5: Verify command and guard tests pass**

Run: `swift test --no-parallel --filter LibraryCreationCommandTests && swift test --no-parallel --filter WriteGuardTests`

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroCore/WriteGuard.swift Sources/AstroApplication/Features/Library/LibraryCreationCommand.swift Tests/AstroApplicationTests/LibraryCreationCommandTests.swift Tests/AstroCoreTests/WriteGuardTests.swift
git commit -m "feat: add safe AstroTool library creation"
```

### Task 2: First-success coordinator state

**Files:**
- Create: `Sources/AstroUI/Onboarding/FirstSuccessOnboardingStore.swift`
- Create: `Tests/AstroUITests/FirstSuccessOnboardingStoreTests.swift`

**Interfaces:**
- Consumes: `LibraryCreationCommand`, existing `OnboardingStore`, `NewSessionStore`, and `CaptureImportStore` factories.
- Produces: `FirstSuccessOnboardingStore`, `EntryChoice`, `Step`, `Mode`, `chooseEntry(_:)`, `skipImport()`, `finishUnderstanding()`, and completion state.

- [ ] **Step 1: Write failing state-machine tests**

Cover the three exact entry choices, understanding returning to the landing page, new/existing library reaching the optional import decision, skip completing without creating a session, help mode remaining reopenable, and errors preserving the current recoverable step.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter FirstSuccessOnboardingStoreTests`

Expected: compile failure because the store does not exist.

- [ ] **Step 3: Implement the minimal coordinator**

Use these stable state names:

```swift
@MainActor @Observable
public final class FirstSuccessOnboardingStore {
    public enum Mode: Equatable { case firstRun, help }
    public enum EntryChoice: Equatable { case createLibrary, openLibrary, understand }
    public enum Step: Equatable {
        case landing, understanding(Int), createLibrary, openLibrary
        case importOffer, importFlow, completion
    }
}
```

Keep dependencies closure-backed so tests never display file pickers or touch a real user library. The coordinator owns navigation only; it must not recreate import classification or copy code.

- [ ] **Step 4: Verify state tests pass**

Run: `swift test --no-parallel --filter FirstSuccessOnboardingStoreTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI/Onboarding/FirstSuccessOnboardingStore.swift Tests/AstroUITests/FirstSuccessOnboardingStoreTests.swift
git commit -m "feat: coordinate the first-success onboarding"
```

### Task 3: Intentional novice-facing SwiftUI flow

**Files:**
- Create: `Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift`
- Create: `Sources/AstroUI/Onboarding/LibraryMapView.swift`
- Modify: `Sources/AstroUI/Onboarding/LibraryWelcomeView.swift`
- Modify: `Tests/AstroUITests/V2OnboardingTests.swift`
- Create: `Tests/AstroUITests/FirstSuccessOnboardingSurfaceTests.swift`

**Interfaces:**
- Consumes: `FirstSuccessOnboardingStore` and existing embedded library/import stores.
- Produces: `FirstSuccessOnboardingView` initializer accepting `mode`, dependencies, and `dismiss`.

- [ ] **Step 1: Write failing surface assertions**

Pin the three Hungarian-localizable source strings, the persistent copy-only safety message, the `Mi jön létre a gépemen?` disclosure, identifiers for all three entry cards, and the absence of a move/delete import action.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter FirstSuccessOnboardingSurfaceTests`

- [ ] **Step 3: Build the landing and understanding views**

Use `AstroTokens`, native buttons/cards, one clear primary action per screen, `ScrollView` for large text, and a library-map component that progresses through Library → Project → Night → Capture → frame roles. Respect reduce motion and preserve visible keyboard focus.

- [ ] **Step 4: Embed create/open and import stages**

The create path presents preview before `LibraryCreationCommand.create`. The open path reuses `OnboardingStore`. The import stage binds directly to `CaptureImportStore`/`NewSessionStore`, keeps the safety strip visible, and exposes one skip action before any project/session creation.

- [ ] **Step 5: Add completion and failure summaries**

Show copied, SHA-verified, skipped-collision, and failed counts separately. Repeat that source files were unchanged. Never label a partial result as complete.

- [ ] **Step 6: Verify focused UI tests pass**

Run: `swift test --no-parallel --filter FirstSuccessOnboardingSurfaceTests && swift test --no-parallel --filter V2OnboardingTests && swift test --no-parallel --filter CaptureImportStoreTests`

- [ ] **Step 7: Commit**

```bash
git add Sources/AstroUI/Onboarding Tests/AstroUITests/FirstSuccessOnboardingSurfaceTests.swift Tests/AstroUITests/V2OnboardingTests.swift
git commit -m "feat: add guided first-success experience"
```

### Task 4: First-run and Help integration

**Files:**
- Modify: `Sources/AstroCore/Config/Onboarding.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`
- Modify: `Sources/AstroUI/Help/FirstStepsView.swift`
- Modify: `Sources/AstroToolApp/Views/Commands.swift`
- Modify: `Tests/AstroCoreTests/OnboardingTests.swift`
- Modify: `Tests/AstroUITests/HelpSurfaceTests.swift`
- Modify: `Tests/AstroUITests/AppRouterTests.swift`

**Interfaces:**
- Consumes: `FirstSuccessOnboardingView(mode:.firstRun/.help)`.
- Produces: onboarding lifecycle version `2`; the existing `.firstSteps` route now opens the same full onboarding in help mode.

- [ ] **Step 1: Write failing lifecycle and routing tests**

Assert `currentVersion == 2`, completed version 1 presents again, `.firstSteps` resolves to the full first-success view, and first-run completion persists version 2.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter OnboardingTests && swift test --no-parallel --filter HelpSurfaceTests`

- [ ] **Step 3: Wire both presentation paths**

Replace the static checklist sheet with the shared full onboarding. Preserve route identity and dismiss behavior so existing menu commands and router tests remain valid.

- [ ] **Step 4: Verify routing tests pass**

Run: `swift test --no-parallel --filter OnboardingTests && swift test --no-parallel --filter HelpSurfaceTests && swift test --no-parallel --filter AppRouterTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroCore/Config/Onboarding.swift Sources/AstroUI/App/V2RootView.swift Sources/AstroUI/Help/FirstStepsView.swift Sources/AstroToolApp/Views/Commands.swift Tests/AstroCoreTests/OnboardingTests.swift Tests/AstroUITests/HelpSurfaceTests.swift Tests/AstroUITests/AppRouterTests.swift
git commit -m "feat: make onboarding available on first run and Help"
```

### Task 5: Localization, accessibility, and end-to-end safety proof

**Files:**
- Modify: `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings`
- Modify: `Tests/AstroUITests/LocalizationCoverageTests.swift`
- Create: `Tests/AstroApplicationTests/FirstSuccessJourneyTests.swift`

**Interfaces:**
- Consumes: the complete onboarding and its commands.
- Produces: source-manifest safety proof and complete HU/EN copy.

- [ ] **Step 1: Add failing journey and localization tests**

Create a temporary unstructured source with light/flat/dark/bias fixtures, snapshot every source relative path/size/SHA before import, run library creation + session/capture creation + import, and assert the source manifest is identical afterward. Assert destination hashes, exact canonical tree, no overwrite on a second run, and skip-without-session behavior.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter FirstSuccessJourneyTests && swift test --no-parallel --filter LocalizationCoverageTests`

- [ ] **Step 3: Complete localized copy and accessibility metadata**

Keep the English development-language strings in Swift source clear and complete, add every corresponding Hungarian entry, add concise VoiceOver labels/hints to the three choices and progress, and avoid path-heavy accessibility values.

- [ ] **Step 4: Verify onboarding suite**

Run: `swift test --no-parallel --filter FirstSuccess && swift test --no-parallel --filter V2Onboarding && swift test --no-parallel --filter LocalizationCoverageTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroToolApp/Resources Tests/AstroApplicationTests/FirstSuccessJourneyTests.swift Tests/AstroUITests/LocalizationCoverageTests.swift
git commit -m "test: prove onboarding safety and accessibility"
```
