# AstroTool V3 First Steps Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a new, linked, responsive First Steps page that mirrors the app onboarding and its copy-only safety model.

**Architecture:** Add `docs/first-steps.html` to the existing shared static design system, keep `tutorial.html` as a compatibility bridge, and update every public entry point to the new canonical page. Surface tests pin navigation, truthful safety copy, accessibility, and V3 identity.

**Tech Stack:** Semantic HTML, existing `docs/assets/site.css`, minimal existing JavaScript, Swift Testing source-surface tests.

**Spec:** `docs/superpowers/specs/2026-08-20-v3-first-success-onboarding-design.md`

## Global Constraints

- The page is for non-technical users and leads with outcomes, not paths.
- It must show the three exact onboarding choices.
- It must state repeatedly that import copies and leaves sources unchanged.
- It must not promise deletion, source cleanup, or overwrite behavior.
- It must use the shared site stylesheet and work with reduced motion and dark mode.

---

### Task 1: Pin the new public surface

**Files:**
- Modify: `Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift`
- Modify: `scripts/check-public-content.sh`

**Interfaces:**
- Produces: checks requiring `docs/first-steps.html`, canonical navigation, the three choices, copy-only/source-unchanged/no-standalone-delete statements, and V3 stable identity.

- [ ] **Step 1: Add failing website tests**

Add `first-steps.html` to the shared-design page list. Assert the exact three Hungarian choice labels and phrases equivalent to `csak másolatot készít`, `a forrásaid változatlanok maradnak`, and `nincs önálló törlés`.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --no-parallel --filter PublicWebsiteSurfaceTests && scripts/check-public-content.sh`

- [ ] **Step 3: Commit the red test**

```bash
git add Tests/AstroCoreTests/PublicWebsiteSurfaceTests.swift scripts/check-public-content.sh
git commit -m "test: define the V3 first-steps website"
```

### Task 2: Build the new First Steps story

**Files:**
- Create: `docs/first-steps.html`
- Modify: `docs/assets/site.css`

**Interfaces:**
- Consumes: existing site header/footer/card/step/callout styles.
- Produces: semantic sections `choices`, `library-map`, `create`, `import`, `verify`, `reopen`.

- [ ] **Step 1: Create the semantic page**

Use one H1, ordered workflow sections, a three-choice card group, an accessible conceptual library tree, a persistent-style safe callout, and a final stable-download action. Keep raw folder paths inside a `<details>` element titled `Mi jön létre a gépemen?`.

- [ ] **Step 2: Extend the shared design deliberately**

Add only reusable `.choice-grid`, `.choice-card`, `.library-path`, and `.safety-strip` rules. Use the existing color variables, visible focus styles, single-column narrow layout, and a reduced-motion override.

- [ ] **Step 3: Verify HTML and surface tests**

Run: `swift test --no-parallel --filter PublicWebsiteSurfaceTests && scripts/check-public-content.sh`

- [ ] **Step 4: Commit**

```bash
git add docs/first-steps.html docs/assets/site.css
git commit -m "docs: add guided V3 first steps page"
```

### Task 3: Link every public entry point and preserve old URLs

**Files:**
- Modify: `docs/index.html`
- Modify: `docs/features.html`
- Modify: `docs/cli.html`
- Modify: `docs/privacy.html`
- Modify: `docs/support.html`
- Modify: `docs/tutorial.html`
- Modify: `README.md`
- Modify: `Sources/AstroCore/Product/ProductInfo.swift`
- Modify: `Tests/AstroCoreTests/ProductInfoTests.swift`

**Interfaces:**
- Produces: canonical First Steps URL `https://themokx1.github.io/Astro-Tool/first-steps.html` and compatibility navigation from `tutorial.html`.

- [ ] **Step 1: Add failing link assertions**

Assert the homepage nav and primary onboarding action use `first-steps.html`, ProductInfo exposes the same URL, and no maintained public page uses `tutorial.html` as the primary First Steps link.

- [ ] **Step 2: Update links and V3 wording**

Change the site identity from 2.0 to 3.0 where it describes the current product. Turn `tutorial.html` into a concise accessible compatibility page with a normal link and immediate meta refresh to `first-steps.html`; do not use JavaScript-only redirection.

- [ ] **Step 3: Verify all public content**

Run: `swift test --no-parallel --filter PublicWebsiteSurfaceTests && swift test --no-parallel --filter ProductInfoTests && scripts/check-public-content.sh`

- [ ] **Step 4: Commit**

```bash
git add docs README.md Sources/AstroCore/Product/ProductInfo.swift Tests/AstroCoreTests/ProductInfoTests.swift
git commit -m "docs: link the V3 first-success guide"
```

