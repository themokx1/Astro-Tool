# V2 Navigation Rework Implementation Plan (wave 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zoltán UX-visszajelzése alapján a V2 navigáció átépítése: a keret (sidebar + toolbar-akciók) stabil marad és csak a tartalom törzse cserélődik; drill-down NavigationStack-pushsal és natív Vissza gombbal; a munkaterek route-ok tabokkal, nem „Done"-os overlay-ek; kattintható breadcrumb; és a feltárt két adatbug (state-átszivárgás `.id()` híján, annotation-race) javítása.

**Architecture:** Kétoszlopos `NavigationSplitView` (sidebar + detail) — a mai egyelemű ContentColumn megszűnik, a Library aloldalai (Health, Calibration) sidebar-gyereksorok lesznek. A detail oszlop `NavigationStack(path:)`-t kap; az `AppRouter` skalár `contentRoute`-ja szekciónkénti `path: [ContentRoute]` stackké válik (a `contentRoute` computed marad a kompatibilitásért). A workspace-akciók focused-value-n át publikált `WorkspaceActions`-ként a rögzített shell-toolbarban jelennek meg. A Review/Results/Conversion/Cleanup/SensorProfiles overlay-ek route-ok lesznek.

**A diagnózis (kötelező olvasmány a részletekhez):** a jelen terv a 2026-08-14-i navigációs felderítés megállapításaira épül; kulcshelyek: `V2RootView.swift:205-247` (shell), `:704-859` (lapos switch), `:325-347` (overlay-ek), `AppModel.swift:33-168` (skalár router, inspector-csatolás `:111,:118,:148`), `ProjectWorkspaceView.swift:26` (elvesző tab-state), `:83` (kézi chevron), `ProjectsStore.swift:99-100` (annotation-race), `AppRoute.swift:60-61` (kezeletlen `.result`/`.reviewFrame`), V1 minta: `MainShellView.swift:59-110` + `TargetDetailPage` `.id(name)`.

**Tech Stack:** Swift 6, SwiftUI macOS 14+ (NavigationStack, navigationDestination, toolbarRole(.editor), focusedSceneValue), Observation, Swift Testing.

**Teszt-futtatás:** `set -o pipefail && swift test --disable-sandbox --no-parallel --filter <F> 2>&1 | tail -20`; teljes: `--quiet | tail -5`; build: `swift build --disable-sandbox --target AstroToolApp`. Kiindulás: 05446bd után 2011 teszt zöld.

**UX-elvek (memóriában is rögzítve):** (1) a shell stabil, csak a törzs cserél; (2) drill-down = push + natív Vissza, sheet csak rövid megerősítő/szerkesztő dialógusra; (3) munkaterek tab-alapúak, tabváltás nem navigáció; (4) a kontextus akciói a toolbarban maradnak drill-down alatt is.

---

### Task 1: Router-stack, NavigationStack, overlay-ek kiváltása route-tal, adatbugok

**Files:**
- Modify: `Sources/AstroUI/App/AppModel.swift` (AppRouter: szekciónkénti `path: [ContentRoute]`, `push/pop`, computed `contentRoute`; inspector-visibility leválasztása a navigációról)
- Modify: `Sources/AstroUI/App/AppRoute.swift` (új route-ok: `.review(projectID: UUID)`, `.resultsWorkspace(projectID: UUID)`, `.conversion`, `.cleanup`, `.sensorProfiles`; a meglévő `.result(String)` kezelése; WindowRestorationState + deep link kompatibilitás)
- Modify: `Sources/AstroUI/App/V2RootView.swift` (DetailHost: `NavigationStack(path:)` + `navigationDestination`, `.toolbarRole(.editor)`; a `.overlay` blokkok törlése; `.id(route)` a pusholt munkaterekre)
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift` (Done törlése — route-ként él), `Sources/AstroUI/Features/Results/ResultsView.swift` (Close törlése), `Sources/AstroUI/Features/Library/ConversionWorkspace.swift` (Close/Done törlése), `Sources/AstroUI/Features/Library/{CleanupPreviewView,SensorProfilesView}.swift` (Close törlése, route-ként), `HealthView.swift` (overlay-hívások → push)
- Modify: `Sources/AstroUI/Features/Projects/ProjectsStore.swift` (`selectProject`: snapshot + annotation atomikus publikálása)
- Test: `Tests/AstroUITests/AppRouterTests.swift` (van-e — ha nincs, új), `Tests/AstroUITests/V2NavigationSurfaceTests.swift` (új), meglévő surface-suite-ok frissítése (az overlay-t állító assertek cseréje)

- [ ] Failing router-tesztek: push/pop szemantika; `contentRoute` = `path.last ?? root`; szekcióváltás megőrzi az adott szekció stackjét; deep link + restoration oda-vissza.
- [ ] Implementálás.
- [ ] Failing surface-tesztek: `NavigationStack(` jelen a V2RootView-ban; NINCS `.overlay` a Review/Results/Conversion-höz; nincs `"Done"` a ReviewWorkspace-ben; `navigationDestination` kezeli az összes ContentRoute-ot (nincs default→üres a valós route-okra); `.id(` a workspace-push-okon.
- [ ] Implementálás: switch-karok → `navigationDestination`; overlay-ek törlése; Vissza = natív chevron (kézi „Projects/Nights/Project" chevron-gombok törlése a workspace-fejlécekből).
- [ ] Failing store-teszt az annotation-race-re: `selectProject` után a snapshot ÉS az annotation együtt, egy megfigyelhető állapotban jelenik meg (jegyzet sosem üresül ki).
- [ ] Implementálás.
- [ ] Teljes suite + build; commit `feat: rebuild V2 navigation on a router stack`; push.

### Task 2: Kétoszlopos shell, stabil toolbar-akciók, breadcrumb

**Files:**
- Modify: `Sources/AstroUI/App/V2RootView.swift` (ContentColumn megszüntetése — kétoszlopos NavigationSplitView; V2Sidebar: Library alá Health + Calibration gyereksorok; a szekció-gyökér nézetek közvetlenül a detail stack gyökerei)
- Create: `Sources/AstroUI/App/WorkspaceActions.swift` (focused-value típus: a route aktuális munkaterének akciói — export menü, Review Frames, Results, Night Actions, Run Audit stb. — címke+ikon+akció+enabled)
- Modify: a workspace-ek (`ProjectWorkspaceView`, `NightWorkspaceView`, `SeriesWorkspaceView`, `HealthView`, `ReviewWorkspace`, `ResultsView`) publikálják a `WorkspaceActions`-t; az in-body akciógomb-sorok kikerülnek a fejlécből
- Create: `Sources/AstroUI/App/BreadcrumbBar.swift` (a stack path-ból épülő, kattintható morzsasor; morzsára kattintva pop az adott mélységre; a fejléc-eyebrow `"Project › …"` stringek cseréje)
- Test: `Tests/AstroUITests/WorkspaceActionsTests.swift` (új), `Tests/AstroUITests/BreadcrumbBarTests.swift` (új), `V2NavigationSurfaceTests` bővítés

- [ ] Failing tesztek: BreadcrumbBar a path-ból helyes címkéket képez, kattintás popol; WorkspaceActions publikálás projekt-route-on tartalmazza az Exportot és Review-t; a shell-toolbar renderei a fókuszált akciókat (`v2.toolbar.workspace-actions`).
- [ ] Implementálás.
- [ ] Failing surface-tesztek: nincs ContentColumn; sidebar tartalmaz `v2.sidebar.library.health` + `.calibration` sorokat; a ProjectWorkspaceView fejlécében NINCS gomb-sor (csak identitás + breadcrumb).
- [ ] Implementálás; teljes suite + build; commit `feat: stabilize the V2 shell with workspace toolbar actions and breadcrumbs`; push.

### Task 3: Tab-state a routerben, tabok mindenhol, valódi Results-tab

**Files:**
- Modify: `Sources/AstroUI/App/AppModel.swift` (`projectTab`, `nightTab` a routerben — drill-down és vissza után megmarad)
- Modify: `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift` (tab-state a routerből; a Results tab a valódi per-projekt results tartalmat hostolja a ResultsView route helyett; a Nights/Series tabok sorai pusholnak)
- Modify: `Sources/AstroUI/Features/Nights/NightWorkspaceView.swift` (tabok: Overview / Series / Frames / Notes — a mai egy-scroll bontása)
- Modify: `Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift` (tabok: Overview / Frames)
- Test: `Tests/AstroUITests/V2NavigationSurfaceTests.swift` + store-tesztek a tab-megőrzésre

- [ ] Failing tesztek: projekt → night → Vissza után a projekt-tab az marad, ami volt; a Results tab valódi tartalmat renderel (nem „nyomd meg a Results gombot" placeholder — az a szöveg nem létezhet többé).
- [ ] Implementálás.
- [ ] Failing surface-tesztek: NightWorkspaceView + SeriesWorkspaceView tartalmaz segmented Picker-t; a placeholder-szöveg törölve.
- [ ] Implementálás; teljes suite + build; commit `feat: give V2 workspaces router-backed tabs`; push.

---

## Végső kapu

- [ ] Teljes suite zöld (--no-parallel), build zöld.
- [ ] Kézi füst-teszt forgatókönyv (app indítás után): Projects → dupla-katt projekt → tabok váltás → Nights tab → night push → natív Vissza → a projekt-tab megmaradt; Review route-ként nyílik és Vissza-val zárul; sidebar Health/Calibration; akciógombok a toolbarban maradnak minden lépésben.
- [ ] Záró kódreview a hullámra.
- [ ] Build-szám emelés, `./build.sh`, `./scripts/install-local.sh`, app-indítás ellenőrzés.
