# PLAN-R12 — Újra-átnézés utáni javítások + második funkciókör

> Élő terv-fájl. Előzmény: PLAN-R11.md (T1–T17 mind leszállítva, 1295 teszt).
> Az R12 bemenete: 5 workflow-validátor + kód-review + UX-sweep + 4 persona
> újranézés a friss állapoton (2026-08-08). Vasszabályok változatlanok
> (PLAN-R11.md). FONTOS többlet-szabály: az AstroCore HÁLÓZAT-MENTES marad —
> a weather-funkciók app/CLI rétegben vagy külön kis targetben élhetnek.

## Állapot

- [x] 0. Újra-átnézés lefutott, eredmények feldolgozva
- [ ] 1. U-hullám (javítások): U1 [x] U2 [x] U3 [x] U4 [ ] U5 [ ]
- [ ] 2. Release v0.13.0 (R11 + javítások)
- [ ] 3. V-hullám (új funkciók): V1 [ ] V2 [ ] V3 [ ] V4 [ ] V5 [ ] V6 [ ] V7 [ ]
- [ ] 4. Záró review + release v0.14.0

## 1. Összegzett vélemény (újra-átnézés után)

**Ami beérett (nem nyúlunk hozzá):** a sidebar most már "térkép, nem menü"
(derivált szegmens-route-ok, feltételes sorok); a szűrő-dimenzió a
gyűjtés-oldalon végig ér (kártya→cél→ajánlás→stacklist egy forrásból); a
kezdő-réteg (checklist, Fogalomtár, verdikt-popover, percentilis) tanít; a
CLI gépi szerződése (exit-kódok, schema_version, changed_targets) pipeline-
képes; a mérési réteg (verify, szenzor-történet, trendek) pro-szintű.

**A három szerkezeti tanulság:**
1. **Állapot-versenyek az AppState-ben** — az egy-slotos currentTask +
   láncolt loaderek mintája négy helyen okoz valós hibát (site-váltó,
   scan-elvesztés, reviewFrames, Trends-cache). Egy összevont, bundle-elt
   loader-minta kell (a loadDashboardData már jó példa).
2. **A láncok "utolsó métere" hiányzik** — stack-export után nincs kéz
   (Siril/DSS/WBPP), publikálásnál a CSV hibás több szűrőnél, a triage-
   kártyáról 4 lépés a kiugró-döntés. Az összekötés olcsóbb, mint új felület.
3. **A kezdő legnagyobb fala változatlan**: nem kanonikus (ASIAIR) könyvtárral
   a scan "sikerül", de minden üres — a rendezés-varázsló az egyetlen tétel,
   ami nélkül a célcsoport harmada be sem tud lépni.

## 2. U-hullám — javítások (a validátorok/review találatai)

### U1 — Állapot/loader javítások (app)
1. **Site-váltó összevont loader**: új `AppState.loadSiteScopedData(date:)`
   (loadDashboardData mintára): EGY Task-ban plan+nightInfo+resolvedSite,
   feltételesen month/discovery (ha be volt töltve), loadWeather CSAK az új
   resolvedSite landolása után. Hívja: TonightPage sitePickerSelection setter
   ÉS LocationSettingsView.save(). A TonightPage 135–139. sor hazug kommentje
   javítandó.
2. **Scan-védelem**: a runScan eredmény-alkalmazása ne vesszen el, ha közben
   read-only loader indul (a scan ne a közös currentTask-slotban fusson, vagy
   az eredmény-írás ne függjön Task.isCancelled-től) — a freshSessionKeys/
   lastScanDate/scanSummary mindig landoljon, ha a scanner végigfutott.
3. **reviewFrameScores verseny**: target|date kulcs-ellenőrzés visszaíráskor +
   onDisappear cancel; a frameVerdicts ne szűküljön mellékhatásként.
4. **Nem-observált UserDefaults propertyk**: firstStepsCardDismissed,
   autoScanOnMount, selectedSiteName → tárolt @Observable property + didSet
   UserDefaults-írás (cloudBannerDismissed minta).
5. **Trends frissesség**: runScan/runRate végén trendPoints=nil + "Frissítés"
   toolbar-gomb; NightsPage/SessionsSegment sor-menüben "Megnyitás a
   Trendeken" (setup-előszűréssel).
6. **effectiveSiteName** case-insensitive validálás; site-chip ("Helyszín:
   <név>") a Felfedezés és Naptár fejlécén, ha >1 site.

### U2 — Stacklist/export javítások (core+app)
1. **EXDEV copy-fallback** a stacklist exportban (hardlink kötethatáron) +
   érthető hiba, docs-pontosítás.
2. **Re-export konzisztencia**: exportkor a lights/ fa szinkronba hozása a
   friss kiválasztással — a .astro_tool/stacklists/<slug>/ a tool SAJÁT
   állapota, ezen belül (és CSAK ezen belül, szigorú útvonal-guarddal) a
   kiválasztásban nem szereplő korábbi hardlinkek eltávolíthatók; a művelet
   előtt a sheet/CLI jelezze ("N elavult link eltávolítása"). Teszt: régi
   linkek eltűnnek, a képkönyvtár érintetlen, dssfilelist/ssf/manifest
   konzisztens.
3. **--keep-filter** case-insensitive kulcs + warning ismeretlen szűrőnévre;
   "(nincs szűrő)" bucket CLI-alias (`none=0.8`).
4. **Slug/név ütközések**: üres filter-slug → "filter_N" fallback;
   slug-ütközésnél utótag; bucketen belüli azonos fájlnévnél suffix; teszt.
5. **StackListSheet**: cél-felirat a valós slugolt útvonallal + .ssf említés;
   a QualitySegment kontroll-sávjába "Stackelés előkészítése…" gomb
   (selectedDate-tel).
6. **manifest.csv**: kommentsor a library-gyökér abszolút útvonalával.
7. **DSS-ingest guard**: source=="app" verdict-et az ingest SOHA ne írja
   felül (info.txt-ág mintájára). Teszt.

### U3 — Verify/audit javítások
1. **Verify-találatok megőrzése**: runAudit őrizze meg a verify-kategóriákat;
   openRoot töltse vissza a legutóbbi "verify"-run findingjait; "Utolsó
   integritás-ellenőrzés: <dátum> · N fájl · M eltérés" sor az Audit oldalon.
2. **Csempék**: verify-only futás után a 3 audit-csempe maradjon "n/a ·
   nincs audit"; isEverythingClean ne mondjon zöldet audit nélkül.
3. **Diff×verify**: verify-kategóriájú csoport mindig "új"-ként látszódjon a
   "Csak az újak" szűrőben (vagy a szűrő kapcsolódjon ki runVerify után).
4. **Klasszifikáció**: (mtime változott, méret azonos) → NE content-changed:
   új "modified-in-place" kategória suspicious szinten; usageText/cli.html
   szöveg-ellentmondás javítása; read-error súlyosság suspicious-ra.
5. **Lefedettség**: VerifyConfirmationSheet mutassa "N fájlnak van
   ellenőrző-összege az M-ből (X%)" + "Hiányzó ellenőrző-összegek pótlása"
   opció (baseline-hash, DB-írás, képfájlokhoz nem nyúl); CLI:
   `verify --baseline`.
6. **Audit-diff**: a runs.config_json includeDuplicates összevetése — eltérő
   beállításnál a duplicate-kategóriák kimaradnak a diffből (vagy felirat).
7. **Karantén-utóélet**: Takarítható szegmensben "Karantén" sor
   (.astro_tool/cleanup_quarantine mérete + legrégebbi batch + Finder).

### U4 — Publikálás/cél javítások
1. **AstroBin CSV szűrőnként**: (session, filter, nominális expozíció)
   csoportosítás, soronként saját filter-ID; több-szűrős teszt. Ez BUG-fix
   (ma a domináns szűrő alá gyűri).
2. **Filter-goals a modellben**: ProjectStatus.buildState collecting-feltétel
   + todo ("hiányzik még 6,5h SII"); ProjectState.filterGoals additív mező;
   Planner.score missingNeed = max(összcél, legnagyobb szűrő-deficit);
   Hiányzik/Cél oszlopok fallbackje a szűrő-célok összegére.
3. **GoalEditSheet**: "Cél törlése" kérdezzen rá a szűrő-célokra; összcél-
   stepper 0-ról induljon, ha nincs cél (ne írjon akaratlan goal:10h-t);
   "+ szűrő" sor új (még nem fotózott) szűrőre.
4. **Riportok**: TargetReport "Szűrők" tábla (merge-ből); NightReport
   date-scoped filter-bontás; report/target-report --out PATH honorálása.
5. **Unmapped filterek**: app-toast nevekkel; Settings-szerkesztő
   "használt, még nem leképezett szűrők" előajánlás + case-normalizált kulcs.
6. **Publikálás-kész kapu**: TargetDetail "Exportálás…" mellé státusz-sor
   (fázis, célok szűrőnként, unmapped filterek, van-e feldolgozott kimenet)
   kattintható javító-akciókkal.

### U5 — Apró sweep (UX/CLI/docs/perf)
1. BatchRejectOutliersConfirmSheet literál "n/a" → TDFormat; flatSummaryText
   "—" → "hiányzik"/"✗"; TrendsPage "e⁻/s/□″" → "e⁻/s/″²" (2 string +
   features.html); AuditPage privát formatBytes → TDFormat.bytes.
2. MetricInfoButton opcionális Fogalomtár-horgony (vagy doc-komment javítás).
3. Menüsor: feltételes "Előző éjszaka" menüpont; "Szenzor" → "Szenzor-
   profilok"; features.html: T6/T7/T8 funkciók + Súgó-lista + meta.
4. CLI usage: plan/night-info `--site` feltüntetése; `calib --shopping
   [--date --site --json]` (CalibShoppingList CLI-ből); bevásárlólista-felirat
   dátum-követő ("… <dátum> éjszakájára"); CalibShoppingList doc-frissítés.
5. Kalibráció: teendő-nyelvezet egységesen felszólító; flat "Linkelés…" az
   ÉRINTETT session-t nyissa (CalibNeed hordozzon (target,date) párokat);
   Kalibráció oldalról link a Settings ▸ Kalibráció fülre; pre-audit
   Takarítás-nézeten is legyen szegmens-picker.
6. LibraryPercentiles: midrank (azonos értékek ne legyenek mind "worst") +
   "kevés adat (N/6)" semleges jelzés; percentilis-pötty a triage-kártyán.
7. Terv-CSV: `night` oszlop + nyers `filter` + `filter_missing_hours` +
   `missing_hours` (pont-tizedes); NSSavePanel default "terv-<dátum>.csv";
   exportPlanToCSV hibaág az aktivitás-naplóba.
8. Perf: NightsQueries.allNights ne fizessen O(sessions×files)-t a
   FilterBreakdown-ra (egyszer lekért file/meta készlet átadása).
9. v10 migráció tranzakcióba (vagy oszloplét-ellenőrzés) — általános
   migráció-guard minta.
10. Triage-kártya: hasNotes/hasConflict ikon + "Jegyzet…" akció +
    SessionActionMenu context-menü + fejléc-szám a kártyaszámból; letiltott
    "Átnézés…" gomb magyarázó felirattal; megszakított batch-pontozás után
    kártya-rebuild; SessionsSegment README-cella ütközés-⚠️.

## 3. V-hullám — új funkciók (persona-prioritás szerint)

### V1 — Rendezés-varázsló (kezdő #1, MAGAS)
`astrotool organize [--from <mappa>] --suggest [--json]` + app "Rendezés…"
varázsló (FirstScanView + Súgó menü). Bemenet: a root nem kanonikus fájljai
vagy külső forrásmappa. Javaslat a fits_meta-ból: DATE-OBS→session-dátum,
IMAGETYP→szerep, OBJECT/fájlnév-minta→célpont (ASIAIR minták), FILTER.
Kimenet: előnézeti tábla (jelenlegi→javasolt út, konfidencia, soronként
kihagyható) + mkdir/mv javaslat-script a .astro_tool/suggestions/-be (YES-
kapuval; a tool maga SOHA nem mozgat). Strukturáltság-mérő: scan-összegzőbe
és FirstScan-kártyára "N fájlból M kanonikus területen kívül (X%)"; Első
lépések 0. lépés ("Mappastruktúra"); `scan --json` other_area_files mező.

### V2 — Triage v2 (MAGAS)
Friss sessionök a DB-ből (runs/files: scannedAt az utolsó előtti scan-run
után) → app-újraindítást és CLI-scant is túléli; a feltételes sidebar-sor
ebből él. Kártyán: "Kiugrók átnézése (N)" (subsetLabel-es FrameReviewSheet,
isOutlier && nincs verdict), badge az elbírálatlan kiugrók számával (zöld ha
0), opcionális "Összes kiugró elvetése…".

### V3 — Projekt-stacklist (MAGAS)
`stacklist --target T --all-sessions` + app "Projekt-stacklist
előkészítése…" (StacksSegment/TargetDetail): minden session usable+verdikt-
szűrt keretei szűrőnként, EGY fa: lights/<FILTER>/<date>_<fájl> hardlinkek,
közös manifest.csv, szűrőnként összesített dssfilelist. `--with-calib` /
sheet-checkbox: linkelt masterek hardlinkje calib/ alá + KIKOMMENTEZETT
`# calibrate` sor az .ssf-ben. Export után: "Megnyitás Sirilben" gomb +
"Hogyan tovább?" mini-súgó (Siril/DSS/WBPP 3 út). Szűrőnkénti keep-értékek
perzisztálása configban (stacking.keepFractionPerFilter). Cleanup: a
stacklists/ régi exportjai a cleanup --suggest körébe.

### V4 — Site v2 + időjárás-összevetés (KÖZEPES-MAGAS)
SiteProfile += opcionális timeZone (IANA), elevationM, minAltDeg (additív
decode). A Planner a site zónájában számol, kimenetben jelölve; --json
site_timezone. Weather: a kliens kis külön modulba (NEM AstroCore-ba —
hálózat-mentesség marad), CLI `astrotool weather [--site|--all-sites]
[--json]`; app Ma este fejlécben több-site összevető sor ("Bakony 85% ☁ ·
Mórágy 20%"), kattintásra site-váltás (U1-es atomikus loaderrel).

### V5 — Karbantartás-panel + status/pipeline CLI (KÖZEPES)
"Karbantartás" panel (FirstSteps-minta, Audit oldal tetején/Súgóból):
lépésenként utolsó futás dátuma a runs-ból (scan/audit/verify/calib/sensor),
e havi pipa, ugró-gomb. CLI: `astrotool status --json` (utolsó futások,
calib-teendők, tárhely, elavult profilok; konfigurálható küszöbökkel exit 1)
és `astrotool pipeline [--rate] [--verify --sample N] [--json]`
(scan→changed_targets rate→calib→opcionális verify, egy összegző JSON).

### V6 — PHD2/NINA log-ingest (KÖZEPES)
`ingest-logs [--target T --date D]` (ingest-dss minta): PHD2 GuideLog/NINA
log felderítés a session-fában (read-only), session-RMS (össz/RA/Dec ″),
kitérés-események → additív guiding tábla. UI: SessionsSegment "Vezetés"
oszlop + triage-kártya RMS; kiugró-popoverben keret-időbélyeg ↔ kitérés
korreláció ("a felvétel alatt 2,1″ kitérés"); NightReport guiding-szakasz.

### V7 — Tervező-extrák (KÖZEPES)
(a) Naptár célpont-előrejelzés: célpont-picker a Naptárban, "SII: még ~2
éjszaka (aug 12., 13.)" — láthatósági ablak × library duty-cycle becslés,
forrás jelölve, sosem kitalált szám; `plan --month --target T --json`
forecast mező. (b) "Ma esti javaslat" kezdő-kártya a planTable fölött
(legjobb célpont + ablak + javasolt sub + cél-hiány, csak megjelenítés).
(c) VerdictExplainPopover küszöbökkel ("Hold-szeparáció 23° — 40° felett
nem zavarna") a meglévő config/Planner konstansokból.

## 4. Ticket-sorrend

U1→U2→U3→U4→U5 (javítások, egyenként commit+push, teszt-kapuval) →
**release v0.13.0** (bevált recept) → V1→V2→V3→V4→V5→V6→V7 → záró review →
**release v0.14.0**.

## 5. Iterációs napló

- 2026-08-08: újra-átnézés lezárva (11 agent), PLAN-R12 megírva. Következő: U1.
- 2026-08-08: U3 elkészült — tartós verify/audit állapot, baseline + coverage,
  konfiguráció-tudatos auditdiff és karantén-összesítő; 1333 teszt zöld.
