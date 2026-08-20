# AstroTool 3.0.0 Stable Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify, package, install, tag, and publish AstroTool 3.0.0 as a real stable release rather than a beta.

**Architecture:** Promote the already universal V3 product to stable metadata only after the complete onboarding and website gates pass. Build through the existing release script, verify bundle identity and both architectures, install through the rollback-safe installer, then publish a signed/notarized GitHub release when credentials are available.

**Tech Stack:** SwiftPM/Xcode, shell release scripts, codesign/notarytool, DMG packaging, GitHub Actions/Releases.

**Spec:** `docs/superpowers/specs/2026-08-20-v3-first-success-onboarding-design.md`

## Global Constraints

- Version is exactly `3.0.0`, build exactly `30002`, release channel Stable.
- The app must contain `arm64` and `x86_64` slices.
- Stable publication requires successful tests, signing, and notarization.
- A missing signing identity or notary credential must be reported honestly; it must not be bypassed or described as a successful public release.
- Local installation must preserve a recoverable backup until post-install verification succeeds.

---

### Task 1: Stable metadata and release notes

**Files:**
- Modify: `Sources/AstroCore/Product/ProductInfo.swift`
- Modify: `Tests/AstroCoreTests/ProductInfoTests.swift`
- Modify: `Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift`
- Create: `docs/releases/v3.0.0.md`
- Modify: `scripts/check-release-metadata.sh`

**Interfaces:**
- Produces: `ProductInfo.version == "3.0.0"`, `build == 30002`, stable release channel, and release notes naming the first-success onboarding and copy-only guarantees.

- [ ] **Step 1: Write failing stable metadata tests**

Assert exact version/build/display version, no `beta` in public identity, and release notes containing `Új képkönyvtár létrehozása`, `Már van AstroTool-könyvtáram`, `Előbb szeretném megérteni`, verified copy, source unchanged, and no standalone deletion.

- [ ] **Step 2: Verify tests fail**

Run: `swift test --no-parallel --filter ProductInfoTests && swift test --no-parallel --filter ReleasePackagingSurfaceTests`

- [ ] **Step 3: Update metadata and write release notes**

Use stable version `3.0.0`, numeric build `30002`, and no prerelease label. Include system requirements, upgrade behavior, safety guarantees, and known signing status only from current evidence.

- [ ] **Step 4: Verify metadata checks pass**

Run: `swift test --no-parallel --filter ProductInfoTests && swift test --no-parallel --filter ReleasePackagingSurfaceTests && scripts/check-release-metadata.sh`

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroCore/Product/ProductInfo.swift Tests/AstroCoreTests/ProductInfoTests.swift Tests/AstroCoreTests/ReleasePackagingSurfaceTests.swift docs/releases/v3.0.0.md scripts/check-release-metadata.sh
git commit -m "release: prepare AstroTool 3.0.0"
```

### Task 2: Complete verification gate

**Files:**
- Verification only; fix any discovered regression in the owning source and test files with a focused red-green cycle before rerunning this gate.

**Interfaces:**
- Produces: fresh evidence for tests, public content, clean install behavior, and source immutability.

- [ ] **Step 1: Run the full test suite**

Run: `swift test --no-parallel`

Expected: zero failures.

- [ ] **Step 2: Run public and packaging checks**

Run: `scripts/check-public-content.sh && scripts/check-release-metadata.sh`

Expected: both scripts succeed.

- [ ] **Step 3: Run clean-install smoke**

Run: `scripts/smoke-clean-install.sh`

Expected: clean first launch succeeds without touching the fixture library before consent.

- [ ] **Step 4: Confirm clean worktree**

Run: `git status --short`

Expected: no output.

### Task 3: Build, sign, notarize, and inspect the universal artifacts

**Files:**
- Existing: `scripts/release.sh`
- Existing: `.github/workflows/release.yml`

**Interfaces:**
- Produces: stable `AstroTool-3.0.0.dmg` and application archive with verified bundle metadata and signatures.

- [ ] **Step 1: Audit signing prerequisites**

Run: `security find-identity -v -p codesigning` and inspect whether the configured notary profile exists without printing secrets.

Expected: a valid Developer ID Application identity and configured notary credentials. If absent, continue with local artifact verification and installation, but do not claim or publish a notarized stable release.

- [ ] **Step 2: Build the release artifacts**

Run: `scripts/release.sh`

Expected: the script completes with version 3.0.0 artifacts.

- [ ] **Step 3: Verify bundle version and architectures**

Inspect `CFBundleShortVersionString`, `CFBundleVersion`, `lipo -archs` for the app executable, `codesign --verify --deep --strict`, and `spctl --assess` when signing exists.

Expected: `3.0.0`, `30002`, both `arm64 x86_64`, valid signature, and accepted Gatekeeper assessment for the public artifact.

- [ ] **Step 4: Verify notarization**

Submit/wait through the existing release process and run `xcrun stapler validate` on both the app/DMG artifacts supported by the script.

Expected: accepted notarization and valid staple before public release.

### Task 4: Install and smoke-test the stable app

**Files:**
- Existing: `scripts/install-local.sh`

**Interfaces:**
- Consumes: verified local AstroTool 3.0.0 app artifact.
- Produces: `/Applications/AstroTool.app` version 3.0.0 with recoverable prior-app backup.

- [ ] **Step 1: Install with the rollback-safe installer**

Run: `scripts/install-local.sh <verified-app-path>`

Expected: installer reports verified version and architectures and preserves the previous app backup.

- [ ] **Step 2: Verify the installed bundle independently**

Inspect `/Applications/AstroTool.app/Contents/Info.plist`, executable architectures, and signature.

Expected: `3.0.0`, `30002`, `arm64 x86_64`, matching signature state.

- [ ] **Step 3: Launch smoke without disturbing an existing user process**

If no AstroTool process is already running, launch the installed build with an isolated temporary Application Support/cache and verify first-run presentation. If an older user process is running, do not terminate it; record installation verification without launch.

### Task 5: Stable GitHub publication

**Files:**
- Git/tag/release state only.

**Interfaces:**
- Produces: pushed `v3.0.0` tag and non-prerelease GitHub Release with signed/notarized assets.

- [ ] **Step 1: Push the release commit/branch**

Run: `git push origin codex/v2.0.0-ui-rework`

Expected: remote branch contains the verified stable commit.

- [ ] **Step 2: Create and push the stable tag**

Run: `git tag -a v3.0.0 -m "AstroTool 3.0.0"` then `git push origin v3.0.0`.

Expected: release workflow starts for the exact verified commit.

- [ ] **Step 3: Watch release CI and inspect assets**

Wait for the release workflow. Verify success, release is not marked prerelease, asset names/version match, and downloaded artifacts pass checksum/signature/notarization checks.

- [ ] **Step 4: Publish only after all gates**

If CI creates a draft, publish it after the checks above. If signing/notarization secrets are missing, leave publication blocked and report the exact missing external credential rather than uploading an unsigned artifact as a stable public macOS release.

