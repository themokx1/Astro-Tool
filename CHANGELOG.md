# Changelog

Minden lényegi változás ebben a fájlban van dokumentálva.

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elvein
alapul, a verziószámozás a [Semantic Versioning](https://semver.org/) szerint
történik.

## [Unreleased]

### Added

- **Célpont-részletek oldal** (R9-T3), a review szerint "a legértékesebb új
  felület": beolvasztja a teljes Minőség fület. `Views/TargetDetailPage.swift`
  fix fejléccel (identitás + fázis-chip, 5 tile — Valós integráció/Cél/
  Hiányzik/Sessionök/Legjobb session —, "Következő lépés" mondat +
  akció-gomb + "További N teendő" disclosure) és `Views/TargetDetail/*.swift`
  öt szegmenssel (Áttekintés/Sessionök/Minőség/Stackek/Jegyzetek). Cél-UI
  (B11): inline ✏️ popover óra-`Stepper`rel, `AppState.setGoal(target:hours:)`
  írja/törli a `goal:Xh` cél-tag-et — először 0 cél-tag volt a DB-ben, ez adja
  az első GUI-utat hozzá. Minőség szegmens: session-dátum `Menu` a
  szabadszöveges mező helyett, `Menu`-primary-action "Keretek pontozása" +
  "Újra minden keret mérése (lassú)"/"Siril nélkül (csak natív)" (új
  `AppState.runRate(noSiril:)` paraméter), 10-bucket pontszám-hisztogram.
  Sessionök szegmens: sor-kiválasztásra inline idővonal-BAR (a
  `NightReport`-riport CSS-bar-koncepciójának SwiftUI-portja) + hardver-
  egészség sor. Stackek szegmens: a törölt `StackGroupSheet` hierarchikus
  táblája beágyazva (nem sheet). `Views/QualityView.swift` törölve;
  `StatsView`-ból a `Műveletek` kolonna teljesen megszűnt (jobb-klikk
  context-menükbe került, ez az első `Table`-context-menü ebben a
  kódbázisban), a `.stacksSummary` gyerek-sor + "Kész stackek…"/"Panelek…"
  gombok törölve (a detail oldal veszi át), célpont-sor dupla-kattintásra a
  detail oldalra navigál. 817 teszt zöld (app-layer réteg, `AstroCore`
  változatlan).

- **Audit-oldal átépítése: Hibák/Gyanús/Takarítható háromszegmenses reframing +
  találat-elfogadás (ack) + findings-retenció** (R9-T2): a régi egyetlen
  "Gyanús" vödör (a valós könyvtáron 3 545, 88%-ban takarítható maradék) helyett
  `Views/AuditPage.swift` egy `Picker(.segmented)`-et ad — `Hibák` (biztos
  hiba) / `Gyanús` (gyanús MÍNUSZ residue MÍNUSZ duplicate-content) /
  `Takarítható` (a `CleanupSummary` csoportjai) —, 4 fejléc-tile-lal (Biztos
  hiba/Gyanús/Takarítható GB/Szándékos). A Hibák/Gyanús csoport-fejlécek `⋯`
  menüt kaptak (Csoport megjelölése rendben lévőként/Rendben-jelölés
  visszavonása, Első fájl megnyitása Finderben, Összes útvonal másolása); a
  szabadszöveges kategória-szűrő többválasztós `Menu` lett; toolbar-toggle
  "Rendben-jelöltek megjelenítése" mutatja/rejti az elfogadott csoportokat. A
  Takarítható szegmens hierarchikus `Table`-t ad (Kategória/Fájlok/Méret,
  kinyitható útvonal-listával + "…további N" sorral, `Limit` stepperrel) egy
  állandó banner alatt a Vasszabályról ("a script `mv`-vel karanténba mozgat,
  soha nem töröl"). Toolbar: "Audit futtatása" `Menu`-primary-actionnel
  ("Duplikátum-keresés nélkül (gyors)" menüponttal, a menüsorban is), a két
  script egy "Script…" menübe ("Javító script (hibák)…" /
  "Karantén-script (takarítható)…"). Új `finding_acks` tábla (schema v9,
  `Database.ackFindingGroup`/`unackFindingGroup`/`ackedKeys`, kulcs
  `(category, groupKey)` — túléli az újra-auditot); a sidebar Audit-badge
  ezt a csoport-szintű, ack-mentes számot mutatja. `AuditEngine.run` minden
  audit végén `Database.pruneFindings(keepRuns: 3)`-t hív, hogy a `findings`
  tábla (32k+ sor 12 run-ból, korábban soha nem takarítva) ne nőjön
  korlátlanul.

## [0.8.0] - 2026-08-05

### Added

- **Teljes navigációs átépítés: `NavigationSplitView` sidebar + ablak-toolbar +
  menüsor + first-run flow** (R9-T1): a régi hat-fülű `TabView`-t egy oldalsávos
  navigáció váltja fel (`AppState.Page`: Ma este/Naptár/Minden célpont/
  célpont-részletek/Kalibráció/Audit/Szenzor-profilok/Kereső), valódi
  fázis-színes ponttal minden célpontra és valódi számlálós badge-ekkel
  (Audit-badge kizárólag biztos hibát számol). Az ablak-toolbar egy Menüt ad a
  gyökér nevével (Mappa választása…/Legutóbbi könyvtárak/Megnyitás Finderben/
  config.json megjelenítése), egy "Beolvasás" gombot a legutóbbi beolvasás
  relatív idejével, egy "+" menüt (Új session…) és egy "Műveletek" menüt.
  Teljes menüsor (Fájl/Nézet/Műveletek/Súgó): ⌘1-⌘6 oldal-navigáció, ⌘R
  beolvasás, ⌘N új session, ⌘⌥A audit, ⌃⌘S oldalsáv, "Mappastruktúra súgó"
  sheet + Tutorial/CLI-referencia külső linkek. `Settings { }` scene váltja a
  Beállítások fület (⌘,). Új first-run élmény: bookmark nélkül `WelcomeView`
  (app-ikon, 3 pont, egész ablak drop-target a mappaválasztáshoz), kiválasztott
  de sosem beolvasott gyökérnél `FirstScanView` (mappaszerkezet-checklist,
  "Beolvasás indítása"/"Kihagyom, később", opcionális azonnali audit, eredmény-
  kártya). A "sosem beolvasva" állapot most a `runs` táblából (új
  `Database.lastRunDate(kind:)`, additív AstroCore-változás) derül ki, nem csak
  in-memory state-ből, így túléli az újraindítást — ugyanez adja a toolbar
  "Utolsó: X perce/órája/napja" feliratát is. `AccessDeniedView` mindkét
  hibaképe kapott "Másik mappa választása…" gombot; a kötet-hiány képernyő
  automatikusan újrapróbál (5s `Timer` + `NSWorkspace.didMountNotification`
  observer), amint a kötet megjelenik. Toolbar óra-ikon: az utolsó 50
  háttérművelet naplója (cím, relatív idő, piros hibaszöveg hiba esetén).
- **Csoportosított stack-nézet variánsokkal, szerkesztett/eredeti jelzéssel,
  expozícióval és Finder-gombokkal** (R8-3): valós screenshot alapú
  visszajelzésre válaszul — egy NGC2237-stack tucatnyi variánsa (`_og`,
  `starless_`, `starmask_`, `..._work_graxpert_result_HOO_Improved`,
  `..._seti_strech.jpg`) eddig kezelhetetlen lapos listaként jelent meg. A
  `StackDiscovery` most `StackVariantKind`-ot (eredeti/szerkesztett/starless/
  starmask/export) rendel minden fájlhoz a fájlnév alapján, és
  `StackGroup`-okba (`groupedStacks`) fésüli az egy stackhez tartozó
  variánsokat a közös `stem` (a `NxSUBsec_TOTALs` + drizzle + időbélyeg mag)
  szerint; a legjobb ismert expozíció a névből, vagy — ha a névben nincs
  keretszám — a FITS header `STACKCNT`/`LIVETIME`/`EXPTIME` mezőiből. A
  Statisztika fülön a "Stackek…" popover helyett egy átméretezhető
  (min. 800×500) sheet nyílik: hierarchikus táblázat csoport-sorokkal
  (típus-badge, **kövér** expo, "headerből" jelzés) és behúzott
  variáns-sorokkal (színes típus-badge, kiemelt "edit chain" névrész),
  minden soron "Megnyitás" és "Finderben" gombbal. `astrotool stacks` emberi
  kimenete mostantól csoportosítva listáz (típus-bontással, pl.
  "(+9 szerkesztett · 2 starless)"), `--verbose` a variánsokat is kilistázza;
  `--json --grouped` az új `[StackGroup]` alakot adja vissza (az alapértelmezett
  `--json` változatlan marad).

### Changed

- **Átnevezések és mozgatások a navigációs átépítés részeként** (R9-T1):
  Statisztika "Frissítés" → "Újraszámolás"; Áttekintés "Könyvtár beolvasása"
  gomb törölve (a toolbar "Beolvasás" gombja veszi át) és "DSS-adatok
  beolvasása" → "DSS-döntések importálása"; Kalibráció "Mérés" → "Szenzor
  mérése…", a Szenzor-profilok szekcióval együtt önálló oldalra mozgatva;
  Áttekintés "Ugrás" doboza törölve (a sidebar veszi át a szerepét).

### Fixed

- **Per-Bayer paritás-mediánok páratlan oszlopa mindig `NULL` volt**
  (`bg_01`/`bg_11`): a valós DB-n minden pontozott keretnél a páros oszlopok
  (`bg_00`/`bg_10`) ki voltak töltve, a páratlanok soha. Ok:
  `NativeStats`-ban a nagy (1M pixel felett mintavételezett) keretek stride-ja
  páros volt, ami páros `NAXIS1` (minden valós kamera) mellett azt jelentette,
  hogy MINDEN mintázott pixelindex páros oszlopra esett — a páratlan
  oszlopok egyszerűen soha nem kaptak mintát. Javítás: a mintavételezés most
  2×2 Bayer-CELLÁKAT választ stride-dal (`bayerCellStride`/
  `isBayerCellSampled`), és egy kiválasztott cella MIND a 4 pixelét felveszi
  — így minden paritás garantáltan kap mintát. **Öngyógyítás**: a `Rater`
  staleness-ellenőrzése régen csak `bg_00 == nil`-t nézte (egy félig kitöltött
  sor "kész"-nek tűnt); most `bg_00`/`bg_01`/`bg_10`/`bg_11` bármelyikének
  `nil`-je stale-nek számít, így egy sima `rate` (nem csak `--force`)
  automatikusan újraszámolja és pótolja a hiányzó bucketeket minden már
  létező, félig kitöltött sornál — nincs szükség kézi beavatkozásra.
- **Olvasási zaj alulmért volt** (`SensorProfiler`, ~1.06 e⁻ a mért ~1.30 e⁻
  helyett, IMX571-en): a bias-pár különbségén futó egypasszos 5σ-clip a
  szenzor valódi (nem kozmikus-sugár) zajának egy részét — az IMX571 RTS-
  ("csillogó") pixeleinek kb. 0.5%-át — is levágta, ezzel a mért szórást a
  MAD-becslés felé (1.02-1.06 e⁻) torzítva, jóval a független szakértői
  referencia (~1.30 e⁻) alá. Javítás: a clip-küszöb 5σ → 10σ — ez még
  védekezik a valóban korrupt/telített keret extrém kilógóival szemben, de a
  farkat (és a benne rejlő valódi szenzorzajt) a megtartott mintában hagyja.
  **Fontos**: a tárolt szenzor-profilokat újra kell mérni
  (`astrotool sensor --measure` / app "Mérés" gomb — az upsert felülírja a
  meglévő sort), és a pontozást újra kell futtatni a `bg_01`/`bg_11`
  oszlopok pótlásához (ez automatikus a következő `rate` futáskor, lásd
  fent).

## [0.7.0] - 2026-08-05

### Added

- **Célpont-riport HTML** (R8-2, `astrotool target-report`): az "éjszaka
  riport" mintájára, de EGY célpont teljes történetéről — fejléc (feloldott
  név, katalógus-designáció, RA/Dec, setup-fingerprint(ek), goal-tag,
  wide-field jelző), összkép (usable/gross integráció, keret-bontás,
  pipeline-fázis + teendők), sessionök táblázata (keret/integráció/
  expozíció/kamera/gyújtótáv/gain/hőm./szűrő/README/DSS/kizárt jelzők, plusz
  "van éjszaka-riport" jelzés ha az adott éjszakának már van saját
  `NightReport`-ja), minőség-táblázat + expozíció-tanácsadó, felderített
  stackek (R8-1) legjobb-kiemeléssel, kalibráció (session-szintű +
  flat-higiénia), mozaik-panelek (ha van), tervezés (`Planner`
  láthatóság/verdikt/Hold, goal-hiány, +10% SNR költsége), README-jegyzetek
  session-önként. Minden szekció-fejléc mindig megjelenik, hiányzó adatnál
  Hungarian megjegyzés lép a helyére. `.astro_tool/reports/
  target-<célpont>.html`-be íródik. `astrotool target-report --target T
  [--out -] [--root R]`; az app Statisztika fülének célpont-sor
  "Exportálás…" menüjében új "Célpont-riport" tétel. A megosztott dark-theme
  CSS `Sources/AstroCore/Export/ReportStyle.swift`-be került (`NightReport`
  ugyanazt használja, viselkedése változatlan).
- **Stack-file felderítés a teljes könyvtárban, célpontonként/session-önként**
  (R8-1, `astrotool stacks`): a `StackDiscovery` motor a teljes scannelt
  könyvtárat átfésüli — nem csak a kanonikus `stacks/<célpont>/<dátum>/` és
  `processed/<célpont>/<dátum>/` helyeken, hanem bárhol (session-mappában,
  a célpont `stacks/` gyökerében dátum-almappa nélkül, vagy a könyvtár
  gyökerében is) — és filename-alapú felismeréssel (ASIAIR autosave-stack
  névalak, `*_stacked*`, `Autosave*.tif`, `MasterLight*`, mozaik-nevek,
  ASIAIR számozott live-stack capture) találja meg a már létrejött
  stack/feldolgozott kimeneteket. Egy calib-master névalakú találat
  (`*_darks_stacked` stb.) listázva marad, csak `"master-jelölt"`-ként
  jelölve; a `stacks/<T>/`/`processed/<T>/` fán kívüli találatokat
  fájlnév-token-egyezés köti egy ismert célponthoz, egyezés nélkül egy
  "Besorolatlan" csoportba kerülnek. `astrotool stacks [--target T] [--json]`
  CLI parancs; az app Statisztika fülén a célpont sessionjei után egy
  "Stackek" összegző sor (darabszám + legjobb) és egy "Stackek…" popover a
  teljes táblával. `ProjectStatusQueries` a felfedezett stackek dátumait is
  beleszámítja a "van-e már stack ehhez a session-höz" eldöntésébe, még ha a
  stack fájl nem is a kanonikus `stacks/` fán van.

### Fixed

- **Minőség fül panelei a pontozás után is a régi ("nincs adat"/"n/a")
  állapotot mutatták**: a "Session-minőség" és "Expozíció-tanácsadó" panel
  (`AppState.qualitySummaries`/`exposureAdvice`) csak a célpont-picker
  változásán töltődött újra — a "Pontozás"/"Újrapontozás" gomb a
  keret-táblázatot (`frameScores`) frissítette, a két panelt nem, hiába
  volt friss adat a DB-ben. `AppState.runRate` mostantól sikeres pontozás
  után, még a saját műveletén belül, újraszámolja és beállítja mindkét
  property-t.
- **A tervező (`plan`/`plan --month`) hónapokkal korábbi session-WCS-ből
  származó üstökös-koordinátára hamis "ma jó" verdiktet adott**, és a havi
  naptár top-3 célpontja közé sorolta — üstökösök napi több fokot mozognak,
  a felvétel idejéből származó koordináta a tervezéskor már értelmetlen.
  Üstökös célpontok (`C/<év> <hó-betű><szám>` designáció) mostantól
  `plan`-ben "üstökös — a tárolt koordináta a felvétel idejéből való, ma
  már nem érvényes" verdiktet és `0` pontszámot kapnak (kulmináció/
  láthatóság/Hold-adat nélkül), `plan --month`-ban teljesen kimaradnak a
  havi naptár legjobb célpontjai közül.
- **Két különböző mappa (pl. egy üstökös normál és `_Wide` felvétele) ugyanarra
  a katalógus-designációra oldódott fel, megkülönböztethetetlen sorokat adva**
  a `plan` CLI-táblában és az app "Ma este" dobozában. `Planner.plan`
  mostantól, ütköző megjelenített név esetén, zárójeles egyedi
  mappanév-utótagot fűz a névhez (pl. `"C/2025 R3 (Panstarrs)"` /
  `"C/2025 R3 (Panstarrs_Wide)"`).

## [0.6.0] - 2026-08-05

### Fixed

- **Kalibráció-lefedettség és session-párosítás duplán számolta a
  CR3+TIF-párokat** (az R7-B6 sor follow-up bejegyzésében jelzett hiba):
  `CalibAnalyzer.lightGroups`/`coverage` és `SessionMatcher.match` a
  session `role == .light` fájlokat közvetlenül számolta, nem a
  `FrameSet.lightBuckets(...).usable` deduplikált halmazát (ahogy a
  `StatsQueries` már tette) — egy fizikailag egyetlen DSLR-felvétel
  eredeti `.CR3` ÉS a belőle konvertált `.tif` alakja egyaránt `role =
  light`-ként volt nyilvántartva, ezért kétszer számított bele a
  `lightCount`-ba/`SessionCalibration.lights`-ba. Javítva: mindkettő most
  a deduplikált, nem-elvetett keretkészletet használja. `NightHealth`/
  `ExposureAdvisor` ellenőrizve — azok már eleve `FrameSet.lightBuckets`-en
  mentek át.
- **⚠️ Minden e⁻/s/arcsec² égháttér-érték ~64×-esen inflálva volt a 0.4.0
  óta** (`SessionQuality.backgroundEPerSecPerArcsec2`, és minden rá épülő
  `quality`/`health`/export szám): a képlet sosem vonta le a szenzor
  bias-pedesztálját (ASI2600, gain 100/offset 50: ~501 ADU) — valós Rosette
  session-adaton 0,147 e⁻/s/arcsec² jelentett a mért 0,0023 igazsághoz
  képest. Javítva: `max(0, (background_ADU − biasLevel) × EGAIN / EXPTIME /
  scale²)`; `biasLevel` az új, mért `sensor_profile` táblából EXAKT
  `(camera, gain, offset)` egyezéssel jön (sosem gain-only/kamera-only
  fallback) — amíg egy kombóhoz nincs mérve bias-szint, a szám `n/a`
  (`nil`), sosem egy hibás érték. Lásd az új `astrotool sensor` parancsot
  lent a méréshez.
- **A Siril-adapter csendben nem működött ezen a gépen**: minden mért
  rating sorban `siril_version` a "Siril is started as macOS application"
  indítási banner volt egy valódi verziószám helyett, és `fwhm`/
  `roundness`/`star_count` 100%-ban `NULL` — a `findstar`-kimenet
  regex-mintája nem illeszkedett a valós Siril 1.4 szövegére ("Found N
  Gaussian profile stars…", extra szavak a szám és a "star" szó közt).
  Mindkettő javítva, és egy valódi `siril-cli` bináris ellen futó
  integrációs teszttel is ellenőrizve. `astrotool rate` mostantól stderr
  figyelmeztetést ír, ha egy ≥5 keretes batch egyetlen keretre sem kap
  Siril-metrikát ("a Siril nem adott metrikát egyetlen keretre sem —
  ellenőrizd a telepítést") — pont ez a csendes hiba-mód maradt észrevétlen
  korábban.
- **A `rate` gyorsítótár sosem gyógyult egy egyszer megsérült sorból**: ha
  egy keret `ratings` sora egy törött Siril-adapter (vagy a `bg_00..11`
  oszlopok bevezetése előtti) korból származott — `fwhm`/`roundness`/
  `star_count` és/vagy `bg_00` `NULL` —, a puszta `input_sig`-egyezés
  örökre cache-hitnek jelölte, akárhányszor futott is újra `rate` (a valós
  DB-n 141 keret ragadt "Siril metrika: 0/141"-en). Javítva: egy
  `input_sig`-egyező sor mostantól a hiányzó RÉSZÉT (natív statisztika
  és/vagy csillag-metrika, egymástól függetlenül) újraszámolja, egy
  `dss`-sorsú sort viszont sosem futtat újra Sirillel (a metrikái DSS-ből
  jöttek) — meglévő, nem-hiányzó érték sosem íródik felül nil-lel. Új
  `astrotool rate --force` (és app: "Újrapontozás" checkbox a Minőség
  fülön) egy szándékos, teljes újramérésre, a gyorsítótártól függetlenül.
- **A leolvasási-zaj becslő 1,02 e⁻-t mért, ahol a szakértői referencia
  ~1,30 e⁻ volt**: a `clippedStandardDeviation` konvergenciáig iterált
  5σ-klippelése valós, kvantált szenzoradaton egyre lejjebb konvergált (egy
  MAD-alapú becsléssel statisztikailag megkülönböztethetetlen 1,02 e⁻-ig),
  mert minden további kör a szenzor valós (bár kilengő, feltehetően
  "twinkling"/RTS-pixel) viselkedését is levágta, nem csak a valódi
  kiugrókat. Valós bias-pár ellenőrzésen (ZWO ASI2600MC Pro, gain 100):
  klippelés nélküli σ 1,294 e⁻-t adott, egyetlen 5σ-klippelési kör 1,062
  e⁻-t. Javítva: a becslő mostantól EGY klippelési kört futtat (nem
  iterál konvergenciáig) — a `sensor --measure` valós újramérése 1,02-ről
  1,06 e⁻-re javult.
- **A kalibráció-lefedettség szétesett float-zajos expozíciókon**: "készíts
  30 s darkot" két külön sorban jelent meg ugyanarra a névleges
  expozícióra (pl. 822 és 91 keret 30,0s és 29,899999618523s `exptime`
  mellett), mert a csoportosítás csak 0,1s-re kerekített, nem
  `NominalExposure.nominal(_:)`-t használt (ami már létezett a `Rater`-hez,
  csak a kalibráció-lefedettség sosem hívta). Javítva. Ahol a szétválás
  VALÓS (pl. ugyanaz a névleges expozíció/kamera, de eltérő `GAIN`), a
  todo-szöveg mostantól megnevezi a kamerát/gaint, ha az valóban ambiguus a
  batchben — az egyértelmű, egykamerás/egygain-es esetben a szöveg
  változatlan marad. Hiányzó hőmérséklet (`SET-TEMP`, tipikusan DSLR)
  mostantól explicit "(hőmérséklet nélkül)" jelzést kap, ahol korábban a
  hőmérséklet-tagmondat csendben csak kimaradt.

### Added

- **Helyes célpont-megjelenítés (beépített katalógus-feloldás)**: a
  mappanevek (`NGC_7000_North_American_Nebula`, `M42_Orion_wide_field`,
  `IC1805-1848_Heart-and-Soul_Nebula`, `C2025_R3_C2025_R3_Panstarrs`,
  `M_Milky_Way`, ...) helyett a feloldott katalógusnév látszik, a
  mappanévvel másodlagos infóként — pl. `"NGC 7000 · Észak-Amerika-köd"`.
  Új `Sources/AstroCore/Stats/TargetNameResolver.swift`: tisztán szöveges
  parser (nincs DB/fájlrendszer-hozzáférés), amely `M`/`NGC`/`IC` (incl.
  IC-tartomány, pl. `IC1805-1848`)/`Sh2`/üstökös (`C<yyyy>_<betű><szám>`,
  duplikált prefixszel is) designációkat ismer fel, és egy beépített
  magyar közismert-név táblázatból (`CatalogNames.swift`, ~55 bejegyzés)
  próbál hozzájuk köznapi nevet találni. Egy `name:<szöveg>` cél-tag
  felülírhatja a talált köznapi nevet (`NameTag`). Bekötve: `TargetStats`/
  `TargetPlan`/`ProjectState` additív `displayName` mezője, CLI `stats`/
  `plan`/`projects` emberi táblái, az app Statisztika/Áttekintés/Minőség
  fülei, és az éjszaka-riport fejléce/címe.
- **Éjszaka-riport HTML (`astrotool report`) + havi tervező naptár (`plan
  --month`)**: `astrotool report --target T --date D` egyetlen
  önmagában-is-megnyitható HTML fájlt ír (`.astro_tool/reports/
  <cél>-<dátum>.html`, `--out -` stdout-ra), sötét témával, JS/külső
  erőforrás nélkül — tisztán a már meglévő lekérdezések (`SessionStats`,
  `SessionTimeline`, `SessionQuality`, `NightHealth`, `SessionMatcher`,
  `ExposureAdvisor`, `ProjectStatusQueries`) összefésülése, plusz két új
  számítás: a session usable lightjainak magasság/légmassza-menete
  (`DATE-OBS` × `AltAz`/`SiderealTime`, koordináta `TargetCoordinates`-ből
  plate-solve fallback-kel) és a session ablaka alatt VALÓBAN elért
  Hold-geometria (megvilágítás az ablak közepén, medián szeparáció, Hold
  max. magassága) — mindkettő nil-safe, koordináta/site hiányában
  magyarázó megjegyzéssel marad ki, sosem hasal el. Az alkalmazásban a
  session sor "Éjszaka-riport" gombja a háttérben elkészíti és megnyitja a
  böngészőben.
  `astrotool plan --month [--nights 30] [--json]` egy 30 éjszakás
  tervező-naptárat ad (`Planner.month`): sötét óra (valódi csillagászati
  éjszaka, nautikai fallback esetén `n/a` + megjegyzés), Hold-fázis, és
  éjszakánként a top 3 célpont a `(magasság ≥ min) ∩ (sötét ablak) ∩ (Hold
  rendben: szeparáció ≥ 40° VAGY megvilágítás < 60%)` átfedés szerint — a
  Hold-veto nem csökkenti, NULLÁZZA az adott célpont aznapi óráit. A havi
  szken 10 perces mintavétellel fut (a `plan`/`stats --timeline` 2 perces
  felbontásához képest szándékosan durvább — havi tervezéshez elég pontos,
  és `night × target × sample` méretben ez tartja olcsón). A Áttekintés fül
  "Ma este" doboza fölött "Hónap…" gomb nyitja meg a táblát.
- **Stack-lista export (`astrotool stacklist`)**: híd a keret-pontozás
  (`rate` / DSS-verdiktek) és a tényleges stackelés között. Kiválasztja egy
  session legjobb frame-jeit, majd olyan artifacteket ír, amiket a
  felhasználó valódi eszközei (DeepSkyStacker + Siril/Sirilic) közvetlenül
  beolvasnak — mivel Siril 1.4-ben nincs "stackeld ezt a listát" parancs, és
  a sequence-index select/unselect törékeny, a kiválasztott lightokat egy
  külön mappába HARDLINKELI, és fölé egy sima `convert`/`register`/`stack`
  Siril-scriptet generál. Kiválasztás: a `FrameSet` usable (dedupolt, nem
  `Reject/`) lightjaiból hard drop a DSS-ben elvetett (`user_verdicts`) és a
  kiugróan gyenge (`score < -outlierZScore`) keretekre, majd a maradék
  `score` szerinti rangsorból `keepFraction` (alapból 80%, min. 3 keret)
  tartása — egy pontozatlan keret SOSEM esik ki a hiányzó adat miatt, mindig
  megtartva. Export: `.astro_tool/stacklists/<cél>-<dátum>/lights/` alá
  hardlinkeli a kiválasztott frame-eket (`WriteGuard.linkStackListFile` —
  additív, sosem felülíró, idempotens), mellé ír egy `.dssfilelist`-et
  (csak a kiválasztott frame-ek, `CHECKED=1` sorokkal) és egy `.ssf`
  Siril-scriptet (fejléc-kommenttel a kalibráció-mesterek saját kézi
  beillesztéséről — sosem `rm`, sosem destruktív parancs). CLI `astrotool
  stacklist --target T --date D [--keep 0.8] [--json] [--root R]` — nincs
  `--dry-run`/`--yes` kapu, mindig lefut és beszámol (additív/idempotens).
  App: Statisztika fül session-sorának Műveletek cellájában "Stack-lista…"
  gomb → megtartás-csúszka (50–100%) + élő szempont-előnézet, "Exportálás" →
  háttérművelet → Finder-reveal.
- **Expozíció-tanácsadó (`astrotool expose`)**: mennyi legyen egy sub
  hossza — a mért szenzor-adatokból (`sensor_profile` bias-szintje/
  leolvasási zaja/EGAIN-je) és a mért per-Bayer háttérből (`ratings.bg_00/
  01/10/11`, R7-B1) számolva, sosem találgatva. A leggyengébb (legalacsonyabb
  mért égi-fotonrátájú) csatorna szabja meg az ideális hosszt: `t = R² / (B
  × ((1+C)² − 1))`, `C` (alapból 5%) azt mondja meg, mennyi extra
  leolvasási zajt engedünk a tiszta foton-zaj felett (`C=5%` ≡ Glover
  "égháttér ≥10×R²" ökölszabálya); a `C=10%` "rövidebb subok" variáns
  mindig kiszámolva mellette. Két sapka: `expose.maxSubSeconds` (alapból
  300s — guiding/műhold-kockázat) és egy szaturáció-sapka (ha a session már
  a jelenlegi sub-hosszon szaturál, sosem javasol hosszabbat). Relatív
  SNR-szakasz semmilyen égháttér-adatot nem igényel, csak a célpont eddigi
  (a domináns setup-fingerprintre szűkített) használható integrációját:
  "+3 óra → relatív SNR ×N-szoros", és mennyi idő kell a következő
  +10%/+5% SNR-nyereséghez. Őszinte `n/a` sosem hibás szám helyett: nincs
  mért szenzor-profil a kombóhoz, a keretek a per-Bayer háttér bevezetése
  előtt lettek pontozva, vagy a kamerának nincs `BAYERPAT` fejléce
  (mono/DSLR, pl. Canon — ez a funkció csak színes ASI-szenzorokhoz
  készült). Új `Sources/AstroCore/Stats/ExposureAdvisor.swift`
  (`ExposureAdvice`, `ExposureAdvisor.advise`/`adviseAll`), új
  `ExposeRule` config (`maxSubSeconds`, `noiseContributionC`). CLI
  `astrotool expose [--target T] [--json] [--root R]` — `--target` nélkül
  egy sor/célpont táblázat, `--target`-tel a teljes tanács minden mondata
  kiírva. App: Minőség fül, session-összegzés fölött "Expozíció-tanácsadó"
  doboz a kiválasztott célpontra.
- **DSS-metrikák és döntések beolvasása (`astrotool ingest-dss`)**: a
  könyvtárban meglévő 346 DeepSkyStacker `<frame>.info.txt` (mért
  csillag-metrikák) és `.dssfilelist` (a felhasználó saját
  elfogadás/elutasítás döntése a `CHECKED` oszlopban) fájl eddig
  kihasználatlanul hevert a lemezen. Az új parancs mindkettőt beolvassa: az
  `info.txt`-ből `fwhm ≈ 2×MeanRadius`, `roundness ≈ Circularity` (vagy a
  per-csillag `Axises` tengelyarányok átlaga, ha nincs `Circularity`),
  `star_count = NrStars` kerül a `ratings` táblába `source = 'dss'`
  jelöléssel — SOSEM írja felül egy már meglévő astrotool/Siril mérést
  (`source IS NULL` győz). A `.dssfilelist` `CHECKED` oszlopa az új
  `user_verdicts` táblába kerül (`Database.acceptedCounts(target:date:)`).
  Séma v8 (additív): `ratings.source`, `user_verdicts(file_id, accepted,
  source, recorded_at)`. Ismétlődő futtatás idempotens (változatlan
  `input_sig`-ű `dss`-sorokat kihagyja). `SessionDetail` mostantól
  `dssAcceptedCount`/`dssRejectedCount`-ot is hordoz — a Statisztika fül
  session-sorának "Keretek" oszlopa " · DSS: N✓/M✗" jelvényt kap, ha van
  rögzített döntés. `astrotool ingest-dss [--root R] [--json]` — szándékosan
  NEM fut automatikusan a `scan --refresh-meta`-val (egy DSS-fa nagy tud
  lenni, ez marad egy explicit, kiszámítható lépés). App: Áttekintés
  "DSS-adatok beolvasása" gomb (csak akkor jelenik meg, ha van nyilvántartott
  `.dssfilelist`).
- **Mért szenzor-karakterizáció (`astrotool sensor`)**: `(camera, gain,
  offset)` kombónként méri a bias-pedesztált, a leolvasási zajt (két bias
  frame különbségének 5σ-klippelt szórásából, NEM MAD-dal — az ADU-
  kvantálás alulmérné), a dark-rátát és az EGAIN-t a már nyilvántartott
  BIAS/DARK keretekből. `astrotool sensor [--measure] [--json]` — `--measure`
  nélkül csak a már tárolt profilokat listázza; figyelmeztet (stderr), ha
  usable lightok olyan kombót használnak, amihez nincs mért profil. App:
  Kalibráció fül "Szenzor-profilok" read-only táblázata + "Mérés" gomb.
- **Per-Bayer-csatornás égháttér**: `NativeStats` mostantól a meglévő
  összesített medián mellett négy Bayer-parity mediánt is számol ugyanabban
  a pixel-passzban; `BayerMap.channelMedians` RGGB/BGGR/GRBG/GBRG mintát
  R/G/G/B csatornákra map-el. Perzisztálva a `ratings.bg_00/01/10/11`
  oszlopokba (séma v7).
- **Plate-solve backfill Sirillel (`astrotool solve`)**: a wide-field Canon
  CR3 célpontoknak nincs FITS fejlécük (és így WCS-ük sem) — a `plan`/
  `panels` "nincs koordináta"-t adott rájuk. `astrotool solve --target T\|
  --all [--frames N] [--force] [--json]` blind plate-solve-olja Sirillel a
  koordináta nélküli usable lightokat, és az eredményt (RA/Dec/skála/
  rotáció) a `fits_meta` séma v6 additív `solved_ra`/`solved_dec`/
  `solved_scale_arcsec`/`solved_rotation_deg` oszlopaiba írja — a Siril
  munka mindig egy ideiglenes scratch könyvtárban zajlik, a képkönyvtár
  fájljait sosem módosítja. `TargetCoordinates`/`FieldGeometry` mostantól a
  fejléc WCS-ét részesíti előnyben, és csak akkor esik vissza a solved
  oszlopokra, ha a fejléc (vagy annak hiánya) nem ad koordinátát. App:
  Statisztika fül célpont-sorának Műveletek menüje "Plate-solve…" gombot kap
  koordináta nélküli célpontokon.
- **Dokumentációs weboldal + tutorial**: a `docs/` GitHub Pages-oldal
  egyoldalas letöltő-lapból 4-oldalas oldallá bővült, közös dark
  starry-theme navval (`Kezdőlap · Tutorial · Funkciók · CLI · Letöltés`).
  Új `docs/tutorial.html` — kezdőbarát, magyar tutorial a könyvtár
  felépítéséről (`sessions`/`stacks`/`processed`/`calibration_library`,
  mappánként 1 mondattal), az elnevezési szabályokról (célpontnév-képzés,
  dátum, szándékos jelölések: `-2` futás-utótag, dátum-tartomány, `-OSC`,
  `_hibas`), egy éjszaka munkafolyamatáról (`scan → audit → rate →
  stacklist → stackelés → report`, plusz `plan`/`projects` mikor-melyiket),
  kalibráció-gyorstalpalóról (`<exp>sec_<temp>deg` konvenció, flat-rotátor,
  `link-calib`) és a vasszabályról (mit ír/nem ír az eszköz). `docs/
  index.html` átdolgozva: 6 kiemelt-képesség kártya valós projekt-számokkal.
  Új `docs/features.html` (teljes funkciólista az app 5 füle szerint) és
  `docs/cli.html` (mind a 24 CLI-alparancs csoportosítva, egy-egy
  leírással és példával). Docs-only változás, nincs Swift-kód érintve.

## [0.5.0] - 2026-08-03

### Added

- **README-indexelés / kereshető éjszaka-napló (`astrotool search`)**: az
  égbolt-körülmények (Bortle, SQM, seeing, dew, egyéb megjegyzés) sosem
  kerülnek FITS fejlécbe — de a felhasználó munkafolyamata már most is
  beírja őket minden session `README.txt`-jének "Fill in metadata"
  szakaszába (`Camera:`, `Location/Bortle:`, `Notes/issues:` stb., plusz
  bármilyen egyéni kulcs, pl. `SQM:`). Séma v5: új `session_notes(target,
  session_date, key, value)` tábla (`PRIMARY KEY(target, session_date,
  key)`), `Database.upsertSessionNotes(target:date:notes:)` (session-önkénti
  teljes csere: delete-then-insert a class saját lock-ján belül — ez a
  SAJÁT `.astro_tool` DB-je, nem a képkönyvtár, a vasszabály erre nem
  vonatkozik), `sessionNotes(target:date:)`, `searchNotes(query:)` (SQLite
  `LIKE`, ami ASCII-re alapból kis-nagybetű-független, `COLLATE` nélkül is).
  Új `Sources/AstroCore/Scan/ReadmeNotesParser.swift`
  (`ReadmeNotesParser.parse(text:)`/`parse(data:)`) — `^([A-Za-z][A-Za-z0-9
  ()/_-]{0,40}):\s*(.*)$` mintára illeszkedő sorok kulcs/érték párokra
  bontása, üres érték kihagyva, 64 KiB felett vagy nem-UTF8 tartalomnál
  `nil` (a scan védekezően, `Data(contentsOf:)`+`try?` mögött hívja). Scan-
  integráció: minden ÚJ/MEGVÁLTOZOTT session-szintű `README.txt`
  (`sessions/<target>/<date>/README.txt` pontosan, sosem egy role-alkönyvtár
  alatti névazonos fájl — ezt a `PathClassifier` `.other` szerepe dönti el)
  a meglévő FITS-meta-capture melletti új ág a `Scanner.captureMeta`-ban,
  `--refresh-meta` alatt egy változatlan README is újraolvasódik, ha még
  nincs hozzá `session_notes` sora (pl. R6-4 előtti scan). CSAK OLVAS — a
  `README.txt`-t a scanner soha nem írja. `SessionDetail` additív
  `notes: [String: String]` mezője (`SessionStatsQueries` tölti a
  `session_notes`-ból); az app Statisztika fülének "README" jelvényén
  `.help` tooltip listázza a `kulcs: érték` sorokat. CLI: `astrotool search
  <query> [--root R] [--json]` — cél/dátum szerint csoportosított emberi
  kimenet, `tag add`/`tag remove` mintájára pozicionális `<query>` argumentum
  (`splitPositionalArgs`), nincs találatnál is exit 0. Export: `astrobin`
  formátum eddig üresen hagyott `bortle`/`meanSqm` oszlopai most a session
  jegyzeteiből töltődnek — `bortle` az első "Bortle"-t tartalmazó kulcs
  értékéből az első ÖNÁLLÓ 1-9 számjegy (pl. `"4"` vagy `"falu, 4"` is `"4"`,
  de `"42"` végződése NEM önálló), `meanSqm` az első "SQM"-et tartalmazó
  kulcs értékéből az első 16-22 tartományba eső decimális szám (a
  tartományon kívüli számok — pl. egy műszer-sorozatszám — átugorva, nem
  megállítva a keresést); egyik sincs kulcs/tartományba eső szám nélkül —
  üresen marad, nem tippel. Tervező/minőség érintetlen. Új tesztfájl
  `Tests/AstroCoreTests/ReadmeNotesParserTests.swift` (7: valódi
  `SessionCreator`-sablon fejléc-kulcsai megvannak + üres mezők kihagyva,
  egyéni kulcs (SQM) elfogva, colon/kezdő-betű nélküli sor kihagyva, 64 KiB
  felett/nem-UTF8-nál `nil`, üres szövegre `[:]`), `DatabaseTests` +5 (v4→v5
  migráció táblával+meglévő sor érintetlen, replace-all szemantika, cél/dátum
  szerinti izoláció, üres alapérték, `searchNotes` kulcs/érték LIKE
  kis-nagybetű-független), `ScannerTests` +5 (új README elfogva, role-
  alkönyvtárbeli névazonos fájl NEM az, megváltozott README újraolvasva
  replace-all-lal, változatlan README NEM íródik újra, `--refresh-meta`
  pótolja a hiányzó jegyzeteket), `SessionStatsTests` +1
  (`SessionDetail.notes` README-vel/nélküle), `AcquisitionExportTests` +2
  (bortle és meanSqm: sima számjegy/beágyazott szám/hiányzó → üres),
  `CLISmokeTests` +2 (`search` találat a fixture README-jén, találat nélkül
  is exit 0).
- **Mozaik-panel követés + setup-fingerprint (`astrotool panels`)**: a
  szélesmezős mozaikoknál (pl. `M_Milky_Way/Panel1..Panel11`) a panelek
  közti egyenlőtlen integráció látható SNR-lépcsőt okoz a varratoknál — a
  plate-solve-olt WCS (`CRVAL1`/`CRVAL2`) alapján a keret-középpontok
  klaszterezése felfedi a paneleket és azok integráció-egyensúlyát. Új
  `Sources/AstroCore/Sky/FieldGeometry.swift` (`FrameField`, `Panel`,
  `PanelReport`, `FieldGeometry.frameField(headerJSON:naxis1:naxis2:)` +
  `FieldGeometry.panels(target:db:config:)`) — `frameField` a `CRVAL1`/
  `CRVAL2`-t (kötelező), a rotációt és a pixel-skálát a WCS `CD` mátrixból
  (`CD1_1..CD2_2`, `sqrt(|det|)·3600` skála, `atan2(CD1_2,CD1_1)` rotáció)
  vagy — `CD` mátrix hiányában — a meglévő `SessionQuality.pixelScaleArcsec`
  (`xpixsz`+`focallen`) helperrel adja vissza (utóbbi esetben rotáció
  nélkül), a látómezőt (`NAXIS1`/`NAXIS2` × skála) pedig csak akkor, ha van
  skála. `panels` a célpont ÖSSZES session-jének usable lightjait (`FrameSet`
  dedup) klaszterezi mohó egykapcsolatú (single-linkage) módszerrel a
  nagykör-távolság (`SunMoon.angularSeparationDeg`, publikus) alapján —
  összekapcsolási küszöb az ismert látómező-szélességek mediánjának fele,
  vagy 1.0° ha egyetlen keretnek sincs ismert látómezeje; a panel középpontja
  a tagok RA/Dec-jének EGYSÉGVEKTOR-átlaga (nem naiv számtani átlag — ez
  helyesen kezeli a 0°/360° RA-átfordulást, pl. 359.9° és 0.1° körülbelül
  0.0°-ra klaszterez, nem a szemközti 180°-ra), keretszám szerint csökkenő
  sorrendben A/B/C…-vel címkézve. `isMosaic` (`panels.count >= 2`),
  `isUnbalanced` (legalább két nemnulla integrációjú panel közül a
  legnagyobb/legkisebb arány > 1.5 — pl. 2:10 vs. 0:35). Új
  `Sources/AstroCore/Stats/EquipmentProfile.swift` (`SetupFingerprint`,
  `EquipmentProfile.fingerprint(meta:headerJSON:)` +
  `sessionFingerprints(target:date:db:config:)`) — kompakt eszköz-ujjlenyomat
  (kamera + gyújtótáv egész mm-re kerekítve + pixelméret 2 tizedesre +
  binning ha van + Bayer-minta + guide-kamera ha van), pl.
  `"ASI2600MC·302mm·3.76µm·RGGB"`; `nil` ha a keretnek se kamerája, se
  gyújtótávja, se pixelmérete nincs. Két új audit szabály (`Rules.swift`, 17.
  és 18.): `mixed-setup-in-session` (suspicious — egy session usable
  lightjai ≥2 különböző fingerprintre esnek szét, a fingerprint nélküli
  keretek figyelmen kívül maradnak) és `mixed-setup-in-target`
  (probablyIntentional — egy célpont session-jeinek DOMINÁNS fingerprintje
  eltér session-ök között, pl. egyik éjjel 302mm, másikon 480mm optikával —
  ez gyakran szándékos gyújtótáv-váltás, csak figyelmeztetés, nem hiba),
  mindkettő a megosztott, DB-mentes `EquipmentProfile.fingerprintCounts`
  helperen át, hogy sose térjenek el attól, mit számol fingerprintnek a
  `sessionFingerprints`. `SessionDetail` additív `setupDescriptor: String?`
  mezője (a session domináns fingerprintjének leírója, `nil` ha egyetlen
  usable lightnak sincs fingerprintje). CLI: `astrotool panels --target T
  [--json]` — emberi táblázat (PANEL / KÖZÉP RA/DEC / KERET / INTEGRÁCIÓ /
  ROT / SCALE oszlopokkal) + `"⚠️  kiegyenlítetlen mozaik"` figyelmeztető sor
  ha `isUnbalanced`. App: `AppState.panelReportsByTarget` (a `loadStats()`
  minden célponthoz kiszámolja a `sessionDetailsByTarget` mellett);
  `StatsView` célpont-sorának név-tooltipje mozaik célpontnál egy "Panelek: 3
  panel: A 2:10 · B 1:50 · C 0:35 ⚠️ kiegyenlítetlen" sort kap, a Műveletek
  cellában az Exportálás… menü mellé egy "Panelek…" gomb kerül, ami egy teljes
  panel-táblázatot mutat popoverben (label, közép RA/Dec, keretszám,
  integráció, rotáció, pixel-skála). Új tesztfájlok
  `Tests/AstroCoreTests/FieldGeometryTests.swift` (12: `CRVAL`-parszolás,
  `CD`-mátrixból pontos skála+rotáció egy elforgatás-mátrix determinánsával,
  `XPIXSZ`/`FOCALLEN` fallback skála, `NAXIS`-ból számolt látómező, egyetlen
  mező nem mozaik, két, 3°-ra lévő, 1° látómezős csoport 2 panelre
  klaszterezése, kiegyenlítetlen/kiegyensúlyozott integráció-jelzés, RA
  0°/360°-átfordulás helyes egységvektor-átlaga, üres célpont, JSON
  round-trip) és `Tests/AstroCoreTests/EquipmentProfileTests.swift` (15:
  fingerprint-leíró pontos formátuma, binning ki-/bekapcsolt állapotban,
  guide-kamera, `nil` azonosító adat nélkül, kerekítés, session-önkénti
  darabszám, domináns fingerprint kiválasztása, `SessionDetail.
  setupDescriptor` mindkét ág, JSON round-trip, mindkét audit szabály
  tüzelése/csendben maradása + fingerprint nélküli keretek figyelmen kívül
  hagyása), `CLISmokeTests` +3 (`panels --json` dekódolás, emberi "no
  WCS-solved frames" üzenet CRVAL nélküli fixture-ön, hiányzó `--target`
  hibakód).

- **Éjszakai hardver-egészség (`astrotool health`)**: session-önkénti
  hűtő-stabilitás + fókusz-trend egy paranccsal/fülön — nyáron az ASI2600
  hűtője nem biztos, hogy tartja a -20°C célhőmérsékletet, ami csendben
  lerontja a dark-kalibrációt; a FWHM éjszakán belüli emelkedése pedig
  fókuszcsúszásra/páralecsapódásra utal, ami a KÖVETKEZŐ éjszaka
  újrafókusz-intervallumát alapozza meg. Új
  `Sources/AstroCore/Stats/NightHealth.swift`
  (`NightHealth.report(target:date:db:config:)`) — (a) **hűtés**: minden
  usable light frame páros `CCD-TEMP`/`SET-TEMP` (`fits_meta`) eltérésének
  mediánja, max abszolút eltérése, és a `calib.coolerToleranceC`-n (alapból
  1.0°C) túli keretek aránya — `"stabil"` / `"hűtő nem tartja a
  célhőmérsékletet (max +3.2°C, a keretek 34%-án)"` / `"n/a — nincs hűtési
  adat"` (DSLR, nincs SET-TEMP header); (b) **fókusz**: a session pontozott
  keretjeinek `ratings.fwhm` (px) lineáris regressziója az idő (óra)
  függvényében, arcsec/óraban ha a session-nek van pixel-skálája
  (`xpixsz`+`focallen`, a `SessionQuality`-vel megosztott
  `pixelScaleArcsec` helperen át), egyébként px/óraban — `"stabil fókusz"`
  / `"fókuszcsúszás gyanú (+0.6"/3 óra)"` / `"javuló FWHM
  (lehűlés/seeing) (...)"` / `"n/a — kevés pontozott keret"` (5-nél
  kevesebb pontozott keret). Új `AstroConfig.calib.coolerToleranceC: Double
  = 1.0` mező, megosztva az új `cooler-not-reaching-setpoint` audit
  szabállyal (suspicious — session-önként, ha a keretek több mint 10%-a
  lépi túl a hűtési tűrést). CLI: `astrotool health --target T [--date D]
  [--json]` — `--date` nélkül a célpont összes session-je. App: Minőség fül
  kiválasztott session-sorának idővonal-sora alá egy második, színkódolt
  sort kapott (zöld "stabil", narancs "gyanú"/"nem tartja").

- **Kalibráció-egészség riport (`astrotool calib --health`)**: flat-fegyelem,
  bias-készlet és dark-készlet egészség egy paranccsal/fülön. Új
  `Sources/AstroCore/Calib/CalibHealth.swift` (`CalibHealth.report(db:config:)`) —
  (a) session-önkénti flat-fegyelem: `"nincs flat"` / `"flat nem illik"`
  (gyújtótáv ±2mm, szűrő, `ROTATOR`-szög `calib.rotatorToleranceDeg`-en túl,
  flat-kor `calib.flatMaxAgeDays`-en túl) / `"rendben"`; (b) minden bias frame
  (session + `calibration_library`) csoportosítva gain/offset/kamera szerint,
  plusz a usable lightok által használt, biassal le nem fedett kombók
  listája; (c) minden master dark könyvtár kora, CCD-TEMP stabilitása
  (>1.5°C szórás → figyelmeztetés), keretszáma, és nem-használt (orphan)
  jelzése. Új `AstroConfig.calib` mezők: `flatMaxAgeDays: Int = 30`,
  `rotatorToleranceDeg: Double = 2.0`. CLI: `astrotool calib --health
  [--json]`. App: Kalibráció fül új "Kalibráció-egészség" szakasza három
  lenyitható blokkal.

## [0.4.0] - 2026-08-03

### Added

- **Acquisition export (`astrotool export`)**: publikálásra kész
  acquisition-riport egyetlen paranccsal/gombbal, a TRUE (dedupolt) számokból
  — nincs több kézi adatgyűjtés session-önként. Új
  `Sources/AstroCore/Export/AcquisitionExport.swift` (`ExportFormat`:
  `astrobin`/`csv`/`md`, `render(target:format:db:config:)`/
  `write(target:format:timestamp:db:config:using:)`). `astrobin`: AstroBin
  "long acquisition" bulk-import CSV-je (`date,filter,number,duration,
  binning,gain,sensorCooling,darks,flats,flatDarks,bias,bortle,meanSqm`
  fejléc), egy sor session×nominális-expozíció csoportonként; `_hibas`-
  kizárt session teljesen kimarad, binning mindig üres (a light-oldali
  binning ma nincs elmentve, sosem tippel 1-et). `csv`: gazdagabb,
  session-önkénti általános CSV, `SessionQualitySummary`-vel joinolva,
  szabványos vessző/idézőjel-escaping-gel. `md`: emberi session-napló magyar
  címkékkel, célpont-fejléc + session-önkénti alszakaszok (README, keretek,
  expozíciók, kamera/optika, minőség, idővonal) + záró "Összegzés" (session-
  szám, összes usable integráció, cél haladás % ha van `goal:Xh` tag). CLI:
  `astrotool export --target T --format astrobin|csv|md [--out PATH]
  [--root R]` — alapból `.astro_tool/exports/`-be ír és kiírja az útvonalat,
  `--out -` stdoutra, `--out PATH` a könyvtáron kívülre engedélyezett. App:
  Statisztika fül célpont-sorának Műveletek cellájában "Exportálás…" menü
  (AstroBin CSV / CSV / Markdown) → Finder-reveal.

- **Észlelés-tervező (`astrotool plan`)**: a könyvtár-kezelőt éjszakai
  tervezővé bővítő új parancs — minden ismert célponthoz megmutatja a meglévő
  (usable) integrációt, a hiányzó órákat (a meglévő `goal:<óra>h` tag alapján,
  pl. `goal:6.5h`), a ma esti kulminációt és max magasságot, a `--min-alt`
  fölötti láthatósági ablakot a csillagászati éjszakán belül, a Hold
  fázisát/szögtávolságát a célponttól, és egy magyar verdiktet (`"ma jó"` /
  `"Hold zavar (32°, 89%)"` / `"alacsony (max 18°)"` / `"nem látszik ma
  éjjel"` / `"nincs koordináta"`), pontszám szerint csökkenő sorrendben. Új,
  zéró-függőségű `Sources/AstroCore/Sky/` modul (`JulianDate`, `SiderealTime`,
  `AltAz`, `SunMoon` — Meeus *Astronomical Algorithms* alacsony-pontosságú
  Nap/Hold-formulái, Meeus tankönyvi példáival validálva) és
  `TargetCoordinates` (célpont RA/Dec mediánja plate-solve `CRVAL1`/`CRVAL2`
  vagy `RA`/`DEC` fejlécekből, számos-vagy-szexagezimális formában is).
  `AstroConfig.site: SiteRule` (`latitudeDeg`/`longitudeDeg`, alapból `nil`) —
  ha üres, a `SITELAT`/`SITELONG` fejlécek könyvtár-mediánjából származik,
  csak memóriában cachelva, sosem lemezre írva. CLI: `astrotool plan
  [--date YYYY-MM-DD] [--min-alt 30] [--json]` — az emberi kimenet fejléce a
  szürkület/hajnal időt és a Hold fázisát mutatja, a helyszín koordinátáit
  SOHA (privacy). App: „Ma este" doboz az Áttekintés fülön (top 5 célpont,
  színezett verdikt-jelvény, „Frissítés" gomb).

- **Projekt-státusz (`astrotool projects`)**: célpontonkénti feldolgozási
  állapot ("felhős este mit dolgozzak fel?") — minden ismert célponthoz egy
  fázis (`gyujtes` / `stackelheto` / `feldolgozasra_var` / `kesz`) és egy
  konkrét, magyar to-do lista. Új `Sources/AstroCore/Stats/ProjectStatus.swift`
  (`ProjectPhase`/`ProjectState`/`ProjectStatusQueries.projects`) —
  `StatsQueries`/`SessionStatsQueries` session-részleteire és a `files` tábla
  `stacks`/`processed` sorainak dátum-átfedésére épül (ugyanaz az
  átfedés-logika, mint az audit `missing-counterpart` szabályáé), a
  `goal:<óra>h` cél-tag parse-olása kiemelve a `Planner`-ből egy közös
  `Sources/AstroCore/Stats/GoalTag.swift` helperbe (`GoalTag.parse(tags:)`),
  amit mindkét feature használ. `AstroConfig.stats.collectingThresholdSeconds`
  additív mező (alapból 2 óra) — sztek nélküli célpont eddig számít
  "gyűjtés alatt"-nak. To-do sorok: „készíts stacket: cél/dátum", „dolgozd
  fel: stacks/cél/dátum", „hiányzik még N.N óra a célhoz (goal:Xh)", „nincs
  README: cél/dátum", „kizárt session: dátum (hibas)" — a `_hibas` sessionök
  nem befolyásolják a fázist, csak megjelennek a listában. CLI: `astrotool
  projects [--root R] [--json]` — emberi kimenet fázis szerint csoportosítva
  (magyar fejlécek: „Gyűjtés alatt" / „Stackelhető" / „Feldolgozásra vár" /
  „Kész"), célpontonként név + meglévő/cél óraszám + első 2 to-do. App:
  „Projektek" doboz az Áttekintés fülön (Takarítás alatt) — fázisonkénti
  darabszám színes jelvényekkel, top 3 tennivaló célpont az első to-dójukkal,
  automatikusan frissül scan után (`AppState.loadProjects()`).

## [0.3.0] - 2026-08-03

### Added

- **Valós (usable) integráció és keret-statisztika**: a kimutatott
  integrációs idő eddig ~30%-kal felfújt volt, mert a `PathClassifier`
  mindent light keretnek jelölt a `lights/` mappa alatt — a Siril-oldali
  triázs-eszköz (`Stack`/`Review`/`Reject/<ok>`) hardlinkelt másolatait,
  CR3+TIF duplikátumokat, `.xmp`/`.png`/`.txt`/`.html`/`.csv`/`.ssf`/`.json`
  sidecar-okat, feldolgozott derivatívumokat (`starless_*`, `starmask_*`),
  a `Reject/`-be triázsolt kereteket, és a `_hibas`-címkés ("rossz éjszaka")
  session-öket is beleszámítva. Új `Sources/AstroCore/Stats/FrameSet.swift`
  (`FrameSet.lightBuckets`) — a "melyik fájl valódi, használható light
  keret" egyetlen igazságforrása: nem-keret kiterjesztés/derivatívum-név
  kiszűrve, dedup elsődlegesen a fájlrendszer `inode`-ja szerint (új séma
  v3: `files.inode`/`files.nlink`, a `Scanner` minden fájlnál rögzíti),
  `inode` hiányában `(célpont, session-dátum, DATE-OBS, exptime)`
  fallback-kulccsal, plusz cross-extension CR3+TIF összevonás (a nyers CR3
  marad). `AstroConfig.stats.excludeLabels` (`["hibas"]` alapértelmezett)
  — `.labeled` session-dátumok, ha címkéjük szerepel a listán, kimaradnak
  a célpont-összegekből (a session-részletekben viszont változatlanul,
  `isExcludedFromTotals` jelzéssel megjelennek). `TargetStats`/
  `SessionDetail` additív mezői (`usableIntegrationSeconds`/
  `grossIntegrationSeconds`, `usableFrameCount`/`usableLightCount`,
  `duplicateLinkCount`, `rejectedFrameCount`/`rejectedCount`,
  `nonFrameFileCount`, `excludedSessionDates`) — `totalIntegrationSeconds`
  mostantól a valós (usable) számot adja vissza. CLI `stats --gross`
  kapcsoló mutatja mellé a régi (dedup nélküli) bruttó számot is. App:
  session-sorok „N light (+N elvetett · N link)" formában, kizárt
  (`_hibas`) session-sorok fél-áttetsző „kizárva" jelvénnyel, célpont-sorok
  tooltipje a teljes bontással.
- **Részletes minőség-táblázat**: a Minőség fül eddig csak Útvonal/Pontszám/
  Kiugró oszlopokat mutatott — ha a Siril nem adott metrikát egy kerethez,
  a pontszám kizárólag a háttér-metrikából jött, ami azonos-pontszám
  klasztereket eredményezett, és a hosszú útvonalakból nem látszott, melyik
  saját triázs-almappában (pl. `lights/Junk`) ül a keret. `FrameScore`
  additív bővítése: `saturatedFraction`, `exptime`, számolt `fileName`, és
  `sessionSubdir` (a `sessions/<target>/<date>/` és a fájlnév közti
  útvonal-rész — egy felhasználó saját triázs-almappája így azonnal
  látszik); mind opcionális, a régi (mező nélküli) JSON változatlanul
  betölthető marad. `QualityView` táblázata Fájl (teljes útvonal tooltip),
  Mappa, Pontszám, FWHM, Kerekség, Csillagok, Háttér, Szat. %, Exp. és
  Kiugró oszlopokra bővült, rendezhető fejlécekkel (alapértelmezés:
  Pontszám csökkenő) és kiugró sorok piros kiemelésével, plusz egy futás
  utáni összegző sor ("N frame · kiugró: K · Siril metrika: M/N"). CLI
  `rate` emberi táblázata FWHM/Kerekség/Csillagok/Háttér/Szat.%
  oszlopokkal bővült ("-" nil esetén); `--json` automatikusan hozza az új
  mezőket.
- **Abszolút session-minőség (arcsec, e-/s), éjszaka-idővonal, rate-javítások
  (R4-2)**: a `rate` z-score-jai RELATÍVAK — nem tudnak válaszolni arra,
  hogy "ma éjjel jobb volt-e, mint tavaly?" — ehhez kellenek beállítás-
  függetlenül összehasonlítható ABSZOLÚT metrikák. Séma v4: `fits_meta.
  xpixsz`/`egain` új oszlopok (pixelméret µm-ben, kamera e-/ADU gain) —
  migráció visszatölti a meglévő sorok `header_json`-jából (nincs
  fájlolvasás), a `Scanner` új FITS-eknél a fejlécből rögzíti. Új
  `Sources/AstroCore/Stats/SessionQuality.swift`
  (`SessionQualitySummary`/`SessionQuality.summaries`) — session-önkénti
  medián FWHM pixelben ÉS ívmásodpercben (`206.265 × xpixsz(µm) /
  focallen(mm)` pixelskála), égi háttér e-/s/ívmásodperc²-ben
  (`háttér(ADU) × egain / exptime / skála²`), medián csillagszám,
  kiugró-arány (a tárolt `score` és `config.rating.outlierZScore` alapján
  újraszámolva), és rangsor a célpont session-jei között (1 = legjobb
  ívmásodperces FWHM, hiányzó metrikájú session nem kap rangot). Új
  `Sources/AstroCore/Stats/SessionTimeline.swift`
  (`SessionTimeline.timeline`) — éjszaka-idővonal a használható lightok
  DATE-OBS-jából (FITS ÉS EXIF formátum is): ablak eleje/vége, integráció,
  hatékonyság (integráció/ablak), és a csendes kiesések listája
  (`config.stats.gapThresholdSeconds`, 0 = auto → 3× a session medián
  NOMINÁLIS expozíciója). Rate-javítások: (a) `NominalExposure.nominal`
  — egy valós könyvtárban az exptime lebegőpontos zajjal jár (30.0 és
  29.899999618523 ugyanaz a "30s" sub, 822 ill. 91 kerettel) — 10s alatt
  0.1s-re, felette egész másodpercre kerekítve, ez küszöböli ki a
  parányi, std≈0 csoportokat a `Rater` pontozásában ÉS az
  `exposureBreakdown` kulcsaiban (`StatsQueries`/`SessionStatsQueries`);
  (b) a `Rater` pontozás-csoportosítása mostantól (session-dátum, nominális
  exptime) párra megy, nem csak exptime-ra — így egy `--date` nélküli,
  több éjszakát átfogó `rate` nem keveri össze a különböző éjszakák
  égbolt-viszonyait egy z-score populációba; (c) `SirilCLI.
  parseFindstarOutput` mostantól `nil`-t ad vissza hiányzó kerekségre a
  korábbi kitalált `0.5` helyett (`StarMetrics.roundness` → `Double?`) —
  a `Rater` súly-újranormalizálása már eddig is kezelte a hiányzó
  metrikákat. CLI: `astrotool quality --target T [--date D] [--json]`
  (dátum, keret, FWHM px/", háttér e-/s/"², csillag, kiugró%, rang
  táblázat) és `astrotool stats --target T --timeline [--date D] [--json]`
  (ablak, integráció, hatékonyság%, kiesés-lista). App: a Minőség fülön a
  keret-táblázat FÖLÉ kerül egy session-összegző szakasz (dátum · keret ·
  FWHM" · háttér · rang jelvény, pl. "2/6"), session kiválasztásakor
  idővonal-sor jelenik meg ("Ablak 3:42 · integráció 2:11 · hatékonyság
  59% · 2 kiesés (37m, 12m)") — `AppState.loadQualitySummaries(target:)`/
  `loadSessionTimeline(target:date:)` háttérműveletek.
- **Kalibráció-illesztés teljes elektronikus kulccsal (gain/offset/bin/
  kamera), DATE-OBS-alapú master-kor (R4-3)**: a `CalibAnalyzer` eddig
  csak a master DIR NEVÉBŐL olvasott (exponálás, hőmérséklet) alapján
  párosított darkot lightokkal — de egy hűtött CMOS kamera (pl. ASI2600)
  dark-jele GAIN-től és OFFSET-től is függ, egy rossz gain-ű dark
  linkelése AKTÍVAN ÁRT a kalibráción. Mostantól a masterek saját FITS
  fejlécükből (`GAIN`/`OFFSET`/`INSTRUME`/`XBINNING`) épített elektronikus
  identitást kapnak, és egy light csak akkor illeszkedik egy azonos
  (exponálás, hőmérséklet) masterhez, ha minden bekapcsolt dimenzió is
  egyezik. Ha egy master a helyes exponálás/hőmérsékletnél van, de rossz
  elektronikán, a `link-calib`/`calib` most figyelmeztet ahelyett, hogy
  csendben linkelné vagy csendben semmit se találna: `CalibNeed`/
  `CalibLinkPlan` `mismatchReasons` mezője magyarul elmondja miért (pl.
  `"gain 0 ≠ 100"`, `"másik kamera: ZWO ASI2600MC Pro"`). A master kora
  mostantól elsősorban a fájlok `DATE-OBS`-ából számol (mtime csak
  fallback, ha nincs DATE-OBS) — egy sima copy/rsync nem "fiatalítja meg"
  hamisan a mastert. CLI: `calib` figyelmeztető sort ír mismatch esetén,
  `link-calib` üres terv esetén a konkrét okot írja ki. App:
  `CalibrationView` új "Megjegyzés" oszlopa, `CalibLinkSheet` a mismatch
  okot mutatja üres terv esetén.

### Changed

- **`CalibRule` két alapértéke** (`AstroConfig.calib`): `tempToleranceC`
  **0.5 → 1.0** (egy hűtött CMOS set-pontja ±0.1-0.2°C-ot ingadozik, a régi
  érték feleslegesen szigorú volt) és `darkMaxAgeMonths` **6 → 12** (a kor
  csak figyelmeztetés, nem elsődleges érvénytelenítő — az új elektronikus
  kulcs-ellenőrzés az). **Meglévő `config.json`-nal rendelkező
  felhasználók nem érintettek automatikusan**: a fájlban explicit szereplő
  régi érték változatlanul betöltődik; csak az új, még soha el nem mentett
  konfigurációk kapják az új alapértéket. Ha valaki korábban már mentette
  a Beállítások képernyőt (akár változtatás nélkül), a `config.json`
  tartalmazza a régi 0.5/6 értéket, és az a Beállítások következő
  mentésekor is megmarad, amíg valaki kézzel át nem írja.

## [0.2.3] - 2026-08-03

### Javítva

- **Kritikus: `Array index is out of range` crash a Pontozás (`rate`)
  futtatásakor valós FITS fájlokon**: gyökérok — egy fájlban véletlenül
  szomszédos CR+LF bájtpár (`0x0D 0x0A`) esett a 2880 bájtos fejléc-blokkba;
  Swift a `"\r\n"`-t EGYETLEN `Character`-ként grafémaklaszterezi (Unicode
  UAX #29 GB3 szabály), így `Array(String(data:encoding:.ascii))` egy ilyen
  blokkból csak 2879 elemű tömböt adott 2880 helyett. A `FITSReader.
  readOneHeader` (és a testvér `NativeStats.primaryHeaderInfo`, ami
  szándékosan duplikálja ugyanezt a blokk-szkennelést a nyers primary
  `NAXIS` miatt, ha a fő `FITSReader.parse` már összefésülte egy `.fz`
  extenzióval) 0-alapú, fix `cardIndex * 80` kártya-szeletelése emiatt
  elszállt, amint a ciklus elért egy olyan kártyáig, aminek a tartománya már
  nem fért bele a lerövidült tömbbe. Javítás: mindkét helyen bájtonkénti
  dekódolás (`data.map { Character(Unicode.Scalar($0)) }`) a
  `String(data:encoding:.ascii)` + `Array(_:)` pár helyett — szigorú 1:1
  bájt↔tömbelem megfelelés, függetlenül a bájttartalomtól. Az
  `autoreleasepool` memóriakorlátozás (lásd 0.1.3 audit memória-javítás)
  változatlan. `Rater.rate` már meglévő `do/catch` blokkja
  (`NativeStats.compute(url:)` körül) egy dobott `AstroError.corruptFITS`-et
  változatlanul lekezel és a batch többi keretét tovább pontozza — a valódi
  védelem azonban a forrás-javítás, mivel egy Swift `Fatal error` trap sosem
  catch-elhető.

## [0.2.2] - 2026-08-03

### Changed

- **Statisztika tab újratervezés**: a `DisclosureGroup`-alapú célpont-lista
  helyett natív SwiftUI hierarchikus `Table` (oszlopfejlécek, átméretezhető
  oszlopok, váltakozó sorháttér, beépített lenyitó-chevron a session-sorokon)
  — a session-sorok automatikusan behúzva jelennek meg az első oszlopban,
  minden más érték a saját oszlopában marad, sorhatáron nem törik.
  - 8 oszlop: Célpont/Session (wide-field jelvény + README badge),
    Integráció, Keretek, Expozíciók/Utolsó dátum, Kamera, Részletek
    (csak session-soroknál: gyújtótáv/gain/hőm./szűrő), Címkék (tag-chipek,
    változatlan hozzáadás/törlés), Műveletek (session-soroknál „Kalibráció
    linkelése…").
  - `AppState.loadStats()` mostantól minden célpont session-részleteit is
    egyszerre betölti (`sessionDetailsByTarget: [String: [SessionDetail]]`)
    — a `Table(children:)` nem tud lenyitáskor lazy-betölteni, ezért ez
    kiváltja a régi egy-célpontos `loadSessionDetails`/`sessionDetails`/
    `selectedTarget` API-t (eltávolítva, sehol máshol nem volt rá hivatkozás).

## [0.2.1] - 2026-08-03

### Changed

- **Audit tab UX**: éles screenshotokból jött panaszok javítva.
  - Minden audit-finding üzenet (`Rules.swift`, `DuplicateFinder`,
    `SessionMatcher`, `CleanupReport`) magyarra fordítva — eddig a magyar UI
    közepén angol mondatok jelentek meg (`FITS IMAGETYP "Dark" doesn't match
    this file's location`, `".DS_Store" looks like leftover processing
    residue`).
  - Új `AuditEngine.suppressRedundantFindings` post-pass: egy beágyazott
    session-fa (pl. `sessions/<target>/<date>/flats/sessions/session1/
    darks/`) korábban egyetlen `nested-session-tree` találat MELLETT tucatnyi
    vagy száznál is több azonos `calib-in-wrong-dir`/`misplaced-file`/
    `loose-frames-in-date-dir` sort produkált a mögötte lévő fájlokra — ezek
    most elnyomódnak, ha az útvonaluk egy ugyanabban a futásban
    `nested-session-tree`-vel jelölt mappa alatt van.
  - `AstroConfig.toolOutputDirNames` új alapértelmezett eleme: `"masters"` —
    stackelt master fájlok szándékos `masters/` alkönyvtára a raw-ok mellett
    (pl. `sessions/<target>/<date>/darks/masters/…stacked.fit`) többé nem
    kap `calib-in-wrong-dir` találatot, hanem egy `probablyIntentional`
    `tool-output` találatot.
  - App: `AuditView` a lapos táblázatot lenyitható, csoportosított listára
    cserélte (Stats fül `DisclosureGroup` stílusában) — egy sor egy
    (súlyosság, kategória, csoport) hármasra, darabszám-jelvénnyel, lenyitva
    az egyedi találatokkal. CLI: `astrotool audit` emberi kimenete
    (`--json` nélkül) ugyanígy csoportosítva, csoportonként max 3 példa-
    útvonallal — a teljes lista változatlanul elérhető `--json`-nal. A
    csoportosító logika közös: új `Sources/AstroCore/Audit/
    FindingGrouper.swift`.

## [0.2.0] - 2026-08-03

### Added

- **Méret szerint rendezett szemét-riport (`cleanup`)**: az audit már ismeri
  a Siril-maradványokat (`.seq`/`.lst`/`r_*`/`process/` stb.) és a
  duplikátum-tartalmakat findingenként, de nem volt egy összesítő válasz
  arra, hogy „mit érdemes kitakarítani és mennyit nyerek vele". Új
  `Sources/AstroCore/Audit/CleanupReport.swift`
  (`CleanupGroup`/`CleanupSummary`/`CleanupReport.build(db:config:
  maxPathsPerGroup:)`): kategóriánként (`residue-seq`/`residue-lst`/
  `residue-process-dir`/`residue-other`/`duplicate-content`) csökkenő méret
  szerint rendezett csoportok, csoportonként a legnagyobb fájlok felsorolva
  (alapból max. 50, a többi csak számban). A duplikátum-csoport pazarolt
  bájtja méret × (n−1), a megtartott példány a `sessions/` másolat (ha van),
  egyébként az ábécé szerint első — ha még nem futott duplikátum-kereső
  audit, a csoport egyszerűen hiányzik (nincs becslés/nullázás). A meglévő
  `ResidueRule` glob-illesztő és `residueDirNames`-ellenőrző logikája egy
  megosztott `ResidueMatcher` helperbe lett kiemelve (nincs duplikálva), és
  a `toolOutputDirNames` alá eső fájlok sosem számítanak reziduumnak, akárhogy
  is hívják őket. CLI: `astrotool cleanup [--root R] [--json] [--suggest]
  [--limit N]` — emberi kimenet csoportonként méret + top útvonalak, majd
  „összesen felszabadítható" összegzés. `--suggest` egy karantén-alapú,
  visszafordítható scriptet ír: minden jelölt fájlt egy `.astro_tool/
  cleanup_quarantine/<időbélyeg>/<eredeti relatív útvonal>` alá **mozgat**
  (`mv`, mkdir -p a szülőkönyvtárra) — SOHA nem `rm`, a felhasználó a
  karanténmappát később saját kézzel ürítheti. Ehhez a meglévő
  `SuggestionScript` kapott egy `commentSuspicious: Bool = true` paramétert
  (`generate`/`write`) — alapból (auditnál) változatlan a komment-soros
  gyanús-találat viselkedés, a cleanup script viszont `false`-t ad át, hogy
  a karantén-`mv`-k aktívan (nem kikommentelve) kerüljenek be. App:
  Áttekintés fülön új „Takarítás" doboz (összesen felszabadítható + top 3
  kategória) és „Takarítási script generálása" gomb (`AppState.
  cleanupSummary`/`loadCleanup()`/`generateCleanupScript()`, audit után
  automatikusan frissül).

- **Kalibráció hard-linkelés (új írási művelet, kizárólag explicit gombra/
  parancsra)**: a tool megkeresi a session lightjaihoz illő master darkot,
  a flatjaihoz illő flat-darkot és a bias mastert a `calibration_library/`-ban
  (ugyanaz az exp/temp tűrés-illesztés, mint a kalibrációs lefedettség
  nézetnél), és **hard linkeli** őket a session saját `darks`/`biases`
  mappájába. Meglévő cél-fájlt **soha nem ír felül** — ha már ott van,
  kihagyja és jelzi. Kizárólag hard link (azonos kötet); ha ez valamiért
  mégsem menne (cross-device), hibát jelez, NEM esik vissza csendben
  másolásra. Semmi más nem törlődik vagy mozog — a vasszabály (nincs
  törlés/mozgatás a képkönyvtárban) változatlan. Új `WriteGuard.
  linkCalibrationFile(sourceRelative:destDirRelative:)` — a forrásnak a
  `calibration_library/` alá, a célnak szigorúan `sessions/<target>/<date>/
  (darks|biases|flats)` mintára kell esnie, mindkettő a `writeToolFile`-lal
  azonos útvonal-védelemmel. Új `Sources/AstroCore/Calib/CalibLinker.swift`
  (`CalibLinker.plan`/`apply`) a meglévő `SessionMatcher`/`CalibAnalyzer`
  illesztési logikáját újrahasználva. CLI: `astrotool link-calib --target T
  --date D [--dry-run] [--yes] [--json]` — alapból kiírja a tervet és
  stdin-en kér megerősítést (`Type YES to link:`), `--dry-run` sosem ír,
  szkriptelt/`--json` híváshoz `--yes` kötelező. App: „Kalibráció
  linkelése…" gomb minden session-sornál (Statisztika fül) egy megerősítő
  sheet-tel, ami a tervet célkönyvtár szerint csoportosítva, indoklással
  mutatja, és a linkelés után frissíti a session-részleteket.

- **Szabad szöveges címkék (tagek) célpontokra és session-ökre**: DB séma
  v2-re bővült egy `tags` táblával (`kind`, `target`, `session_date`, `tag`,
  `UNIQUE(kind, target, session_date, tag)`); a migráció verzió-lépcsős
  (`if version < 1 { … } if version < 2 { … }`), így egy már éles v1 könyvtár
  a meglévő adatai érintetlenül maradása mellett kapja meg a `tags` táblát,
  egy friss könyvtár pedig egyből v2-re fut. Új `Database` API:
  `addTag`/`removeTag`/`tags(target:sessionDate:)`/`allTags()`/
  `targetsWithTag(_:)` — a `kind` mindig a `sessionDate` nil-ességéből
  származik, a tag szöveg trim-elve és üres/csak-szóköz esetén
  `AstroError.invalidInput`-ot dob, a hozzáadás explicit exists-check-kel
  idempotens (a `UNIQUE` index önmagában nem elég, mert SQL `NULL` sosem
  egyenlő `NULL`-lal). CLI: `astrotool tag add/remove --target T [--date D]
  <tag> [--json]` egy session-höz vagy magához a célponthoz, `tag list
  [--target T] [--date D] [--json]` (célpont nélkül minden tag
  csoportosítva kiírva), valamint `stats --tag TAG` szűrő, ami csak a
  target-szintű tag-gel rendelkező célpontokat mutatja. `TargetStats` és
  `SessionDetail` új `tags: [String]` mezőt kapott (a régi JSON-ból hiányzó
  `tags` kulcs `[]`-ra esik vissza dekódoláskor). App oldalon a Stats fül
  táblája lenyitható (`DisclosureGroup`) célpont-sorokra cserélődött —
  fejlécben a régi oszlopok mellett tag-chipek, lenyitáskor lazy
  session-lista session-önkénti tag-chipekkel, „+" chip popoverrel új címke
  felvételéhez és ✕ törléshez; a keresőmező mostantól célpont neve VAGY
  címke szerint is szűr.

## [0.1.3] - 2026-08-02

### Added

- **Session-részletes statisztika**: `astrotool stats --target T --sessions
  [--json]` és a Stats fül (célpont-sor kiválasztása) mostantól session-önkénti
  bontást ad az adott célpont minden `sessions/<target>/<date>/` mappájához —
  kereten-számok szerep szerint (light/flat/dark/bias), integrációs idő és
  expozíció-bontás (csak a light keretekből, ugyanúgy, mint a `TargetStats`),
  valamint a light keretek `fits_meta`-jából származó gyújtótávolság
  (kerekítve 1 mm-re), kamera (`instrume`), gain/ISO, szenzor hőmérséklet
  (kerekítve 0.5°C-ra) és szűrő listája, plusz hogy a session-mappának van-e
  `README.txt`-je. Új `Sources/AstroCore/Stats/SessionStats.swift`
  (`SessionDetail`, `SessionStatsQueries.sessions(target:db:config:)`); app
  oldalon `AppState.loadSessionDetails(target:)` + `StatsView` táblasor-
  kiválasztás alatti részletpanel.

### Javítva

- **Audit memória-javítás**: `astrotool audit` (duplikátum-keresés) korlátlanul
  nőtt memóriában valós könyvtárakon (~40 GB néhány másodperc alatt egy
  ~281 GB/~14 700 fájlos könyvtáron), mert (1) a `DuplicateFinder` chunkolt
  SHA-256 olvasása (`sha256Hash(of:)`) nem volt `autoreleasepool`-ba
  csomagolva chunkonként, így a Darwin Data/NSData-hidalás autorelease
  pufferei a teljes futás végéig életben maradtak a hashelt bájtok teljes
  mennyiségével arányosan nőve, ÉS (2) az azonos kameráról származó FITS
  keretek méret szerint gyakorlatilag mind egyeznek, így a méret-előszűrő
  szinte mindent átengedett teljes SHA-256 hashelésre. Javítás: minden
  chunk olvasás+hash-frissítés saját `autoreleasepool`-ba került
  (`DuplicateFinder`, `FITSReader.readOneHeader`, `Rater.rate` a
  `NativeStats.compute(url:)` hívás körül); a `DuplicateFinder` új
  prefix-hash réteget kapott — azonos méretű, még nem cache-elt fájlok
  előbb az első 64 KiB alapján csoportosulnak (streamelve, memóriakorlátos),
  és csak azok a (méret, prefix) csoportok mennek tovább teljes tartalmi
  SHA-256-ra, amelyeknél ez is ütközik; a prefix-hash tisztán futásidőn
  belüli optimalizáció, nem kerül perzisztálásra — a `content_hash` mezőbe
  továbbra is csak a teljes hash íródik, változatlanul viselkedve a
  gyorsítótár-találatok esetén. Mért csúcs-RSS egy 60×5 MiB (300 MiB)
  szintetikus fixture-ön (3 valódi duplikátum-pár, minden fájl azonos
  méretű): **javítás előtt +301,5 MiB** (kb. 1:1 arány a teljes hashelt
  bájtmennyiséggel — az összes fájl teljes SHA-256 hashelésre ment),
  **javítás után +2,3 MiB** — a memórianövekedés a fájlszámtól/mérettől
  függetlenül korlátos marad.

## [0.1.2] - 2026-08-02

### Added

- **`astrotool scan --refresh-meta`**: metaadat-backfill változatlan fájlokra —
  újraolvassa a `fits_meta`-t ott, ahol nincs meta-sor, vagy ahol egy
  RAW/kép-fájl `exptime`-ja üres (a Canon CR3/TIF expozíciós idő EXIF-ből
  történő kinyerése a funkció megjelenése ELŐTT beolvasott fájlokra így
  pótolható). A scan-összegzés új `meta_refreshed` mezőt kapott.
- **Session-létrehozás**: új `Sources/AstroCore/NewSession/SessionCreator.swift`
  fogja össze a sanitize+dátum-validáció+README+könyvtárfa-létrehozás logikát
  egy helyen — a CLI `new-session` és a SwiftUI app `AppState.createSession`
  mostantól ezt hívja a korábbi, egymástól függetlenül duplikált logika
  helyett. A generált `README.txt` a valós `add_new_session.sh` szó szerinti
  szövegét követi (fejléc, "Folder map", "Fill in metadata", "Calibration
  reminder" szakaszok).
- **Audit**: új `tool-output` szabály és `AstroConfig.toolOutputDirNames`
  (alapértelmezés: `Stack`, `Review`, `Reject`,
  `light_frame_rating_report_assets`) — a `tools/rate/LightFrameRater.py`
  triázs-eszköz ismert kimeneti mappáit `probablyIntentional` súlyossággal,
  "ismert tool-kimenet" üzenettel jelzi, ahelyett hogy a
  `noncanonical-subdir`/`assets-without-date`/`loose-frames-in-date-dir`
  szabályok gyanúsként megjelölnék.

### Javítva

- **Elavult besorolás gyógyítása beolvasáskor**: a `scan` az `unchanged`
  (méret+mtime azonos) fájlokra is újraszámolja a `PathClassifier` kimenetét
  (terület/cél/session-dátum/szerep) és a `kind`-öt, és helyben frissíti a
  DB-sort, ha az eltér a tárolttól — korábban egy classifier-javítás után a
  már beolvasott sorok örökre megtartották a régi (hibás) besorolást, amíg a
  fájl maga meg nem változott. A lazán heverő keret (`loose-frames-in-date-dir`)
  IMAGETYP-alapú szerep-finomítása védett marad: ha a tárolt szerep konkrét
  keret-szerep (light/flat/dark/bias), egy újrabeolvasás nem degradálja
  vissza `.other`-re csak azért, mert a tiszta útvonal-osztályozó azt adná.
  Új `ScanSummary.reclassified: Int` mező (additív, alapértelmezett 0); a CLI
  `scan` ", reclassified N"-t ír ki, ha N > 0.
- **DSLR (CR3/TIF) expozíciós idő az Exif-ből**: a FITS `EXPTIME` fejléc
  nélküli DSLR fény-keretek (pl. Canon CR3) eddig
  `exposureBreakdown["unknown"]`-ban landoltak, 0 másodperccel járulva hozzá
  az integrációs időhöz. `ImageMetaReader`/`ImageMeta` mostantól kiolvassa az
  Exif `ExposureTime`-ot és `ISOSpeedRatings`-et is; a `Scanner` ezeket a
  `fits_meta.exptime`/`gain` oszlopokba menti CR3/TIF fájloknál (az ISO a
  `gain` oszlopban), így a `StatsQueries` integrációs/exponálási statisztikái
  változtatás nélkül beszámítják őket.
- **Ground-truth verifikáció**: a valós `add_new_session.sh` elolvasása után
  kiderült, hogy a `sanitize()` a nem engedélyezett karaktereket TÖRLI
  (`tr -cd 'A-Za-z0-9._-'`), nem `_`-ra cseréli — a portolt `Sanitizer`
  javítva erre a szemantikára (`"a///b   c"` → `"ab_c"`, nem `"a_b_c"`).
- `WriteGuard.createSessionTree` mostantól a script tényleges teljes fáját
  hozza létre: a `sessions/<T>/<D>/{lights,flats,darks,biases}` + `README.txt`
  mellett `stacks/<T>/<D>/`-t és `processed/<T>/<D>/`-t is, és mkdir -p
  szemantikával biztosítja a bázis-mappákat
  (`calibration_library/{darks,flats,biases}`).
- **Pontozás (rate)**: a z-score-ok mostantól exponálási csoportonként (FITS
  `EXPTIME`, 0.1s-re kerekítve; expozíció nélküli képek egy közös csoportot
  alkotnak) számolódnak a teljes batch helyett, ugyanúgy, ahogy a bevált
  `tools/rate/LightFrameRater.py` mindig fixen külön hasonlítja össze az
  azonos expozíciós idejű képeket.

- Valós-könyvtár keménység (R1): a `PathClassifier` helyesen kezeli a sekély
  útvonalakat (`sessions/.DS_Store`, `sessions/<target>/.DS_Store` stb.) —
  korábban a fájlnevet tévesen célpont/dátum néven értelmezte.
- A session-terület szerep-alkönyvtárai (`lights/flats/darks/biases`) mostantól
  egyes számban is felismerésre kerülnek (`light`/`flat`/`dark`/`bias`,
  kis-nagybetűtől függetlenül); a `calibration_library/` viselkedése
  változatlan (az árva `bias` mappa továbbra is jelzésre kerül).
- A dátum-mappában közvetlenül (alkönyvtár nélkül) heverő fény/flat/dark/bias
  keretek szerepe a beolvasáskor a FITS `IMAGETYP` alapján finomodik, így
  helyesen számítanak bele a statisztikába/kalibrációba; új audit szabály
  (`loose-frames-in-date-dir`) jelzi az ilyen elrendezést.
- A beolvasás (`scan`) többé nem szakad meg egy mélyebb (nem gyökér)
  alkönyvtár EPERM/EACCES hibájánál — azt a részfát kihagyja, az érintett
  útvonalat `ScanSummary.inaccessiblePaths`-be jegyzi, és folytatja a többi
  fát; az így kimaradt fájlok nem lesznek tévesen hiányzónak jelölve. A CLI
  `scan` figyelmeztetést ír stderr-re, ha volt ilyen. A gyökér/megadott
  alútvonal saját hibája továbbra is `accessDenied`-et dob (exit 2).
- `StatsQueries`: regresszióteszt, hogy egy `sessions/` alatt közvetlenül lévő
  fájl soha nem hoz létre statisztika-sort (a fenti classifier-javítás
  következménye).
- Az app: sikeres `runScan()` után a Statisztika és Kalibráció fülek adatai is
  automatikusan frissülnek, nem csak a következő fül-váltáskor.

## [0.1.1]

### Javítva

- Javítva: TCC-hiba helyes kezelése (exit 2) a `.astro_tool` létrehozásakor és
  DB-nyitáskor; app: stale operation guard.

## [0.1.0] - 2026-08-02

Első kiadás.

### Added

- **CLI (`astrotool`)**: `scan`, `audit` (`--suggest`, `--include-suspicious`,
  `--no-duplicates`), `rate` (`--target`, `--date`, `--no-siril`), `stats`,
  `calib`, `match`, `new-session`, `config` (`show`/`path`) alparancsok;
  `--json` kimenet minden alparancsnál; `exit 2` a TCC/hozzáférés-megtagadás
  jelzésére.
- **Audit motor**: hármas súlyosság-besorolás (biztos hiba / gyanús /
  valószínűleg szándékos), reziduum- és duplikátum-felismerés, javaslat-script
  generálás (`<ROOT>/.astro_tool/suggestions/`) — a könyvtárban semmit nem
  töröl vagy mozgat automatikusan.
- **Minőség-pontozás (rate)**: natív metrikák és opcionális Siril CLI hibrid
  worker-pool, outlier-jelzéssel.
- **Statisztika**: cél szerinti integrációs idő, session-szám, utolsó
  felvétel dátuma, wide-field besorolás.
- **Kalibráció**: lefedettség-elemzés és hiánylista (todo) a fény-keretekhez
  tartozó dark/flat/bias készletekhez.
- **Session-párosítás (match)**: egy adott cél+dátum session-höz tartozó
  kalibrációs keretek és a hozzájuk kapcsolódó problémák összerendelése.
- **Új session létrehozás (new-session)**: kanonikus `YYYY-MM-DD`
  könyvtárstruktúra és README sablon generálása.
- **SwiftUI alkalmazás (AstroTool.app)**: hat fülből álló felület (Áttekintés,
  Audit, Minőség, Statisztika, Kalibráció, Beállítások), biztonsági
  hatókörű könyvtár-választás (bookmark), hozzáférés-megtagadás képernyő
  útmutatással.
- **Csomagolás**: `build.sh` — release build, ad-hoc kódaláírás, DMG és CLI
  zip előállítása, helyi telepítés (`~/Applications`, `~/.local/bin`).
- **CI/dokumentáció**: GitHub Actions release workflow, README, LICENSE
  (MIT), changelog.
