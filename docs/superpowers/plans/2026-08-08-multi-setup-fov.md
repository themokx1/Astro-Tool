# Több képalkotó setup és kézi látómező Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Névvel menthető fix és zoom képalkotó setupokból számolt, a Felfedezésben választható látómező hozzáadása, WCS-fallback megtartásával.

**Architecture:** Az AstroCore új `ImagingSetupProfile` értéktípusa tárolja és számolja a fizikai setupadatokat; az `AstroConfig` additív listában perzisztálja őket. Az AppState a felhasználó setup- és zoomválasztását UserDefaultsban tartja, a Felfedezés pedig egyetlen feloldott FOV-ot ad tovább a meglévő `DiscoveryPlanner`-nek.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI/macOS 14, Foundation, Swift Package Manager.

---

### Task 1: Setupmodell és config-kompatibilitás

**Files:**
- Create: `Sources/AstroCore/Sky/ImagingSetup.swift`
- Modify: `Sources/AstroCore/Config/AstroConfig.swift`
- Create: `Tests/AstroCoreTests/ImagingSetupTests.swift`
- Modify: `Tests/AstroCoreTests/ConfigTests.swift`

- [x] **Step 1: Write the failing model tests**

Add tests that construct fixed and zoom profiles, assert `clampedFocalLengthMM`, `fieldOfView(at:)`, `isZoom`, and `defaultSetup(in:)`. Use these numeric fixtures:

```swift
let apsc = ImagingSetupProfile(
    id: "apsc", name: "APS-C astro 100–400", cameraName: "APS-C astro kamera",
    cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.7,
    focalLengthMinMM: 100, focalLengthMaxMM: 400,
    defaultFocalLengthMM: 200, isDefault: true
)
#expect(apsc.isZoom)
#expect(apsc.clampedFocalLengthMM(500) == 400)
#expect(apsc.clampedFocalLengthMM(50) == 100)
```

- [x] **Step 2: Run the model tests and verify RED**

Run: `swift test --filter ImagingSetupTests`

Expected: compilation failure because `ImagingSetupProfile` and `CameraKind` do not exist.

- [x] **Step 3: Implement the minimal setup model**

Create public Codable/Equatable/Sendable types with:

```swift
public enum CameraKind: String, Codable, CaseIterable, Sendable {
    case dedicatedAstro, unmodifiedColor, modifiedColor, monochrome
}

public struct SetupFieldOfView: Equatable, Sendable {
    public var widthDeg: Double
    public var heightDeg: Double
}

public struct ImagingSetupProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var cameraName: String
    public var cameraKind: CameraKind
    public var sensorWidthMM: Double
    public var sensorHeightMM: Double
    public var focalLengthMinMM: Double
    public var focalLengthMaxMM: Double
    public var defaultFocalLengthMM: Double
    public var isDefault: Bool

    public var isZoom: Bool { abs(focalLengthMaxMM - focalLengthMinMM) > 0.000_001 }

    public func clampedFocalLengthMM(_ proposed: Double?) -> Double {
        min(max(proposed ?? defaultFocalLengthMM, focalLengthMinMM), focalLengthMaxMM)
    }

    public func fieldOfView(at proposed: Double? = nil) -> SetupFieldOfView? {
        let focal = clampedFocalLengthMM(proposed)
        guard sensorWidthMM > 0, sensorHeightMM > 0,
              focalLengthMinMM > 0, focalLengthMaxMM >= focalLengthMinMM,
              focal > 0 else { return nil }
        let width = 2 * atan(sensorWidthMM / (2 * focal)) * 180 / .pi
        let height = 2 * atan(sensorHeightMM / (2 * focal)) * 180 / .pi
        return SetupFieldOfView(widthDeg: width, heightDeg: height)
    }
}
```

Add a deterministic `defaultSetup(in:)` helper: flagged setup first, otherwise first list element.

- [x] **Step 4: Add config decode/round-trip tests and verify RED**

Assert that `{}` decodes to `imagingSetups == []`, and that an encoded/decode config preserves a three-profile list including camera kind and zoom bounds.

Run: `swift test --filter ConfigTests`

Expected: compilation failure because `AstroConfig.imagingSetups` does not exist.

- [x] **Step 5: Add `imagingSetups` to AstroConfig and verify GREEN**

Add the property, initializer parameter, CodingKey, assignment, and backward-compatible `decodeIfPresent(... ) ?? []` decode.

Run: `swift test --filter 'ImagingSetupTests|ConfigTests'`

Expected: all selected tests pass.

- [x] **Step 6: Commit Task 1**

```bash
git add Sources/AstroCore/Sky/ImagingSetup.swift Sources/AstroCore/Config/AstroConfig.swift Tests/AstroCoreTests/ImagingSetupTests.swift Tests/AstroCoreTests/ConfigTests.swift
git commit -m "feat: add configurable imaging setup model"
```

### Task 2: Kézi setup elsőbbsége és WCS-fallback

**Files:**
- Modify: `Sources/AstroCore/Sky/FieldGeometry.swift`
- Modify: `Tests/AstroCoreTests/FieldGeometryTests.swift`

- [x] **Step 1: Write failing selection tests**

Add tests for a new resolver:

```swift
let fov = try #require(try FieldGeometry.discoveryFOV(
    db: db, config: config, setupID: "r8-16", focalLengthMM: 16
))
#expect(abs(fov.widthDeg - 96.73) < 0.1)
#expect(abs(fov.heightDeg - 73.74) < 0.1)
```

Cover selected profile, missing ID falling back to configured default, and empty `imagingSetups` falling back to the existing `dominantFOV` result.

- [x] **Step 2: Run and verify RED**

Run: `swift test --filter FieldGeometryTests`

Expected: compilation failure because `discoveryFOV` does not exist.

- [x] **Step 3: Implement the resolver**

Add:

```swift
public static func discoveryFOV(
    db: Database,
    config: AstroConfig,
    setupID: String?,
    focalLengthMM: Double?
) throws -> (widthDeg: Double, heightDeg: Double)?
```

Resolve exact ID, then configured default/first. If a configured profile exists, return its calculated FOV; only call `dominantFOV` when the config list is empty.

- [x] **Step 4: Verify GREEN and regression**

Run: `swift test --filter FieldGeometryTests`

Expected: all FieldGeometry tests pass, including the old dominant-WCS tests.

- [x] **Step 5: Commit Task 2**

```bash
git add Sources/AstroCore/Sky/FieldGeometry.swift Tests/AstroCoreTests/FieldGeometryTests.swift
git commit -m "feat: resolve discovery FOV from configured setup"
```

### Task 3: AppState setup- és zoomválasztás

**Files:**
- Modify: `Sources/AstroToolApp/AppState.swift`

- [x] **Step 1: Add observable persisted selection state**

Add UserDefaults keys and stored observable properties for the selected setup ID and a JSON-encoded `[String: Double]` map of last planning focal lengths. Add computed values:

```swift
var effectiveImagingSetup: ImagingSetupProfile? {
    config.imagingSetups.first { $0.id == selectedImagingSetupID }
        ?? ImagingSetupProfile.defaultSetup(in: config.imagingSetups)
}

var effectiveDiscoveryFocalLengthMM: Double? {
    guard let setup = effectiveImagingSetup else { return nil }
    return setup.clampedFocalLengthMM(discoveryFocalLengthsBySetup[setup.id])
}
```

- [x] **Step 2: Route every discovery calculation through the resolver**

Capture the effective setup ID and focal length on the main actor, then replace all three direct `dominantFOV` calls used for Discovery with `FieldGeometry.discoveryFOV`.

- [x] **Step 3: Add selection mutation methods**

`selectImagingSetup(_:)` validates the ID, persists it, and reloads Discovery. `setDiscoveryFocalLengthMM(_:)` clamps and persists the applied value for the active setup; the popover keeps slider/text edits in a local draft and triggers one reload only on explicit Apply.

- [x] **Step 4: Compile the app target**

Run: `swift build --target AstroToolApp`

Expected: build succeeds.

- [x] **Step 5: Commit Task 3**

```bash
git add Sources/AstroToolApp/AppState.swift
git commit -m "feat(app): persist discovery setup selection"
```

### Task 4: Beállítások ▸ Felszerelés szerkesztő

**Files:**
- Create: `Sources/AstroToolApp/Views/Settings/EquipmentSettingsView.swift`
- Modify: `Sources/AstroToolApp/Views/SettingsWindow.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`

- [x] **Step 1: Add the settings route and tab shell**

Add `.equipment` to `SettingsTab`, then insert `EquipmentSettingsView()` with tab label `Felszerelés`. Increase the settings window only as much as the native form needs.

- [x] **Step 2: Implement draft list and editor**

Use draft UUID identity, a list summary, add/edit/delete/default controls, and a sheet editor. Provide sensor presets for 23.5×15.7, 22.3×14.9, 36×24, and custom. Fixed mode writes min=max=default; zoom mode exposes min/max/default fields.

- [x] **Step 3: Implement concrete validation and save**

Reject empty/duplicate names, empty camera, non-positive dimensions/focal lengths, inverted zoom bounds, and default focal length outside the range. Normalize exactly one default, save with `WriteGuard`, update `appState.config`, reconcile deleted selections, and reload Discovery if it was already loaded.

- [x] **Step 4: Build the app**

Run: `swift build --target AstroToolApp`

Expected: build succeeds with no SwiftUI generic or concurrency errors.

- [x] **Step 5: Commit Task 4**

```bash
git add Sources/AstroToolApp/Views/Settings/EquipmentSettingsView.swift Sources/AstroToolApp/Views/SettingsWindow.swift Sources/AstroToolApp/AppState.swift
git commit -m "feat(app): add imaging setup settings"
```

### Task 5: Felfedezés setupválasztó és FOV-üres állapot

**Files:**
- Modify: `Sources/AstroToolApp/Views/DiscoveryPage.swift`

- [x] **Step 1: Add the setup Picker**

When profiles exist, show a compact Picker bound through `appState.selectImagingSetup`. Its labels use the profile name and camera, while the control label stays short enough for the existing toolbar.

- [x] **Step 2: Add zoom planning control**

For `effectiveImagingSetup.isZoom`, show a compact popover/menu containing a bounded Slider, numeric mm field/Stepper, min/max labels, and an explicit `Alkalmazás és újraszámítás` action. Fix lenses show only the focal length in the setup caption.

- [x] **Step 3: Make the FOV tile actionable and truthful**

Show the manual setup name plus current mm as caption. If neither manual nor WCS FOV exists, show `n/a`, „nincs kézi setup vagy WCS-adat”, and a `Setup beállítása…` action that routes to `.equipment` before opening Settings. Update metric help to describe manual-first/WCS-fallback behavior.

- [x] **Step 4: Build and smoke-test**

Run: `swift build --target AstroToolApp`

Expected: build succeeds.

- [x] **Step 5: Commit Task 5**

```bash
git add Sources/AstroToolApp/Views/DiscoveryPage.swift
git commit -m "feat(app): select setup and focal length in discovery"
```

### Task 6: Teljes ellenőrzés és dokumentáció

**Files:**
- Modify: `README.md` if it has a user-facing feature list/config example section
- Modify: `docs/superpowers/plans/2026-08-08-multi-setup-fov.md`

- [x] **Step 1: Run format/static diff checks**

Run: `git diff --check`

Expected: no output.

- [x] **Step 2: Run the full test suite**

Run: `swift test`

Expected: all tests pass.

- [x] **Step 3: Run debug and release builds**

Run: `swift build --target AstroToolApp`

Run: `swift build -c release --target AstroToolApp`

Expected: both builds succeed.

- [x] **Step 4: Update user documentation and plan checkboxes**

Document the Felszerelés setup workflow and examples without changing the user's existing config automatically. Mark completed plan items.

- [x] **Step 5: Request code review, fix findings, and re-run verification**

Review model validation, config compatibility, every Discovery load path, selection fallback, SwiftUI bindings, and accidental changes to the untracked audit report.

- [x] **Step 6: Commit verification/docs**

```bash
git add README.md docs/superpowers/plans/2026-08-08-multi-setup-fov.md
git commit -m "docs: explain multi-setup FOV workflow"
```
