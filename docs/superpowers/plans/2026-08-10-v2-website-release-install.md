# AstroTool V2 Website, Release, and Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the public site around the real V2 product, produce verified Universal 2.0.0 artifacts, and install the locally verified app with rollback protection.

**Architecture:** Product identity remains centralized in `ProductInfo`. Public checks derive rather than duplicate version state. Clean-install and V1-import smoke tests run against temporary libraries and isolated app storage; the release pipeline fails closed when Developer ID or notarization credentials are unavailable.

**Tech Stack:** Swift 6, Swift Testing, static HTML/CSS/JS, shell, GitHub Actions, Universal binaries, codesign, DMG, notarytool.

---

## Task 1: Redesign the website around the V2 workflow

**Files:**
- Modify: `Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift`
- Modify: `docs/index.html`
- Modify: `docs/assets/site.css`
- Modify: `docs/assets/site.js`
- Modify: `docs/features.html`
- Modify: `docs/tutorial.html`
- Modify: `docs/cli.html`
- Modify: `docs/privacy.html`
- Modify: `docs/support.html`

- [ ] **Step 1: Write failing V2 website tests**

```swift
@Test func publicSiteTellsTheRealV2Story() throws {
    let index = try website("index.html")
    #expect(index.contains("Project → Night → Series → Frame → Result"))
    #expect(index.contains("Night Ribbon"))
    #expect(index.contains("synthetic"))
    #expect(index.contains("read-only"))
    #expect(!index.contains("Minden célpont"))
    #expect(!index.contains("Szenzor-profilok"))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter PublicWebsiteSurfaceTests`

Expected: FAIL on V1 copy/mockup.

- [ ] **Step 3: Implement the new site**

Use semantic landmarks, skip link, visible focus, reduced motion, light/dark, responsive layouts, system typography, one restrained indigo/cyan data accent, a synthetic V2 Project/Night/Series preview and Night Ribbon. Rewrite feature/tutorial/privacy/support copy to match Application Support storage and the explicit mutation model. Keep CLI URLs and commands truthful.

- [ ] **Step 4: Run GREEN and link check**

Run: `swift test --no-parallel --filter PublicWebsiteSurfaceTests && scripts/check-public-content.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add docs Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift && git commit -m "feat: redesign the AstroTool V2 website"`

## Task 2: Update social artwork and visually verify the site

**Files:**
- Modify: `docs/og-card.html`
- Modify: `icon/make_og.swift`
- Modify: `docs/og-image.jpg`
- Create: `docs/screenshots/v2-home.png`
- Create: `docs/screenshots/v2-night.png`

- [ ] **Step 1: Add failing dimensions/content guards**

Extend `PublicWebsiteSurfaceTests` to require 1200×630 social art source, V2 wording, synthetic-data marker, and no decorative starfield generator.

- [ ] **Step 2: Run RED, update generator, regenerate art**

Run the repository's Swift artwork generator, then verify dimensions with `sips -g pixelWidth -g pixelHeight docs/og-image.jpg`.

- [ ] **Step 3: Render browser matrix**

Serve `docs/` locally. Inspect 1440×900, tablet and 390px mobile in light/dark and reduced-motion modes. Correct overflow, contrast, hierarchy, focus and misleading release state.

- [ ] **Step 4: Commit**

Run: `git add docs/og-card.html docs/og-image.jpg icon/make_og.swift docs/screenshots Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift && git commit -m "design: align V2 social and product visuals"`

## Task 3: Switch product identity and documentation to 2.0.0

**Files:**
- Modify: `Tests/AstroCoreTests/ProductInfoTests.swift`
- Modify: `Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift`
- Modify: `Sources/AstroCore/Product/ProductInfo.swift`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Create: `docs/releases/v2.0.0.md`
- Modify: `scripts/check-public-content.sh`
- Modify: `scripts/check-release-metadata.sh`
- Modify: `build.sh`

- [ ] **Step 1: Write failing identity consistency tests**

Require exact version `2.0.0`, a numeric build, V2 release note, README/changelog/site mention, generated plist equality, CLI equality and report footer equality. Derive release-note path from `ProductInfo.version`.

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter ProductInfoTests && swift test --no-parallel --filter ReleasePackagingSurfaceTests`

Expected: FAIL on V1 identity.

- [ ] **Step 3: Update identity and public documentation**

Set `ProductInfo.version = "2.0.0"` and increment numeric build. Declare only localization that is genuinely complete. Release notes cover the new mental model, read-only storage, import, archive safety, system requirements, local ad-hoc versus signed/notarized status and exact verification facts.

- [ ] **Step 4: Run GREEN**

Run: `swift test --no-parallel --filter ProductInfoTests && swift test --no-parallel --filter ReleasePackagingSurfaceTests && scripts/check-public-content.sh && scripts/check-release-metadata.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add Sources/AstroCore/Product/ProductInfo.swift Tests README.md CHANGELOG.md docs/releases/v2.0.0.md scripts build.sh && git commit -m "release: prepare AstroTool 2.0.0 identity"`

## Task 4: Replace clean-install smoke and add V1-import smoke

**Files:**
- Modify: `scripts/smoke-clean-install.sh`
- Create: `scripts/smoke-v1-import.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift`

- [ ] **Step 1: Write failing release guards**

Require both smoke scripts, isolated Application Support/cache overrides, before/after manifest comparison, and explicit assertion that `.astro_tool` is not created or changed.

- [ ] **Step 2: Run RED**

Run: `swift test --no-parallel --filter ReleasePackagingSurfaceTests`

Expected: FAIL because V1 smoke expects a library-local DB and V1 import smoke is absent.

- [ ] **Step 3: Implement safe smoke scripts**

Both scripts create temporary fixture trees, temporary app-support/cache/defaults suites and trap cleanup. Clean smoke asserts no personal presets and no library changes. Import smoke copies a V1 fixture, captures SHA-256 manifest before/after, imports twice, proves idempotence, then compares bytes.

- [ ] **Step 4: Run GREEN**

Run: `scripts/smoke-clean-install.sh && scripts/smoke-v1-import.sh && swift test --no-parallel --filter ReleasePackagingSurfaceTests`

Expected: PASS.

- [ ] **Step 5: Commit**

Run: `git add scripts .github/workflows/ci.yml Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift && git commit -m "test: harden V2 clean install and migration"`

## Task 5: Harden local installation validation and rollback

**Files:**
- Modify: `scripts/install-local.sh`
- Modify: `Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift`

- [ ] **Step 1: Write failing installer guards**

Require post-copy bundle version, build, identifier, signature and embedded CLI verification. Require rollback to the timestamped previous app if any post-copy check fails. Require optional CLI symlink creation only with an explicit flag.

- [ ] **Step 2: Run RED and implement**

Run: `swift test --no-parallel --filter ReleasePackagingSurfaceTests`

After `ditto`, use PlistBuddy, embedded CLI `--version`, `codesign --verify --deep --strict` and `lipo -archs`. On failure move the bad destination to `/private/tmp/AstroTool.failed-install.<timestamp>.app` and restore the previous app.

- [ ] **Step 3: Run GREEN and shell syntax**

Run: `bash -n scripts/install-local.sh && swift test --no-parallel --filter ReleasePackagingSurfaceTests`

Expected: PASS.

- [ ] **Step 4: Commit**

Run: `git add scripts/install-local.sh Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift && git commit -m "build: verify and rollback V2 local installs"`

## Task 6: Execute the complete V2 release gate

**Files:**
- Modify only defects found by verification.

- [ ] **Step 1: Unit, application and UI tests**

Run: `swift test --no-parallel`

Run: `xcodegen generate && xcodebuild test -project AstroTool.xcodeproj -scheme AstroTool -destination 'platform=macOS'`

Expected: all tests PASS with no crash and no real-library access.

- [ ] **Step 2: Safety and public checks**

Run: `scripts/smoke-clean-install.sh && scripts/smoke-v1-import.sh && scripts/check-public-content.sh && scripts/check-release-metadata.sh && git diff --check`

Expected: PASS; manifest outputs prove bit equality.

- [ ] **Step 3: Build Universal artifacts**

Run: `./build.sh`

Expected artifacts:

```text
build/AstroTool.app
build/AstroTool-2.0.0.dmg
build/astrotool-2.0.0-macos-universal.zip
build/SHA256SUMS.txt
```

- [ ] **Step 4: Verify artifacts**

Run: `lipo -archs build/AstroTool.app/Contents/MacOS/AstroTool && lipo -archs build/AstroTool.app/Contents/Resources/astrotool && codesign --verify --deep --strict build/AstroTool.app && hdiutil verify build/AstroTool-2.0.0.dmg && unzip -l build/astrotool-2.0.0-macos-universal.zip && (cd build && shasum -a 256 -c SHA256SUMS.txt)`

Expected: arm64 and x86_64 are present, signature and archives verify, checksums are OK.

- [ ] **Step 5: Commit verification fixes**

Run: `git add -A && git commit -m "test: verify AstroTool 2.0.0 release candidate"`

Skip the commit only when verification changed no tracked file.

## Task 7: Install and verify AstroTool 2.0.0 locally

**Files:**
- No repository changes expected.

- [ ] **Step 1: Record the current installation**

Run PlistBuddy version/build/bundle checks and `codesign --verify` on `/Applications/AstroTool.app`; record the current CLI symlink target.

- [ ] **Step 2: Install with rollback protection**

Run: `scripts/install-local.sh`

Expected: prior app moved to a timestamped `/private/tmp/AstroTool.previous.*.app`; verified V2 copied to `/Applications/AstroTool.app`.

- [ ] **Step 3: Verify installed app and embedded CLI**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/AstroTool.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/AstroTool.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/AstroTool.app/Contents/Info.plist
/Applications/AstroTool.app/Contents/Resources/astrotool --version
codesign --verify --deep --strict /Applications/AstroTool.app
lipo -archs /Applications/AstroTool.app/Contents/MacOS/AstroTool
```

Expected: version `2.0.0`, correct build and bundle ID, CLI `2.0.0`, valid signature, arm64+x86_64.

- [ ] **Step 4: Launch isolated smoke, then normal app**

First launch with temporary preferences/app storage and a temporary fixture. Only after the no-mutation guard passes launch the installed app normally. Never pass `/Volumes/images` to automated launch.

- [ ] **Step 5: External release boundary**

Do not run `scripts/release.sh`, create/push tag `v2.0.0`, or publish a GitHub release unless Developer ID/notary credentials exist and the exact repository publication is authorized. A local ad-hoc release must be labeled accurately.
