# PLAN-R11 — Teljes szakértői átnézés + funkcióbővítés + UI-átalakítás

> Élő terv-fájl: a tervezés ÉS a végrehajtás állapota is itt van, hogy bármely
> új sessionből folytatható legyen. Mérvadó előzmény: CHANGELOG.md (v0.12.0).
> A kör módszere: 7 feltérképező agent + 4 persona-review (kezdő / haladó /
> profi / UX-designer) → szintézis → ticket-szerű végrehajtás Sonnet
> agentekkel → záró review-kör → release.

## Vasszabályok (változatlanok)

- A képkönyvtárban SEMMIT nem törlünk/mozgatunk; a tool csak jelöl és
  jóváhagyandó scriptet ír. Írás csak additívan (.astro_tool/, hardlink).
- A README.txt-t csak olvassuk. Az AstroCore hálózat-mentes marad.
- Release-recept: verzió 2 helyen (`Sources/astrotool/main.swift` +
  `build.sh`), CHANGELOG, `swift test` PIPEFAIL-lel, commit, push, tag,
  `./build.sh`, `gh release create`.

## Állapot

- [x] 0. Terv-fájl létrehozva (2026-08-07)
- [x] 1. Feltérképezés (7 agent) — kész
- [x] 2. Persona-review (4 agent) — kész
- [x] 3. Szintetizált vélemény + spec + UI-terv (lásd lent)
- [x] 4. Végrehajtás — A-hullám (konzisztencia): T1 [x] T2 [x] T3 [x] T4 [x]
- [ ] 5. Végrehajtás — B-hullám (fő funkciók): T5 [x] T6 [x] T7 [x] T8 [x] T9 [x] T10 [x] T11 [x] T12 [ ] T13 [ ]
- [ ] 6. Végrehajtás — C-hullám (pro funkciók): T14 [ ] T15 [ ] T16 [ ] T17 [ ]
- [ ] 7. Záró review-kör (kód-review + UX-sweep + persona-újranézés), javítások
- [ ] 8. Release v0.13.0

---

## 1. Szakértői vélemény (szintézis)

### Ami kiemelkedően jó — ehhez nem nyúlunk

- **A bizalom-filozófia**: "soha nem töröl/mozgat, csak jelöl" + karantén-script
  + hardlink-export. Ez az eszköz legfontosabb terméke, minden felületen jól
  kommunikált (Welcome, kék banner, script-fejlécek).
- **Őszinte mérés**: usable vs bruttó integráció (FrameSet dedup), per-Bayer
  háttér, bias-pedestal-lal korrigált e⁻/s/″², "sosem becsül, notAvailableReason"
  (ExposureAdvisor). Publikálás-minőségű mérési réteg.
- **CLI-paritás ~100%** közös determinisztikus JSON-encoderrel — scriptelhetőség
  szempontjából a kereskedelmi eszközök fölött van.
- **Információs architektúra alapja jó**: a sidebar (tervezés → KÖNYVTÁR →
  ÁLLAPOT → ESZKÖZÖK) követi az asztrofotós mentális modelljét. A 9 oldalt NEM
  kell se összevonni, se szétszedni.
- Súgó-infrastruktúra (ⓘ "mikor hazudik" szekcióval, Fogalomtár, üres állapotok
  akciógombbal), "Következő lépés" sor, blink-review A/X/U.

### A fő hiányok (mind a 4 persona egybehangzóan)

1. **A szűrő-dimenzió hiányzik a teljes döntési láncból.** A core-ban kész a
   FilterBreakdown, de a UI-ban sehol: a cél egyetlen összóraszám, a "Hiányzik"
   aggregátum, a tervező nem tudja, hogy Holdas égen Ha/SII-t, sötét égen
   OIII/LRGB-t érdemes lőni. Mono+szűrőkerekes (haladó/profi) felhasználónak ez
   A projekt-állapot alapegysége.
2. **A gépi "Kiugró" és a "Saját döntés" két néma, össze nem kötött rendszer**
   — pont a review-hurok közepén nincs híd (miért kiugró? vessem el? mind
   egyszerre?).
3. **Az éjszaka utáni reggeli rutin szét van szórva** 4-5 oldalra; minden
   építőelem kész (rate, NightHealth, SessionQuality, riport), csak nincs egy
   "Előző éjszaka" lapra fűzve.
4. **A kezdő a legelső lépésnél magára marad**: nem kanonikus (ASIAIR-szerkezetű)
   könyvtárnál a FirstScan piros X-eket mutat segítség nélkül; a Fogalomtárból
   pont azok a fogalmak hiányoznak, amiket az app maga kérdez (Bortle, SQM,
   seeing); a számoknak (FWHM 2.8″) nincs viszonyítási alapja.
5. **Skálázási rések a pro szinten**: egy helyszín, felülíródó szenzor-profil
   (öregedés nem követhető), nincs hosszú távú trend-nézet, nincs
   fixity/bitrot-ellenőrzés (pedig a content_hash megvan), durva exit-kódok,
   verziózatlan JSON-séma.
6. **Konzisztencia-adósságok**, amik együtt a megbízhatatlanság érzetét keltik:
   háromféle hiányzó-érték jel ("-", "n/a", "—" akár egy táblán belül), verdikt
   hol chip hol csak szín, két hamis sidebar-route (Naptár, Takarítás
   szegmens-preselect), NightsPage/AllTargets akció-aszimmetria, elavult
   docs/features.html.

---

## 2. Hiányzó funkciók — pontos specifikáció

### F1. Per-szűrő integráció a UI-ban (FilterBreakdown bekötése)
- **Kinek/mire**: mono+szűrőkerekes és dual-band OSC felhasználó projekt-állapota.
- **Működés**: TargetDetail Áttekintésbe új "Szűrők" kártya (Szűrő | Usable
  keret | Integráció | Cél | Hiányzik, mini progress-sávval; "(nincs
  szűrő-adat)" külön sor). Fejléc "Valós integráció" tile caption: top
  szűrő-bontás ("Ha 8,2h · OIII 3,1h"). Integráció-halmozódás grafikon
  szűrőnként színezve. NightsPage "Szűrők" oszlop: felsorolás helyett óraszám
  ("Ha 1,5h · OIII 0,8h"), tooltip keretszámmal.
### F2. Szűrőnkénti célok
- **Működés**: tag-konvenció bővítés `goal:Ha=12h` (a meglévő `goal:30h`
  összcélként megmarad, visszafele kompatibilis). GoalEditSheet "Szűrőnként"
  lenyitás: a célpontnál ténylegesen előforduló szűrők + óra-stepper.
  "Hiányzik" tile caption: legnagyobb deficit ("legtöbb hiány: SII 6,5h");
  TonightPage "Hiányzik" cella popoverben bont. CLI: `goal set --target T
  --filter Ha --hours 12`, `goal list --json` per-filter missing mezőkkel.
### F3. Hold-tudatos szűrő-ajánlás a tervezőben
- **Működés**: küszöb-szabály (Hold-illum > 40% VAGY szeparáció < 60° →
  keskenysáv-ajánlás); NB/BB besorolás config-listából (default: Ha, OIII, SII,
  L-eXtreme, L-Ultimate = NB). TonightPage planTable új "Szűrő ma" oszlop
  chippel ("Ha/SII — Hold 82%"), tooltip indoklással; Naptár éjszaka-soraiban
  "NB" / "sötét ég" címke. Csak ajánlás, sosem hard szabály. Szűrő-deficittel
  (F2) kombinálva: "ma jó — Ha-ra".
### F4. Kiugró↔Saját döntés híd
- **Működés**: (a) ⚠️ kattintható → popover metrikánkénti z-score bontással
  ("FWHM 4.2 px, session-medián 2.9, z=−2.4") + "Átnézés" és "Elvetés" gomb;
  (b) QualitySegment kontroll-sávba "Kiugrók átnézése (N)" gomb → FrameReviewSheet
  csak a kiugrókkal; (c) "Összes kiugró elvetésre jelölése… (N)" menüpont
  megerősítő sheettel ("csak jelölés, fájlt nem érint"); (d) döntetlen kiugró
  sorban halvány "javasolt: elvetés" felirat a Saját döntés cellában.
### F5. "Előző éjszaka" triage oldal
- **Működés**: scan után, ha új session-fájl érkezett → feltételes sidebar-sor
  "Előző éjszaka" badge-dzsel a Ma este alatt (ha nincs friss anyag, nem
  látszik). Lap: session-kártyák (célpont, keret, integráció, szűrő-bontás,
  FWHM″, hűtés/fókusz verdikt, kiugró-arány) + kártyánként "Pontozás",
  "Átnézés…", "Éjszaka-riport" gomb; felül "Új sessionök pontozása" (csak az
  újakra). Opt-in beállítás: "Automatikus beolvasás kötet csatlakozásakor"
  (mount-observer már létezik).
### F6. Audit-diff
- **Működés**: audit futás után összevetés az előző run findings-ével
  (groupKey-egyezés). AuditPage tetején "+3 új · 5 megoldódott · 12 változatlan"
  összegző sor, "ÚJ" badge az új csoportokon, "Csak az újak" toggle.
  `audit --json` diff blokkal.
### F7. Trendek oldal
- **Működés**: új sidebar-sor az ÁLLAPOT szekcióban. Időtartomány-picker
  (6 hó/1 év/3 év/mind) + setup-fingerprint szűrő; 3 Swift Charts idősor
  (medián FWHM″/session, háttér e⁻/s/″², hatékonyság%) pont + mozgóátlag;
  pontra kattintás → session. CLI: `trends --metric fwhm --json`.
### F8. Szenzor-profil történet
- **Működés**: új `sensor_profile_history` tábla (append-only,
  `measured_at` + `estimator_version`); a `sensor_profile` marad "legfrissebb"
  nézet. Staleness a hardcode-olt dátum helyett estimator_version-ből.
  SensorPage sor lenyitható: mérés-lista + sparkline (read noise, dark rate).
  CLI: `sensor --history --json`. Sheet-szöveg: "új mérés kerül a történetbe".
### F9. Fixity / bitrot-ellenőrzés
- **Működés**: `astrotool verify [--target T] [--path P] [--sample N] --json` —
  tárolt content_hash újraellenőrzése; eltérés = sure_error "content-changed"
  finding (régi/új hash, mtime-változott-e). Exit 5 = eltérés. App: Audit
  toolbar split-menüben "Integritás-ellenőrzés…" megerősítő sheettel (időbecslés),
  eredmény a Hibák szegmensben saját kategóriával. Read-only, sosem javít.
### F10. Automatizálási csomag (CLI)
- **Működés**: (a) exit-kód szerződés: 0 siker, 1 usage/általános, 2 TCC/kötet,
  3 nem található target/session, 4 külső eszköz (Siril), 5 verify-eltérés —
  dokumentálva a cli.html-ben; (b) minden `--json` gyökerébe `schema_version`;
  (c) `--out PATH|-` az audit --suggest / cleanup --suggest / stacklist
  parancsokon is; (d) `scan --json` kimenetben `changed_targets` lista;
  (e) `config show` tartsa tiszteletben a `--json`-t (ember-olvasható alap).
### F11. Kezdő-csomag
- **Működés**: (a) Fogalomtár-bővítés ~15 szócikkel (Bortle, SQM, seeing,
  átlátszóság, plate-solve, master, gain/offset, ADU, EGAIN, kulmináció, sub,
  integráció bruttó/valós, dither…) + keresőmező + horgony-paraméter (adott
  szócikkre nyitás); (b) SessionNoteSheet sablonmezői mellé ⓘ (1-2 mondat +
  értékskála + példa-placeholder); (c) Siril-segéd sheet (mi ez, letöltés-link,
  mi megy nélküle — táblázattal) a Siril-hiány figyelmeztetésből, a Settings
  piros státusza mellől és a Súgó menüből; (d) VerdictChip kattintható →
  popover számokkal ("Hold zavar: 87% illum, 23° szeparáció"); (e) minőség-
  percentilis színsáv: FWHM″/hatékonyság cellák halvány zöld/sárga/narancs
  pöttye a KÖNYVTÁR SAJÁT eloszlásához mérve + tooltip ("könyvtár-medián 3.1″
  — ez a jobbik 25%").
### F12. Első lépések élő checklist
- **Működés**: 5-7 soros, DB-állapotból számolt lista (scan? audit? helyszín?
  Siril? pontozás? szenzor-profil? első stack-lista?) — soronként pipa/teendő,
  1 mondat "miért", 1 gomb (indít vagy odanavigál). FirstScan eredmény-kártya
  után automatikusan; később Súgó menü "Első lépések…" + elutasítható kártya a
  Ma este tetején, amíg <4 pipa.
### F13. Sidebar hamis route-ok megszüntetése
- **Működés**: "Naptár" a "Ma este" alá indentált valódi al-elemként (saját
  Page-érték, a TonightPage a szegmenst a route-ból kapja); "Takarítás" az
  "Audit" alá ugyanígy. A sidebar-kijelölés mindig a tényleges helyet mutatja.
### F14. Session-akció paritás
- **Működés**: közös session-akció menü-builder (egyetlen komponens), amit
  NightsPage, AllTargetsPage, SessionsSegment egyaránt használ: Megnyitás
  Finderben, Kalibráció linkelése…, Stackelés előkészítése…, Keretek pontozása,
  Éjszaka-riport, Éjszaka-jegyzet…, Címke hozzáadása/eltávolítása.
### F15. Szűrő-tudatos stack-lista + WBPP-barát export
- **Működés**: StackList.select() szűrőnkénti csoportosítással; hardlink-fa
  `lights/<FILTER>/` almappákkal; szűrőnként külön .dssfilelist; `manifest.csv`
  (fájl, szűrő, pontszám, session); .ssf szűrőnként, opcionális. Sheet:
  alapnézetben egy közös Megtartás% + szűrőnkénti élő darabszám-preview
  ("Ha 45/52 · OIII 28/40"); "Szűrőnkénti finomhangolás" DisclosureGroup mögött
  külön csúszkák; az export-cél útvonal kiírva.
### F16. Több helyszín (site-profilok)
- **Működés**: config `sites: [{name, latitudeDeg, longitudeDeg, default}]`
  (a régi `site` egyelemű listaként migrál). Session→site: legjobb
  SITELAT/SITELONG-egyezés, felülbírálás `site:<név>` taggel. Settings Helyszín
  fül: lista-szerkesztő; TonightPage: site-Picker (CSAK ha >1 helyszín);
  NightsPage opcionális Site oszlop. CLI: `plan --site <név>`.
### F17. Flat-lefedettség szűrőnként (CalibAnalyzer v2)
- **Működés**: session lightok FILTER (+FOCALLEN) kombói vs session flats/ és
  calibration_library/flats/ (kor: flatMaxAgeDays). Coverage-tábla új "Szűrő"
  oszlop; Teendők közé "Hiányzó flat: OIII — 3 session érintett" kártya;
  TargetDetail kalibráció-kártyán flat szűrőnként ("flat: Ha ✓, OIII —").
  CLI: `calib --flats`.
### F18. Terv-export + kalibrációs bevásárlólista
- **Működés**: (a) TonightPage toolbar "Terv exportálása…": vágólap
  (név + RA/Dec + ablak soronként), CSV; kijelölt sorok, különben a "ma jó"
  verdiktűek; CLI: `plan --out`. (b) Ma este lap alján lenyitható "Kalibrációs
  teendők ma estére" (CalibNeed × ma esti célpontok kombói): "☐ 30×120 s dark
  @ −10 °C, gain 100 — M31, M42 használná", Markdown-másolás gombbal; üres
  állapot: "Minden kalibráció friss."
### F19. Tárhely-nézet
- **Működés**: Takarítás szegmensben "Tárhely" kártya-blokk: célpontonként
  méret area-bontással (sessions/stacks/processed), top 10 azonnal + "összes"
  lenyitás; soronként Finder + célpont-link. Csak térkép, semmi akció.
### F20. Apró hidak
- README↔jegyzet ütközés-jelzés (sárga "eltér a README-től: <érték>" +
  "README-érték átvétele" gomb; NightsPage Jegyzet oszlop ⚠️ ütközésnél).
- wideField.overrides UI (AllTargets/TargetDetail context-menü "Besorolás":
  Automatikus/Wide-field/Deep-sky; Settings Könyvtár-szabályok fülön lista).
- AstroBin filter-ID leképezés (config `astrobin.filterIds`; export ID-t ír,
  le nem képezett névnél warning + név marad; Settings szerkesztő + toast).
- Korrupt FITS audit-szabály (fits-kind fájl fits_meta nélkül → sure_error).
- docs/features.html frissítés (Felfedezés, Éjszakák, ⌘-számozás, R11 újdonságok).

**Backlog (R12-re, ha az R11 lezárult)**: PHD2 guiding-log ingest + Vezetés
oszlop; befejezés-előrejelzés ("várható kész: ~2026. nov."); rendezés-segéd
nem kanonikus ASIAIR/NINA könyvtárhoz (mv-javaslat script, vasszabály-konform).
A rendezés-segéd NAGY tétel — külön kört érdemel, first-class tervvel.

---

## 3. UI-terv (oldalanként: mi látszik azonnal, mi kerül lenyitás mögé)

**Sidebar**: (tervezés) Ma este [⌘1] → alatta indentálva Naptár [⌘2] ·
Felfedezés [⌘3] · [feltételes] Előző éjszaka · [feltételes] Keresés —
KÖNYVTÁR: Minden célpont [⌘4], Éjszakák [⌘5], célpont-sorok, fázis-jelmagyarázat —
ÁLLAPOT: Kalibráció [⌘6], Audit [⌘7] → alatta indentálva Takarítás [⌘8],
Trendek — ESZKÖZÖK: Szenzor [⌘9]. (A Trendek shortcut nélkül indul; a ⌘-séma
többi része változatlan.)

- **Ma este**: azonnal: 5 csempe + planTable (+ új "Szűrő ma" oszlop) + kijelölt
  sor alatti SkyChart; felhő>70% esetén egysoros elutasítható jelzés a tábla
  fölött ("nézd meg a következő derült éjszakát" linkkel). Lenyitásra: lap alján
  "Kalibrációs teendők ma estére" (badge ha van tétel); "Hiányzik" szűrő-bontás
  popoverben; VerdictChip-indoklás popoverben. Gombra: Terv exportálása…
  (toolbar), Hónap = Naptár al-elem.
- **Naptár**: változatlan tartalom, saját route-tal; éjszaka-sorokban új NB/sötét
  címke a Hold mellett.
- **Előző éjszaka** (új): azonnal: session-kártyák kulcsszámokkal; gombra:
  Pontozás/Átnézés/Riport, felül "Új sessionök pontozása".
- **Felfedezés**: változatlan; nincs-helyszín üres állapota magyarázatot + két
  gombot kap ("Helyszín beállítása…", "Felismerés a képeim fejlécéből").
- **Minden célpont**: változatlan szerkezet; session-akciók a közös builderből.
- **Éjszakák**: Szűrők oszlop óraszámmal; session-akció paritás; opcionális Site
  oszlop (csak több helyszínnél).
- **Célpont-részletek**: fejléc: "Következő lépés" kártya-szerű kiemeléssel
  (fázis-színnel) — ez az oldal cselekvésre hívó fókusza; "Valós integráció" és
  "Hiányzik" tile-ok szűrő-captionnel. Áttekintés: Koordináták → Setup →
  **Szűrők kártya (új)** → Láthatóság → [mozaiknál ITT a MosaicPanelTable] →
  Ma esti ív → Integráció-halmozódás (szűrő-színes) → Expozíció-tanácsadó →
  Kalibráció (flat szűrőnként). Sessionök: Hűtés/Fókusz szín-pötty → VerdictChip.
  Minőség: kontroll-sávban szűrő chip-sor (csak előforduló szűrők) + "Kiugrók
  átnézése (N)"; tábla alapból 6 oszlop (Fájl, Szűrő, Pontszám, FWHM, Kiugró,
  Saját döntés), a többi (Kerekség/Csillagok/Háttér/Szat.%/Exp./Mappa)
  oszlop-választó menü mögött; ⚠️ kattintható (miért-popover). Stackek/Jegyzetek:
  változatlan (+ jegyzet-ütközés jelzés).
- **Kalibráció**: Teendők kártyák közérthető cselekvés-mondattal ("Hiányzik:
  30×120 s dark −10 °C, gain 100 — 3 session használná") + flat-hiány kártyák
  szűrő-névvel; kártyák felül, kombinációs tábla alattuk (új Szűrő oszloppal).
- **Audit**: tetején diff-összegző sor (audit után); Takarítható fülön
  emlékeztető-sor ha sosem futott audit + a másik 3 csempe "—" "nincs audit"
  captionnel; Takarítható szegmensben új Tárhely-blokk; toolbar split-menüben
  "Integritás-ellenőrzés…".
- **Trendek** (új): azonnal: időtartomány-picker + 3 idősor-chart; toolbar Menu
  mögött setup/site/típus szűrő.
- **Szenzor**: sorok lenyithatók (mérés-történet + sparkline); staleness
  estimator-verzióból.
- **Beállítások**: Helyszín fül → helyszín-lista szerkesztő + fülszintű reset
  (eddig hiányzott); Könyvtár-szabályok → wideField.overrides lista; Könyvtár →
  AstroBin filter-ID szerkesztő; tolerancia-mezők magyarázó captionök
  ("0 = kikapcsolva…", gainTolerance skála).
- **Globális konvenciók**: hiányzó érték = közös formázó-helper (cella "-",
  tile "n/a", SOSEM "—"); állapot-verdikt mindig VerdictChip; "⋯" oszlop
  egységesen 28pt; hibapolitika kétszintű (toast + aktivitás-napló; inline sáv
  csak ott, ahol enélkül üres lenne az oldal); minden hibaszöveg "Mit tehetsz:"
  záró mondattal (közös AstroError→tanács fordító).

---

## 4. Task-lista (ticket-szerű commitok, Sonnet agentek, push tickenként)

Minden task: implementáció + tesztek + `swift test` pipefail-lel + CHANGELOG
[Unreleased] bejegyzés + commit (`feat(app|cli|core): R11-Tx …`) + push.

### A-hullám — konzisztencia (kis kockázat, egymás után gyorsan)
- **T1 — UI-konzisztencia csomag**: közös missing-value helper (cella "-",
  tile "n/a") + minden előfordulás cseréje; Saját döntés "—"→"-"; Hűtés/Fókusz
  → VerdictChip; "⋯" oszlop 28pt egységesen; Minőség-tábla oszlop-választó +
  szűkített alapkészlet; hibaszövegek "Mit tehetsz:" fordítója.
- **T2 — Akció-paritás + apró UX**: közös session-akció builder (NightsPage/
  AllTargets/SessionsSegment); Audit kereszt-szegmens emlékeztető + "—" csempék;
  TonightPage felhő-kontextus sáv; mozaik-tábla előbbre; "Következő lépés"
  kártya-kiemelés.
- **T3 — Settings csomag**: Helyszín fülszintű reset; tolerancia/gain captionök;
  wideField.overrides szerkesztő + "Besorolás" context-menü; Siril-segéd sheet
  (3 belépési pont).
- **T4 — CLI/automatizálás + docs**: F10 teljes (exit-kódok, schema_version,
  --out, changed_targets, config show fix); korrupt-FITS audit-szabály;
  docs/features.html + cli.html frissítés.

### B-hullám — fő funkciók
- **T5 — Szűrő-dimenzió alapok**: F1 + F2 (FilterBreakdown UI + goal:Ha=12h +
  GoalEditSheet + CLI goal --filter).
- **T6 [x] — Tervező-bővítés**: F3 (Szűrő ma oszlop + NB/sötét címkék) + F18
  (terv-export + kalibrációs bevásárlólista).
- **T7 — Kiugró-híd**: F4 teljes (miért-popover, kiugrók átnézése, batch
  elvetés-jelölés, "javasolt: elvetés").
- **T8 [x] — Audit-diff + Tárhely**: F6 + F19.
- **T9 [x] — Előző éjszaka**: F5 (oldal + feltételes sidebar-sor + auto-scan opt-in).
- **T10 [x] — Trendek + szenzor-történet**: F7 + F8.
- **T11 — Stack-lista v2**: F15 (szűrő-bontott hardlink-fa, manifest.csv,
  sheet-finomhangolás).
- **T12 — Kezdő-csomag**: F11 + F12 (Fogalomtár, ⓘ-k, Siril-segéd linkek,
  VerdictChip-popover, percentilis-sávok, Első lépések checklist).
- **T13 — Navigáció + jegyzet-híd**: F13 (Naptár/Takarítás valódi al-elem) +
  F20 README↔jegyzet ütközés.
### C-hullám — pro funkciók
- **T14 — Verify**: F9.
- **T15 — Több helyszín**: F16.
- **T16 — Kalibráció v2 + AstroBin ID**: F17 + F20 AstroBin filter-ID.
- **T17 — (tartalék/összefésülő)**: az előzőekből kimaradt apróságok, review-találatok.

### Záró kör
- Kód-review agent (funkcionális hibák) + UX-sweep agent (konzisztencia) +
  persona-újranézés ugyanazzal a 4 szemmel; találatok javítása; amíg van
  érdemi találat, újabb javító-ticket.
- Release v0.13.0 a bevált recepttel.

## 5. Iterációs napló

- 2026-08-07 reggel: kör indítva; feltérképezés (7 agent) + persona-review
  (4 agent) lezárva; szintézis + teljes spec + UI-terv beírva; task-lista kész.
  Következő: T1–T4 (A-hullám) kiosztása.
- 2026-08-08: T4 (CLI/automatizálás + docs) kész — F10 teljes (exit-kódok
  3/4/5-fenntartva, schema_version minden --json gyökérben, --out PATH|-
  audit/cleanup/stacklist-en, scan changed_targets, config show --json-fix),
  korrupt-FITS audit-szabály, docs/features.html + cli.html frissítve. Ezzel
  az A-hullám (T1–T4) teljes. Következő: B-hullám (T5–T13) kiosztása.
- 2026-08-08: T5 (Szűrő-dimenzió alapok) kész — F1 teljes (TargetDetail
  "Szűrők" kártya, fejléc-tile top-3/legnagyobb-hiány caption, szűrőnkénti
  Integráció-halmozódás grafikon, NightsPage óraszám-bontás+tooltip) és F2
  teljes (`goal:F=Xh` tag-konvenció, `FilterGoalQueries.merge`/
  `biggestDeficit`, GoalEditSheet "Szűrőnként" szekció, TonightPage
  "Hiányzik" popover, CLI `goal set/clear --filter` + `goal list` + `stats
  --filters --json` cél/hiány mezők). Mellékesen javítva: `AppState.setGoal`/
  CLI `goal set/clear` (összcél) eddig egy bare `hasPrefix("goal:")`-tal
  törölte volna a szűrőnkénti tageket is. Következő: T6 (Tervező-bővítés).
- 2026-08-08: T6 (Tervező-bővítés) kész — F3 teljes (`plan.narrowbandFilters`
  config, core `FilterAdvisor.advice`/`chipText`/`augmentedVerdict`,
  TonightPage "Szűrő ma" oszlop + tooltip, Naptár NB/sötét címke,
  "ma jó — Ha-ra" verdikt-bővítés + `VerdictChip` `hasPrefix` javítás) és F18
  teljes (core `PlanExport` CSV/vágólap-renderelés, TonightPage "Terv
  exportálása…" toolbar-menü + toast, CLI `plan --out PATH|-`; core
  `CalibShoppingList` + TonightPage "Kalibrációs teendők ma estére"
  DisclosureGroup + Markdown-másolás). Tudatos eltérés: a planTable
  egysoros kijelölés marad (nincs multi-select a Table-ökben sehol az
  appban) — "kijelölt sorok" a kijelölt EGY sort jelenti, kijelölés nélkül a
  megszokott "ma jó"/minden-sor eshez folyamodik. Következő: T7
  (Kiugró-híd).
- 2026-08-08: T7 (Kiugró-híd) kész — F4 teljes: core `OutlierBreakdown` +
  a `Rater`-ből kiemelt, mostantól közösen használt `RatingGroupMath`
  (grouping + z-score, teszt determinisztikus bemenetekkel), `FrameScore
  .outlierBreakdown` additív mező (`Rater.rate`/`Rater.cachedScores`
  töltik ki) — ez a `rate --json` CLI-kimenetet is automatikusan bővíti
  metrikánkénti z-score-okkal (F4 CLI-tétel), Commands.swift-módosítás
  nélkül. Minőség-tábla: kattintható ⚠️ popover (metrikánkénti bontás,
  domináns metrika kiemelve, valószínű-ok mondat, "Átnézés"/"Elvetés"),
  "Kiugrók átnézése (N)" gomb (`FrameReviewSheet` új `subsetLabel`
  paraméterével, "Kiugrók: 3/7" fejléc), "Összes kiugró elvetésre
  jelölése… (N)" megerősítő sheet, "javasolt: elvetés" jelzés a Saját
  döntés cellában és a review-sheet fejlécében. Következő: T8
  (Audit-diff + Tárhely).
- 2026-08-08: T8 (Audit-diff + Tárhely) kész — F6: core `AuditDiff`
  (severity/category/groupKey granularitás, ack-független) +
  `Database.previousRunID(before:kind:)` (ugyanaz a hívás szolgálja ki a
  friss futást ÉS az újraindítás utáni visszaállítást); AuditPage
  diff-összegző sor a szegmens-picker alatt, "ÚJ" jelvény, "Csak az újak"
  toolbar-váltó; CLI `audit --json` additív `diff` blokk + emberi
  összegző sor. F19: core `StorageQueries`/`TargetStorage`/
  `StorageSummary` (célpontonkénti méret area-bontással, `missing`
  kizárva); AuditPage ▸ Takarítható "Tárhely" `DisclosureGroup` a
  cleanup-tartalom fölött (top 10 + "Összes megjelenítése", "⋯" menü,
  semmi törlés-akció); CLI `cleanup --json` additív `storage` blokk
  (indoklás: ugyanaz a szegmens, nem külön alparancs). Következő: T9
  (Előző éjszaka).
- 2026-08-08: T9 (Előző éjszaka) kész — F5 teljes: core
  `ScanSummary.changedSessions` (`Scanner.swift`) a `changedTargets`
  (T4) session-szintű additív bővítése — csak `.sessions`-terület LIGHT
  hozzáadás/frissítés számít bele (hiányzó fájl, más szerep, stacks/
  processed-terület nem), új `ScanSummary.SessionKey` típus, 4 új
  `ScannerTests` eset. `AppState.freshSessionKeys` (memóriában, session-
  only) a legutóbbi scan `changedSessions`-e; feltételes "Előző éjszaka"
  sidebar-sor (jelvény = friss session-szám, `⌘`-gyorsbillentyű nélkül,
  mint a majdani Trendek) a Ma este/Naptár/Felfedezés alatt. Új
  `Page.previousNight` + `PreviousNightPage`: session-kártyák (célpont+
  dátum címsor a Sessionök szegmensre navigál, keret/integráció/szűrő-
  bontás a T5 `TDFormat.filterBreakdownSummary`-val, medián FWHM″,
  Hűtés/Fókusz `VerdictChip` `NightHealth.report`-ból, kiugró-arány
  `Rater.cachedScores`-ból vagy "még nincs pontozva"), kártyánként
  Pontozás/Átnézés…/Éjszaka-riport gomb, felül "Új sessionök pontozása"
  (megerősítés nélkül, meglévő isBusy/progress/Mégse infrastruktúra),
  üres állapot `ContentUnavailableView` + "Beolvasás" gombbal. Opt-in
  "Automatikus beolvasás kötet csatlakozásakor" (Settings ▸ Könyvtár,
  alapból KI) `UserDefaults`-ban (`AppState.autoScanOnMount`, NEM
  `AstroConfig`-ban — app-viselkedés, nem könyvtár-szabály), a meglévő
  mount-observer sikeres `retryRootAccess()`-e után indít `runScan()`-t,
  ha épp semmi más nem fut. Következő: T10 (Trendek + szenzor-történet).
- 2026-08-08: T10 (Trendek + szenzor-történet) kész — F7 teljes: core
  `TrendQueries.points` (`NightsQueries.allNights` session-metrikáinak
  újrahasznosítása, időrendi sorrend, opcionális setup-fingerprint/
  dátumtartomány szűrés, `EquipmentProfile.dominant` per session) +
  tiszta `TrendMath.movingAverage` (5-pontos ablak, hiányzó pontot
  átugorva); `TrendsPage` (időtartomány-picker + 3 Swift Charts, px-
  fallback FWHM üres karikával, pontra kattintás → `pendingTargetSegment`/
  `pendingSessionSelection` a Sessionök szegmensre, toolbar setup/
  célpont-típus szűrő, kliens-oldali szűrés a NightsPage-mintára, <5
  session ContentUnavailableView); sidebar "Trendek" sor (ÁLLAPOT, `⌘`
  nélkül) + menü-parancs; CLI `trends --metric fwhm|background|
  efficiency [--setup][--from][--to][--json]`. F8 teljes: séma-v10
  migráció (`sensor_profile.estimator_version` additív oszlop NULL a
  régi sorokon + új append-only `sensor_profile_history` tábla,
  visszatöltve a meglévő `sensor_profile` sorokból NULL becslő-
  verzióval — teszt bizonyítja, hogy egy v9 DB gond nélkül nyílik), új
  `SensorProfiler.estimatorVersion` konstans (2) — `measure` mostantól
  history-ba ír, majd upsertel; `SensorProfileRecord.isEstimatorStale`
  váltja a `SensorPage` korábbi hardcode-olt 2026-08-05 dátum-ellenőrzését;
  `SensorPage` `Table` → `List`+`DisclosureGroup` (soronkénti mérés-
  történet + 2 sparkline), "Szenzor mérése…" sheet-szöveg frissítve; CLI
  `sensor --history [--json]`. 25 új teszt (core: TrendQueries+
  DatabaseTests migráció+SensorProfileTests; CLI: trends+sensor
  --history smoke), `swift test` zöld (1146). Tudatos eltérés: a
  px-fallback jelölés nem szó szerint SwiftUI Charts beépített "üres
  kör" szimbólum (nincs ilyen `BasicChartSymbolShape`), hanem
  `.symbol { Circle().stroke(...) }` egyedi tartalom — vizuálisan
  ugyanaz, csak nem a `.symbol(_ shape:)` API-n át. Következő: T11
  (Stack-lista v2).
- 2026-08-08: T11 (Stack-lista v2) kész — F15 teljes. Core:
  `StackList.select` a usable lightokat FITS `FILTER` fejléc szerint
  (`FilterBreakdownQueries.noFilterSentinel` a szűrő nélküli bucket)
  csoportosítja, és a hard-drop + keepFraction pipeline-t SZŰRŐNKÉNT futtatja
  (`selectWithinGroup`) — a "sosem kevesebb 3 keretnél" padló és az új
  opcionális `keepFractionPerFilter: [String: Double]` felülbírálás is
  szűrőnként érvényes; egyetlen bucket esetén (mono egy szűrő, vagy
  szűrőtlen OSC) a kimenet bájtra ugyanaz, mint a szűrő-bontás előtt
  (`StackSelection.perFilter` `nil` marad). Új `StackFilterSelection`
  (szűrőnkénti kiválasztva/összes + útvonalak) és `StackManifestRow`
  (file/filter/score/fwhm_px/session_date/verdict) típus; `StackSelection`
  additív `perFilter`/`manifest` mezőkkel bővült. `StackList.export`/
  `exportToDirectory`: több szűrős kiválasztásnál `lights/<SZŰRŐ>/`
  almappánként hardlink + saját `<cél>-<dátum>-<SZŰRŐ>.dssfilelist`/`.ssf`
  pár (a `.ssf` `cd`-je magába a szűrő-mappába megy, mert Siril `convert`-je
  csak a cwd-et olvassa — ellenőrizve a Siril doksi ellen); szűrőtlen
  anyagnál a lapos `lights/`+`stack.dssfilelist`+`stack.ssf` szerkezet
  változatlan. Mindkét esetben `manifest.csv` a gyökérben, MINDEN usable
  keretre (kiválasztva és elvetve is), `verdict` oszloppal
  (`selected`/`rejected_verdict`/`rejected_outlier`/`rejected_keepfraction`).
  `WriteGuard.linkStackListFile` a `.astro_tool/stacklists/<slug>/
  lights/<szűrő>` (5 komponensű, validált) útvonalat is elfogadja a régi
  4 komponensű `lights` mellett. `StackListSheet`: közös Megtartás%-csúszka
  változatlan; több szűrős preview-nál "Ha 45/52 · OIII 28/40" bontás-sor +
  "Szűrőnkénti finomhangolás" `DisclosureGroup` (csúszka szűrőnként, alapérték
  a közös érték, a közös csúszka mozgatása visszaállítja őket) + export-cél
  sor; szűrőtlen/egy szűrős anyagnál a sheet nézete változatlan. CLI:
  `stacklist --keep-filter "Ha=0.9,OIII=0.7"` (vesszős lista — `ArgParser`-nek
  nincs ismételhető-flag mechanizmusa, ez az egyszerűbb alak), emberi
  kimenet + `--json` `per_filter` szűrőnkénti bontással (kiválasztva/összes),
  `docs/cli.html` frissítve. 17 új teszt (core: 11 `StackListTests` — szűrőnkénti
  csoportosítás/keepFraction/override/backward-compat/manifest tartalom/
  export-fa; 2 `WriteGuardTests` — beágyazott szűrő-almappa elfogadása/
  elutasítása; CLI: 4 `CLISmokeTests` — `--keep-filter` elfogadás/hibás érték/
  szűrőnkénti felülbírálás/valódi többszűrős FITS-en át `scan`+`stacklist
  --json` végpontig), `swift test` zöld (1163). Tudatos eltérés: a
  `manifest.csv` `verdict`-értékei angolul vannak (nem magyarul), mert ez a
  fájl külső eszköznek (WBPP/szkript) szól, ugyanaz a regiszter, mint a
  `.dssfilelist`/`.ssf` már meglévő kulcsszavai, nem az app magyar UI-ja.
  Mellékesen észrevétel (NEM javítva ebben a ticketben, külön feladatba
  jelölve): a szűrőtlen/egy-szűrős `.ssf` `cd`-je a stacklist-könyvtárba megy
  (a `lights/` SZÜLŐJÉBE), nem magába a `lights/`-ba, pedig Siril `convert`
  parancsa csak a cwd-et olvassa — ez már R7-B4 óta így van, gyanús, hogy a
  meglévő (lapos) `.ssf` valójában nem talál frame-eket futtatáskor; az új,
  R11-T11-es szűrőnkénti `.ssf`-ek ezt már helyesen, közvetlenül a szűrő
  mappájába cd-zve generálják. Következő: T12 (Kezdő-csomag).
