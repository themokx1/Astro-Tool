# Task 6 Report — Native iPhone plan, briefing, and sync surfaces

## Design tokens and wireframe

- Dark-adaptation surface: system background plus a restrained deep-sky horizon band (`#0B1020`), cyan for current/connected state (`#5FE7F2`), amber for a stale plan, and system green only for completed checklist items.
- Tonight uses a vertical field-card flow: freshness band → human plan title/readiness → planned targets/warnings → grouped checklist → editable note.
- Projects uses a native grouped list with stable name/catalog/phase rows, defensive goal progress, and a detail list for image-set facts and project notes.
- Briefings uses a readable saved-plan list and document-like detail view with planned dates/times, targets, warnings, checklist, and effective note text.
- Sync is a safety/status page: freshness, human counts, queued phone changes, Task 5 import/scanner/recovery access, and the permanent original-photo promise.
- All controls use system materials, Dynamic Type-compatible fonts, native controls, and minimum 52pt checklist hit areas. The one custom visual risk is the quiet horizon band; no scattered animation or gradient spectacle was added.

Wireframe:

```text
Tonight       Projects       Briefings       Sync
┌──────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────┐
│ Plan from│  │ M31   M31  │  │ Aug 23 v1  │  │ Freshness    │
│ Mac · ...│  │ Ready 50% │  │ Ready      │  │ Counts       │
└──────────┘  └────────────┘  └────────────┘  │ Safety       │
Tonight's plan   detail         detail       │ Newer plan   │
Targets         image sets     Planned      └──────────────┘
Checklist       note           checklist
Your note                       note
```

## RED / GREEN evidence

The interaction contract test was added before the UI implementation. It covers the explicit 24-hour freshness boundary, latest queued checklist/note overlays, defensive project progress, and the two-method mutation allowlist. Xcode unit/UI runtime execution is blocked by the current account/CoreSimulator gate, so no XCTest runtime result is claimed here.

GREEN evidence available without that gate:

```text
xcodegen generate                                      # passed
swiftc -frontend -parse <mobile sources/tests>         # passed
swiftc -typecheck <all iOS mobile sources>             # passed against iOS 26 SDK
localization key parity (EN/HU)                        # passed
swift test --disable-sandbox --filter MobilePackageServiceTests --no-parallel
                                                       # 39 tests passed
git diff --check                                       # passed
```

The generated Xcode graph includes the four new app surfaces, `MobileInteractionTests.swift`, and the existing mobile UI-test target.

## State overlay and safety semantics

- The first three tabs read `MobileLibrarySnapshot` and receive the actor's queued typed changes as a separate overlay. The immutable snapshot is never rewritten by phone UI.
- Checklist controls call only `MobileLibraryStore.toggleChecklistItem`; note editors call only `MobileLibraryStore.editNote`. Successful store append is required before the root refreshes the effective state.
- Effective state folds the latest queued value for the same briefing/item or note ID, matching the store's no-op behavior after relaunch.
- Empty note text is retained as a blank revision; there is no trash/delete action.
- Project progress treats missing, zero, negative, nonfinite, and over-goal values defensively and never renders an invalid progress fraction.
- Sync explains queued changes as “Ready to send back in the next step” and never claims that return sync has happened.
- Task 5 staged import, scanner, recovery, durability warnings, and empty/import flow remain reachable. A staged update also appears as a nonintrusive global banner that selects Sync.

## Accessibility and localization

English and Hungarian tables have matching key sets. Stable identifiers include `v5.mobile.tab.today`, `.projects`, `.briefings`, `.sync`, `v5.mobile.checklist`, `v5.mobile.note`, `v5.mobile.note.save`, `v5.mobile.stale`, `v5.mobile.safety`, and `v5.mobile.import`. Checklist state is communicated by icon, text styling, and VoiceOver value; native controls retain system high-contrast behavior. Planned times are explicitly labelled “Planned” and use the device locale/time zone formatting.

The imported fixture now contains a real project, night, capture/image set, briefing, target warning, checklist item, and editable note. The UI journey navigates all four tabs, toggles a checklist item, edits a note, checks the queued-change explanation, and checks the safety promise. Existing empty-state English/Hungarian coverage remains.

## Visual self-critique

The shell stays intentionally quiet for outdoor use: one freshness signal, one vertical plan flow, and native grouped lists elsewhere. The fixture and stale-date behavior should be checked on a real device for Dynamic Type accessibility sizes and VoiceOver rotor order once the Xcode account/runtime gate is available. The current static pass cannot validate actual tab-bar hit targets, keyboard avoidance in the note editor, or contrast under every system appearance.

## Runtime gate / concerns

No Xcode build, simulator launch, XCTest execution, camera path, or UI-test runtime pass is claimed in this task. The host's current Xcode account/CoreSimulator gate blocks the fresh iOS build/runtime requested in the brief; it was not retried or escalated. The next verification should build the three mobile targets and run the focused unit/UI journeys on an available iOS 26.x runtime or Personal-Team device.

## Fix round 1 — reviewer closure

- Reconciled presentation with production mobile payload values: project phases `planned`, `collecting`, `processing`, `complete`, `archived`; briefing readiness `ready`, `attention`, `incomplete`; target roles `primary`, `backup`. The imported fixture now uses `collecting`, `ready`, and `primary`.
- Tonight selection is deterministic: local-today briefing first, then nearest upcoming plan, then most recent past plan, then most recently saved undated plan. The title says Tonight, Upcoming plan, Saved plan from the past, or Saved plan honestly.
- Planned date/time formatting resolves the matching `MobileNight.localDate` and `timeZoneID`; it never assumes the first night or silently chooses an unrelated zone.
- Scanner/import action errors are rendered in the root safe-area banner for both empty and existing-library states. Constructed dates, durations, progress values, VoiceOver states/hints, plan windows, revisions, and save errors use localized keys in both EN/HU tables.
- The horizon band now uses dynamic label color against the deep-sky surface and retains an icon/text stale signal; freshness shows both absolute and relative snapshot timestamps.
- Sync says “Mac plan saved on this iPhone”, which describes persisted offline state without claiming a live Mac connection.
- Removed the hand-written mutation/safety allowlist test. Interaction tests now cover real domain labels, deterministic briefing selection, matching-night timezone lookup, and effective queue overlays; the store relaunch test asserts the exact two-change queue and both effective note/checklist values.
- Project rows show collected integration and use stable ID tie-breakers after name/phase/progress comparisons. Briefing rows display saved date plus planned date. Detail note styling follows the effective queued note text.
- UI journeys now verify effective note display, exact queued count, production phase wording, and imported Hungarian navigation/safety wording. Runtime execution remains gated by Xcode account/CoreSimulator availability.

Fix-round safe verification:

```text
xcodegen generate                                      # passed
swiftc -typecheck <all iOS mobile sources>             # passed against iOS 26 SDK
swiftc -frontend -parse <mobile sources/tests/UI tests> # passed
localization key parity (EN/HU)                        # passed
swift test --disable-sandbox --filter MobilePackageServiceTests --no-parallel
                                                       # 39 tests passed
git diff --check                                       # passed
```
