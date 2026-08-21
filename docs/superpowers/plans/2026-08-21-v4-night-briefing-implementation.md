# AstroTool V4 Night Briefing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver AstroTool 4.0.0 stable with a beginner-friendly five-step Night Briefing workflow that saves immutable drafts and exports the same offline A4 document as selectable-text PDF and optional 144 DPI PNG pages.

**Architecture:** `AstroApplication` owns the Codable draft, validation, composition and immutable revision store. A render-independent `NightBriefingDocument` is transformed into self-contained HTML, while thin `AstroUI` WebKit/PDFKit adapters create PDF, PNG pages and preview. SwiftUI owns navigation and the five-step editor; export writes only new files chosen by the user and never touches the photo library.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, WebKit, PDFKit, Swift Testing, XCTest UI tests, semantic HTML/CSS/SVG, static bilingual website.

**Spec:** `docs/superpowers/specs/2026-08-21-v4-night-briefing-design.md`

## Global Constraints

- No standalone delete operation and no overwrite of an existing draft revision or export.
- Briefing storage stays under Application Support, outside the photo library.
- No renderer network requests, remote assets, scripts or invented astronomical/weather/equipment values.
- PDF is canonical; PNG pages are always rendered from the completed PDF.
- Hungarian and English user-facing copy must remain understandable to non-technical beginners.
- A public `v4.0.0` tag/release is allowed only after Developer ID signing and notarization succeed.
- Every implementation task follows red-green-refactor and ends in a focused commit.

---

## Task 1: Define the briefing domain and readiness validation

**Files:**
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingModels.swift`
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingValidator.swift`
- Create: `Tests/AstroApplicationTests/NightBriefingValidatorTests.swift`

**Interfaces:**

```swift
public enum BriefingDocumentLanguage: String, Codable, CaseIterable, Sendable { case hu, en }
public enum BriefingDataState<Value: Codable & Sendable>: Codable, Sendable {
    case known(Value)
    case missing(reason: String)
    case stale(Value, updatedAt: Date)
}
public enum BriefingTargetRole: String, Codable, Sendable { case primary, backup }
public struct NightBriefingDraft: Codable, Identifiable, Sendable { /* stable id + revision + user choices */ }
public struct NightBriefingDocument: Codable, Sendable { /* immutable rendered facts and sections */ }
public enum BriefingReadiness: String, Codable, Sendable { case ready, attention, incomplete }
public struct BriefingValidationReport: Equatable, Sendable {
    public let readiness: BriefingReadiness
    public let issues: [BriefingValidationIssue]
    public var blocksExport: Bool
}
public struct NightBriefingValidator: Sendable {
    public func validate(_ draft: NightBriefingDraft) -> BriefingValidationReport
}
```

- [ ] Write failing tests for a ready draft, missing date, end-before-start, missing weather/site/setup, overlapping blocks and a missing primary target.
- [ ] Run `swift test --filter NightBriefingValidatorTests`; expect compile failures because the domain does not exist.
- [ ] Add Codable/Equatable domain types for location/setup summaries, timeline blocks, capture plans, checklist sections/items, contingencies, notes and document sections.
- [ ] Implement readiness rules so only a missing date and invalid target time range block export; missing contextual data stays clearly exportable as attention/incomplete.
- [ ] Run `swift test --filter NightBriefingValidatorTests`; expect all tests to pass.
- [ ] Commit with `git add Sources/AstroApplication/Features/Briefing Tests/AstroApplicationTests/NightBriefingValidatorTests.swift && git commit -m "feat: define night briefing domain"`.

## Task 2: Store immutable draft revisions

**Files:**
- Modify: `Sources/AstroApplication/Library/AppStoragePaths.swift`
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingRevisionStore.swift`
- Modify: `Tests/AstroApplicationTests/AppStoragePathsTests.swift`
- Create: `Tests/AstroApplicationTests/NightBriefingRevisionStoreTests.swift`

**Interfaces:**

```swift
public actor NightBriefingRevisionStore {
    public init(directory: URL, fileManager: FileManager = .default)
    public func save(_ draft: NightBriefingDraft) throws -> NightBriefingDraft
    public func latest(id: UUID) throws -> NightBriefingDraft?
    public func latestRevisions() throws -> [NightBriefingDraft]
}
```

- [ ] Write failing tests proving first save creates revision 1, later save creates revision 2, revision 1 remains byte-for-byte intact, corrupt JSON is skipped, and an existing filename is never overwritten.
- [ ] Extend `AppStoragePaths` with public `briefings` under `Application Support/AstroTool/Libraries/<libraryID>/briefings` and include it in `allURLs`; assert it is outside the selected library.
- [ ] Run `swift test --filter NightBriefingRevisionStoreTests`; expect failure before implementation.
- [ ] Implement deterministic `<uuid>-r000001.json` naming, atomic new-file writes with `.withoutOverwriting`, filename scanning for latest revision, and no delete API.
- [ ] Run `swift test --filter NightBriefingRevisionStoreTests` and `swift test --filter AppStoragePathsTests`; expect pass.
- [ ] Commit with `git commit -am "feat: preserve briefing revisions"` after adding new files.

## Task 3: Compose the canonical document without inventing data

**Files:**
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingComposer.swift`
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingChecklistTemplate.swift`
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingContingencyBuilder.swift`
- Create: `Tests/AstroApplicationTests/NightBriefingComposerTests.swift`

**Interfaces:**

```swift
public struct NightBriefingContext: Sendable { /* computed sky, project, calibration, weather facts */ }
public struct NightBriefingComposer: Sendable {
    public func compose(draft: NightBriefingDraft, context: NightBriefingContext) -> NightBriefingDocument
}
public struct NightBriefingChecklistTemplate: Sendable {
    public func sections(language: BriefingDocumentLanguage) -> [BriefingChecklistSection]
}
public struct NightBriefingContingencyBuilder: Sendable {
    public func build(draft: NightBriefingDraft, context: NightBriefingContext) -> [BriefingContingency]
}
```

- [ ] Write failing tests for primary/backup ordering, manual overrides winning over suggestions, known/missing/stale propagation, integration math, calibration gaps, five checklist sections, hidden built-ins, custom items and all six contingency categories.
- [ ] Assert a contingency never names an unavailable target/action and explicitly says no alternative is known when input data cannot support one.
- [ ] Run `swift test --filter NightBriefingComposerTests`; expect failure.
- [ ] Implement pure composition with no clocks, file access or renderer calculations; inject all timestamps through the draft/context.
- [ ] Run the focused tests; expect pass.
- [ ] Commit with `git commit -am "feat: compose complete night briefings"` after adding new files.

## Task 4: Render deterministic offline HTML and inline SVG

**Files:**
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingHTMLRenderer.swift`
- Create: `Sources/AstroApplication/Features/Briefing/NightBriefingSVGRenderer.swift`
- Create: `Tests/AstroApplicationTests/NightBriefingHTMLRendererTests.swift`

**Interfaces:**

```swift
public struct NightBriefingHTMLRenderer: Sendable {
    public func render(_ document: NightBriefingDocument) -> String
}
public struct NightBriefingSVGRenderer: Sendable {
    public func altitudeChart(_ points: [BriefingChartPoint], labels: BriefingChartLabels) -> String
}
```

- [ ] Write failing tests for HU/EN headings, mandatory cover/timeline/checklist/notes, omission of empty optional sections, HTML escaping, deterministic output, page-break classes and fixture SVG coordinates.
- [ ] Add a strict assertion that output contains no `http:`, `https:`, `file:`, `<script`, `@import` or external font/image references.
- [ ] Run `swift test --filter NightBriefingHTMLRendererTests`; expect failure.
- [ ] Implement semantic HTML with embedded print CSS for A4 portrait, minimum 11pt text, high contrast, checkboxes and inline SVG only.
- [ ] Run the focused tests; expect pass.
- [ ] Commit with `git commit -am "feat: render offline briefing documents"` after adding new files.

## Task 5: Export canonical PDF and matching PNG pages safely

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingPDFExporter.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingPNGExporter.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingExportCommand.swift`
- Create: `Tests/AstroUITests/NightBriefingExportTests.swift`

**Interfaces:**

```swift
@MainActor public protocol NightBriefingPDFExporting { func pdfData(html: String) async throws -> Data }
@MainActor public final class NightBriefingPDFExporter: NightBriefingPDFExporting { /* hidden WKWebView */ }
public struct NightBriefingPNGExporter { public func pages(from pdf: Data, dpi: CGFloat) throws -> [Data] }
public enum BriefingExportFormat: Sendable { case pdf, pdfAndPNG, pngOnly }
@MainActor public struct NightBriefingExportCommand {
    public func export(document: NightBriefingDocument, to destination: URL, format: BriefingExportFormat) async throws -> BriefingExportResult
}
```

- [ ] Add failing integration tests for `%PDF` data, selectable cover text via PDFKit, readable page count, PNG/page count equality, A4 at 144 DPI, non-empty pixels, and refusal to overwrite existing output.
- [ ] Add a failure-path test proving no final PNG directory appears if a page conversion fails and the already successful PDF remains for combined export.
- [ ] Link WebKit/PDFKit in `AstroUI`, implement `WKWebView.loadHTMLString` plus `createPDF`, then PDFKit page rendering at 2× A4 scale.
- [ ] Implement unique temp names owned by the current export, output validation and atomic move into user-selected paths; clean only those fresh temp artifacts.
- [ ] Run `swift test --filter NightBriefingExportTests`; expect pass.
- [ ] Commit with `git commit -am "feat: export briefing pdf and png"` after adding new files.

## Task 6: Implement editor state, autosave and preview recovery

**Files:**
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingStore.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingPreviewStore.swift`
- Create: `Tests/AstroUITests/NightBriefingStoreTests.swift`
- Create: `Tests/AstroUITests/NightBriefingPreviewStoreTests.swift`

**Interfaces:**

```swift
@MainActor @Observable public final class NightBriefingStore {
    public enum Step: Int, CaseIterable, Sendable { case basics, timeline, capture, checklist, preview }
    public private(set) var draft: NightBriefingDraft
    public private(set) var report: BriefingValidationReport
    public func update(_ mutation: (inout NightBriefingDraft) -> Void)
    public func saveRevision() async throws
}
@MainActor @Observable public final class NightBriefingPreviewStore {
    public enum State { case idle, rendering, ready(Data), failed(String) }
    public func render(_ document: NightBriefingDocument) async
    public func retry() async
}
```

- [ ] Write failing state tests for all five steps, readiness badges, draft mutation, save/reopen, no revision on unchanged state, preview failure and retry.
- [ ] Implement dependency-injected clock, revision storage, composer and PDF exporter so tests do not launch UI or reach the network.
- [ ] Run `swift test --filter NightBriefingStoreTests` and `swift test --filter NightBriefingPreviewStoreTests`; expect pass.
- [ ] Commit with `git commit -am "feat: manage briefing editor state"` after adding new files.

## Task 7: Build the five-step beginner UI and navigation entry points

**Files:**
- Modify: `Sources/AstroUI/App/AppRoute.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift`
- Modify: `Sources/AstroUI/Features/Home/HomeView.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingStartView.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingEditorView.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingBasicsStep.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingTimelineStep.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingCaptureStep.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingChecklistStep.swift`
- Create: `Sources/AstroUI/Features/Briefing/NightBriefingPreviewStep.swift`
- Create: `Tests/AstroUITests/NightBriefingSurfaceTests.swift`
- Modify: `Tests/AstroUITests/AppRouteTests.swift`

- [ ] Invoke `frontend-design` before implementing the visual surface; retain the existing AstroTool visual language while making the step/status hierarchy unmistakable at 1280px and compact widths.
- [ ] Write failing route tests for `.briefing`, `astrotool://planning/briefing` and its Planning primary section.
- [ ] Write failing surface tests for the three exact start choices, five step titles, beginner explanations, visible missing/stale warnings, PDF and PDF+PNG actions, accessibility labels and no developer jargon.
- [ ] Add `.briefing` routing and render it inside the existing selected-library environment without introducing a new primary sidebar section.
- [ ] Implement the start screen choices: “A ma estét szeretném megtervezni”, “Másik dátumra készülök”, “Egy korábbi briefinget folytatok” (and English equivalents).
- [ ] Implement the split editor, progressive disclosure of “miért fontos?”, clear `Kész / Ellenőrizd / Hiányos` status language, keyboard navigation and VoiceOver labels.
- [ ] Wire Planning toolbar, recommendation context menu and Home recommendation entry points while preserving the current selected date/site/setup context.
- [ ] Run `swift test --filter NightBriefingSurfaceTests` and `swift test --filter AppRouteTests`; expect pass.
- [ ] Commit with `git commit -am "feat: add the night briefing workspace"` after adding new files.

## Task 8: Add actual macOS journey tests and visual PDF verification

**Files:**
- Modify: `UITests/AstroToolUITests/AstroToolLaunchTests.swift`
- Modify: `.github/workflows/ci.yml`
- Create: `Tests/Fixtures/NightBriefing/complete-hu.json`
- Create: `Tests/Fixtures/NightBriefing/incomplete-en.json`

- [ ] Add an XCUITest that launches a clean fixture, opens Planning → Briefing, chooses tonight, traverses five steps, saves, reopens and exports PDF+PNG.
- [ ] Use stable accessibility identifiers for every interaction; assert human-visible copy, not implementation details.
- [ ] Add CI artifact collection for the generated fixture PDF and PNG pages.
- [ ] Run `xcodegen generate` and the project’s existing focused `xcodebuild test` UI command; expect pass.
- [ ] Invoke the PDF skill, render every exported page to images, inspect page breaks, overflow, contrast, checkbox alignment and phone-scale legibility; fix and repeat until clean.
- [ ] Commit with `git commit -am "test: cover the complete briefing journey"` after adding fixtures.

## Task 9: Publish the bilingual website guide

**Files:**
- Create: `docs/night-briefing.html`
- Create: `docs/en/night-briefing.html`
- Modify: `docs/index.html`
- Modify: `docs/en/index.html`
- Modify: `docs/styles.css`
- Modify: `Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift`

- [ ] Write failing website surface tests for HU/EN navigation links, five-step guide, PDF/PNG explanation, offline use, warning semantics and beginner-safe wording.
- [ ] Build an “Éjszakai briefing / Night briefing” page using the existing homepage design tokens and real in-product terminology.
- [ ] Explain the process step by step, including what users need to decide, what AstroTool fills in, and why missing data is shown rather than guessed.
- [ ] Run `swift test --filter PublicWebsiteSurfaceTests`; expect pass.
- [ ] Invoke the browser skill and visually validate both pages at desktop and mobile widths, all internal links, language switch and download paths.
- [ ] Commit with `git commit -am "docs: publish the night briefing guide"` after adding pages.

## Task 10: Finalize AstroTool 4.0.0 stable metadata and release notes

**Files:**
- Modify: `Sources/AstroCore/Product/ProductInfo.swift`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Create: `docs/releases/v4.0.0.md`
- Modify: `Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift`
- Modify: `scripts/check-release-metadata.sh`

- [ ] Write/update failing packaging tests requiring semantic version `4.0.0`, build number above V3, stable (non-beta) wording, Universal targets and V4 release notes.
- [ ] Update product metadata, bilingual release-facing copy, safety statement and supported export formats.
- [ ] Run `swift test --filter ReleasePackagingSurfaceTests`, `scripts/check-release-metadata.sh` and `scripts/check-public-content.sh`; expect pass.
- [ ] Commit with `git commit -am "chore: prepare AstroTool 4.0.0 stable"` after adding release notes.

## Task 11: Full verification, installation and release

**Files:**
- Modify only if verification exposes defects; add a regression test beside every fix.

- [ ] Invoke `superpowers:verification-before-completion` and run `swift test` from a clean build state; record the exact suite/test counts.
- [ ] Run `xcodegen generate` then the complete macOS `xcodebuild test` command from `.github/workflows/ci.yml`; require zero failures.
- [ ] Run `./build.sh`; verify the app and CLI contain both `arm64` and `x86_64` with `lipo -info`.
- [ ] Run `scripts/smoke-clean-install.sh` and then `scripts/install-local.sh`; launch the installed `/Applications/AstroTool.app` and repeat the briefing export smoke.
- [ ] Confirm no generated or modified file exists inside the test photo library and that an existing export is refused rather than overwritten.
- [ ] Invoke `superpowers:requesting-code-review`, inspect the complete diff against `origin/main`, fix every release-blocking issue with regression tests, and rerun affected/full verification.
- [ ] Push `codex/v4-night-briefing`, open a PR, wait for every required CI check, and merge only after green results.
- [ ] On updated `main`, check `security find-identity -v -p codesigning` and required notarization secrets. If present, run signed packaging/notarization, create the non-prerelease `v4.0.0` tag and GitHub release, verify downloads and website links. If absent, do not create a misleading public release; report this single external blocker while retaining the verified installed stable build.
- [ ] Mark the active goal complete only after all feasible release work has succeeded; include exact final verification evidence and clearly distinguish local stable installation from a notarized public release.

