# AstroTool V2 — UI-funkciószintű paritásaudit a V1-hez képest

**Dátum:** 2026. augusztus 13.
**Vizsgált állapot:** `codex/v2.0.0-ui-rework` worktree, HEAD `fe1c562` (2.0.0 RC2, build 20010), 1794/1794 teszt zöld.
**Kérdés:** mi hiányzik még a V2 felületből abból, ami a V1 (classic) felületben már jól működik?
**Módszer:** két független, teljes kódbejárás. (1) A hat ismert paritásterület kódszintű térképe. (2) Minden V1 képernyő, sheet, menü és művelet szisztematikus leltára, összevetve a `Sources/AstroUI` tényleges állapotával. „Jól működik a V1-ben” = valódi `AppState` handler + tesztelt core-motor; a V1-ben is halott/letiltott kódot kihagytuk.

**Besorolások:** ✅ **MEGVAN** (V2-ben azonos funkció, valódi handlerrel) · 🟡 **RÉSZLEGES** (van V2 megfelelő, de kevesebbet tud) · ❌ **HIÁNYZIK** (nincs V2 megfelelő).

---

## 1. Vezetői összefoglaló

A V2 munkatér-architektúrája (Projects → Night → Series → Frame → Result lánc, natív táblák, route-alapú navigáció) készen áll, és a fő olvasó-navigáló út valóban jobb, mint a V1-ben. A hiány három rétegben koncentrálódik:

1. **Műveleti réteg.** A V1 ereje a mindenhonnan elérhető műveletekben van: `SessionActionMenu` (12 művelet), Műveletek menü (7 batch-művelet), 9 különböző export-útvonal, kalibráció-linkelés, frame-pontozás, archiválás-alkalmazás, audit-futtatás, fixity-ellenőrzés, ack-kezelés. **A V2 ma szinte kizárólag olvas** — a metadata-verdictek (Accept/Reject) és a projektjegyzet/cél kivételével gyakorlatilag minden író/exportáló/futtató művelet hiányzik.
2. **Visszajelző réteg.** Nincs toast, nincs activity log, nincs futó művelet + Mégse (az első scan kivételével), nincsenek sidebar-badge-ek. Az `OperationCenter` megírva, tesztelve — **egyetlen view sem hivatkozik rá**.
3. **Magyarázó réteg.** A teljes discoverability-réteg (fogalomtár, metrika-ⓘ popoverek, Siril-súgó, mappastruktúra-súgó, első lépések checklist, onboarding-wizard) V1-only.

A paritás-CSV 19 sora jó vázlat, de **öt „complete” sora túlállít** (lásd 9. szakasz), és legalább 14 hiánycsoportot egyáltalán nem említ (lásd 8. szakasz).

Számszerűen: a leltár ~120 valódi V1 UI-funkciót azonosított; ebből V2-ben **~15 MEGVAN, ~20 RÉSZLEGES, ~85 HIÁNYZIK**. A hiányok nagy része mögött kész, tesztelt core-motor áll (`AstroCore`/`AstroApplication`), tehát a munka döntően UI-bekötés, nem motorfejlesztés.

---

## 2. Globális réteg: menüsor, toolbar, sidebar, keresés, inspector

A V1 parancsai: `Views/Commands.swift:47-262`; V2: `Views/Commands.swift:267-299`.

| Funkció | V1 hivatkozás | V2 |
|---|---|---|
| Új session… (⌘N) | `Commands.swift:50` → `AppState.createSession` (`AppState.swift:5621`) | ❌ — a V2 „New Night…” menüpont `disabled(true)` |
| Mappa választása… (⇧⌘O) menüből | `Commands.swift:58` | 🟡 — csak Library gombról / onboardingból |
| Legutóbbi könyvtárak menü | `Commands.swift:63` → `selectRecentRoot` | ❌ |
| **Beolvasás (⌘R) — újra-szken** | `Commands.swift:73` → `runScan` (`AppState.swift:1799`) | ❌ — V2-ben csak a mappa újraválasztásával lehet újraindexelni |
| ⌘1–⌘9 oldalnavigáció | `Commands.swift:94-132` | 🟡 — ⌘1–⌘6 |
| Kereső fókuszálása (⌘F) | `Commands.swift:165` | ❌ |
| **Műveletek menü:** Audit futtatása (⌥⌘A), gyors audit, Minden célpont pontozása, Plate-solve mindenre, Szenzor mérése, DSS-import, Expozíció-tanácsadó | `Commands.swift:172-229`; handlerek `AppState.swift:1914, 5220, 4990, 4407, 4585, 5297` | ❌ — mind a 7 batch-művelet hiányzik |
| **Súgó menü:** mappastruktúra-súgó, fogalomtár, Sirilről, első lépések, tutorial, CLI-referencia, diagnosztika, adatvédelem, támogatás | `Commands.swift:232-261` | ❌ — mind a 9 |
| Root-menü: Finderben megnyitás, config.json megjelenítése | `MainShellView.swift:250-271` | ❌ |
| Futó művelet + **Mégse** | `MainShellView.swift:275-280` → `cancelCurrentOperation` | 🟡 — csak az első scan szakítható meg |
| Activity log popover (utolsó 50 művelet + „Mit tehetsz” tanács) | `MainShellView.swift:299-363` | ❌ — az `OperationCenter.swift` (AstroApplication) egyetlen view-ból sincs hivatkozva |
| Toast-visszajelzés | `ToastOverlay.swift:17` | ❌ |
| Elavult-scan banner | `MainShellView.swift:161-178` | ❌ |
| Sidebar fázispöttyök + oldalankénti badge-ek (ma esti darabszám, kalibrációhiány, audit-hibák, cleanup-méret, szenzor/szűrő) | `SidebarView.swift:96-123, 286-326` | ❌ — a V2 sidebar lapos, 6 elemű lista |
| Globális keresés | `SidebarView.swift:224` + `SearchResultsPage.swift` | 🟡 — a V2 popover keres projektet/éjszakát/seriest/fájlt/jegyzetet, de nincs találati oldal, nincs kategóriánkénti darabszám, nincs sor-művelet (Finder, szülőcélpont), és nincs **result-tartalmi keresés** (`GlobalSearchResultKind`-ban nincs `.result` eset — `GlobalSearchStore.swift:6-12`) |
| Inspector | — (V2-újdonság) | 🟡 — a fő ablak inspektora stub: csak „Type”/„Identifier” (`InspectorView.swift:36-44`); a valódi `SeriesInspector`/`FrameInspector` csak a Review-ból érhető el |

---

## 3. Ma este / Naptár → V2 Home + Nights

V1: `Views/TonightPage.swift` (1300 sor).

| Funkció | V1 | V2 |
|---|---|---|
| Ma esti rangsor (láthatóság, delelés, Hold, verdict) | `:565-742` | 🟡 — a Home csak top-ajánlásokat mutat, nincs teljes tábla/rendezés (`HomeView.swift:78-117`) |
| Terv exportálása → vágólap / CSV | `:92-97` → `AppState.swift:3169, 3183` | ❌ |
| Site-választó (több helyszín) | `:113-124` | ❌ — a V2 Home fixen „Site not set” (`HomeView.swift:162`) |
| **Felhőzet: Open-Meteo előrejelzés, felhő-banner, naptár Felhő-oszlop** | `:438-563`, `WeatherService.swift` | ❌ — teljes egészében |
| Kalibrációs teendők ma estére + Markdown-másolás | `:293-344` → `AppState.swift:3211` | ❌ |
| Kiválasztott sor égi íve (magasság-görbe) | `:744-770`, `SkyChartView.swift` | ❌ — V2-ben sehol nincs magasság-chart |
| Verdict-magyarázó popover (max. magasság / látható órák / Hold) | `SharedComponents.swift:389-457` | ❌ — csak a verdict szövege látszik |
| Metrika-ⓘ popoverek (fogalomtár-hivatkozással) | `MetricInfoButton.swift:17-88` | ❌ |
| Sor-menü: riportok, plate-solve, cél, Finder | `:923-941` | 🟡 — csak a projekt megnyitása maradt |
| 30 éjszakás naptár (sötét órák, Hold, legjobb célpontok) | `:960-1091` | ✅ (`NightsView.swift:93-114`) |
| **„Terv erre az éjszakára”** — egy dátum teljes tervének megnyitása | `:1070` → `loadPlan(date:)` | ❌ (a CSV is jelzi) |
| Legjobb célpontnevek linkként | `:1158-1177` | ❌ — sima szöveg |
| Első lépések kártya (checklist) | `FirstStepsChecklistView.swift` | ❌ |

---

## 4. Felfedezés → V2 Planning

V1: `Views/DiscoveryPage.swift`.

| Funkció | V1 | V2 |
|---|---|---|
| Setup-választó a **felhasználó saját felszerelés-presetjeiből** | `:124-136`, `config.imagingSetups` | 🟡 — a `PlanningStore.swift:58-77` **3 beégetett setupot** használ; a felhasználói felszerelést sosem olvassa |
| Fókusztáv-felülbírálás (slider + mező + stepper + Alapérték + újraszámítás) | `:138-215` | 🟡 — csak sima slider |
| „Meglévő célpontok elrejtése” | `:90` | ❌ |
| Sor-menü: Új session létrehozása…, Ma esti ív… (égi ív sheet) | `:602-614, 734-773` | 🟡 — csak „Plan Selected” → új projekt; égi ív ❌ |
| Helyszín-felismerés a képfejlécekből | `:301-306` → `recognizeSiteFromImageHeaders` | ❌ |

---

## 5. Előző éjszaka / Minden célpont / Éjszakák → V2 Nights + Projects

**Előző éjszaka** (`PreviousNightPage.swift`): a V2-ben egyetlen `needsReviewCount` metrika-kártya van (`NightsView.swift:37`). ❌ Hiányzik: „Új sessionök pontozása” batch, kártyánkénti Pontozás, Átnézés… (`FrameReviewSheet`), Éjszaka-riport, session-műveletmenü.

**Minden célpont** (`AllTargetsPage.swift`):

| Funkció | V1 | V2 |
|---|---|---|
| Célponttábla + keresés | `:174-181` | ✅ (`ProjectsView.swift:43-96`) |
| **Mappa drag-and-drop → részszken** (megerősítéssel) | `:209-228` | ❌ |
| Megnyitás Finderben | `:495-496` | ❌ |
| Cél beállítása (`GoalEditSheet`: összóra **+ szűrőnkénti célok** + törlés) | `GoalEditSheet.swift:31-160` | 🟡 — V2-ben egyetlen óramező, nincs szűrőnkénti cél, nincs törlés (`ProjectWorkspaceView.swift:107-141`) |
| Besorolás (wide-field / deep-sky / auto) | `:511` → `setWideFieldOverride` | ❌ |
| **Exportálás → AstroBin CSV / CSV / Markdown** | `:517-520` → `exportAcquisition` (`AppState.swift:2191`) | ❌ — V2-ben sehol nincs acquisition-export |
| Célpont-riport / Éjszaka-riport | `:522` → `AppState.swift:4338, 4308` | ❌ |
| Plate-solve… | `:525` | ❌ |
| Címkék (hozzáadás/eltávolítás/keresés) | `:528-533` → `AppState.swift:3422, 3444` | ❌ — V2-ben nincs tagging |

**Éjszakák** (`NightsPage.swift`): év+hónap szűrő → 🟡 (V2: csak hónap); frissítés ❌; sor-menü = teljes session-műveletmenü → 🟡 (V2: csak „Open Night”).

---

## 6. SessionActionMenu — a legnagyobb egyedi hiány

`Views/SharedComponents.swift:205-292`; négy oldalról használt, 12 műveletes menü. V2-megfelelője csak két elemnek van:

| Művelet | Handler | V2 |
|---|---|---|
| Célpont megnyitása | — | ✅ |
| Session átalakítása gyűjtésekre… | `CaptureWorkflowSheets.swift:495` | 🟡 (lásd 7. szakasz) |
| Megnyitás Finderben | `AppState.swift:5839` | ❌ |
| **Kalibráció linkelése…** (`CalibLinkSheet` + apply) | `AppState.swift:4173, 4214` | ❌ |
| Stackelés előkészítése… (keep-fraction slider + export) | `AppState.swift:4269` | ❌ |
| Keretek pontozása | `AppState.swift:4676` | ❌ |
| Éjszaka-riport készítése | `AppState.swift:4308` | ❌ |
| Éjszaka-jegyzet szerkesztése… (README kulcs-érték mezők, egyéni kulcsok, README-érték átvétele) | `SessionNoteSheet.swift:28-320` → `saveSessionNotes` | ❌ — V2-ben csak projektszintű szabad szöveg van |
| Megnyitás a Trendeken (setup-szűrt deep link) | `:255` | ❌ |
| Új capture-gyűjtés… (CRUD) | `AppState.swift:5329, 5357, 5386` | ❌ |
| Címke hozzáadása / eltávolítása | `:271-277` | ❌ |

---

## 7. Célpont-részletek → V2 Project workspace / Review / Results / Conversion

**Oldal-toolbar** (`TargetDetailPage.swift:149-165`): Riport…, Exportálás…, Besorolás — mind ❌.

**Áttekintés szegmens** (`TargetDetail/OverviewSegment.swift`): szűrőnkénti cél-tábla (usable/integráció/cél/hiány, `:193-215`) ❌; **publikálási-készenlét checklist műveletgombokkal** (`:243-264`) ❌; plate-solve, szenzormérés innen ❌.

**Minőség szegmens** (`QualitySegment.swift`, 1562 sor) → V2 `ReviewWorkspace.swift` — itt a legmélyebb a szakadék:

| Funkció | V1 | V2 |
|---|---|---|
| Accept / Reject / Clear verdict | `:1239-1246` | ✅ (⇧⌘A / ⇧⌘R, `ReviewWorkspace.swift:156-183`) |
| Frame-tábla FWHM/HFR/háttér/excentricitás/score oszlopokkal + oszlopválasztó | `:548-557` | ❌ — a V2 tábla 3 fix oszlop, **mért metrika egy sincs** |
| **Keretek pontozása** (újramérés, Siril/natív) | `:449-458` → `runRate` | ❌ |
| **`FrameReviewSheet`: képelőnézet, ←/→ lapozás, a/x/u gyorsbillentyűk** (blink-átnézés) | `FrameReviewSheet.swift:230-263` | ❌ — V2-ben nincs vizuális frame-átnézés |
| Kiugrók átnézése / összes kiugró elvetése batch | `:488-499` | ❌ |
| **Áthelyezés archívumba / visszaállítás (apply)** | `:1234, 1249` → `applyFrameArchive` (`AppState.swift:4891`) | 🟡 — V2 csak előnézetet mutat, alkalmazni nem tud (`ReviewWorkspace.swift:256-288`) |
| Thumbnails + QuickLook nagy előnézet | `ThumbnailCell.swift`, `QuickLookController.swift` | ❌ — V2-ben sehol |
| Capture-besorolás… (scope + csoport + felülbírálások) | `CaptureWorkflowSheets.swift:277-412` → `assignCaptureMetadata` | ❌ |
| Session-/capture-csoport szűrőmenük | `:404-447` | ❌ |

**Stackek szegmens** → V2 Results: Megnyitás / Finder / útvonal-másolás ✅ (`ResultsView.swift:129-137`); thumbnail-oszlop, QuickLook, stack-lista-előkészítés ❌.

**Jegyzetek szegmens**: riportfájl-lista Megnyitás / Finder / **Újragenerálás** műveletekkel (`NotesSegment.swift:117-124` → `regenerateReport`) ❌.

**Konverziós wizard** (`CaptureWorkflowSheets.swift:495-830` → V2 `ConversionWorkspace.swift`) — a legélesebb részleges eset: a 3 lépcsős wizard és a logikai előnézet megvan, de ❌ a javasolt csoportnév/szenzor/jelzés/szűrő szerkesztése, ❌ a kétértelműség-feloldás („Hová tartozik?”), ❌ maga az **alkalmazás** (`applySessionConversion`), ❌ a bizonylat-megnyitás és a **visszavonás** (`rollbackSessionConversion`). A V2 záró gombja: „Done / Preview only”.

---

## 8. Kalibráció, Audit/Takarítás, Trendek, Szenzor, Szűrők

**Kalibráció** (`CalibrationPage.swift`, 541 sor) → V2 Health: a V2 `LibraryHealthQuery` **nem hívja** a V1 kalibrációs motorokat (`CalibAnalyzer`, `CalibHealth`, `SessionMatcher`), hanem két nyers SQL-jelzést számol (session fény van + flat nincs / dark nincs — `LibraryHealthQuery.swift:47-80`). Ezért ❌: master-könyvtár leltár és kiválasztás, **linkelés-előnézet + apply** (`CalibLinker`, `WriteGuard.linkCalibrationFile`), eltérés-magyarázat (gain/offset/binning/kamera), dark-öregedés és nem használt masterek, flat-fegyelem, bias-lefedettség, bevásárlólista, master-mappa Finderben, kalibrációs tolerancia-beállítások.

**Audit/Takarítás** (`AuditPage.swift`) → V2 Health + Cleanup preview:

| Funkció | V1 | V2 |
|---|---|---|
| Audit futtatása (+ gyors, duplikátum nélkül) | `:273-292` → `runAudit` | ❌ — a V2 csak index-pillanatképet olvas |
| **Fixity/integritás-ellenőrzés** (minta 10% / hiányzó összegek pótlása) | `VerifyConfirmationSheet.swift:65-79` → `runVerify` | ❌ |
| **Ack: csoport rendben-jelölése / visszavonása + történet** | `:580-587` → `ackFindingGroup` (`finding_acks` tábla, `Database.swift:717`) | ❌ — a V2 metadata-DB-ben az ack csak befagyasztott `legacy_imports` JSON; nincs natív tábla, API, UI |
| „Rendben-jelöltek” / „Csak az újak” szűrők (AuditDiff) | `:299-308`, `AuditDiff.swift:21-61` | ❌ |
| Javító / karantén-script generálás | `:319-326` → `generateSuggestions`, `generateCleanupScript` | ❌ |
| Útvonalak másolása, első fájl Finderben | `:589-596` | ❌ |
| Tárhely célpontonként (top-lista + műveletek) | `:733-785` | ❌ |
| Cleanup-jelöltek listázása | `:692` | ✅ read-only előnézetként (`CleanupPreviewView.swift`) |
| **Karantén-apply** (jóváhagyott, naplózott, visszavonható) | V1-ben script-útvonal; V2-ben a teljes `LibraryMutationAuthorizer` gépezet (1428 sor, 22 teszt) készen áll | ❌ — a `CleanupPreviewQuery` fixen `canApply: false` (`:44`), a `mutationConfirmation` route placeholder (`V2RootView.swift:658-690`) |

**Trendek** → V2 Insights: idősávváltó, célpont-típus szűrő, „Szűrők törlése”, frissítés, **chart-pontra kattintva session megnyitása** (`TrendsPage.swift:387`) — mind ❌; év- és setup-szűrő ✅.

**Szenzor-profilok** (`SensorPage.swift`) → V2 `SensorProfilesView.swift`: ❌ a mérésindítás (megerősítő sheet → hosszú művelet → progress → mégse; `measureSensorProfiles`, `AppState.swift:4407`), ❌ a történet-sparkline-ok (a V2 query a `sensor_profile_history` táblát **nem is olvassa** — `SensorProfilesQuery.swift:36-45`), ❌ a hiányzó-profil figyelmeztetések (`combosMissingProfile`).

**Szűrők** (`FilterProfilesPage.swift`) → V2 Settings ▸ Equipment: hozzáadás/törlés ✅; ❌ meglévő szűrő **szerkesztése**, ❌ a „már használt, de nincs a listában” auto-felismerés + Importálás (`:197-234`), ❌ AstroBin ID-hozzárendelés. Ráadásul a V2 szűrőlista `UserDefaults`-ban él (`SettingsStore.swift:44`), nem a könyvtár-DB-ben, mint a V1-é.

---

## 9. Beállítások: V1 7 tab → V2 5 tab

| V1 tab | V1 fájl | V2 |
|---|---|---|
| **Helyszín** — site-lista CRUD, koordináták, **Open-Meteo kapcsoló** | `LocationSettingsView.swift:76-211` | ❌ teljes egészében |
| **Minőség/Pontozás** — Siril-útvonal + tallózás, 7 pontozási súly, expozíció-tanácsadó, integrációs cél min/max | `RatingSettingsView.swift:60-237` | ❌ teljes egészében |
| **Kalibráció** — öregedés, toleranciák, GAIN/OFFSET/binning/kamera match | `CalibrationSettingsView.swift:36-151` | ❌ teljes egészében |
| **Könyvtárszabályok** — residue-minták, futás-suffix/dátumeltérés, wide-field, statisztika | `LibraryRulesSettingsView.swift:45-166` | ❌ teljes egészében |
| **Könyvtár** — legutóbbiak, config.json megjelenítése, auto-scan mountkor, kizárások, **AstroBin-mapping**, onboarding-újraindítás | `LibrarySettingsView.swift:32-199` | 🟡 — a V2 Libraries tab egyetlen (halott) kapcsoló |
| **Felszerelés** — teljes setup CRUD (kamera, f/, hatásfok, szenzor-presetek, prime/zoom, fókusztartomány) | `EquipmentSettingsView.swift:104-247` | ❌ — a V2 Equipment tab csak szűrőtábla; a kamera/optika presetek beégetve a `PlanningStore`-ban |
| **Támogatás** — valós diagnosztika élő állapotból, Másolás, **Mentés fájlba**, ürítés | `SupportSettingsView.swift:35-51` | 🟡 — a V2 diagnosztikája **csupa nulla placeholder** (`V2SettingsView.swift:150-159`: `databaseSchemaVersion: nil, libraryConnected: false, targetCount: 0…`), fájlba mentés nincs, doksi/support/forrás linkek nincsenek |

**CSV-n túli lelet:** a V2 öt tabjából három olyan `@AppStorage` kulcsokat ír, amelyeket **semmi nem olvas** — `v2.general.showGuidance`, `v2.library.scanOnOpen`, `v2.planning.referenceHours/referenceFocalRatio/referenceSurfaceBrightness` (az `IntegrationTimeModel.swift:45-46` beégetett `10.0`/`22.0` értékekkel számol). A CSV a `settings-planning` sort „complete”-nek jelöli — a kódban ez egy no-op űrlap.

---

## 10. Első indítás, onboarding, hibahelyreállítás

| Funkció | V1 | V2 |
|---|---|---|
| Üdvözlő: mappa-drop + struktúra-súgó | `WelcomeView.swift:100-133` | 🟡 — picker + drop megvan, súgó ❌ |
| Első scan: „Auditot is futtassunk most?” | `FirstScanView.swift:87-156` | 🟡 — mégse + személyre szabás megvan, audit-a-scan-után ❌ |
| **7 oldalas onboarding-wizard** (helyszín/felszerelés/szűrők/minőség/célidő) | `OnboardingWizardView.swift:13-427` | ❌ — a V2 „Personalize…” a jórészt üres Settingsre mutat |
| Hozzáférés-megtagadva: Adatvédelem-beállítások megnyitása + újrapróbálás | `AccessDeniedView.swift:66-74` | 🟡 — másik mappa/vissza megvan, Privacy-link és retry ❌ |
| Legacy-migráció választó (tiszta indítás / átvétel) | `WelcomeView.swift:24-25` | ❌ |
| Kötet-mount auto-scan | `AppState.swift:1561, 1596` | ❌ |

---

## 11. A paritás-CSV korrekciói

A `docs/superpowers/reviews/v2-feature-parity.csv` öt „complete” sora a kód alapján túlállít; javasolt visszaminősítés `beta-partial`-ra konkrét `known_gap` szöveggel:

1. **`target-detail`** — hiányzik: vizuális frame-review, mért minőség-oszlopok, pontozás, archiválás-apply, capture-besorolás, riportok, exportok, címkék, szűrőnkénti célok.
2. **`all-targets`** — hiányzik: drag-drop részszken, exportok, címkék, plate-solve, besorolás, Finder.
3. **`settings-planning`** — a három preferencia-mező no-op (semmi nem olvassa).
4. **`trends`** — hiányzik: idősáv, célpont-típus szűrő, chart-pont → session drill-down.
5. **`discover`** — a setupok beégetettek, nincs új-session, nincs égi ív.

(A visszaminősítés a `V2FeatureParityTests` kapuval konzisztensen tehető meg: `beta-partial` + nem-üres `known_gap`.)

---

## 12. A CSV-ben egyáltalán nem szereplő hiánycsoportok

1. Műveletek + Súgó menü (7 batch-művelet, 9 súgóelem) — teljesen eltűnt.
2. Globális újra-szken (⌘R).
3. Activity log, toastok, művelet-megszakítás; a bekötetlen `OperationCenter`.
4. Finderben-megnyitás / útvonal-másolás a legtöbb entitásra.
5. Thumbnails + QuickLook.
6. Címkék.
7. Wide-field/deep-sky besorolás-felülbírálás.
8. **9 export-útvonal** (AstroBin/CSV/MD acquisition, célpont- és éjszaka-riport, terv CSV/vágólap, bevásárlólista, stack-lista, audit/cleanup scriptek).
9. Frame-mérés/pontozás (Siril + natív) és a mért oszlopok.
10. Sidebar-badge-ek / fázismodell.
11. A fő ablak inspector-stubja.
12. Halott V2-preferenciák (9. szakasz).
13. Fogalomtár + metrika-magyarázatok rétege.
14. Éjszaka-szintű strukturált jegyzetek (README kulcs-érték).

---

## 13. Javasolt prioritás

A folyamatban lévő hat paritás-munkaterület (schema v5 ack/history; kalibráció-linkelés + masterválasztás; karantén-apply; szenzormérés; result-keresés; settings/support) **jó lefedést ad a 8. és 9. szakasz mag-hiányaira**, de az audit alapján érdemes eléjük/melléjük venni:

1. **Műveleti gerinc:** `OperationCenter` bekötése + toast/activity/cancel — enélkül minden később bekötött hosszú művelet (audit, pontozás, szenzormérés, apply) visszajelzés nélkül fut.
2. **Újra-szken (⌘R)** — a leggyakoribb napi művelet; ma a V2-ben nem létezik.
3. **SessionActionMenu-paritás** a Nights/Projects táblák kontextusmenüjében (Finder, riport, jegyzet, linkelés, pontozás) — egy menü, sok hiány egy helyen.
4. **Frame-review minimum:** mért oszlopok + pontozás-futtatás + `FrameReviewSheet`-szintű vizuális átnézés; e nélkül a Review workspace a V1 blink-workflow-t nem váltja ki.
5. **Exportok** egységes V2 export-szolgáltatásként (acquisition, riportok, terv, stack-lista).
6. A CSV öt túlállító sorának visszaminősítése (11. szakasz) — hogy a paritás-kapu ismét a valóságot mérje.

---

## 14. Bizonyíték-megjegyzés

A V1-oldali „működik” minősítés mögött: valódi `AppState`-handler + a mögötte lévő core-motor tesztjei (`AcquisitionExportTests`, `CalibLinkerTests`, `CalibHealthTests`, `AuditTests`, `AuditDiffTests`, `SensorProfileTests`, `FrameArchiveTests`, `CaptureWorkflowSurfaceTests` stb.). Az `AstroToolApp` targetnek nincs saját unit-teszt targetje (`Package.swift:29-40`), tehát a V1 UI-réteg maga csak motor-szinten fedett — ez a V2-portolásnál érv a store-réteg + surface-teszt párosa mellett, ahogy a már portolt területeken történt. A V2-oldali MISSING/PARTIAL minősítések mindegyike kódellenőrzésen alapul (fájl:sor hivatkozások a táblázatokban).
