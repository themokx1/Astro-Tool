# V2 Parity Wave 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 2026-08-13-i V2 UI-paritásaudit magas prioritású hiányainak megszüntetése: őszinte paritás-CSV, működő műveleti gerinc (OperationCenter + toast + cancel), globális újra-szken, metadata schema v5 audit-acknowledgement + history, kalibráció-linkelés és masterválasztás, jóváhagyott karantén-apply, V2 szenzormérés, result-tartalmi keresés, valamint valódi settings/support műveletek.

**Architecture:** Minden funkció a meglévő, tesztelt core-motorokra épül (`CalibAnalyzer`, `CalibLinker`, `CalibHealth`, `SensorProfiler`, `CleanupReport`, `LibraryMutationAuthorizer`, `SupportDiagnostics`) — a munka query/command réteg az `AstroApplication`-ben + store/view az `AstroUI`-ban. Fizikai fájlművelet KIZÁRÓLAG a `LibraryMutationAuthorizer`/`WriteGuard` útvonalon, explicit felhasználói jóváhagyással; a `/Volumes/images/Astro` képfájlokat a fejlesztés és teszt során tilos módosítani — minden teszt izolált temp könyvtárat használ.

**Tech Stack:** Swift 6, SwiftUI macOS 14+, Observation, Swift Testing, SQLite, Swift Charts.

**Teszt-futtatás:** `set -o pipefail && swift test --disable-sandbox --no-parallel --filter <Filter> 2>&1 | tail -20` (a pipefail kötelező — sima `| tail` elnyeli a bukást). Teljes suite a task végén: `set -o pipefail && swift test --disable-sandbox --no-parallel --quiet 2>&1 | tail -5`.

**Kulcs-referenciák:**
- Audit: `docs/superpowers/reviews/2026-08-13-v2-ui-parity-audit.md`
- Paritás-CSV + kapu: `docs/superpowers/reviews/v2-feature-parity.csv`, `Tests/AstroCoreTests/V2FeatureParityTests.swift` (a kapu: `status=complete ⟺ known_gap=none`; complete sorhoz létező unit+ui teszt név kell)
- V2 metadata séma: `Sources/AstroApplication/Persistence/MetadataSchema.swift` (`currentVersion = 4`, migrációk `migrate(_:)` :141, tranzakcióban)
- V1 ack: `Sources/AstroCore/DB/Database.swift:3231-3279` (`ackKey`, `ackFindingGroup`, `unackFindingGroup`, `ackedKeys`, `allAcks`), tábla `finding_acks` (:717)
- Kalibráció-motorok: `Sources/AstroCore/Calib/{CalibAnalyzer,SessionMatcher,CalibLinker,CalibHealth,CalibShoppingList}.swift`
- Mutation-gépezet: `Sources/AstroApplication/Mutations/{LibraryMutationAuthorizer,LibraryMutationPlan,LibraryAccessMode}.swift` (22 teszt: `LibraryMutationAuthorizerTests`)
- OperationCenter: `Sources/AstroApplication/Operations/{OperationCenter,OperationState}.swift` — SEMMILYEN view nem hivatkozza még
- Szenzor: `Sources/AstroCore/Stats/SensorProfile.swift` (`SensorProfiler.measure` :69, `combosMissingProfile` :173), history tábla `sensor_profile_history` (`Database.swift` schemaSQLv10)
- Keresés: `Sources/AstroUI/Features/Search/GlobalSearchStore.swift` (`GlobalSearchResultKind` :6-12), `Sources/AstroApplication/Features/Results/ResultsQuery.swift` (`snapshot(projectID:)` :64 — csak projekt-szintű)
- Support: `Sources/AstroCore/Support/SupportDiagnostics*` + `Sources/AstroUI/Settings/V2SettingsView.swift:150-159` (ma csupa-nulla placeholder)

---

### Task 1: Őszinte paritás-CSV + halott beállításkulcsok eltávolítása

**Files:**
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv`
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift`
- Test: `Tests/AstroCoreTests/V2FeatureParityTests.swift`
- Test: `Tests/AstroUITests/V2SettingsTests.swift`

- [ ] Írj failing tesztet a `V2FeatureParityTests`-be: a `target-detail`, `all-targets`, `settings-planning`, `trends`, `discover` sorok státusza `beta-partial` és a `known_gap` nem `none`.
- [ ] Futtasd: `--filter V2FeatureParityTests` — az új elvárás bukjon.
- [ ] Minősítsd vissza az 5 sort `beta-partial`-ra, konkrét `known_gap` szöveggel az audit 11. szakasza szerint (pl. target-detail: `visual frame review, measured quality columns, rating, archive apply, capture assignment, reports, exports, tags and per-filter goals remain unavailable`).
- [ ] Írj failing surface-tesztet a `V2SettingsTests`-be: a `V2SettingsView.swift` nem tartalmazhat olyan `@AppStorage` kulcsot, amelyet a `Sources/` alatt semmi más nem olvas — konkrétan a `v2.planning.referenceHours/referenceFocalRatio/referenceSurfaceBrightness` mezők vagy bekötöttek, vagy a Planning tab jelezze, hogy a mezők még nem hatnak (a no-op űrlap megtévesztő). Egyszerű, becsületes megoldás: a Planning tab mezői mellé kerüljön „Not yet applied to planning calculations" felirat és a CSV `settings-planning` known_gap mondja ki ugyanezt. (A tényleges bekötés a Task 9-ben történik.)
- [ ] Implementáld, futtasd a fókuszált teszteket, majd a teljes suite-ot.
- [ ] Commit: `docs: downgrade overstated parity rows and label dead planning prefs`, push.

### Task 2: Műveleti gerinc — OperationCenter bekötése, toast, futásjelző, Mégse

**Files:**
- Create: `Sources/AstroUI/Operations/OperationHost.swift` (`@MainActor @Observable` store az `OperationCenter` actor fölé: `run(kind:title:work:)`, `cancel(id:)`, `activeOperations`, `recentOutcomes`, toast-üzenetek)
- Create: `Sources/AstroUI/Operations/OperationStatusView.swift` (toolbar-indikátor: futó művelet címe + progress + Mégse gomb; utolsó műveletek popover)
- Create: `Sources/AstroUI/Operations/ToastOverlay.swift` (V2 toast-réteg, min. success/failure/info szint, automatikus eltűnés)
- Modify: `Sources/AstroUI/App/V2RootView.swift` (toolbar + overlay bekötés, `OperationHost` environment)
- Test: `Tests/AstroUITests/OperationHostTests.swift`
- Test: `Tests/AstroUITests/V2ShellSurfaceTests.swift`

- [ ] Írj failing store-tesztet: `OperationHost.run` regisztrálja a műveletet az `OperationCenter`-ben, a futás alatt `activeOperations` tartalmazza, sikeres befejezés után toast kerül a sorba, `cancel` a cooperative cancellationt kiváltja (a work closure `Task.isCancelled`-et lát).
- [ ] Futtasd: `--filter OperationHostTests` — bukjon (nincs ilyen típus).
- [ ] Implementáld az `OperationHost`-ot a meglévő `OperationCenter`/`OperationState` API-ra építve (NE írj új operation-modellt).
- [ ] Írj failing surface-tesztet a `V2ShellSurfaceTests`-be: a `V2RootView.swift` tartalmazza az `OperationStatusView` és `ToastOverlay` bekötést, és az azonosítókat `v2.toolbar.operations`, `v2.toast-layer`.
- [ ] Implementáld a két view-t és a bekötést; buildeld: `swift build --disable-sandbox --target AstroToolApp`.
- [ ] Teljes suite, commit: `feat: wire the V2 operation backbone with toasts and cancel`, push.

### Task 3: Globális újra-szken (⌘R)

**Files:**
- Modify: `Sources/AstroToolApp/Views/Commands.swift` (V2 blokk, :267-299)
- Modify: `Sources/AstroUI/App/V2RootView.swift` + `Sources/AstroUI/App/AppModel.swift` (rescan action az aktuális library sessionre)
- Modify: `Sources/AstroUI/Features/Library/LibraryView.swift` („Rescan Library" gomb)
- Test: `Tests/AstroUITests/V2ShellSurfaceTests.swift`
- Test: `Tests/AstroUITests/LibraryRescanTests.swift` (új)

- [ ] Írj failing tesztet: az `AppModel` (vagy a library session store) `rescan()` művelete az onboarding first-scan pipeline-ját újrafuttatja a megnyitott gyökéren, az `OperationHost`-on keresztül (progress + cancel), és frissíti a store-okat; zárolt: ha nincs megnyitott könyvtár, no-op hibaüzenettel.
- [ ] Futtasd — bukjon.
- [ ] Implementáld a rescan use-case-t az onboarding scan-útvonal (LibraryWelcomeView/FirstScan által használt session-API) újrahasznosításával; SEMMI új scan-motor.
- [ ] Írj failing surface-tesztet: V2 Commands tartalmaz `Rescan` menüpontot `⌘R` shortcuttal, a `LibraryView.swift` pedig rescan-gombot.
- [ ] Implementáld, build + fókuszált tesztek + teljes suite.
- [ ] Commit: `feat: add global rescan to V2`, push.

### Task 4: Metadata schema v5 — audit acknowledgement + history

**Files:**
- Modify: `Sources/AstroApplication/Persistence/MetadataSchema.swift` (`currentVersion = 5`, `versionFiveSQL`)
- Modify: `Sources/AstroApplication/Persistence/MetadataStore.swift` (ack + audit-run API)
- Modify: `Sources/AstroApplication/Features/Library/LibraryHealthQuery.swift` (ack-szűrés + history)
- Modify: `Sources/AstroApplication/Persistence/V1MetadataImporter.swift` (legacy ack → natív tábla)
- Modify: `Sources/AstroUI/Features/Library/HealthView.swift` (ack műveletek + „acknowledged" szűrő + history szekció; a privát inline store kerüljön ki dedikált `LibraryHealthStore.swift`-be)
- Create: `Sources/AstroUI/Features/Library/LibraryHealthStore.swift`
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`audit` sor)
- Test: `Tests/AstroApplicationTests/MetadataStoreTests.swift`
- Test: `Tests/AstroApplicationTests/LibraryHealthQueryTests.swift`
- Test: `Tests/AstroUITests/LibraryHealthStoreTests.swift` (új)

**Séma (versionFiveSQL):**
```sql
CREATE TABLE IF NOT EXISTS audit_acknowledgements (
    id TEXT PRIMARY KEY,
    ack_key TEXT NOT NULL UNIQUE,
    category TEXT NOT NULL,
    group_key TEXT NOT NULL,
    acked_at TEXT NOT NULL,
    note TEXT
);
CREATE TABLE IF NOT EXISTS audit_run_history (
    id TEXT PRIMARY KEY,
    ran_at TEXT NOT NULL,
    finding_count INTEGER NOT NULL,
    group_keys TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_run_history_ran_at ON audit_run_history(ran_at);
```

- [ ] Írj failing migrációs teszteket a `MetadataStoreTests`-be: v4 DB v5-re migrál adatvesztés nélkül; a verzió 5-öt mutat; hibás migráció rollbackel (kövesd a meglévő :150-267 mintákat).
- [ ] Futtasd: `--filter MetadataStoreTests` — bukjon.
- [ ] Implementáld a v5 migrációt a meglévő `if version < 5` mintával, tranzakcióban.
- [ ] Írj failing store-API teszteket: `acknowledgeFindingGroup(category:groupKey:note:)` (ack_key = V1 `Database.ackKey` formátumával azonos: kategória+groupKey determinisztikus kulcs), `revokeAcknowledgement(ackKey:)`, `acknowledgements()`, `recordAuditRun(findingCount:groupKeys:at:)`, `auditRunHistory(limit:)`; új/megoldódott csoportok számítása két run között (V1 `AuditDiff` szemantika: új = utóbbi runban van, előzőben nincs).
- [ ] Implementáld; fókuszált tesztek zöldek.
- [ ] Írj failing importer-tesztet: a `V1MetadataImporter` a `finding_acks` sorokat a natív `audit_acknowledgements` táblába is beírja (a meglévő `legacy_imports` másolat megmarad); idempotens (kétszeri import nem duplikál).
- [ ] Implementáld.
- [ ] Írj failing query-teszteket a `LibraryHealthQueryTests`-be: a findings sorok `isAcknowledged` mezőt kapnak; alapértelmezésben az ack-elt csoportok elrejthetők; a query visszaadja az utolsó N audit-run összefoglalót új/megoldódott számokkal.
- [ ] Implementáld.
- [ ] Emeld ki a `HealthView` privát store-ját `LibraryHealthStore.swift`-be; írj failing store-tesztet: ack/unack action a `MetadataStore`-ra delegál és frissíti a sorokat; „Show acknowledged" toggle.
- [ ] Írj failing surface-tesztet: `HealthView.swift` tartalmaz ack/unack context-menü műveletet, acknowledged-szűrőt és `v2.health.audit-history` szekciót.
- [ ] Implementáld a UI-t (ack/unack a findings tábla context-menüjében + toolbar toggle + history lista).
- [ ] CSV `audit` sor: known_gap frissítés (marad beta-partial, gap: `audit run trigger from V2 remains unavailable` — az audit-futtatás nem e task része).
- [ ] Teljes suite, commit: `feat: add schema v5 audit acknowledgements and history`, push.

### Task 5: Kalibráció-linkelés és masterválasztás

**Files:**
- Create: `Sources/AstroApplication/Features/Library/CalibrationQuery.swift` (read-only: `CalibAnalyzer.coverage`, `masterDirInfos`, `CalibHealth.report`, `SessionMatcher` mismatch-okok)
- Create: `Sources/AstroApplication/Features/Library/CalibrationLinkCommand.swift` (`CalibLinker.plan` előnézet + `apply` a WriteGuard útvonalon; apply csak `LibraryAccessMode.mutationEnabled` mellett)
- Create: `Sources/AstroUI/Features/Library/CalibrationView.swift` + `CalibrationStore.swift` (lefedettség-tábla, master-leltár kiválasztással, link-előnézet sheet + apply, Finder-reveal a master mappákra)
- Modify: `Sources/AstroUI/Features/Library/HealthView.swift` (belépési pont: „Calibration…" a kalibrációs findings context-menüjében)
- Modify: `Sources/AstroUI/App/AppRoute.swift` + `V2RootView.swift` (`.calibration` route)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`calibration` sor)
- Test: `Tests/AstroApplicationTests/CalibrationQueryTests.swift` (új)
- Test: `Tests/AstroApplicationTests/CalibrationLinkCommandTests.swift` (új)
- Test: `Tests/AstroUITests/CalibrationStoreTests.swift` (új)
- Test: `Tests/AstroUITests/V2WorkspaceParitySurfaceTests.swift`

- [ ] Írj failing query-teszteket temp-könyvtáras fixture-rel (kövesd a `Tests/AstroCoreTests/CalibTests.swift` fixture-mintáit): coverage-igények session-enként; master-leltár (`MasterDirInfo` vetítés: útvonal, típus, hőmérséklet, kor, staleness); mismatch-okok (gain/offset/binning/kamera) szövegesen.
- [ ] Implementáld a `CalibrationQuery`-t a motorok hívásával — TILOS újraimplementálni a matching-logikát.
- [ ] Írj failing command-teszteket: `plan(target:date:)` a `CalibLinker.plan`-t adja vissza item-szinten; `apply(plan:)` read-only módban `LibraryMutationError`-t dob; mutationEnabled módban temp-fixture-ben ténylegesen létrehozza a linkeket és receipt-összefoglalót ad.
- [ ] Implementáld.
- [ ] Írj failing store + surface teszteket: `CalibrationView` Table-alapú (coverage + masters szekció), master-sor kiválasztható, link-sheet `v2.calibration.link-preview` azonosítóval, apply gomb read-only módban letiltva „Requires write access" magyarázattal.
- [ ] Implementáld a UI-t + route-ot.
- [ ] CSV `calibration` sor: known_gap szűkítése (`calibration settings tolerances remain unavailable`).
- [ ] Teljes suite, commit: `feat: add V2 calibration linking and master selection`, push.

### Task 6: Jóváhagyott karantén-apply

**Files:**
- Modify: `Sources/AstroApplication/Features/Library/CleanupPreviewQuery.swift` (a fix `canApply: false` helyett accessMode-függő; `CleanupPreviewGroup` → `LibraryMutationPlan` építés fingerprintekkel)
- Create: `Sources/AstroApplication/Features/Library/QuarantineApplyCommand.swift` (plan-regisztráció + apply + rollback a `LibraryMutationAuthorizer`-rel, `mutation_journal` naplózással; progress az `OperationCenter`-en)
- Modify: `Sources/AstroUI/Features/Library/CleanupPreviewView.swift` (kijelölhető csoportok, „Apply quarantine…" gomb)
- Create: `Sources/AstroUI/Features/Library/MutationConfirmationSheet.swift` (a `PresentationRoute.mutationConfirmation` valódi képernyője: érintett fájlszám+méret, cél-karantén útvonal, confirmation-token gépelős megerősítés, apply, receipt-nézet, „Undo" rollback)
- Modify: `Sources/AstroUI/App/V2RootView.swift` (placeholder :658-690 cseréje a valódi sheetre)
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift` (Libraries & Safety: explicit „Enable write operations" kapcsoló → `LibraryAccessMode`)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`cleanup` sor)
- Test: `Tests/AstroApplicationTests/QuarantineApplyCommandTests.swift` (új)
- Test: `Tests/AstroApplicationTests/CleanupPreviewQueryTests.swift`
- Test: `Tests/AstroUITests/MutationConfirmationTests.swift` (új)
- Test: `Tests/AstroUITests/V2ShellSurfaceTests.swift`

**Biztonsági kontraktus (tesztelendő, nem csak dokumentált):** apply CSAK regisztrált plan + helyes confirmation token + mutationEnabled hármassal fut; a cél mindig `.astro_tool/cleanup_quarantine/<timestamp>/` alá kerülő MOZGATÁS (törlés soha); rollback visszaállít; minden lépés a `mutation_journal`-ba íródik; read-only módban a teljes útvonal elérhetetlen. Minden teszt izolált temp könyvtárban fut (`V2FixtureLibrary` minták) — a valós képkönyvtárat tesztek nem érinthetik.

- [ ] Írj failing query-teszteket: `canApply` accessMode-függő; a kijelölt csoportokból épített `LibraryMutationPlan` entry-nként forrást, karantén-célt és fingerprintet tartalmaz, a `CleanupReport.quarantineFindings` cél-sémáját követve.
- [ ] Implementáld.
- [ ] Írj failing command-teszteket temp-fixture-ben: sikeres apply mozgatja a fájlokat és receiptet ad; hibás token elutasítva; read-only mód elutasítva; rollback visszaállítja a fájlokat; ismételt apply ugyanarra a planre elutasítva (a 22 meglévő authorizer-teszt mintái szerint, de a cleanup-integráción keresztül).
- [ ] Implementáld a commandot a `LibraryMutationAuthorizer.register/apply/rollback` hívásaival — TILOS az authorizert megkerülni vagy duplikálni.
- [ ] Írj failing UI-teszteket: a confirmation sheet mutatja a darabszámot/méretet/célútvonalat, az apply gomb csak helyes token-bevitelnél aktív, sikeres apply után receipt + Undo látszik; surface-teszt: a `V2RootView.swift`-ben a `mutationConfirmation` már NEM placeholder.
- [ ] Implementáld a sheetet + a settings-kapcsolót (alapértelmezés: read-only).
- [ ] CSV `cleanup` sor: known_gap szűkítése (`suggestion script export remains unavailable`).
- [ ] Teljes suite, commit: `feat: enable approved quarantine apply in V2`, push.

### Task 7: Szenzormérés a V2-ből

**Files:**
- Create: `Sources/AstroApplication/Features/Library/SensorMeasurementCommand.swift` (`SensorProfiler.measure` wrapper progress-callbackkel az `OperationCenter`-en át; cancel-támogatás)
- Modify: `Sources/AstroApplication/Features/Library/SensorProfilesQuery.swift` (history: `sensor_profile_history` olvasása komb.-nként; `combosMissingProfile` vetítés)
- Modify: `Sources/AstroUI/Features/Library/SensorProfilesView.swift` (a privát store kiemelése `SensorProfilesStore.swift`-be; „Measure Sensors…" gomb + megerősítő sheet + progress + Mégse; history-sparkline Swift Charts-szal; hiányzó-profil figyelmeztetések)
- Create: `Sources/AstroUI/Features/Library/SensorProfilesStore.swift`
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`sensor-profiles` sor)
- Test: `Tests/AstroApplicationTests/SensorMeasurementCommandTests.swift` (új)
- Test: `Tests/AstroApplicationTests/SensorProfilesQueryTests.swift`
- Test: `Tests/AstroUITests/SensorProfilesStoreTests.swift` (új)
- Test: `Tests/AstroUITests/V2ShellSurfaceTests.swift`

- [ ] Írj failing query-teszteket: history-sorok időrendben komb.-nként (kamera+gain+offset); `missingCombos` a `SensorProfiler.combosMissingProfile`-ból.
- [ ] Implementáld.
- [ ] Írj failing command-teszteket temp-fixture DB-vel (kövesd `Tests/AstroCoreTests/SensorProfileTests.swift` fixture-jeit): a mérés lefut, upsertel, progress-eseményeket ad, cancel megszakítja.
- [ ] Implementáld.
- [ ] Írj failing store + surface teszteket: mérés-indítás megerősítő sheetből (`v2.sensor-profiles.measure`), futás közben progress + Mégse, befejezés után lista-frissítés + toast; history-chart jelenlét; empty-state szöveg frissítve (nem hivatkozhat már CLI-re mint egyetlen útra).
- [ ] Implementáld.
- [ ] CSV `sensor-profiles` sor: status `complete`, known_gap `none` — CSAK ha a kapu-teszt követelményei (létező unit+ui tesztnevek) teljesülnek; különben beta-partial maradjon pontos gappal.
- [ ] Teljes suite, commit: `feat: run sensor measurement from V2`, push.

### Task 8: Result-tartalmi keresés

**Files:**
- Modify: `Sources/AstroApplication/Persistence/MetadataStore.swift` (új: `allResults()` — library-szintű result-lista projekt-névvel joinolva)
- Modify: `Sources/AstroApplication/Features/Results/ResultsQuery.swift` (library-szintű kereshető vetítés: kind, role, relativePath, softwareName/Version, projectName, createdAt)
- Modify: `Sources/AstroUI/Features/Search/GlobalSearchStore.swift` (`GlobalSearchResultKind.result` + keresés a result-vetítésen a meglévő normalizálással)
- Modify: `Sources/AstroUI/App/V2RootView.swift` (`.result` találat routing a meglévő `.result` route-ra)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`search` sor)
- Test: `Tests/AstroApplicationTests/MetadataStoreTests.swift`
- Test: `Tests/AstroApplicationTests/ResultsQueryTests.swift`
- Test: `Tests/AstroUITests/GlobalSearchStoreTests.swift`

- [ ] Írj failing store-tesztet: `allResults()` több projekt resultjait adja vissza projekt-névvel; üres DB üres listát.
- [ ] Implementáld (SQL join a `results` + `projects` táblákon; használd a meglévő indexeket).
- [ ] Írj failing query-tesztet: a kereshető vetítés tartalmazza a software-t, role-t, relativePath-t, projektnevet.
- [ ] Implementáld.
- [ ] Írj failing search-teszteket: `"Siril"` lekérdezés result-találatot ad `.result` kinddal; a találat a megfelelő `.result` route-ra navigál; diakritika-érzéketlen egyezés a projektnévre.
- [ ] Implementáld a store + routing bekötést.
- [ ] CSV `search` sor: known_gap szűkítése vagy complete a kapu-szabályok szerint.
- [ ] Teljes suite, commit: `feat: search result content in V2 global search`, push.

### Task 9: Valódi settings/support műveletek

**Files:**
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift`
- Modify: `Sources/AstroUI/Settings/SettingsStore.swift`
- Modify: `Sources/AstroUI/Features/Planning/PlanningStore.swift` (a beégetett 10.0/22.0 helyett a planning-preferenciák olvasása)
- Modify: `Sources/AstroUI/App/AppModel.swift` (recent libraries lista a meglévő bookmark-mechanizmusra építve)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`settings-general`, `settings-library`, `settings-support`, `settings-planning` sorok)
- Test: `Tests/AstroUITests/V2SettingsTests.swift`
- Test: `Tests/AstroUITests/PlanningStoreTests.swift` (ha nincs, új)
- Test: `Tests/AstroCoreTests/SupportDiagnosticsTests.swift` (referencia, nem módosítandó)

Hatókör (a teljes V1 settings-migráció NEM fér e taskba; ez a support + a halott kulcsok megszüntetése):
1. **Valódi diagnosztika:** a `generateDiagnostics()` élő értékekkel töltse a `SupportDiagnostics`-ot (metadata `schemaVersion()`, library-connected, projekt/éjszaka/szűrő/szenzorprofil darabszámok a query-rétegből); privacy-kontraktus változatlan (semmi útvonal/célpontnév).
2. **Mentés fájlba:** a Copy mellé „Save…" (NSSavePanel) — a V1 `saveSupportDiagnostics` (`AppState+Support.swift:39`) megfelelője.
3. **Linkek:** Documentation / Support / Source / Privacy a `ProductInfo` URL-jeiből; verzió + OS + architektúra sor.
4. **Planning-preferenciák bekötése:** a `PlanningStore` a `v2.planning.*` értékeket olvassa (default 10.0 / f5 / 22.0); a Task 1-ben felvett „not yet applied" felirat eltávolítása.
5. **Recent libraries:** a legutóbbi könyvtárak listája + váltás a Libraries tabon (a meglévő security-scoped bookmark tárolásra építve).
6. **`scanOnOpen` + `showGuidance` bekötése:** a scanOnOpen ténylegesen vezérelje az open-flow újraindexelését; a showGuidance a guidance-feliratok láthatóságát.

- [ ] Írj failing teszteket a diagnosztikára: élő schema-verzió és nem-nulla darabszámok fixture-könyvtárral; a payload továbbra sem tartalmaz útvonalat/célpontnevet.
- [ ] Implementáld.
- [ ] Írj failing surface-teszteket: Save-gomb, ProductInfo-linkek, verzió-sor jelen vannak (`v2.settings.support.save`, `v2.settings.support.links`).
- [ ] Implementáld.
- [ ] Írj failing PlanningStore-tesztet: a referencia-preferenciák megváltoztatása megváltoztatja a célidő-számítást.
- [ ] Implementáld (a `IntegrationTimeModel` hívás paraméterezése).
- [ ] Írj failing teszteket a recent-libraries listára és a scanOnOpen/showGuidance tényleges hatására.
- [ ] Implementáld.
- [ ] CSV-sorok frissítése a kapu-szabályok szerint.
- [ ] Teljes suite, commit: `feat: connect real V2 settings and support operations`, push.

---

## Végső ellenőrzés (minden task után kötelező, itt összegezve)

- [ ] `set -o pipefail && swift test --disable-sandbox --no-parallel --quiet 2>&1 | tail -5` — 0 bukás.
- [ ] `swift build --disable-sandbox --target AstroToolApp` — zöld.
- [ ] A `/Volumes/images/Astro` alatt semmi nem változott (a tesztek temp-könyvtárasak; fejlesztés közben a valós könyvtárat megnyitni sem szabad írásra).
- [ ] Parity CSV konzisztens a kapuval (`V2FeatureParityTests`).
- [ ] Minden task külön commitban, pusholva.
