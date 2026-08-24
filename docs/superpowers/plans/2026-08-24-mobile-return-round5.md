# Mobile Return Round 5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use inline execution with red-green test cycles; this task explicitly forbids delegation.

**Goal:** Close the public authorization, compare-and-set, cross-window persistence, marker authority, chronology, and mobile lifecycle gaps identified in `task-7-review-round5.md`.

**Architecture:** The public return path will own the authenticated capability and published-base validation, while internal domain bridges perform only closed typed mutations. Normal Mac editors will compare their loaded revisions inside the same persistence transaction. Durable ledgers and sent bases will reload under a process-wide lock for each mutation.

**Tech Stack:** Swift 6, SwiftPM Testing, SQLite, SwiftUI, Xcode project generation.

**Spec:** `.superpowers/sdd/2026-08-23-v5-airdrop-companion-wave1/task-7-review-round5.md`

## Global Constraints

- Preserve the already reviewed package-purpose, no-overwrite, and confirmation closures.
- Domain mutation and an owner/payload-bound change marker share one atomic store operation.
- Public callers never receive a raw mutation hook or a reusable authenticated capability.
- Every behavioral production change starts with a focused failing test.

### Task 1: Stale ordinary Mac saves

**Files:** `NightBriefingStore.swift`, `MetadataStore.swift`, `ProjectsStore.swift`, their UI/application tests.

- [ ] Write red tests where a phone revision wins after a Mac editor loaded a briefing/project annotation.
- [ ] Replace ordinary save paths with loaded-revision compare-and-set inside the immutable-file/SQLite transaction.
- [ ] Reload and surface the conflict without dropping phone IDs/markers.
- [ ] Run focused tests green.

### Task 2: Return authorization and durable evidence

**Files:** mobile-sync application stores, importer/receipt/sent-snapshot tests.

- [ ] Write red coordinator tests for copied/discarded capability and unpublished base refusal.
- [ ] Put capability lifetime, current-base validation, publication state, and acknowledgement pruning behind the coordinator/store transaction.
- [ ] Reload every ledger/sent-base transaction under a process-wide lock and bound encoded bytes before mutation.
- [ ] Run focused tests green.

### Task 3: Atomic markers and truthful batching

**Files:** domain bridge, metadata schema/models, importer and tests.

- [ ] Write red tests for cross-owner/payload marker collision, duplicate chronology, invalid latest records, and A-B-A ordering.
- [ ] Persist owner/payload/result markers atomically; scan all owners before applying; preflight final receipt/ledger.
- [ ] Order grouped batches by their effective last phone change and return only durable partial totals.
- [ ] Run focused tests green.

### Task 4: Mobile return UX/localization lifecycle

**Files:** `AstroToolMobile`, mobile UI tests/resources/audit.

- [ ] Write red lifecycle tests for task generation/cancellation and placeholder identity replacement.
- [ ] Prevent stale task UI mutation, expose progress/cancel state, and use retained placeholder identity or refuse deletion.
- [ ] Add EN/HU parity and required accessibility identifiers/labels.
- [ ] Run focused/static graph checks green.

### Task 5: Verification and handoff

- [ ] Run focused suites, full SwiftPM test suite, localization audit, graph check, real macOS AstroTool build, and diff check.
- [ ] Update `task-7-report.md` with only observed evidence; leave iOS runtime as an external gate.
- [ ] Commit the verified changes.
