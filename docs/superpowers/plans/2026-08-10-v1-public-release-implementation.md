# AstroTool 1.0 Public Release Implementation Plan

> **For Codex:** Execute in order with test-driven development. Keep every user-owned file outside this worktree untouched. Do not publish externally without explicit authorization for the exact destination.

**Goal:** Turn the verified v0.16 feature baseline into a clean-install, user-neutral, stable AstroTool 1.0 product, redesign the macOS first-run/shell/settings experience and website, then build and locally install verified release artifacts.

**Architecture:** Preserve AstroCore's tested astrophotography workflows and database schema. Add small pure product/release primitives to AstroCore, keep user preference migration at the app boundary, make root selection explicit, and standardize app surfaces through shared SwiftUI components. The release script has two explicit modes: local ad-hoc and public Developer ID + notarization. The static site uses shared CSS/JS and synthetic product data only.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, SQLite, Swift Package Manager, POSIX shell, static HTML/CSS/JS, GitHub Actions, macOS codesign/notarytool.

---

## Task 1: Establish one product identity and version source

**Files:**

- Create: `Sources/AstroCore/Product/ProductInfo.swift`
- Create: `Tests/AstroCoreTests/ProductInfoTests.swift`
- Modify: `Sources/astrotool/main.swift`
- Modify: `Sources/AstroCore/Export/TargetReport.swift`
- Modify: `build.sh`

1. Add failing tests requiring product name `AstroTool`, semantic version `1.0.0`, public bundle ID `io.github.themokx1.AstroTool`, legacy bundle ID `com.zoltanpalotai.astrotool`, and a numeric build version.
2. Add a source-surface assertion that CLI, report and build script read/parse `ProductInfo` rather than carrying release literals.
3. Run the focused tests and confirm failure.
4. Implement `ProductInfo` as the only committed version/identity definition.
5. Make `astrotool --version`, report footer and `build.sh` derive from it.
6. Run focused tests and `git diff --check`.
7. Commit: `feat: establish AstroTool 1.0 product identity`.

## Task 2: Remove personal fresh-install state and migrate v0.x safely

**Files:**

- Create: `Sources/AstroCore/Product/PreferenceMigration.swift`
- Create: `Tests/AstroCoreTests/PreferenceMigrationTests.swift`
- Modify: `Sources/AstroCore/Config/AstroConfig.swift`
- Modify: `Tests/AstroCoreTests/ConfigTests.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `Sources/AstroToolApp/AstroToolApp.swift`
- Modify: `Tests/AstroCoreTests/OnboardingTests.swift`

1. Change the config expectation first: fresh `AstroConfig().rootPath` is empty, while decoded legacy configs preserve their explicit path.
2. Add pure migration tests for allowlisted keys, idempotence, non-overwrite of new values, no legacy-domain deletion, and exclusion of unknown/sensitive keys.
3. Add startup source tests requiring bookmark-free launch to choose `.noRoot` without calling `openRoot` on a fabricated path.
4. Run focused tests and confirm failure.
5. Implement the empty root default and clear CLI error for root-required commands.
6. Implement one-time migration from the legacy preference domain into the new domain before root resolution. Inject/centralize the `UserDefaults` store sufficiently for isolated tests; never migrate bookmark payload into diagnostics.
7. Keep `-ResetOnboarding`, but scope it to onboarding state only; do not delete the real library bookmark during ordinary UX testing.
8. Run focused tests.
9. Commit: `fix: make fresh install user neutral`.

## Task 3: Redesign first run and remove personal presets

**Files:**

- Modify: `Sources/AstroToolApp/AstroToolApp.swift`
- Modify: `Sources/AstroToolApp/Views/WelcomeView.swift`
- Modify: `Sources/AstroToolApp/Views/FirstScanView.swift`
- Modify: `Sources/AstroToolApp/Views/OnboardingWizardView.swift`
- Modify: `Sources/AstroToolApp/Views/FolderStructureHelpSheet.swift`
- Create: `Tests/AstroCoreTests/PublicFirstRunSurfaceTests.swift`

1. Add failing source-surface tests proving no Canon R8, SV220, personal focal range or `/Volumes/images` appears in production first-run sources.
2. Require the welcome surface to explain local processing, explicit selection and read-only first scan, with one prominent folder action and accessible drop target.
3. Require automatic detailed onboarding to be removed; the explicit wizard remains reachable after library selection and from Settings.
4. Require equipment drafts to start empty. Add only explicitly selected generic APS-C/full-frame sensor presets with neutral names and no brand/model/filter.
5. Add a first-scan result action for optional personalization and ensure every wizard page stays skippable.
6. Implement the views using native controls, `ContentUnavailableView` where appropriate, keyboard defaults and VoiceOver labels.
7. Run focused tests and build the app target.
8. Commit: `feat: deliver clean optional first run`.

## Task 4: Add a coherent native product surface and settings information architecture

**Files:**

- Create: `Sources/AstroToolApp/Views/ProductStyle.swift`
- Modify: `Sources/AstroToolApp/Views/SharedComponents.swift`
- Modify: `Sources/AstroToolApp/Views/MainShellView.swift`
- Modify: `Sources/AstroToolApp/Views/SidebarView.swift`
- Modify: `Sources/AstroToolApp/Views/SettingsWindow.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: selected settings views under `Sources/AstroToolApp/Views/Settings/`
- Create: `Tests/AstroCoreTests/ProductSurfaceTests.swift`

1. Add surface tests for shared spacing/radius/style tokens, responsive minimum sizing, labeled state chips, and a sidebar-based Settings layout with all required categories.
2. Implement a small design system built from system colors/materials, SF Symbols and native typography; do not introduce a custom imitation of Apple assets.
3. Rework shared stat tiles, section headers, empty/error surfaces and chips to use the same hierarchy and avoid color-only state.
4. Replace the crowded settings tab strip with an inset sidebar and detail pane: Általános, Könyvtár, Helyszínek, Felszerelések, Szűrők, Minőség és kalibráció, Adatvédelem és támogatás. Preserve all existing controls and routing entry points.
5. Restore the last main page/settings category through non-sensitive preferences.
6. Verify the app still builds and run surface tests.
7. Commit: `feat: unify the macOS product experience`.

## Task 5: Add private-by-design support diagnostics and About metadata

**Files:**

- Create: `Sources/AstroCore/Support/SupportDiagnostics.swift`
- Create: `Tests/AstroCoreTests/SupportDiagnosticsTests.swift`
- Create: `Sources/AstroToolApp/Views/Settings/SupportSettingsView.swift`
- Modify: `Sources/AstroToolApp/Views/Commands.swift`
- Modify: `Sources/AstroToolApp/Views/SettingsWindow.swift`
- Modify: `Sources/AstroToolApp/AppState.swift`
- Modify: `build.sh`

1. Add failing diagnostics tests covering version/platform/schema/counts and redaction of root paths, coordinates, notes, bookmarks, file names and secrets.
2. Implement a Codable/text support snapshot that accepts already-aggregated safe fields only.
3. Add an Adatvédelem és támogatás page: local-processing explanation, opt-in weather disclosure, version/build, copy diagnostics, save support report and open documentation.
4. Give Info.plist complete About metadata: category, copyright, human-readable version and document/help URLs where supported.
5. Add a standard Help/About command path without adding telemetry or automatic upload.
6. Run focused tests and app build.
7. Commit: `feat: add privacy safe support diagnostics`.

## Task 6: Create production-grade build, signing and notarization lanes

**Files:**

- Modify: `build.sh`
- Create: `scripts/release.sh`
- Create: `scripts/check-public-content.sh`
- Create: `scripts/smoke-clean-install.sh`
- Create: `Tests/AstroCoreTests/ReleasePipelineTests.swift`
- Modify: `.github/workflows/release.yml`
- Create/modify: `.github/workflows/ci.yml`

1. Add failing release-pipeline tests/surface checks requiring universal architecture, explicit local/public modes, hardened runtime + timestamp for Developer ID, `notarytool`, stapling, `spctl`, checksums and tag/version consistency.
2. Implement universal SwiftPM build and verify both `arm64` and `x86_64` slices before packaging.
3. Keep `build.sh` safe for local ad-hoc builds and label the result; remove automatic writes to `~/Applications` and repo-following CLI symlinks from the build step.
4. Implement `scripts/release.sh`: public mode hard-fails without `ASTROTOOL_SIGNING_IDENTITY` and a configured notary keychain profile; signs nested CLI then app with hardened runtime/timestamp, verifies, creates DMG/ZIP, notarizes, staples, Gatekeeper-checks and emits SHA-256 manifest.
5. Implement clean-install smoke with an isolated defaults suite and temporary empty library, proving no personal state is created.
6. Add CI placeholder/content scan and release gates. Do not place credentials in the repository.
7. Run focused tests and a local universal build.
8. Commit: `build: harden AstroTool 1.0 distribution`.

## Task 7: Rebuild the website as a real product site

**Files:**

- Create: `docs/assets/site.css`
- Create: `docs/assets/site.js`
- Modify: `docs/index.html`
- Modify: `docs/features.html`
- Modify: `docs/tutorial.html`
- Modify: `docs/cli.html`
- Create: `docs/privacy.html`
- Create: `docs/support.html`
- Create: `Tests/AstroCoreTests/WebsiteSurfaceTests.swift`

1. Add failing HTML/source tests for one shared stylesheet, semantic landmarks, skip links, visible focus, reduced motion, responsive breakpoints, current version/system requirement, privacy/support pages and no personal paths/metrics.
2. Build the new landing page with product navigation, concise hero, synthetic CSS app mockup, three-part workflow, local-first security section, feature stories, install/release status and documentation footer.
3. Remove emoji as the primary icon system, the decorative starfield, personal-library marketing statistics and unnotarized right-click instructions from the primary flow.
4. Refactor documentation pages onto the shared visual system while preserving their useful content and stable URLs.
5. Add privacy/support pages matching actual app behavior.
6. Validate HTML links and render desktop/mobile screenshots for visual QA. Inspect the images and correct overflow, contrast and hierarchy problems.
7. Commit: `feat: redesign the AstroTool website`.

## Task 8: Release documentation and public-content audit

**Files:**

- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Create: `docs/releases/v1.0.0.md`
- Modify: `docs/index.html`
- Modify: `.github/workflows/release.yml`

1. Add release-note checks requiring install, migration, privacy, system requirements, signing/notarization status and full feature summary.
2. Rewrite README quick start around folder selection; replace `/Volumes/images/Astro` examples with neutral `/path/to/AstroLibrary` or `$ASTRO_LIBRARY` examples.
3. Document local build versus notarized public release without presenting the local ad-hoc package as a public-quality artifact.
4. Run `scripts/check-public-content.sh` over production code, site, README, package metadata and release notes. Historical design docs/tests may contain legacy examples only through an explicit allowlist.
5. Commit: `docs: prepare AstroTool 1.0 release`.

## Task 9: Full regression, clean-room and visual verification

**Files:**

- Update only defects found by verification.

1. Run `swift test --no-parallel` and record the exact pass count.
2. Run `swift build -c release --arch arm64 --arch x86_64` (or the implemented wrapper) and verify slices with `lipo -archs`.
3. Run the public-content scan and clean-install smoke.
4. Verify app/embedded CLI versions, bundle ID, Info.plist, code signature integrity, DMG contents, ZIP entries and checksums.
5. Launch the isolated fresh-install build and the real migrated library build separately; verify no crash across Welcome, first scan, Settings, every sidebar destination and support export.
6. Render and inspect the website at desktop and mobile widths.
7. Fix every release blocker test-first, then rerun the entire matrix.
8. Commit: `test: verify AstroTool 1.0 release candidate`.

## Task 10: Build, install and hand off the 1.0 release

**Files:**

- Update `docs/releases/v1.0.0.md` with final verification facts if needed.

1. Produce final local release artifacts from a clean worktree.
2. Back up the currently installed `/Applications/AstroTool.app` to a timestamped path under `/private/tmp`.
3. Install the verified 1.0 app into `/Applications`, update the local CLI copy/symlink deliberately, and launch it.
4. Verify the running executable path, app version, CLI version, bundle ID and signature.
5. Do not push, tag or create a GitHub release until the user explicitly authorizes the exact repository destination. Do not claim public notarization while no Developer ID identity/notary credential exists on the machine.
6. Report the installed local result, artifact/checksum paths, verification evidence and the single remaining external credential/authorization boundary, if any.

