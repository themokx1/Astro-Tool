# AstroTool V2 Foundation and Native Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-only-by-default AstroApplication layer, deterministic safety guards, scoped operations, typed navigation, and the new native macOS shell without removing any V1 capability.

**Architecture:** Add `AstroApplication` between the tested `AstroCore` engine and a new `AstroUI` module. Library access is actor-owned and app data lives outside the image root. The V1 shell remains available behind a launch switch until the V2 feature-parity matrix is complete.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/AppKit, SQLite, Swift Package Manager, SHA-256 via CryptoKit, XcodeGen/XCUITest for UI automation.

---

## File structure

```text
Sources/AstroApplication/
  Library/AppStoragePaths.swift
  Library/LibraryIdentity.swift
  Library/LibraryManifest.swift
  Library/LibrarySession.swift
  Library/LibrarySnapshot.swift
  Mutations/LibraryAccessMode.swift
  Mutations/LibraryMutationPlan.swift
  Mutations/LibraryMutationAuthorizer.swift
  Operations/OperationCenter.swift
  Operations/OperationState.swift
  Persistence/V1MetadataImporter.swift

Sources/AstroUI/
  App/AppModel.swift
  App/AppRoute.swift
  App/FocusedAppValues.swift
  App/V2RootView.swift
  DesignSystem/AstroTokens.swift
  Features/Home/HomeStore.swift
  Features/Home/HomeView.swift
  Inspector/InspectorView.swift
  Onboarding/LibraryWelcomeView.swift

Tests/AstroApplicationTests/
Tests/AstroUITests/
UITests/AstroToolUITests/
```

## Task 1: Create module and test boundaries

**Files:**
- Create: `Tests/AstroCoreTests/V2PackageSurfaceTests.swift`
- Modify: `Package.swift`
- Create: `Sources/AstroApplication/AstroApplication.swift`
- Create: `Sources/AstroUI/AstroUI.swift`
- Create: `Tests/AstroApplicationTests/AstroApplicationSmokeTests.swift`
- Create: `Tests/AstroUITests/AstroUISmokeTests.swift`

- [ ] **Step 1: Write the failing package-surface test**

```swift
import Foundation
import Testing

@Test func packageDeclaresV2Boundaries() throws {
    let package = try String(contentsOfFile: "Package.swift", encoding: .utf8)
    #expect(package.contains(".target(name: \"AstroApplication\", dependencies: [\"AstroCore\"])"))
    #expect(package.contains(".target(name: \"AstroUI\", dependencies: [\"AstroApplication\"])"))
    #expect(package.contains(".testTarget(name: \"AstroApplicationTests\""))
    #expect(package.contains(".testTarget(name: \"AstroUITests\""))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter packageDeclaresV2Boundaries`

Expected: FAIL because `Package.swift` has no V2 targets.

- [ ] **Step 3: Add the targets and minimal public markers**

```swift
.target(name: "AstroApplication", dependencies: ["AstroCore"]),
.target(name: "AstroUI", dependencies: ["AstroApplication"]),
.executableTarget(name: "AstroToolApp", dependencies: ["AstroCore", "AstroApplication", "AstroUI"]),
.testTarget(name: "AstroApplicationTests", dependencies: ["AstroApplication", "AstroCore"]),
.testTarget(name: "AstroUITests", dependencies: ["AstroUI", "AstroApplication"]),
```

```swift
// Sources/AstroApplication/AstroApplication.swift
public enum AstroApplicationModule: Sendable { public static let isAvailable = true }

// Sources/AstroUI/AstroUI.swift
public enum AstroUIModule: Sendable { public static let isAvailable = true }
```

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --no-parallel --filter V2PackageSurfaceTests && swift test --no-parallel --filter AstroApplicationSmokeTests && swift build --target AstroToolApp`

Expected: all selected tests PASS and app target builds.

- [ ] **Step 5: Commit**

Run: `git add Package.swift Sources/AstroApplication Sources/AstroUI Tests/AstroApplicationTests Tests/AstroUITests Tests/AstroCoreTests/V2PackageSurfaceTests.swift && git commit -m "build: establish V2 module boundaries"`

## Task 2: Put all app-owned data outside the image library

**Files:**
- Create: `Sources/AstroApplication/Library/AppStoragePaths.swift`
- Create: `Sources/AstroApplication/Library/LibraryIdentity.swift`
- Create: `Tests/AstroApplicationTests/AppStoragePathsTests.swift`

- [ ] **Step 1: Write failing path tests**

```swift
import Foundation
import Testing
@testable import AstroApplication

@Test func storageNeverLivesInsideLibrary() throws {
    let base = URL(fileURLWithPath: "/tmp/AstroToolAppSupport")
    let cache = URL(fileURLWithPath: "/tmp/AstroToolCache")
    let root = URL(fileURLWithPath: "/Volumes/Fixture/Astro")
    let id = LibraryIdentity(rootURL: root)
    let paths = AppStoragePaths(applicationSupport: base, caches: cache, libraryID: id.id)
    #expect(paths.metadataDatabase.path.hasPrefix(base.path))
    #expect(paths.indexDatabase.path.hasPrefix(cache.path))
    #expect(!paths.allURLs.contains { $0.path.hasPrefix(root.path + "/") })
    #expect(id == LibraryIdentity(rootURL: root))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter AppStoragePathsTests`

Expected: compile failure because the types do not exist.

- [ ] **Step 3: Implement deterministic identity and paths**

```swift
public struct LibraryIdentity: Hashable, Codable, Sendable {
    public let id: String
    public init(rootURL: URL) {
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.id = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AppStoragePaths: Sendable {
    public let metadataDatabase: URL
    public let indexDatabase: URL
    public let thumbnails: URL
    public let migration: URL
    public var allURLs: [URL] { [metadataDatabase, indexDatabase, thumbnails, migration] }
}
```

Production defaults resolve `Application Support/AstroTool/Libraries/<id>` and `Caches/AstroTool/Libraries/<id>`; tests inject roots.

- [ ] **Step 4: Run GREEN**

Run: `swift test --no-parallel --filter AppStoragePathsTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Library Tests/AstroApplicationTests/AppStoragePathsTests.swift && git commit -m "feat: isolate V2 app storage from image libraries"`

## Task 3: Add a bit-exact read-only library manifest guard

**Files:**
- Create: `Sources/AstroApplication/Library/LibraryManifest.swift`
- Create: `Tests/AstroApplicationTests/LibraryManifestTests.swift`
- Create: `Tests/AstroApplicationTests/Fixtures/V2FixtureLibrary.swift`

- [ ] **Step 1: Write failing manifest tests**

```swift
@Test func manifestDetectsNoChangeAndEveryMaterialChange() async throws {
    let root = try V2FixtureLibrary.make()
    let before = try await LibraryManifest.capture(root: root)
    let unchanged = try await LibraryManifest.capture(root: root)
    #expect(before == unchanged)
    try Data("changed".utf8).write(to: root.appending(path: "sessions/IC1396/2026-08-08/lights/a.fit"))
    let after = try await LibraryManifest.capture(root: root)
    #expect(before != after)
    #expect(after.entries.first?.relativePath.isEmpty == false)
}

@Test func manifestExcludesOnlyExplicitAppOwnedLegacyStoreWhenRequested() async throws {
    let root = try V2FixtureLibrary.make()
    let manifest = try await LibraryManifest.capture(root: root, exclusions: [".astro_tool"])
    #expect(!manifest.entries.contains { $0.relativePath.hasPrefix(".astro_tool/") })
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter LibraryManifestTests`

Expected: compile failure because `LibraryManifest` is missing.

- [ ] **Step 3: Implement manifest capture**

```swift
public struct LibraryManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modifiedAtNanoseconds: Int64
        public let inode: UInt64?
        public let sha256: String
    }
    public let entries: [Entry]
    public static func capture(root: URL, exclusions: Set<String> = []) async throws -> Self
}
```

Enumerate regular files without following symlink escapes; sort by relative path; hash file bytes with CryptoKit; preserve size, mtime and inode.

- [ ] **Step 4: Run GREEN and prove V1 fixture safety**

Run: `swift test --no-parallel --filter LibraryManifestTests && swift test --no-parallel --filter WriteGuardTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Library/LibraryManifest.swift Tests/AstroApplicationTests && git commit -m "test: guard image libraries with bit exact manifests"`

## Task 4: Create actor-owned read-only LibrarySession

**Files:**
- Create: `Sources/AstroApplication/Library/LibrarySnapshot.swift`
- Create: `Sources/AstroApplication/Library/LibrarySession.swift`
- Create: `Tests/AstroApplicationTests/LibrarySessionTests.swift`
- Modify: `Sources/AstroCore/DB/Database.swift`

- [ ] **Step 1: Write failing session tests**

```swift
@Test func openingAndScanningDefaultSessionDoesNotMutateRoot() async throws {
    let root = try V2FixtureLibrary.make()
    let before = try await LibraryManifest.capture(root: root)
    let session = try await LibrarySession.open(rootURL: root, storage: .temporary())
    #expect(await session.accessMode == .readOnly)
    let snapshot = try await session.scan()
    #expect(snapshot.libraryID == LibraryIdentity(rootURL: root))
    #expect(snapshot.revision == 1)
    #expect(try await LibraryManifest.capture(root: root) == before)
}

@Test func staleSnapshotCannotReplaceNewerRevision() async throws {
    let session = try await LibrarySession.open(rootURL: V2FixtureLibrary.make(), storage: .temporary())
    let first = try await session.scan()
    let second = try await session.scan()
    #expect(second.revision > first.revision)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter LibrarySessionTests`

Expected: compile failure for missing session types.

- [ ] **Step 3: Add injectable Database location and implement actor**

```swift
public enum LibraryAccessMode: String, Codable, Sendable { case readOnly, mutationEnabled }

public struct LibrarySnapshot: Sendable, Equatable {
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let projectCount: Int
    public let nightCount: Int
    public let frameCount: Int
}

public actor LibrarySession {
    public nonisolated let identity: LibraryIdentity
    public private(set) var accessMode: LibraryAccessMode = .readOnly
    private var revision: UInt64 = 0
    public static func open(rootURL: URL, storage: AppStoragePaths) async throws -> LibrarySession
    public func scan() async throws -> LibrarySnapshot
}
```

The session opens its index DB at `storage.indexDatabase`; it must never call the V1 convenience that creates `<root>/.astro_tool`. Existing V1 callers remain unchanged.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --no-parallel --filter LibrarySessionTests && swift test --no-parallel --filter DatabaseTests && swift test --no-parallel --filter ScannerTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication Sources/AstroCore/DB/Database.swift Tests/AstroApplicationTests && git commit -m "feat: add read only V2 library sessions"`

## Task 5: Add immutable mutation plans and fail-closed authorization

**Files:**
- Create: `Sources/AstroApplication/Mutations/LibraryMutationPlan.swift`
- Create: `Sources/AstroApplication/Mutations/LibraryMutationAuthorizer.swift`
- Create: `Tests/AstroApplicationTests/LibraryMutationAuthorizerTests.swift`

- [ ] **Step 1: Write failing authorization tests**

```swift
@Test func readOnlySessionRejectsApply() async throws {
    let fixture = try MutationFixture.make()
    let plan = try await fixture.planMove()
    await #expect(throws: LibraryMutationError.readOnly) {
        try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
    }
}

@Test func staleFingerprintAndCollisionFailClosed() async throws {
    let fixture = try MutationFixture.make(mode: .mutationEnabled)
    let plan = try await fixture.planMove()
    try Data("changed".utf8).write(to: plan.entries[0].source)
    await #expect(throws: LibraryMutationError.stalePlan) {
        try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
    }
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter LibraryMutationAuthorizerTests`

Expected: compile failure for missing mutation API.

- [ ] **Step 3: Implement plan/authorize/journal contract**

```swift
public struct LibraryMutationPlan: Codable, Sendable, Identifiable {
    public struct Entry: Codable, Sendable { public let source: URL; public let destination: URL; public let fingerprint: String }
    public let id: UUID
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let entries: [Entry]
    public let totalBytes: Int64
    public let confirmationToken: String
}

public actor LibraryMutationAuthorizer {
    public func register(_ plan: LibraryMutationPlan) throws
    public func apply(planID: UUID, confirmation: String) async throws -> MutationReceipt
    public func rollback(receiptID: UUID) async throws
}
```

Validate scope, revision, every fingerprint, symlink containment and destination nonexistence immediately before any move. Write append-only receipt under app-owned storage and rollback in reverse order.

- [ ] **Step 4: Run GREEN and existing write safety**

Run: `swift test --no-parallel --filter LibraryMutationAuthorizerTests && swift test --no-parallel --filter FrameArchiveTests && swift test --no-parallel --filter SessionConversionExecutorTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Mutations Tests/AstroApplicationTests && git commit -m "feat: authorize library mutations fail closed"`

## Task 6: Add scoped concurrent operations

**Files:**
- Create: `Sources/AstroApplication/Operations/OperationState.swift`
- Create: `Sources/AstroApplication/Operations/OperationCenter.swift`
- Create: `Tests/AstroApplicationTests/OperationCenterTests.swift`

- [ ] **Step 1: Write failing operation tests**

```swift
@Test func operationsAreScopedAndDoNotCancelUnrelatedWork() async throws {
    let center = OperationCenter()
    let scan = await center.start(kind: .scan(library: "A"), cancellation: .cooperative)
    let export = await center.start(kind: .export(project: "P"), cancellation: .discardResult)
    await center.cancel(scan.id)
    #expect(await center.state(scan.id)?.phase == .cancelled)
    #expect(await center.state(export.id)?.phase == .running)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter OperationCenterTests`

Expected: compile failure.

- [ ] **Step 3: Implement operation types and actor**

```swift
public enum OperationKind: Hashable, Sendable {
    case scan(library: String), loadHome(library: String), rate(series: String)
    case audit(library: String), export(project: String), convert(session: String)
}
public enum CancellationPolicy: Sendable { case cooperative, discardResult, unavailable }
public enum OperationPhase: Sendable { case running, succeeded, failed, cancelled }
public struct OperationState: Identifiable, Sendable { public let id: UUID; public let kind: OperationKind; public var phase: OperationPhase; public var completed: Int64; public var total: Int64? }
public actor OperationCenter { /* start, progress, finish, fail, cancel, states */ }
```

- [ ] **Step 4: Run GREEN**

Run: `swift test --no-parallel --filter OperationCenterTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroApplication/Operations Tests/AstroApplicationTests/OperationCenterTests.swift && git commit -m "feat: scope V2 background operations"`

## Task 7: Add typed routes, window state, and focused commands

**Files:**
- Create: `Sources/AstroUI/App/AppRoute.swift`
- Create: `Sources/AstroUI/App/AppModel.swift`
- Create: `Sources/AstroUI/App/FocusedAppValues.swift`
- Create: `Tests/AstroUITests/AppRouterTests.swift`

- [ ] **Step 1: Write failing router tests**

```swift
@Test func selectionDrivesDetailAndInspectorPerWindow() {
    let router = AppRouter()
    router.primarySection = .projects
    router.select(.series("series-1"))
    #expect(router.contentRoute == .projectSeries("series-1"))
    #expect(router.inspectorSelection == .series("series-1"))
}

@Test func restoredStateNeverRestoresConfirmation() {
    let state = WindowRestorationState(primarySection: .library, contentRoute: .health, selection: nil)
    let router = AppRouter(restoring: state)
    #expect(router.presentation == nil)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter AppRouterTests`

Expected: compile failure.

- [ ] **Step 3: Implement route model**

```swift
public enum PrimarySection: String, CaseIterable, Codable, Sendable { case home, projects, nights, planning, library, insights }
public enum LibrarySelection: Hashable, Codable, Sendable { case project(String), night(String), series(String), frame(Int64), result(String) }
public enum ContentRoute: Hashable, Codable, Sendable { case home, projects, project(String), projectSeries(String), nights, night(String), planning, library, health, insights, review(String) }
public enum PresentationRoute: Identifiable { case newProject, newNight, mutationConfirmation(UUID), settingsDeepLink(String) }
@MainActor @Observable public final class AppRouter { /* window-owned route, selection, inspector and presentation */ }
```

- [ ] **Step 4: Run GREEN**

Run: `swift test --no-parallel --filter AppRouterTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroUI/App Tests/AstroUITests/AppRouterTests.swift && git commit -m "feat: add typed window scoped navigation"`

## Task 8: Build the native V2 split-view shell behind a launch switch

**Files:**
- Create: `Sources/AstroUI/DesignSystem/AstroTokens.swift`
- Create: `Sources/AstroUI/App/V2RootView.swift`
- Create: `Sources/AstroUI/Features/Home/HomeStore.swift`
- Create: `Sources/AstroUI/Features/Home/HomeView.swift`
- Create: `Sources/AstroUI/Inspector/InspectorView.swift`
- Create: `Tests/AstroUITests/V2ShellSurfaceTests.swift`
- Modify: `Sources/AstroToolApp/AstroToolApp.swift`
- Modify: `Sources/AstroToolApp/Views/Commands.swift`

- [ ] **Step 1: Write failing shell tests**

```swift
@Test func V2ShellUsesTheSixStableSectionsAndInspector() throws {
    let root = try Source.read("Sources/AstroUI/App/V2RootView.swift")
    #expect(root.contains("NavigationSplitView"))
    #expect(root.contains(".inspector(isPresented:"))
    for section in ["home", "projects", "nights", "planning", "library", "insights"] {
        #expect(root.contains(section))
    }
    #expect(!root.contains("AppState.shared"))
    #expect(!root.contains("NotificationCenter"))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter V2ShellSurfaceTests`

Expected: FAIL because the source is absent.

- [ ] **Step 3: Implement the shell**

Use `NavigationSplitView(sidebar:content:detail:)`, `.inspector`, system toolbar items, `SceneStorage` only for lightweight window state, a minimum usable size of 820×600, and a `-UseV2UI`/`ASTROTOOL_V2_UI` switch. V2 is the default in development; `-UseV1UI` keeps the old shell reachable until parity is complete.

```swift
public struct V2RootView: View {
    @Bindable private var router: AppRouter
    public var body: some View {
        NavigationSplitView { SidebarView(router: router) } content: { ContentColumn(router: router) } detail: { DetailHost(router: router) }
            .inspector(isPresented: $router.isInspectorPresented) { InspectorView(selection: router.inspectorSelection) }
            .toolbar { V2Toolbar(router: router) }
    }
}
```

- [ ] **Step 4: Run GREEN and app build**

Run: `swift test --no-parallel --filter V2ShellSurfaceTests && swift build --target AstroToolApp`

Expected: PASS and successful build.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroUI Sources/AstroToolApp/AstroToolApp.swift Sources/AstroToolApp/Views/Commands.swift Tests/AstroUITests && git commit -m "feat: introduce the native V2 macOS shell"`

## Task 9: Replace first run with a three-state read-only onboarding

**Files:**
- Create: `Sources/AstroUI/Onboarding/LibraryWelcomeView.swift`
- Create: `Sources/AstroUI/Onboarding/FirstScanView.swift`
- Create: `Sources/AstroUI/Onboarding/FirstScanSummaryView.swift`
- Create: `Tests/AstroUITests/V2OnboardingTests.swift`
- Modify: `Sources/AstroUI/App/V2RootView.swift`

- [ ] **Step 1: Write failing onboarding store tests**

```swift
@Test func onboardingStartsWithoutPersonalDefaultsAndNeverRequestsMutation() async throws {
    let store = OnboardingStore(sessionFactory: .fixture())
    #expect(store.phase == .chooseLibrary)
    #expect(store.selectedRoot == nil)
    try await store.openAndScan(V2FixtureLibrary.make())
    #expect(store.phase.isSummary)
    #expect(store.accessMode == .readOnly)
    #expect(store.personalizationIsOptional)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter V2OnboardingTests`

Expected: compile failure.

- [ ] **Step 3: Implement onboarding states**

```swift
public enum OnboardingPhase: Equatable { case chooseLibrary, scanning(progress: Double?), summary(LibrarySnapshot), accessProblem(String) }
@MainActor @Observable public final class OnboardingStore { /* injected session factory, read-only open, skip/personalize */ }
```

The UI has one dominant library action, drag/drop, clear local/read-only text, partial scan progress, and an optional personalization action. No camera, path, filter, site or weather default is prefilled.

- [ ] **Step 4: Run GREEN and manifest guard**

Run: `swift test --no-parallel --filter V2OnboardingTests && swift test --no-parallel --filter LibraryManifestTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroUI/Onboarding Sources/AstroUI/App/V2RootView.swift Tests/AstroUITests && git commit -m "feat: add read only V2 onboarding"`

## Task 10: Add deterministic UI-test application mode

**Files:**
- Create: `project.yml`
- Create: `UITests/AstroToolUITests/AstroToolLaunchTests.swift`
- Create: `Sources/AstroUI/PreviewSupport/V2PreviewFixtures.swift`
- Create: `Tests/AstroCoreTests/V2UITestHarnessSurfaceTests.swift`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write failing harness guard**

```swift
@Test func UIHarnessRejectsRealLibraries() throws {
    let source = try Source.read("Sources/AstroUI/PreviewSupport/V2PreviewFixtures.swift")
    #expect(source.contains("-UITestFixtureRoot"))
    #expect(source.contains("/Volumes/images"))
    #expect(source.contains("refuseRealLibrary"))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter V2UITestHarnessSurfaceTests`

Expected: FAIL because harness is absent.

- [ ] **Step 3: Implement XcodeGen project and fixture-only launch**

The XCUITest target launches with `-UseV2UI -UITestFixtureRoot <temporary path> -UITestAppSupport <temporary path>`. The app must terminate with a clear test error if the fixture resolves to `/Volumes/images`, the user's home Astro folder, or any non-temporary root.

```swift
func refuseRealLibrary(_ url: URL) throws {
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(FileManager.default.temporaryDirectory.path + "/"), !path.hasPrefix("/Volumes/images") else {
        throw FixtureError.nonTemporaryLibrary(path)
    }
}
```

- [ ] **Step 4: Generate and run smoke**

Run: `xcodegen generate && xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS' -only-testing:AstroToolUITests/AstroToolLaunchTests`

Expected: app launches into V2 fixture mode and the six sidebar destinations are hittable.

- [ ] **Step 5: Run full foundation gate**

Run: `swift test --no-parallel && swift build --target AstroToolApp && git diff --check`

Expected: 1565 baseline tests plus all new tests PASS.

- [ ] **Step 6: Commit**

Run: `git add project.yml UITests Sources/AstroUI/PreviewSupport Tests/AstroCoreTests/V2UITestHarnessSurfaceTests.swift .github/workflows/ci.yml && git commit -m "test: add deterministic V2 UI automation"`
