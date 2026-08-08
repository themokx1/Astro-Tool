# Changelog

Minden lényegi változás ebben a fájlban van dokumentálva.

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elvein
alapul, a verziószámozás a [Semantic Versioning](https://semver.org/) szerint
történik.

## [Unreleased]

## [0.14.0] - 2026-08-08

### Added

- Új **Beállítások ▸ Felszerelés** lap névvel menthető kamera–optika
  setupokhoz, fizikai szenzormérettel, kamerajelleggel, fix vagy zoom
  fókusztávval és kijelölhető alapértelmezett profillal.
- Közvetlen sablonok a gyakori workflow-khoz: APS-C dedikált asztrokamera
  100–400 mm, nem modifikált full-frame Canon R8 16 mm, valamint Canon R8
  28–70 mm.
- Setupválasztó a Felfedezés oldalon. Zoomprofilnál csúszka, numerikus mező
  és léptető állítja a konkrét tervezési fókusztávot; az alkalmazás csak az
  explicit „Alkalmazás és újraszámítás” művelettel történik.

### Changed

- A Felfedezés FOV-számítása elsőként a kiválasztott kézi setup valódi
  szenzorméretét és fókusztávját használja. Ha nincs kézi profil, a korábbi
  domináns, WCS-alapú könyvtári látómező marad az automatikus fallback.
- A kiválasztott setup és a zoomprofilok legutóbbi alkalmazott fókusztávja
  megmarad az app újraindítása után is.
- A FOV tile megmutatja a setup nevét és a konkrét fókusztávot; setup- vagy
  fókusztávváltáskor az előző FOV és a belőle számolt célpontilleszkedések
  azonnal érvénytelenné válnak, amíg az új eredmény elkészül.

### Fixed

- Hibásan kézzel szerkesztett, fordított vagy nem véges zoomtartomány nem
  tudja összeomlasztani a Felfedezés csúszkáját.
- Érvénytelen kézi setupnál az app nem talál ki FOV-ot: `n/a` állapotot és
  közvetlen **Érvénytelen setup javítása…** műveletet mutat.
- Felszerelés mentése közben futó korábbi Discovery-számítás nem írhat vissza
  tartósan elavult FOV-ot; a frissítés sorba áll és az új konfigurációval fut.

## [0.13.2] - 2026-08-08

### Fixed

- A Quick Look callback már `CGImage` értéket ad át a continuationön, és az
  `NSImage` csak a fő actoron készül el. Ez megszünteti a macOS 15 runner
  utolsó, nem Sendable AppKit-objektumra vonatkozó fordítási hibáját.

## [0.13.1] - 2026-08-08

### Fixed

- Az előnézeti háttérfeladatok már csak `CGImage` vagy `Data` értéket adnak
  vissza, az `NSImage` példányosítása pedig a fő actoron történik. Ez javítja
  a macOS 15 GitHub Actions runner szigorú Swift concurrency-ellenőrzésén
  elbukó release buildet.

## [0.13.0] - 2026-08-08

A v0.13.0 az R11 teljes workflow-bővítését és az R12 javítási hullámát adja
ki: a korábbi funkciók valós asztrofotós használat szerinti újraellenőrzését,
összekötését és megbízhatósági javításait.

### Added

- **R12-U5 — UX/CLI/teljesítmény sweep**: egységes hiány- és mértékegység-
  formázás, metrikából célzott Fogalomtár-nyitás, feltételes Előző éjszaka
  menüpont és egységes Szenzor-profilok név; új, dátum-/helyszínérzékeny
  `calib --shopping`; pontos session-kulcsokkal működő kalibráció-linkelés;
  midrank percentilis és semleges kevés-adat állapot; gépi night/filter/
  hiány mezőkkel bővített terv-CSV; egyetlen snapshotból számolt Éjszakák
  szűrőbontás; tranzakciós, megszakítás után folytatható v10 migráció; teljes
  jegyzet/ütközés/akció támogatás a reggeli triage-kártyákon.

- **R12-U4 — publikálás és szűrőcélok**: az AstroBin CSV minden
  `(session, szűrő, nominális expozíció)` csoportot külön sorba ír saját
  filter-ID-val; a ProjectStatus, Planner és cél/hiány UI végig kezeli a
  szűrőcélokat; a biztonságos GoalEdit kézi szűrőfelvételt és kétszintű
  törlést ad; a riportok szűrőtáblát és működő `--out PATH|-` útvonalat
  kaptak; a Settings előajánlja a használt, le nem képezett szűrőket; a
  célpont Áttekintésen új, nem blokkoló „Publikálásra kész” ellenőrzés vezet
  közvetlenül a hiányzó cél-, mapping-, stack- vagy feldolgozási lépéshez.
  A célkészlet cseréje egy lockolt SQLite-tranzakció (átfedő mentéseknél sem
  olvad össze), a közös `--out` őr pedig parent- és dangling symlinken át sem
  enged írni a védett könyvtárba.

- **R12-U3 — verify/audit konzisztencia**: külön `modified-in-place`
  suspicious állapot; suspicious olvasási hiba; explicit, idempotens
  `verify --baseline`; hash-lefedettség a CLI-ben és appban; audit- és
  verify-találatok külön perzisztálva és újraindításkor visszatöltve;
  duplikátum-beállításra érzékeny auditdiff; read-only karantén-összesítő.

- **Exit-kód szerződés bővítve** (F10-a): a korábbi 0 (siker) / 1 (általános
  hiba) / 2 (TCC/kötet) mellé **3** = nem található target/session (a
  `stats`, `solve`, `match`, `link-calib`, `report`, `target-report`
  parancsok target/date-lookupja, ahol korábban ez is a generikus 1-es
  kódba esett) és **4** = külső eszköz hiba (`AstroError.sirilNotFound` —
  `solve` Siril-init-hibája) — a meglévő 0/1/2 szemantika változatlan. **5**
  **5** = a `verify` megerősített tartalomeltérést talált. A pontos táblázat
  a `docs/cli.html`-ben.
- **`schema_version` minden `--json` kimenetben** (F10-b): a közös
  `printJSON` encoder (Commands.swift) mostantól minden gyökér-objektumba
  beszúrja a `"schema_version": "1"` mezőt.
- **`--out PATH|-`** az `audit --suggest`, `cleanup --suggest` és
  `stacklist` parancsokon is (F10-c) — eddig csak `export`/`report`/
  `target-report` támogatta. `--out PATH` a könyvtáron kívülre is írhat
  (ugyanaz a "nem írhat a gyökérbe, csak a `.astro_tool/`-alapértelmezésen
  kívül" védelem, mint `export`-nál); `--out -` stdoutra írja a tartalmat
  fájl nélkül `audit`/`cleanup`-nál. `stacklist`-nél `--out -` NEM
  támogatott (egész könyvtárfát exportál, nem egy fájlt) — világos hibával
  leáll; `--out PATH` a stacklist-könyvtárat közvetlenül PATH-ra teszi (a
  szokásos `.astro_tool/stacklists/<cél>-<dátum>/` slug-almappa nélkül).
  Új `StackList.exportToDirectory` (AstroCore) végzi az exportot közvetlen
  `FileManager` hívásokkal, `WriteGuard` megkerülésével (ugyanaz a minta,
  mint `export --out PATH`-nál).
- **`scan --json` → `changed_targets`** (F10-d): a `ScanSummary` új
  `changed_targets` mezőt kapott — azon célpontok rendezett, deduplikált
  listája, ahol a futás során added/updated/missing fájl volt (bármely
  területről: sessions/stacks/processed). Pipeline-oknak szól ("mely
  célpontra fusson rate/audit ez után").
- **`config show` tiszteletben tartja a `--json`-t** (F10-e): eddig
  mindig JSON-t nyomtatott a `--json` kapcsolótól függetlenül. Mostantól
  alapból ember-olvasható, szekciónkénti kulcs-érték kimenetet ad
  (Gyökér/Kizárások/Szándékos minták/Wide-field/Kalibráció/Pontozás/
  Statisztika/Helyszín/Expozíció/Időjárás); `--json`-nal a korábbi teljes
  struktúra. A `config path` viselkedése változatlan.
- **Korrupt-FITS audit-szabály** (F20): új `CorruptFITSRule` — egy
  fits-kind fájl (`.fit`/`.fits`/`.fz` kiterjesztés, light/flat/dark/bias/
  master szerep), aminek nincs `fits_meta` sora, `sure_error` "corrupt-fits"
  találatot kap ("nem olvasható FITS-fejléc — sérült vagy csonka fájl
  lehet"). A Scanner eddig csendben elnyelte ezt az esetet (a fájl bekerült
  a `files`-be, de `fits_meta` sor nélkül) — ez a rés eddig nem volt
  sehol jelezve. Nem-FITS kiterjesztésű (CR3/TIF wide-field) lightokra nem
  szól, elkerülve a hamis pozitívokat.
- **Helyszín fül fülszintű reset**: a Beállítások ▸ Helyszín fül eddig volt
  az egyetlen az öt fül közül "Alaphelyzetbe állítás…" gomb nélkül — most
  a másik négy fül mintáját követi (megerősítő dialógus, majd a draft
  visszaáll automatikus módra, üres koordinátákra és kikapcsolt
  időjárás-előrejelzésre; "Mentés" kell a tényleges perzisztáláshoz).
- **wideField.overrides UI** (F20): a célpontonkénti kézi wide-field/deep-sky
  felülbírálás eddig csak a config.json kézi szerkesztésével volt elérhető.
  Új "Besorolás" menü (`WideFieldClassificationMenu`, SharedComponents.swift)
  az AllTargetsPage célpont-sorainak helyi menüjében és a TargetDetailPage
  fejlécében (a "wide-field" jelvény mellett) — Automatikus (felismerés) /
  Wide-field / Deep-sky, pipával a jelenlegin; a választás
  `AppState.setWideFieldOverride(target:value:)`-on át a meglévő
  WriteGuard-os config-mentési úton íródik, majd frissíti a `stats`-ot (a
  jelvény/besorolás azonnal látszik). A Beállítások ▸ Könyvtár-szabályok fül
  "Wide-field felismerés" szekciója új listát kapott a jelenlegi
  felülbírálásokról (célpont + wide-field/deep-sky felirat + törlés gomb) —
  csak áttekintés/törlés, új felvétel innen nem lehetséges.
- **Siril-segéd sheet** (F11(c)): új `SirilHelpSheet` — mi a Siril (ingyenes,
  nyílt forráskódú asztrofotó-feldolgozó), mire használja az app (FWHM/
  kerekség/csillagszám metrikák a pontozáshoz, blind plate-solve), "Siril
  letöltése…" gomb (siril.org megnyitása böngészőben), és egy táblázat, mi
  működik nélküle (natív háttér-/telítettség-pontozás: igen; FWHM/csillag-
  metrikák: nem; plate-solve: nem). Három belépési pont: a QualitySegment
  Siril-hiány figyelmeztetésének "Mi ez?" gombja; a Beállítások ▸ Pontozás &
  expozíció fül piros "Siril nem található" státusza melletti "Mi a Siril?"
  link; a menüsor Súgó csoportjának új "A Sirilről…" pontja (a Fogalomtár
  notification-mintáját követve, mivel a menüsornak nincs view-state-je).
- **Közös session-akció menü-builder**: `SessionActionMenu`
  (SharedComponents.swift) adja mostantól a teljes session-sor akciókészletet
  (Célpont megnyitása / Megnyitás Finderben / Kalibráció linkelése… /
  Stackelés előkészítése… / Keretek pontozása / Éjszaka-riport /
  Éjszaka-jegyzet szerkesztése… / Címke hozzáadása…/eltávolítása) — a
  NightsPage, az AllTargetsPage session-sorai és a SessionsSegment egyaránt
  ebből építi mind a látható "⋯" menüt, mind a jobbklikk-menüt, így a három
  felület akciókészlete nem tud többé széthúzni. A NightsPage-nek eddig se
  Kalibráció-linkelése, se Stackelés-előkészítése, se Keretek pontozása, se
  címke-akciója nem volt (a `NightRow`/`NightTableRow` új `tags` mezőt
  kapott ehhez); az AllTargetsPage session-sorainak eddig nem volt "Célpont
  megnyitása"; a SessionsSegmentnek eddig nem volt címke hozzáadás/eltávolítás.
- **TonightPage felhő-kontextus sáv**: ha az időjárás be van kapcsolva és a
  ma esti (Open-Meteo napi átlag) felhőzet 70% fölött van, a terv-tábla
  fölött egy elutasítható sáv jelenik meg ("Ma este ~N% felhő várható —
  nézd meg a következő derült éjszakát"), ami a Naptár szegmensre vált; az
  elutasítás munkamenet-szintű (`AppState.cloudBannerDismissed`, app-újraindításig).
- **"Következő lépés" kártya-kiemelés**: a TargetDetailPage fejlécének 3.
  sora mostantól halvány, a célpont fázis-színével tintelt kártya-hátteret
  kap, hogy az oldal cselekvésre hívó fókuszaként olvasható legyen.
- **Szűrő-dimenzió a UI-ban (R11-T5/F1)**: a core-ban már meglévő
  `FilterBreakdownQueries` mostantól látszik is — mono/szűrőkerekes és
  dual-band OSC felhasználóknak a "hány óra van meg szűrőnként" végre nem
  csak a `stats --filters` CLI-ból derül ki.
  - TargetDetailPage ▸ Áttekintés: új "Szűrők" kártya a Setup után (Szűrő |
    Usable keret | Integráció | Cél | Hiányzik, mini progress-sávval —
    narancs ha hiányos, cél nélkül sáv nélkül); a "(nincs szűrő-adat)"
    bucket külön, szürkén; tisztán szűrő nélküli (OSC/DSLR) célpontnál a
    kártya egyetlen diszkrét sorrá egyszerűsödik.
  - Fejléc "Valós integráció" tile: mono/szűrős célpontnál a caption a top 3
    szűrő-bontást mutatja ("Ha 8,2h · OIII 3,1h"); szűrőtlen anyagnál marad a
    "bruttó X" caption.
  - Integráció-halmozódás grafikon: mono/szűrős célpontnál session-önkénti
    kumulatív vonal szűrőnként színezve (Swift Charts
    `foregroundStyle(by:)`); szűrőtlen anyagnál az eredeti egyvonalas forma
    marad.
  - NightsPage "Szűrők" oszlop: felsorolás helyett óraszám-bontás ("Ha 1,5h
    · OIII 0,8h"), tooltipben a keretszámokkal (`NightRow.filterBreakdown`,
    additív mező — `FilterBreakdownQueries.breakdown(..., date:)` session-
    önkénti hívásából).
- **Szűrőnkénti célok (R11-T5/F2)**: `goal:<szűrő>=<óra>h` tag-konvenció
  (pl. `goal:Ha=12h`) a meglévő `goal:<óra>h` összcél mellett, egymástól
  függetlenül — mindkettő élhet ugyanazon a célponton (`GoalTag.
  parseFilterGoals`/`formatFilter`/`isFilterGoalTag`/`isOverallGoalTag`, core
  teszt kötelező). Új `FilterGoalQueries.merge`/`biggestDeficit` (core) fűzi
  össze a szűrőnkénti usable-integrációt a goal-tagekkel — ezt használja a
  "Szűrők" kártya, a fejléc-tile-ok és a CLI is, egy helyen.
  - GoalEditSheet: az összcél-stepper alatt "Szűrőnként" lenyitható szekció —
    a célpontnál ténylegesen előforduló (vagy csak megcélzott, de még nem
    lőtt) szűrők soronként óra-stepperrel, 0 = nincs cél = tag törlése.
  - Fejléc "Hiányzik" tile: szűrőnkénti célnál a caption a legnagyobb
    deficitet mutatja ("legtöbb hiány: SII 6,5h").
  - TonightPage "Hiányzik" cella: szűrőnkénti célnál kis chevron-gomb,
    kattintva popover a szűrőnkénti megvan/cél/hiányzik bontással — az
    oszlop értéke marad az összesített szám (`TargetPlan.filterGoals`,
    additív mező, `Planner.plan` csak azoknál a célpontoknál számolja ki,
    amiknek ténylegesen van szűrő-cél tagje, hogy a gyakori "nincs
    szűrő-cél" eset ne fizessen extra `FilterBreakdownQueries` lekérdezést).
  - CLI: `goal set/clear --target T --filter F [--hours H]` a szűrőnkénti tag
    írására/törlésére (az összcéltól függetlenül); új `goal list --target T
    [--json]` alparancs a szűrőnkénti megvan/cél/hiányzik bontáshoz; `stats
    --filters --json` (teljes célpontra, `--date` nélkül) is megkapja a
    szűrőnkénti cél/hiány mezőket, ha van (additív `goal_seconds`/
    `missing_seconds` mező a meglévő `FilterIntegration` JSON-sémán).
  - **Javítás**: `AppState.setGoal`/a CLI `goal set/clear` (összcél, `--filter`
    nélkül) eddig egy bare `hasPrefix("goal:")` szűrővel találta meg a
    törlendő régi taget — ez a szűrőnkénti `goal:F=Xh` tageket is törölte
    volna egy összcél-mentésnél. Mostantól `GoalTag.isOverallGoalTag`
    szűr, ami csak a saját (nem szűrő-scope-olt) taget találja meg.
- **Hold-tudatos szűrő-ajánlás (R11-T6/F3)**: új `plan.narrowbandFilters`
  config-kulcs (alapértelmezés: Ha, OIII, SII, L-eXtreme, L-Ultimate,
  L-Enhance, Dual-band) + új core `FilterAdvisor` (tiszta, DB-mentes):
  egy éjszaka Hold-állapotát (illumináció > 40% VAGY célponti szeparáció <
  60° → "keskenysáv-éjszaka", egyébként "sötét ég") veti össze a célpont
  szűrőnkénti céljaival (R11-T5/F2 `filterGoals`) — keskenysáv-éjszakán a
  legnagyobb deficitű keskenysáv-szűrőt, sötét égen a legnagyobb deficitű
  szélessáv-szűrőt ajánlja; szűrő-cél nélkül csak az általános címke marad.
  `TargetPlan` új `filterAdvice` mezőt kap (additív, `Planner.plan`
  tölti ki, `nil` ugyanott, ahol `moonSeparationDeg` is az).
  - TonightPage planTable új "Szűrő ma" oszlopa chippel ("Ha (-6,2h)" konkrét
    deficittel, vagy "Ha/SII" ha a kategóriának nincs kiugró hiánya) +
    tooltip az indoklással ("Hold 82%, szeparáció 41° — keskenysáv
    ajánlott"); szűrő-cél nélküli célpontnál a cella "-".
  - Naptár szegmens: az éjszaka-sorok Hold-oszlopa mellett kis "NB"/"sötét"
    címke (csak illumináció > 40% alapján, célponti szeparáció nélkül).
  - Verdikt-integráció: keskenysáv-éjszakán, kiugró NB-deficittel a "ma jó"
    verdikt "ma jó — Ha-ra"-ra bővül (helyes -ra/-re toldalékkal) — a
    `VerdictChip` zöld színezése `hasPrefix("ma jó")`-ra vált (eddig pontos
    egyezés volt), hogy ez a bővített verdikt is zöld maradjon.
- **Terv-export (R11-T6/F18a)**: TonightPage toolbar "Terv exportálása…"
  menüje — "Vágólapra" (célpont, RA/Dec óra/fok formátumban, láthatósági
  ablak, javasolt szűrő, tabulátorral tagolva) és "CSV-fájlba…"
  (`NSSavePanel`, oszlopok: target, ra_deg, dec_deg, window_start,
  window_end, max_alt_deg, moon_illum, verdict, filter_suggestion). A
  kijelölt sor megy, kijelölés nélkül a "ma jó" verdiktűek, ha az sincs,
  minden sor; sikeres exportnál toast. Új core `PlanExport` (tiszta
  string-renderelés) mindkét felületet + a CLI-t kiszolgálja. CLI:
  `plan --out PATH|-` ugyanazokkal az oszlopokkal (nem használható
  `--month`-tal együtt).
- **Kalibrációs bevásárlólista (R11-T6/F18b)**: TonightPage lap alján
  lenyitható "Kalibrációs teendők ma estére" (`DisclosureGroup`, badge a
  tétel-számmal, alapból csukva) — a hiányzó/elavult dark-kombók közül azok,
  amelyeket a ma esti (a Hold-tól függetlenül megfigyelhető, azaz "ma jó"
  vagy "Hold zavar" verdiktű) célpontok session-története ténylegesen
  használna, a meglévő `CalibNeed.todo` szöveggel + az érintett célpontok
  listájával ("…készíts 300 s / -10 °C darkot (5 light frame-hez) — M31,
  M42 használná") — darabszám sosem kitalálva. "Másolás Markdownként" gomb
  (`- [ ]` checklist a vágólapra). Üres állapot: "Minden szükséges
  kalibráció friss — nincs teendő ma estére." Új core `CalibShoppingList`
  (tiszta függvény, `CalibAnalyzer.coverage()` + `Planner.plan()` felett).
- **Kiugró-híd (R11-T7/F4)**: a gépi "Kiugró" z-score jelzés és a
  felhasználó "Saját döntés"-e eddig két néma, össze nem kötött rendszer
  volt. Új core `OutlierBreakdown` (`AstroCore/Rate/OutlierBreakdown.swift`)
  a keret metrikánkénti z-score-bontását adja vissza (session-csoport
  mediánja + oda-vissza orientált z minden metrikára), a `Rater`-ből
  kiemelt, mostantól közösen használt `RatingGroupMath` grouping/z-score
  logikára építve — így a popover "z = -2,4"-je garantáltan ugyanaz a
  számítás, ami a keret tényleges `score`/`isOutlier`-jét is adta. Az
  eredmény re-derive-olt lekérdezéskor (nincs séma-migráció): `FrameScore`
  új, additív `outlierBreakdown` mezőt kapott, amit `Rater.rate` és
  `Rater.cachedScores` is kitölt a saját végső listájára — ez a `rate
  --json` CLI-kimenetet is automatikusan bővíti metrikánkénti
  z-score-okkal, minden Commands.swift-módosítás nélkül.
  - Minőség-tábla "Kiugró" cellája kattintható ⚠️ gomb → popover
    metrikánkénti sorokkal ("FWHM 4.20 px — session-medián 2.90 px · z =
    -2.4", a legrosszabb metrika félkövér pirossal kiemelve) + egy
    valószínű-ok mondat (FWHM-domináns → fókuszcsúszás/szél/felhő;
    roundness → vezetési hiba/szél; starCount/background → felhő/párásodás)
    + "Átnézés" (a `FrameReviewSheet`-et erre az EGY keretre nyitja) és
    "Elvetés" gomb (közvetlen `user_verdict` reject-írás popover-bezárással).
  - "Kiugrók átnézése (N)" gomb a kontroll-sávban (csak N>0-nál) — a
    táblázat aktuális sorrendjében, csak a még saját döntés nélküli kiugró
    kereteket adja a `FrameReviewSheet`-nek; a sheet fejléce ekkor
    "Kiugrók: 3 / 7" formában jelzi a szűkített készletet (új
    `FrameReviewSheet.subsetLabel` paraméter).
  - "Összes kiugró elvetésre jelölése… (N)" gomb → megerősítő sheet
    (fájlnév + fő ok minden sorban, explicit "ez csak jelölés a
    stack-válogatáshoz — fájlt nem érint" szöveg) → megerősítésre minden
    még el nem bírált kiugróra `user_verdict` reject + záró toast.
  - Saját döntés cellában, ha a keret kiugró és nincs még döntés, halvány
    "javasolt: elvetés" felirat a "-" helyett; ugyanez a jelvény a
    `FrameReviewSheet` fejlécében a ⚠️ Kiugró jelvény mellett.
- **Audit kereszt-szegmens állapot-jelzés**: ha még sosem futott audit ebben
  a munkamenetben, a Hibák/Gyanús/Szándékos fejléc-csempék "0" helyett "n/a"
  értéket mutatnak "nincs audit" caption-nel (a Takarítható csempe
  változatlan — az független forrásból töltődik); a Takarítható szegmens
  tetején egy diszkrét info-sor jelenik meg ("Az audit még nem futott — a
  Hibák/Gyanús listához futtasd le.") inline "Audit futtatása" gombbal.
- **Audit-diff (R11-T8/F6)**: audit futás után az ELŐZŐ audit-run
  findings-ei és a mostani futás összevetése — új core `AuditDiff`
  (`AstroCore/Audit/AuditDiff.swift`, tiszta, DB-mentes függvény), a
  `FindingGrouper`-rel azonos `(severity, category, groupKey)` granularitáson
  hasonlít: minden csoport vagy ÚJ (csak a mostani futásban), MEGOLDÓDOTT
  (csak az előzőben) vagy VÁLTOZATLAN (mindkettőben). Az ack-állapot külön
  dimenzió marad — egy elfogadott csoport is simán "változatlan"-ként
  jelenik meg, ha még mindig előfordul. A DB-oldali "előző futás"-keresést
  új `Database.previousRunID(before:kind:)` adja (a `runID` elé eső
  legutóbbi futás azonosítója) — ugyanaz a hívás szolgálja ki friss
  audit-futás UTÁN (`AppState.runAudit`, `Commands.cmdAudit`) ÉS az
  alkalmazás újraindítás utáni visszaállítást (`AppState.openRoot`) is,
  szimmetrikusan. A `pruneFindings(keepRuns: 3)` (B20) miatt az előző futás
  findings-ei garantáltan megvannak, amíg csak 1 futás telt el azóta.
  - AuditPage: a szegmens-picker alatt összegző sor ("+3 új · 5
    megoldódott · 12 változatlan", 0 értékek elhagyva; a sor teljesen
    hiányzik, ha nincs előző futás). "ÚJ" kék kapszula-jelvény a Hibák/
    Gyanús/Szándékos csoportlista új csoportjainak fejlécén. Toolbar
    "Csak az újak" váltó — csak akkor látszik, ha van diff ÉS van benne
    legalább egy új csoport.
  - CLI: `audit --json` kimenete additív `diff` mezőt kap (`new_count`/
    `resolved_count`/`unchanged_count` + `new_groups` — az új csoportok
    `severity`/`category`/`group_key` kulcsai), csak ha volt előző
    audit-futás; emberi kimenet ugyanerről egy összegző sort ír
    ("diff (vs previous run): 3 new, 5 resolved, 12 unchanged"). A
    findings tömb továbbra is az eddigi `items` kulcs alatt van — teljesen
    visszafelé kompatibilis bővítés.
- **Tárhely-nézet (R11-T8/F19)**: célpontonkénti méret-összesítés area-
  bontással (sessions/stacks/processed/egyéb), méret szerint csökkenő —
  új core `StorageQueries`/`TargetStorage`/`StorageSummary`
  (`AstroCore/Stats/StorageQueries.swift`), tiszta lekérdezés a `files`
  táblából (`missing` fájlok kizárva, ugyanaz a konvenció, mint
  `CleanupReport`-nál). Wide-field/deep-sky besorolás itt nem számít.
  - AuditPage ▸ Takarítható szegmens: a meglévő cleanup-tartalom FÖLÉ új
    "Tárhely" `DisclosureGroup` (alapból nyitva, becsukható) — top 10
    célpont soronként (név, mini area-sáv + szöveges bontás, összméret),
    "Összes megjelenítése" lenyitással a többihez; soronként "⋯" menü:
    "Célpont megnyitása", "Megnyitás Finderben". Tisztán térkép — semmi
    törlés-akció. Független attól, futott-e már audit (ugyanúgy töltődik,
    mint a `cleanupSummary`).
  - CLI: `cleanup --json` kimenete additív `storage` mezőt kap (ugyanez az
    összesítés) — nem külön `storage` alparancs, mert az app ugyanabba a
    Takarítható szegmensbe teszi, a meglévő takarítási lista FÖLÉ, sosem
    önálló oldalként; a parancsstruktúra ezt 1:1 követi. A meglévő
    `groups`/`grand_total_bytes` mezők változatlanok.
- **"Előző éjszaka" reggeli triage-oldal (R11-T9/F5)**: az éjszaka utáni
  rutin szét volt szórva 4-5 oldalra — most egy helyen. Új core
  `ScanSummary.changedSessions` (`Scanner.swift`): a `changedTargets`
  (R11-T4) target-szintű bővítése SESSION-szintre — minden `(target, dátum)`
  pár, amihez EBBEN a futásban új/frissült LIGHT-fájl jött (szűrő/dark/bias
  változás, `stacks`/`processed`-terület vagy egy eltűnt fájl sosem számít
  bele — csak a valódi "friss anyag" jelentés), rendezett+deduplikált
  `SessionKey` lista, teszttel (négy új `ScannerTests` eset).
  - `AppState.freshSessionKeys`: a legutóbbi `runScan()` `changedSessions`-e,
    memóriában (session-only, ahogy a spec kéri — app-újraindítás után
    magától kiürül, amíg nincs új scan).
  - Feltételes sidebar-sor "Előző éjszaka" a Ma este/Naptár/Felfedezés
    szekció alján — CSAK akkor látszik, ha `freshSessionKeys` nem üres,
    jelvénnyel (friss session-szám); saját `Page.previousNight`, `⌘`-
    gyorsbillentyű nélkül (mint a Trendek majd később).
  - `PreviousNightPage` (új): session-kártyák (LazyVStack) célpont+dátum
    címsorral (kattintva a célpont Sessionök szegmensére visz), keretszám +
    integráció + szűrő-bontás (a meglévő T5 `TDFormat.filterBreakdownSummary`
    formázóval, ugyanaz, mint a NightsPage "Szűrők" oszlopa), medián FWHM″
    (px-fallback), Hűtés/Fókusz `VerdictChip` (`NightHealth.report`),
    kiugró-arány (`Rater.cachedScores` + `FrameScore.isOutlier`; pontozatlan
    sessionnél "még nincs pontozva"). Kártyánként "Pontozás", "Átnézés…"
    (`FrameReviewSheet`, saját `AppState.reviewFrameScores`/
    `loadReviewFrames` — nem a célpont-oldal `frameScores`-ét használja,
    hogy ne írja felül azt), "Éjszaka-riport" gomb. Felül "Új sessionök
    pontozása" — megerősítés NÉLKÜL lefuttatja a rate-et minden friss
    sessionre, a meglévő isBusy/progress/Mégse toolbar-infrastruktúrával.
    Üres állapot (nincs friss anyag): `ContentUnavailableView` +
    "Beolvasás" gomb.
  - Opt-in "Automatikus beolvasás kötet csatlakozásakor" (Settings ▸
    Könyvtár, alapból KI) — `AppState.autoScanOnMount`, `UserDefaults`-ban
    (nem `AstroConfig`-ban: ez app-viselkedés, nem könyvtár-szabály).
    Bekapcsolva: a meglévő mount-observer sikeres `retryRootAccess()`-e
    után, ha épp nem fut más művelet, automatikusan `runScan()`-t indít.
- **Trendek oldal (R11-T10/F7)**: hosszú távú, session-szintű idősorok
  célpontokon átívelve. Új core `TrendQueries.points` (`Sources/AstroCore/
  Stats/TrendQueries.swift`) — újrahasznosítja `NightsQueries.allNights`
  már kiszámolt session-metrikáit (medián FWHM″/px, háttér e⁻/s/″²,
  duty cycle), időrendi (legrégebbi elöl, a böngésző-nézettel ellentétes)
  sorrendbe rendezve, opcionális `setupFingerprint`/`from`/`to` szűréssel
  (`EquipmentProfile.dominant` per session); `TrendPoint.fwhmValue` adja
  vissza az ívmásodperc-értéket vagy — ha nincs képpont-skála — a
  px-fallbacket a jelző flaggel együtt. Tiszta `TrendMath.movingAverage`
  (5-pontos alapértelmezett ablak, hiányzó pontokat kihagyva, de a
  visszamaradó sorozatot meg nem szakítva) — teszttel.
  - **App**: új "Trendek" sidebar-sor az ÁLLAPOT szekcióban (Kalibráció/
    Audit/Takarítás után), `⌘`-gyorsbillentyű NÉLKÜL. `TrendsPage`:
    időtartomány-picker (6 hónap/1 év/3 év/Mind, segmented) azonnal
    látható; 3 Swift Charts idősor (medián FWHM″, háttér, hatékonyság%)
    pont + mozgóátlag-vonallal, a px-fallback FWHM-pontok üres karikával
    (a `Circle().stroke(...)` szimbólum) + jelmagyarázattal. Pontra
    kattintás (`chartOverlay` + legközelebbi pont keresés) a célpont
    Sessionök szegmensére navigál, a session előválasztásával (ugyanaz a
    `pendingTargetSegment`/`pendingSessionSelection` mechanizmus, mint az
    "Előző éjszaka" kártyáknál). Toolbar Menu mögött setup-fingerprint
    (a meglévő EquipmentProfile-kombinációkból) és célpont-típus
    (wide-field/deep-sky/mind, `TargetStats.isWideField`-ből) szűrő — a
    lap `AppState.trendPoints`-t UNFILTERED tölti be egyszer
    (`loadTrends()`), minden szűrés kliens-oldali (ugyanaz a minta, mint
    a NightsPage év/hónap Pickere). 5 session alatt a szűrt eredményben
    magyarázó `ContentUnavailableView` (szűrők törlésére felkínáló
    gombbal, ha aktív szűrő okozza).
  - **CLI**: `trends --metric fwhm|background|efficiency [--setup FP]
    [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]` — dátum+érték párok
    (a `fwhm` metrikánál `is_pixel_fallback` jelzővel), `schema_version`
    a közös `printJSON`-on át. Emberi kimenet egyszerű táblázat.
- **Szenzor-profil történet (R11-T10/F8)**: a `sensor_profile` tábla
  eddig csak a LEGFRISSEBB mérést tartotta kombónként, a korábbi mérések
  felülíródtak. Új séma-v10 migráció (additív, egy v9-es DB gond nélkül
  nyílik — teszttel): `ALTER TABLE sensor_profile ADD COLUMN
  estimator_version` (a meglévő sorokon `NULL` — sosem kitalált érték) +
  új append-only `sensor_profile_history` tábla (camera, gain, offset,
  bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain,
  measured_at, estimator_version), a migráció visszatölti a meglévő
  `sensor_profile` sorokat egy-egy history-bejegyzésként (`estimator_
  version = NULL`, ugyanaz az "ismeretlen, sosem kitalált" elv). Új
  `SensorProfiler.estimatorVersion` konstans (jelenleg 2 — a 2026-08-05-i
  leolvasásizaj-becslő javítás óta érvényes verzió); `SensorProfiler
  .measure` mostantól MINDEN mérésnél előbb a history-ba ír, utána
  upsertel a "legfrissebb" `sensor_profile` sorba, mindkettőt ugyanazzal
  a becslő-verzióval jelölve. Új `Database.insertSensorProfileHistory`/
  `sensorProfileHistory(camera:gain:offset:)` DAO — teszttel (migráció +
  insert + legfrissebb-nézet konzisztencia).
  - **Staleness általánosítás**: a `SensorPage` korábbi hardcode-olt
    2026-08-05 dátum-alapú "elavult mérés" jelzése helyett `SensorProfile
    Record.isEstimatorStale` (estimator_version < `SensorProfiler
    .estimatorVersion`, vagy ismeretlen = elavult) — a sárga
    figyelmeztető sáv szövege ennek megfelelően általánosodott.
  - **App**: `SensorPage` profil-táblázata `List` + `DisclosureGroup`-ra
    cserélődött (a `Table`-nek nincs soronkénti lenyitása) — soronként
    lenyitható a mérés-történet (dátum, leolvasási zaj, dark-ráta,
    becslő-verzió) + két mini sparkline (leolvasási zaj, dark-ráta
    időben, Swift Charts). A "Szenzor mérése…" megerősítő sheet szövege:
    "minden mérés bekerül a mérés-történetbe; a legfrissebb lesz az
    érvényes".
  - **CLI**: `sensor --history [--json]` — kombónkénti csoportosításban a
    teljes mérés-történet (nem kombinálható `--measure`-rel).
- **Stack-lista v2 — szűrő-tudatos válogatás + WBPP-barát export (R11-T11/
  F15)**: `StackList.select` mostantól a session usable lightjait a FITS
  `FILTER` fejléc szerint csoportosítva válogatja — a keepFraction (és az új
  opcionális `keepFractionPerFilter: [String: Double]` felülbírálás) és a
  "sosem kevesebb 3 keretnél, ha van elég" szabály is SZŰRŐNKÉNT érvényesül,
  hogy egy ritkább szűrő gyengébb keretei ne essenek ki aránytalanul egy
  nagyobb/jobb szűrő mellett. Egyetlen bucket esetén (egy mono szűrő, vagy
  szűrőtlen OSC/DSLR session) a viselkedés bájtra ugyanaz, mint korábban
  (`StackSelection.perFilter` `nil` marad — visszafele kompatibilis).
  - **Export-fa**: több szűrős anyagnál `lights/<SZŰRŐ>/` almappánként
    hardlink + saját `<cél>-<dátum>-<SZŰRŐ>.dssfilelist`/`.ssf` pár (a
    fejléc-komment jelzi a szűrőt) — PixInsight WBPP (és más batch
    preprocesszorok) a mappanévből ismerik fel a szűrőt. Szűrőtlen
    anyagnál a lapos `lights/`+`stack.dssfilelist`+`stack.ssf` szerkezet
    változatlan. Mindkét esetben új `manifest.csv` a stacklist-könyvtár
    gyökerében — MINDEN usable keret (kiválasztva ÉS elvetve is), oszlopok:
    file, filter, score, fwhm_px, session_date, verdict
    (`selected`/`rejected_verdict`/`rejected_outlier`/`rejected_keepfraction`)
    — WBPP-nek/utófeldolgozásnak szánt, angol nyelvű mező.
  - **App**: `StackListSheet` közös Megtartás%-csúszkája változatlan; több
    szűrős preview-nál "Ha 45/52 · OIII 28/40" szűrőnkénti darabszám-sor +
    "Szűrőnkénti finomhangolás" lenyitható szekció (csúszka szűrőnként,
    alapérték a közös érték — a közös csúszka mozgatása visszaállítja
    őket) + egy sor az Exportálás gomb alatt: mit ír és hová. Szűrőtlen/
    egy szűrős anyagnál a sheet nézete változatlan.
  - **CLI**: `stacklist --keep-filter "Ha=0.9,OIII=0.7"` (vesszős
    `filter=arány` lista) szűrőnként felülbírálja a `--keep`-et; a
    `--json` kimenet additív `per_filter` tömbje szűrőnkénti kiválasztva/
    összes bontást ad.
- **Kezdő-csomag — Fogalomtár-bővítés, mező-ⓘ-k, verdikt-indoklás,
  percentilis-sávok, Első lépések (R11-T12/F11+F12)**:
  - **Fogalomtár**: ~17 új szócikk (Bortle-skála, SQM, Seeing, Átlátszóság,
    Plate-solve, Master, Gain/Offset, ADU, EGAIN, Kulmináció,
    Sub-expozíció, Integráció bruttó/valós, Dither, Szűrő NB/BB,
    Setup-fingerprint, Szél, Páralecsapódás) — pont azok a fogalmak,
    amiket a session-jegyzet sablonja és a tervező számai már eddig is
    feltételeztek, de a Fogalomtárban nem szerepeltek. `GlossarySheet`
    kapott egy kereső mezőt (cím+szöveg) és egy opcionális horgony-
    paramétert (`anchor`) — a `.showGlossary` notification `object`-je
    mostantól egy konkrét szócikk nevét is hordozhatja, amire a sheet
    `ScrollViewReader`-rel azonnal odagörget; minden korábbi hívó
    változatlanul `nil`-lel postol (tetején nyílik).
  - **SessionNoteSheet mező-ⓘ-k**: a hat megfigyelési sablonmező (Bortle,
    SQM, Seeing, Átlátszóság, Szél, Páralecsapódás — a szabad szöveges
    "Megjegyzés" kivételével) mellé kis ⓘ gomb került: 1-2 mondatos
    magyarázat + értékskála + lábléc-link a Fogalomtár megfelelő
    szócikkére; a mezők placeholder-e mostantól példaértéket mutat
    ("pl. 5", "pl. 20.8", "pl. 3/5"…).
  - **VerdictChip → kattintható indoklás**: új közös
    `VerdictExplainPopover` (SharedComponents.swift) — kattintásra
    popover a számokkal (max. magasság, látható órák, Hold
    megvilágítottsága, Hold-szeparáció), a `TargetPlan`/`DiscoveryRow`
    már meglévő mezőiből. Bekötve a Ma este planTable Döntés oszlopába,
    az Áttekintés "Láthatóság ma este" kártyájába és a Felfedezés Döntés
    oszlopába; ahol egyetlen szám sem elérhető (pl. "nincs koordináta"),
    a chip sima marad, popover nélkül.
  - **Percentilis-színsávok**: új core `LibraryPercentiles.evaluate`
    (tiszta függvény, teszttel) — a könyvtár SAJÁT FWHM″/Hatékonyság
    eloszlásához méri egy session értékét, és zöld/sárga/narancs
    (legjobb/középső/leggyengébb harmad) sávba sorolja; 6 összehasonlítható
    session alatt nincs színezés. Bekötve a NightsPage FWHM″/Hatékonyság
    és a SessionsSegment FWHM″ celláiba, halvány pötty + help-tooltip
    formában ("A könyvtárad mediánja 3,1″ — ez a session a jobbik
    25%-ban"). A FWHM-eloszlás kizárólag az ívmásodperc-értékeket
    tartalmazza — egy px-fallback-only session sosem keveredik bele, és
    sosem kap pöttyöt sem.
  - **Első lépések checklist**: új `AppState.firstSteps` (6 tétel:
    Beolvasás/Audit/Helyszín/Siril/Pontozás/Szenzor-profil, mindegyikhez
    cím, egy mondatos "miért" és egy akció-gomb) + `FirstStepsChecklistView`/
    `FirstStepsSheet`. Megjelenik a FirstScanView sikeres beolvasás utáni
    eredmény-kártyája alatt, a Ma este lap tetején elutasítható (perzisztens,
    `AppState.firstStepsCardDismissed`) kártyaként amíg 4-nél kevesebb pipa
    van, és bármikor a Súgó menü "Első lépések…" pontjából. Core:
    `Database.hasAnyRating()` (teszttel) az "volt már pontozás?" tételhez.
- **Valódi Naptár/Takarítás route-ok + README↔jegyzet ütközés-jelzés
  (R11-T13/F13+F20)**:
  - **Sidebar-hierarchia**: a "Naptár" sor a "Ma este" alá, a "Takarítás"
    sor az "Audit" alá indentálva (bal-padding) — a sidebar mostantól
    tükrözi, hogy ezek nem önálló testvér-oldalak, hanem a `TonightPage`/
    `AuditPage` egy-egy szegmense. A ⌘-számozás (⌘1-⌘9) változatlan.
  - **Kétirányú page↔szegmens szinkron**: `AppState.tonightSegment`/
    `auditSegment` mostantól `currentPage`-ből SZÁRMAZTATOTT computed
    property (nem külön tárolt állapot) — korábban csak a szegmens-picker
    kattintása írta vissza `currentPage`-et, a FORDÍTOTT irány (sidebar-sor,
    ⌘-billentyű vagy a menüsor közvetlen `currentPage`-írása) nem
    szinkronizálta vissza a szegmenst, ami azt eredményezte, hogy pl. a
    "Ma este" sor helyesen kijelölődött, miközben a Naptár-szegmens
    tartalma maradt látszódóban. Egyetlen forrás (`currentPage`) — nincs
    külön state, nincs végtelen ciklus, nincs render-közbeni írás.
  - **Core**: új `NoteConflicts.detect(appNotes:readmeNotes:)` (tiszta
    függvény, teszttel) — kulcsonkénti ütközés-detektálás a session-jegyzet
    két forrása (`.astro_tool/notes/` és a README) között: ugyanaz a
    normalizált (case-insensitive) kulcs mindkét oldalon, eltérő trimmelt
    értékkel. `SessionDetail`/`NightRow` additív `hasConflict` mezőt kapott
    (mindkettő teszttel).
  - **SessionNoteSheet**: ütköző mezőnél sárga jelzés-sor a mező alatt —
    "eltér a README-től: `<readme-érték>`" + "README-érték átvétele" gomb
    (az app-jegyzet mezőbe másolja az értéket, a README-szekció
    változatlanul érinthetetlen marad).
  - **NotesSegment**: ütköző kulcs sorában sárga ⚠️ + tooltip mindkét
    értékkel.
  - **NightsPage**: a Jegyzet oszlop ✓-ja ütközés esetén sárga ⚠️-re vált
    ("az app-jegyzet és a README eltér" tooltippel).
  - **CLI**: `note show --target T --date D` jelzi az ütközést — human
    kimenetben "⚠ eltér a README-től" a sor végén, `--json`-ban additív
    `conflicts` blokk (a jegyzetek maguk változatlanul a gyökér-objektum
    lapos kulcsai maradnak, nincs törésre változó séma).
- **`astrotool verify` — fixity/bitrot-ellenőrzés (R11-T14/F9)**: a T4-ben
  fenntartott, addig használatlan **5**-ös kilépési kód mostantól ténylegesen
  ezt jelzi (lásd a `docs/cli.html` frissített táblázatát).
  - **Core**: új `FixityVerifier` (Sources/AstroCore/Audit/) — a `files`
    tábla nem-hiányzó, korábban `DuplicateFinder` által már lehash-elt
    fájljain újraszámolja a SHA-256-ot, és összeveti a tárolttal.
    `target`/`path`/`samplePercent` (opcionális, determinisztikus `seed`-del
    a tesztelhetőségért, SplitMix64 alapon) szűkíti a kört. Fájlonkénti
    eredmény: **ok** (egyezik), **content-changed** (méret ÉS módosítási idő
    is változatlan, mégis más hash — néma korrupció gyanús, `sure_error`
    finding), **modified** (méret ÉS módosítási idő is megváltozott —
    szándékos szerkesztés, nem bitrot, `probably_intentional` finding,
    informatív), vagy olvasási hiba. Vasszabály-megfelelés: KIZÁRÓLAG olvas
    — sosem ír vissza hash-t a `content_hash` mezőbe (ellentétben a
    `DuplicateFinder`-rel), és a findingekhez sosem generál javaslat-scriptet
    (egy korrupt fájlra nincs automatikus javítás, a finding-üzenet mondja
    ki: biztonsági mentésből való visszaállítás emberi döntés marad).
    Eredménye egy saját `"verify"`-kind runba íródik (`Database.
    pruneFindings` additív `kind` paramétert kapott, alapértelmezetten
    `"audit"`, hogy a T14 előtti hívók változatlanok maradjanak). Új
    `Database.countHashedFiles` (dedikált `COUNT(*)`, cél/útvonal-szűréssel)
    az app becslésének gyors forrása. Teszttel (ok/content-changed/modified/
    olvasási hiba/hash-visszaírás-tiltás/scope/minta/progress/perzisztencia).
  - **CLI**: `verify [--target T] [--path P] [--sample N (1-100)] [--json]`
    — human kimenet: összegző sor (ellenőrzött/ok/eltérés/módosult/hiba) +
    eltérés-lista; `--json` additív `summary` blokk a szokásos `items`
    találat-lista mellett. Exit 0 minden rendben (a "modified" is annak
    számít), **5** ha legalább egy `content-changed` eltérés van, 1 olvasási
    hibára vagy hibás `--sample`-re, 2 TCC/kötet-hibára. Teszttel
    (CLISmokeTests).
  - **App**: az Audit oldal "Audit futtatása" toolbar split-menüjében új
    "Integritás-ellenőrzés…" tétel — megerősítő sheet (mit csinál, durva
    időbecslés a fájlszám alapján, opcionális "Csak minta (10%)"
    jelölőnégyzet) a meglévő `beginOperation`/progress/"Mégse"
    infrastruktúrával indítva. Az eredmény a Hibák szegmensben jelenik meg
    saját `content-changed` kategóriával, a "modified" a Szándékos
    szegmensben; `AppState.lastVerifyRunID` (a `lastRunID` mellett) biztosítja,
    hogy a lap akkor is mutassa az eredményt, ha ebben a munkamenetben csak
    integritás-ellenőrzés futott, teljes audit nem. Záró toast: "Integritás:
    N fájl rendben, M eltérés".
- **Több helyszín — site-profilok (R11-T15/F16)**: eddig egyetlen (opcionális)
  lat/lon pár volt a Tervező helyszíne (`config.site`, vagy annak hiányában a
  könyvtár SITELAT/SITELONG mediánja) — mostantól **név szerint** több
  helyszín is konfigurálható, és a Tervező/Naptár/Felfedezés/session-böngésző
  mind tudja, melyik session melyik helyszínen készült.
  - **Core**: új `AstroConfig.sites: [SiteProfile]` (`name`/`latitudeDeg`/
    `longitudeDeg`/`isDefault`) a meglévő `site: SiteRule` mellett.
    VISSZAFELÉ KOMPATIBILIS: egy régi, csak `site`-ot kitöltő config.json
    egyelemű `sites` listává értelmeződik dekódoláskor ("Alapértelmezett"
    névvel, `isDefault: true`) — memóriában, a fájl NEM íródik át
    automatikusan; ha mindkét kulcs jelen van, az explicit `sites` az
    irányadó (nem összefésülve a `site`-tal); ha egyik sincs, a régi
    FITS-medián automatika változatlan. `SiteProfile.defaultSite(in:)`:
    az `isDefault` jelölésű, vagy — hiányában — az egyetlen/első elem.
    Új `SiteResolver` (tiszta függvény): egy session SITELAT/SITELONG
    mediánjához a legközelebbi konfigurált site-ot rendeli (haversine,
    50 km küszöb), felülbírálva a session-szintű `site:<név>` taggel (a
    meglévő session-tag rendszerrel, `GoalTag`-hez hasonló lezser
    parse-olással) — 50 km fölött vagy koordináta/tag nélkül nincs
    hozzárendelés. `Planner.resolveSite`/`plan`/`month` új opcionális
    `siteName` paramétert kapott: ha `config.sites` nem üres, az az
    irányadó (`siteName` egy konkrét nevet választ ki, hiánya az
    alapértelmezettet), ismeretlen névre `AstroError.invalidInput` a
    konfigurált nevek felsorolásával; üres `sites` esetén a régi
    `site`/FITS-medián útvonal fut, változatlanul. `NightsQueries.
    allNights` additív `NightRow.site` mezőt kapott (a session hozzárendelt
    site-neve, vagy `nil`). Teszt (config-dekódolás mind a 4 kombinációra,
    `SiteResolver` haversine/tag-felülbírálás/küszöb, `Planner`
    névszerinti/alapértelmezett/hiba-eset, `NightsQueries` hozzárendelés).
  - **CLI**: `plan --site <név>` (napi terv ÉS `--month`), `night-info
    --site <név>` — ismeretlen névre exit 1 a konfigurált nevek
    felsorolásával. `config show` új "Helyszínek (sites)" szekció
    (név, koordináta, `[alapértelmezett]` jelölés — ugyanaz a PRIVACY
    kivétel, mint a meglévő `site` szekciónál).
  - **App**: Settings ▸ Helyszín fül átalakítva — a mód-picker
    (Automatikus/Kézi) megmaradt, "Kézi" módban lista-szerkesztő (név +
    lat + lon soronként, csillag-jelölő az alapértelmezetthez, "+ Új
    helyszín", "Beillesztés a vágólapról" soronként, törlés); a T3-as
    fülszintű reset/dirty-jelzés az új listás formával is működik. Mentés:
    "Automatikus" módban `sites`+`site` is üresre ürül; "Kézi" módban
    `sites` írja a listát, `site` az alapértelmezett site koordinátáit
    tükrözi (hogy egy régebbi CLI-build is működjön ugyanazon a
    config.json-on). `TonightPage` tetején új helyszín-Picker a
    szegmens-picker mellett — CSAK akkor jelenik meg, ha 1-nél több site
    van konfigurálva; a választás perzisztens (`UserDefaults`,
    `AppState.selectedSiteName`) és a Ma este csempék/planTable, a Naptár
    és a Felfedezés mind az így kiválasztott site-ra számolnak (egy
    törölt/érvénytelen mentett választás csendben visszaesik az
    alapértelmezettre, sosem dob hibát a háttér-betöltésben). `NightsPage`
    opcionális "Helyszín" oszlop (csak 1-nél több site esetén, a 10-oszlopos
    `Table`-korlát alatt maradva egy külön nem-feltételes/feltételes
    oszloplista-párral, elkerülve a `TableColumnBuilder` feltételes ágának
    macOS 14.4+ korlátozását).
- **Kalibráció v2 — flat-lefedettség szűrőnként + AstroBin filter-ID
  leképezés (R11-T16/F17+F20)**: eddig `CalibAnalyzer` csak a
  dark-lefedettséget elemezte ("v1 scope") — a flat oldal a session-szintű
  `FlatDiscipline`-re (`CalibHealth`) korlátozódott, könyvtár-szintű
  áttekintés nélkül.
  - **Core**: új `CalibAnalyzer.flatCoverage` (két aláírással: a teljes
    könyvtárra `[CalibNeed]`-et ad vissza, `kind == .flat`, ÉS egyetlen
    session-re `[FlatFilterCoverage]`-t) — session lightok FILTER-e (+
    FOCALLEN-je, ha van) szerint csoportosítva, (a) a session saját
    `flats/` mappája (mindig "friss" a saját sessionjéhez, kor-ellenőrzés
    nélkül) és (b) a `calibration_library/flats/` készlete ellen
    illesztve (kor: `flatMaxAgeDays`, a light/flat DATE-OBS közti
    eltérés — nem "mostantól számítva", mint a darkoknál). FOCALLEN-eltérés
    (`> 2mm`, ugyanaz a tolerancia, mint `CalibHealth.flatMismatchReasons`)
    elutasítja a jelöltet, `mismatchReasons`-ban jelezve, nem hamis
    egyezésként. Szűrő nélküli (OSC/DSLR) lightoknál a szűrő-dimenzió
    kimarad az illesztésből, nincs hamis "(nincs szűrő)" zaj egy
    illeszkedő flatnál. `CalibNeed` új opcionális `filter` mezőt kapott
    (`nil` darkoknál). Szándékosan KÜLÖN függvény maradt (nem olvad a
    dark-only `coverage()`-be) — annak ~25 meglévő tesztje/hívója
    dark-only számot feltételez, és a session-saját-flat fallback a
    darkoknál nincs meg; az app (`AppState.loadCalibBundle`) és a CLI
    plain `calib` a kettőt konkatenálja megjelenítéshez. Új
    `SessionMatcher.SessionCalibration.flatsByFilter` ugyanezt a
    session-szintű API-t hívja. Teszt (mono több szűrős, OSC-zajmentesség,
    hiányzó, elavult library-flat, FOCALLEN-mismatch, a dark-only
    `coverage()` érintetlensége).
  - **App**: Kalibráció-oldal coverage-tábla új "Szűrő" oszloppal
    (darkoknál `TDFormat.missingCell`); a Teendők akciókártyák
    automatikusan megkapják a flat-hiány tételeket is (a meglévő
    todo+targets+"Linkelés…" minta, kind-független); a "Hiányzó" csempe
    captionje szétbontva ("3 dark · 2 flat"). TargetDetail Áttekintés
    kalibráció-kártyáján session-soronként szűrőnkénti flat-bontás
    ("flat: Ha ✓ · OIII —", egyetlen szűrő nélküli bucket esetén csupasz
    "flat: ✓"/"flat: —"). A Ma esti kalibrációs bevásárlólista
    (`CalibShoppingList`, R11-T6) automatikusan felveszi a flat-teendőket
    is, mivel a `calibNeeds` immár darkokat ÉS flatokat is tartalmaz.
  - **CLI**: `calib --flats` (csak a szűrőnkénti flat-lefedettség,
    `--json` additív); a sima `calib` humán-összegzés első sora mostantól
    "N teendő (M dark, K flat)" bontást ad.
  - **AstroBin filter-ID leképezés (F20)**: új `AstroConfig.astrobin.
    filterIds: [String: Int]` (üres alapértelmezett) — a szűrőnevet
    AstroBin equipment-adatbázis numerikus ID-jára fordítja. Az AstroBin
    CSV export `filter` oszlopa a leképezett ID-t írja (case-insensitive/
    trimmelt névillesztés), le nem képezett szűrőnél a név marad + a
    hiányt jelző figyelmeztetés (`AcquisitionExport.
    unmappedAstrobinFilters`): CLI-n `export --format astrobin` stderr
    warningje, appban egy toast az export után ("N szűrő nincs leképezve
    AstroBin ID-ra — Beállítások ▸ Könyvtár"). Settings ▸ Könyvtár fülön
    új "AstroBin export" szekció: kulcs-érték lista-szerkesztő (szűrőnév +
    numerikus ID + törlés, "+ sor"), link az AstroBin equipment-
    böngészőhöz, a meglévő fülszintű dirty/reset/mentés mintával. Teszt
    (mapped/unmapped/vegyes export-sorok, case-insensitive illesztés,
    config decode/round-trip).

### Changed

- **Mozaik-tábla előbbre**: a TargetDetail Áttekintés kártya-sorrendjében
  mozaik-célpontnál a MosaicPanelTable most a "Láthatóság ma este" kártya
  UTÁN következik (a "Ma esti ív", az Integráció-halmozódás és a Kalibráció
  elé kerülve) — mozaiknál a panel-lefedettség a projekt-státusz lényege.

- **Közös hiányzó-érték helper**: `TDFormat.missingCell`/`missingTile`
  konstansok + `TDFormat.cell(_:)`/`tile(_:)` segédfüggvények (Shared.swift)
  — minden app-view-beli literál `"-"`/`"n/a"` hiányzó-érték-előfordulás
  ezeken keresztül fut mostantól, egy helyen módosítható. A Minőség-tábla
  "Saját döntés" oszlopa eddig em dash-t ("—") mutatott döntetlen keretnél —
  ez is a táblacella-konvenció szerinti "-" lett.
- **Hűtés/Fókusz oszlop → VerdictChip**: a SessionsSegment Sessionök
  táblájában a Hűtés/Fókusz eddig csak színezett szöveg volt — mostantól a
  közös `VerdictChip` komponens jeleníti meg őket, egységes vizuális nyelvvel
  a többi verdikt-oszloppal (Ma este, Felfedezés). A `VerdictChip` szótára
  bővült a `NightHealth` hűtés/fókusz verdikt-szövegeivel ("stabil"/"stabil
  fókusz" → zöld, "nem tartja"/"gyanú" → narancs).
- **"⋯" akció-oszlop egységesen 28pt**: minden táblában (Ma este, Naptár,
  Minden célpont, Kalibráció, Felfedezés, Éjszakák, Sessionök, Minőség,
  Stackek) egy közös `actionColumnWidth` konstansra (SharedComponents.swift)
  áll a korábbi, mindenhol külön beírt 36pt helyett.
- **Minőség-tábla oszlop-választó + szűkített alapkészlet**: alapból csak
  Fájl, Pontszám, FWHM, Kiugró, Saját döntés (+ "⋯") látszik; Mappa,
  Kerekség, Csillagok, Háttér, Szat. %, Exp. elrejthető/visszakapcsolható
  a kontroll-sáv "Oszlopok" menüjéből (toggle-ök). A natív
  `.tableColumnCustomization(_:)` macOS 14.4+-ra van gátolva a SDK-ban, ez a
  csomag viszont macOS 14.0-t céloz (`Package.swift`) — a tábla ezért
  `if #available(macOS 14.4, *)` szerint vált a feltételes oszlopokat használó
  változat és egy fix, mindent-mutató (a korábbival pixel-egyező) változat
  között; a gyakorlatban ez a 14.0–14.3-as, mára elenyésző ablakot érinti
  csak, a beállítás `@AppStorage`-ban perzisztálódik.
- **Hibaszövegek "Mit tehetsz:" tanáccsal**: közös `errorAdvice(for:)`
  fordító (SharedComponents.swift) a gyakori `AstroError` esetekhez (Siril
  nem található, hozzáférés megtagadva, kötet nincs csatlakoztatva, írás
  tiltott, útvonal nem található, sérült FITS, adatbázis-hiba). Az
  `AppState` aktivitás-napló popoverjében a hibaüzenet alatt megjelenik a
  tanács is; a toast változatlanul csak az alap üzenetet mutatja, hogy ne
  duzzadjon.
- **Kalibráció fül tolerancia-captionök**: az `exposureToleranceS` sor
  caption-je most jelzi, hogy "0 = kikapcsolva — ilyenkor csak az arányos
  tolerancia (exposureToleranceFraction) él"; a `gainTolerance` caption-je
  skála-magyarázatot kapott ("a FITS GAIN fejléc egységében; 0 = pontos
  egyezés kell").

### Breaking (JSON-séma, `--json` kimenetek — T4)

`schema_version` bevezetése önmagában nem törő (a legtöbb parancsnál csak
egy új mező kerül a meglévő gyökér-objektumba). Ami **törő**: minden
parancs, aminek a `--json` gyökere eddig egy sima JSON TÖMB volt, mostantól
`{"schema_version": "1", "items": [...]}` objektumba van csomagolva — a
korábbi tömböt feldolgozó szkript mostantól a `.items` alatt találja a
listát. Érintett parancsok/módok:

- `audit --json` (a találat-lista)
- `rate --json`
- `stats --json` (célpont nélkül), `stats --target T --sessions --json`,
  `stats --target T --timeline --json`, `stats --target T --filters --json`
  — a `stats --target T` (bontás nélküli, egy célpontra szűkített) mód
  gyökere továbbra is objektum, ÉRINTETLEN
- `quality --json`
- `nights --json`
- `calib --json` (lefedettségi mód — a `calib --health --json` gyökere
  objektum, ÉRINTETLEN)
- `tag list --json` (mindkét mód: `--target`-tel szűkítve és listázva is)
- `ack list --json`
- `search <query> --json` (a `--all` NÉLKÜLI mód — `search <query> --all
  --json` gyökere objektum, ÉRINTETLEN)
- `plan --json` és `plan --month --json`
- `health --json`
- `projects --json`
- `sensor --json`
- `expose --json` (célpont nélkül — `expose --target T --json` gyökere
  objektum, ÉRINTETLEN)
- `stacks --json` és `stacks --json --grouped`

### Fixed

- **Állapot-versenyek az AppState-ben (R12-U1)**: a helyszín-váltó, a
  beolvasás, az "Előző éjszaka" átnézés-visszaírás és a Trendek-cache négy
  külön versenyhelyzetet okozott.
  - **Site-váltó**: a `TonightPage` helyszín-Picker-e és a
    `LocationSettingsView` mentése eddig `loadPlan()`/`loadMonthPlan()`/
    `loadDiscovery()`/`loadWeather()`-t hívta egymás után `await` nélkül —
    mindegyik saját `beginOperation`-je lemondta az előzőt, így a terv a
    régi helyszínen ragadt (a `loadWeather()` is a RÉGI koordinátát kérte le,
    mire a `resolvedSite` frissült volna). Új, összevont
    `AppState.loadSiteScopedData(date:)` EGY háttérműveletben számolja a
    terv/éjszaka-infó/felbontott helyszín (+ feltételesen a havi terv és a
    Felfedezés, ha már be voltak töltve) hármasát, az időjárás-lekérést csak
    ez után indítva.
  - **Beolvasás-védelem**: egy másik, olvasás-jellegű háttérművelet indítása
    (pl. lapváltás) a beolvasás futása közben eddig lemondhatta a beolvasás
    saját `Task`-ját, és az összegzés (`scanSummary`/`lastScanDate`/
    `freshSessionKeys` + az azt követő statisztika/kalibráció-frissítés)
    némán elveszett. A beolvasás mostantól saját, a többi művelettől
    független `Task`-slotban fut.
  - **"Előző éjszaka" átnézés visszaírása**: az Átnézés-sheet gyors
    zárás+újranyitása mellett egy korábbi session lassú betöltése
    rácsúszhatott az újonnan nyitott sheetre (rossz keretek/pontszámok
    jelentek volna meg alatta); most cél+dátum egyezés-ellenőrzés védi a
    visszaírást, és a sheet bezárása lemondja a folyamatban lévő betöltést.
    A visszaírás emellett többé nem cserélte le teljesen a megosztott
    `frameVerdicts` szótárat egyetlen session részhalmazára (ami más
    célpontok gyorsítótárazott döntéseit némán törölte) — saját
    `reviewFrameVerdicts` szótárat kapott.
  - **Nem-observált beállítások**: `firstStepsCardDismissed`,
    `autoScanOnMount`, `selectedSiteName` eddig `UserDefaults`-ba író/olvasó
    számított property-k voltak, amiket az `@Observable` nem követett — egy
    változtatásuk nem feltétlenül frissítette azonnal az őket olvasó
    nézeteket. Mostantól tárolt property-k `didSet`-es visszaírással.
  - **`effectiveSiteName`**: mostantól kis-nagybetű-független
    összehasonlítással azonosítja a kiválasztott helyszínt (ugyanaz a
    szabály, mint amit a `Planner` már használ) — egy eltérő
    kis-nagybetűzéssel elmentett választás korábban némán "nincs
    kiválasztva"-ként viselkedett.
- **Trendek-frissesség**: a beolvasás és bármelyik pontozás-művelet után a
  `trendPoints` gyorsítótár érvényteleníti magát, hogy a Trendek oldal
  legközelebbi megnyitásakor ne mutasson elavult session-metrikákat a friss
  mérések mellett. Ehhez kapcsolódóan: a Trendek oldal eszköztára "Frissítés"
  gombot kapott betöltött állapotban; az Éjszakák/Sessionök/Minden célpont
  sor-menükben új "Megnyitás a Trendeken" akció a session saját
  setup-leírójára előszűrve nyit a Trendekre; a Felfedezés és a Naptár
  szegmens fejlécében diszkrét "Helyszín: <név>" jelvény jelenik meg, ha
  egynél több helyszín van konfigurálva.
- **Stacklist/export javítások (R12-U2)**: hét kisebb, egymástól független
  hiba a `stacklist` exportban és a DSS-import ágban, mind a valós
  workflow-újranézés találatai.
  - **EXDEV copy-fallback**: `stacklist --out PATH` másik kötetre hardlinkelt
    volna (`FileManager.linkItem` ilyenkor kötethatáron mindig elhasal) —
    most egy cross-device (`EXDEV`) hiba esetén az érintett keret másolással
    kerül a célba, a kimenet jelzi ("hardlink helyett másolat készült —
    másik kötet"). A könyvtáron BELÜLI export (`.astro_tool/stacklists`)
    változatlanul tisztán hardlink, mivel az sosem lép kötethatárt.
  - **Re-export szinkron**: újra-exportáláskor a cél `lights/` fa mostantól
    szinkronba kerül a friss kiválasztással — a kiválasztásban már nem
    szereplő korábbi hardlinkek eltűnnek (szigorú útvonal-guarddal,
    kizárólag a tool saját stacklist-fáján belül, szimlinket/mappát sosem
    érintve), a kimenet jelzi ("N elavult link eltávolítva"). Ez egy
    szigorodó `--keep` utáni felesleges linket éppúgy eltakarít, mint egy
    flat→per-filter átmenet stale lapos `lights/*.fit` maradékát.
  - **`--keep-filter` normalizálás**: a szűrőnév-egyeztetés mostantól
    kis-nagybetű-független (a `CalibAnalyzer`/`FilterGoalQueries` mintája);
    a session-ben nem létező szűrőnévre stderr-figyelmeztetés (nem hiba); a
    "(nincs szűrő-adat)" bucket CLI-alul íráshoz `none=<érték>` alias.
  - **Slug/név ütközés-védelem**: üres filter-slug (pl. csupa szimbólumból
    álló szűrőnév) "filter_1", "filter_2"… névre esik vissza; két szűrő
    azonos sanitizált slugjánál számozott utótag (`Ha`, `Ha_2`…); egy
    bucketen belüli azonos fájlnévnél (pl. két különböző session-almappa
    saját `img_0001.fit`-je) a második eddig csendben kimaradt a linkelésből
    — most megkülönböztető utótagot kap (`part2__img_0001.fit`), a
    `.dssfilelist`/`manifest.csv` a tényleges linknevet írja.
  - **`StackListSheet`**: a cél-felirat a valós (`Sanitizer`-slugolt)
    exportútvonalat mutatja + a `.ssf`-et is megemlíti (eddig csak a
    `.dssfilelist`-et); a Minőség szegmens kontroll-sávjában új "Stackelés
    előkészítése…" gomb (a kiválasztott session-nel nyit, "Minden
    session"-nél session-választó menüvel, a Stackek szegmens mintájára).
  - **`manifest.csv`**: első sora mostantól `# library_root: <abszolút út>`
    komment — a fájl `file` oszlopa gyökér-relatív, e nélkül egy külön
    átvitt manifest önmagában nem lenne feloldható.
  - **DSS-ingest guard**: a `.dssfilelist`→`user_verdicts` ág eddig egy
    ellentmondó bulk-importnál felülírhatta egy `source == "app"` (a
    felhasználó által EZEN belül az appban rögzített) döntést — mostantól
    ez az ág sosem írja felül, ugyanaz a védelmi minta, mint amit az
    `info.txt`-ág egy valódi astrotool/Siril-pontszámnál már alkalmazott.

## [0.12.0] - 2026-08-06

Az R10-es kör felülvizsgálati menete: egy teljes kód-review (nem talált
funkcionális hibát) + egy 23 tételes UX-konzisztencia-sweep, minden
találat javítva, plusz a valós könyvtáron futtatott end-to-end CLI-teszt
két lelete.

### Fixed

- **`astrotool nights` név-oszlop**: hosszú mappanévnél a megjelenítendő
  nevet csonkolta 1 betűre a nyers mappanév javára ("N… (NGC_7000_…)") —
  mostantól az emberi név az elsődleges, a nyers név marad el, ha nem fér.
- **Elveszett művelet-visszajelzések**: a "Plate-solve minden koordináta
  nélküli célpontra…" (és az egy-célpontos párja) `endOperation`-je a
  frissítő `loadDashboardData()` MÖGÖTT futott, így a művelet-azonosító
  átíródott és se toast, se tevékenység-napló bejegyzés nem született; a
  Beolvasás "Kész — új/frissült/hiányzó" összegzése pedig sosem ért el a
  felhasználóig. Mindhárom javítva (sorrend + toast-címek).
- **Menüsor-műveletek futó munka alatt**: a menüsorból indított Beolvasás/
  pontozás/plate-solve/szenzor-mérés/tanácsadó nem volt letiltva `isBusy`
  alatt, így csendben megszakíthatta a futó scant — mostantól a toolbar-beli
  párjukkal azonosan tiltódnak.
- **Minőség-tábla interakciók**: a keret-tábla jobbklikk-menüje csak a
  fájlnév-cella fölött működött (a régi R9-D11 hiba mintája) — mostantól
  sor-szintű a kijelölés, a context-menü és a dupla-katt (megnyitás).
- **Időjárás-hiba szennyezése**: egy elbukott Open-Meteo-hívás piros
  `lastError`-sávot húzott a Ma este/Éjszakák/Felfedezés oldalakra — már
  csak a Felhőzet-tile + egy hiba-toast jelzi.
- **Éjszakák FWHM-oszlop**: arcsec-pixelskála nélkül "-" helyett mostantól
  a pixel-alapú érték jelenik meg " px" jelöléssel (a `NightRow` új
  `medianFWHMPixels` mezője + teszt), a Sessionök-tábla konvenciója szerint.

### Changed

- **⌘-gyorsbillentyűk a sidebar sorrendjében**: Ma este ⌘1 · Naptár ⌘2 ·
  Felfedezés ⌘3 · Minden célpont ⌘4 · Éjszakák ⌘5 · Kalibráció ⌘6 ·
  Audit ⌘7 · Takarítás ⌘8 · Szenzor ⌘9; új "Keresés" tétel a Nézet menüben,
  a ⌘F átnevezve "Kereső fókuszálása"-ra.
- **Terminológia-egységesítés az összes felületen**: "Célpont megnyitása" /
  "Megnyitás Finderben" / "Nagy előnézet" / "Frissítés" mindenhol azonosan;
  a verdikt-chip egyetlen közös komponens (a célpont Áttekintésen is színes
  már); a hiányzó érték táblacellában "-", tile-ban "n/a"; az időtartamok
  kanonikus h:mm formában; a Minőség-tábla FWHM-oszlopa jelzi a pixelt.
- **Zsákutcák felszámolása**: a Naptár is kapott ⋯ művelet-gombot; a
  kikapcsolt időjárásnál a "Felhő" oszlop kattintható "ki" linkké vált; a
  no-site chart-üzenetek "Beállítás…" gombot kaptak; az FWHM-trend
  eltűnése helyett magyarázó sor; a Fogalomtár az R10-es fogalmakkal bővült
  (Hatékonyság, FOV-illeszkedés, Saját döntés, Felhőzet-előrejelzés);
  a Beállítások "Mentve." és "Nem mentett módosítások" jelzése többé nem
  látszik egyszerre.

### Removed

- `PLAN-R10.md` — a kör lezárult, minden tétele leszállítva és a
  CHANGELOG-ban dokumentálva.

## [0.11.0] - 2026-08-06

Az R10-es kör lezárása — a 0.10.0-ból kimaradt két utolsó tétel.

### Added

- **Felfedezés oldal** (R10-B4): új "Felfedezés" sidebar-sor (⌘9) a beágyazott
  217 objektumos katalógus fölé — mi áll ma este jól, ami még nincs a
  könyvtárban ("már gyűjtöd" elrejtés-kapcsolóval), típus-szűrővel,
  FOV-illeszkedés verdikttel a domináns setuphoz (új
  `FieldGeometry.dominantFOV` helper + 7 teszt), sortolható táblával,
  sor-műveletekkel ("Ma esti ív" chart-sheet, "Új session létrehozása…" a
  katalógus-designációval előtöltve — a `NewSessionSheet` új
  `prefillDesignation` paramétere).
- **Kézreállóság-csomag** (R10-B7): látható "⋯" művelet-gomb mind a 8 fő
  tábla soraiban (pontosan a jobbklikk-menük tartalmával, közös
  builder-ből); fázis-jelmagyarázat a sidebar KÖNYVTÁR szekciója alján; a
  6 párhuzamos tile-implementáció és a duplikált fázis-chip helperek
  egységesítése (`Views/SharedComponents.swift`); egységes cél-szerkesztő
  (a `GoalEditSheet` saját fájlba került, a célpont-fejléc popovere is ezt
  nyitja); "Fogalomtár…" link a ⓘ metrika-popoverek aljáról
  (`InfoHeader.swift` → `MetricInfoButton.swift` átnevezés); Settings:
  "Nem mentett módosítások" jelzés mind az 5 fülön + numerikus %-mezők a
  pontozási súly-csúszkák mellett.

## [0.10.0] - 2026-08-06

Az R10-es kör ("a vizuális kör") első kiadása — a teljes terv a repó
`PLAN-R10.md` fájljában; a hátralévő két tétel (Felfedezés-oldal,
kézreállóság-csomag) a következő kiadásban érkezik.

### Added

- **FITS-előnézetek + Keret-átnéző kézi döntésekkel** (R10-A1/B1): új
  `Sources/AstroCore/FITS/FITSImageRenderer.swift` (FITS → CGImage —
  BZERO-tudatos 8/16-bites kiolvasás, szuperpixel-debayer RGGB/BGGR/GRBG/
  GBRG-re, Siril-stílusú MTF-autostretch; `.fz`-re őszinte `nil`). A
  Minőség/Stackek táblák thumbnail-oszlopa mostantól FITS-re is él
  (`ThumbnailCell` fallback), és új `Views/FrameReviewSheet.swift` —
  "Átnézés…" blink-lapozó nagy előnézettel (←/→, A=elfogad, X=elvet,
  U=visszavon), a döntés a `user_verdicts` táblába íródik (`source="app"`),
  amit a `stacklist` kiválasztása már eddig is tiszteletben tartott. Új
  "Saját döntés" oszlop + kontextmenü-műveletek a Minőség szegmensben.
- **Magasság-görbe (éjszakai ív) chart** (R10-A2/B2): új
  `Sources/AstroCore/Sky/SkyTrack.swift` (`altitudeTrack`/`moonAltitudeTrack`/
  `nightWindowMarkers`, tisztán számolt, DB-mentes API-k; `SunMoon.dualTwilight`
  egy sweepből adja a −18°/−12° határokat) + új `Views/SkyChartView.swift`
  (Swift Charts: célpont-ív, szaggatott Hold-ív, asztro/nautikus
  szürkület-sávok, min-magasság vonal, "most" jelölő). Megjelenik a Ma este
  terv-tábla sor-kijelölésére és a Célpont-részletek Áttekintés "Ma esti ív"
  kártyáján.
- **Éjszakák oldal + `astrotool nights`** (R10-A3/B3): új
  `Sources/AstroCore/Stats/NightsQueries.swift` — minden session egy
  cross-target listában (FWHM″, háttér e⁻/s/″², hatékonyság%, jegyzet-jelzés),
  CLI `nights [--year N --month M] [--json]` alparanccsal. Az appban új
  "Éjszakák" sidebar-oldal (⌘4; a Kalibráció/Audit/Takarítás/Szenzor ⌘5–8-ra
  csúszott) év/hónap szűrővel, session-megnyitással, éjszaka-riport/jegyzet
  műveletekkel.
- **Beágyazott célpont-katalógus + Felfedezés-tervező API** (R10-A4): új
  `Sources/AstroCore/Sky/TargetCatalog.swift` — 217 ellenőrzött mélyég-objektum
  (a teljes Messier 110 + 85 NGC + 15 IC + 7 Sh2, J2000 koordináták, típus,
  méret, magnitúdó, magyar nevek a `CatalogNames`-szel összhangban) — és
  `DiscoveryPlanner.discover(...)` ("mit fotózzak ma este, ami még nincs meg?"
  + FOV-illesztés), a `Planner`-ből kiemelt közös `NightSweep` sweep-motorra
  építve. Az app-oldali "Felfedezés" felület a következő kiadásban jön.
- **Toast-visszajelzés + IA-javítások** (R10-A5): új `Views/ToastOverlay.swift`
  — minden háttérművelet hibája (és a fájlt termelő műveletek sikere) jobb
  felső értesítés-kapszulaként jelenik meg, az eddigi inline `lastError` és a
  tevékenység-napló mellett. Az Audit oldal 4. "Szándékos" szegmenst kapott
  (eddig zsákutca-szám volt); a Kereső saját sidebar-sort kap aktív keresésnél;
  a Naptár "Legjobb 3 célpont" nevei kattinthatók; a Minőség szegmens
  dátum-szűrője ténylegesen szűri a táblát/hisztogramot; a Takarítás oldal
  audit-futtatás nélkül is mutatja a betöltött takarítási adatot. Javítva
  emellett egy valós race a `runIngestDSS` és a statisztika-újratöltés között.
- **Trend-grafikonok** (R10-B5): "Integráció-halmozódás" kártya az Áttekintésen
  (kumulatív órák session-enként, cél-vonallal) és "FWHM az éjszaka folyamán"
  pont-chart a Minőség szegmensben (kiugrók pirossal, a `NightHealth`
  fókusz-regressziós egyenesével, kizárólag egységhelyes px/h esetben). A
  `FrameScore` új `dateObs` mezőt kapott (mindkét pontozási útvonalon).
- **Opt-in felhőzet-előrejelzés** (R10-B6): új app-rétegbeli
  `WeatherService.swift` (Open-Meteo, kulcs nélkül, 2 tizedesre kerekített
  koordináta, 60 perces cache, 10 s timeout) — alapból KIKAPCSOLVA, a
  Settings ▸ Helyszín fülön kapcsolható, adatvédelmi magyarázattal. Ma este
  oldal: 5. "Felhőzet" tile (szürkület→hajnal), Naptár: színkódolt "Felhő"
  oszlop a 7 napos horizonton belül. Új `weather` config-kulcs (a régi
  configok változatlanul érvényesek); az AstroCore-ba továbbra sem került
  hálózati kód.
- **Per-szűrő integráció + CLI-paritás** (R10-B8): új
  `Sources/AstroCore/Stats/FilterBreakdown.swift` + `stats --target X
  --filters [--date D]` (LRGB/SHO bontás a dedupolt usable keretekből). Új
  alparancsok az eddig app-only képességekhez: `ack list|add|remove`
  (rendben-jelölés), `note show|set` (éjszaka-jegyzet — a README-t sosem
  írja), `goal set|clear` (cél-tag, az app-pal bájtra azonos formátum),
  `search <q> --all` (globális kereső: célpont/session/fájl/jegyzet),
  `night-info` (sötét órák + Hold). A `docs/cli.html` referencia bővült
  mindezekkel (+ a `nights` bejegyzéssel).

### Changed

- A CLI `--version` és az app `Info.plist` verziója mostantól követi a
  kiadást (eddig 0.1.0-n ragadt).
- Tesztszvit: 847 → 945 teszt (98 új), mind zöld.

## [0.9.0] - 2026-08-05

### Added

- **Globális keresés + éjszaka-jegyzet-szerkesztő + thumbnailek/Quick Look +
  batch műveletek + in-app súgó** (R9-T6/B3/B4/B7/B14/B16): `Database.
  searchAll(query:limit:)` négy szekcióval (célpontok/sessionök/fájlok/
  jegyzetek), `Views/SearchResultsPage.swift` valódi tartalommal, a sidebar
  ⌘F/Enter mostantól a teljes könyvtárban keres, nem csak a célpont-listát
  szűri. `Sources/AstroCore/Scan/SessionNoteStore.swift`: session-enkénti
  éjszaka-jegyzetek (Bortle/SQM/Seeing/…) `.astro_tool/notes/`-ba írva --
  a README.txt SOSEM íródik, a két forrás olvasáskor merge-ölődik (README
  nyer) `SessionStatsQueries`-ben, ezért az AstroBin-export és a `search`
  parancs is látja az itt mentett jegyzeteket. `Views/SessionNoteSheet.swift`
  a szerkesztő UI, elérhető a session context-menükből és a Jegyzetek
  szegmensből. `Views/ThumbnailCell.swift` (`QLThumbnailGenerator`) + `Views/
  QuickLookController.swift` (`QLPreviewPanel`) -- thumbnail-oszlop a
  Stackek/Minőség táblákban, "Nagy előnézet"/"Quick Look" a Space-billentyű
  dokumentált fallbackja. A Műveletek menü (toolbar + menüsor) mostantól
  éles: "Minden célpont pontozása…" (confirm-sheet + soros futás,
  `Views/BatchActionSheets.swift`), "Expozíció-tanácsadó minden célpontra…"
  (eredmény-tábla), "Plate-solve minden koordináta nélküli célpontra…",
  "Szenzor mérése…", "DSS-döntések importálása". `Views/InfoHeader.swift`
  (`MetricInfoButton`) egy ⓘ-gomb táblánként a számított metrikák
  magyarázatával ("mikor hazudik" jegyzettel) -- a `TableColumn`-nak nincs
  custom-header-view inicializere ezen az SDK-n, ez a dokumentált,
  leverifikált alternatíva. `Views/GlossarySheet.swift` -- `Súgó ▸
  Fogalomtár` (FWHM, kerekség, z-score, e⁻/s/″², airmass, karantén,
  hardlink, bias/dark/flat).

- **Kalibráció-oldal polírozása + Szenzor-oldal + teljes Settings-szerkesztő**
  (R9-T5/B12): `Views/CalibrationPage.swift` (a régi `CalibrationView`
  felváltása) `Picker(.segmented)`-tel (Lefedettség/Egészség) + 4 tile
  (Hiányzó/Elavult/Friss/Master darkok). Lefedettség: a Teendők felülre
  kerültek akció-kártyaként ("Linkelés…" gombbal, ahol egy session
  azonosítható -- új `AppState.openCalibLinkSheet(forNeed:)` pragmatikusan a
  `CalibNeed` első targetjének legutóbbi session-dátumára oldja fel), a
  tábla 3 új kolonnát kapott a modellből, ami eddig sosem volt megjelenítve:
  `Típus` (`CalibNeed.kind`), `Gain` (`requiredGain`), `Kamera`
  (`requiredCamera`); sor context-menü (Kalibráció linkelése… / Master
  mappa megnyitása Finderben / Érintett sessionök megjelenítése). Egészség:
  a három `DisclosureGroup` fejléce státusz-bontást kapott ("Flat-fegyelem
  — 2 hibás / 34 rendben"), minden problémás sor "Megnyitás Finderben"
  context-menüt kapott. Egyetlen "Újraszámolás" a toolbaron a régi három
  azonos "Frissítés" helyett.
  `Views/SensorPage.swift` teljes átépítése: 3 tile (Profilok/Kamerák/
  Legutóbbi mérés), új `Mért` kolonna + frissesség-figyelmeztetés (sárga
  sor + "Újramérés javasolt…") minden `measuredAt`-nál a leolvasási-zaj-
  becslő javítása (2026-08-05, commit `0928189`) előtt mért profilra,
  primary toolbar "Szenzor mérése…" → confirm-sheet (mit olvas, mennyi
  ideig tart, "csak egy adatbázis-sort ír, a könyvtárhoz nem nyúl"),
  állandó "mire jó?" magyarázó blokk, `ContentUnavailableView` empty state.
  **Teljes config-szerkesztő (B12)**: `Views/SettingsWindow.swift` mostantól
  5 fület mutat; új `Views/Settings/` alkönyvtár -- `LibrarySettingsView.swift`
  (a régi `SettingsView` helyén, `excludedDirNames`/`excludedPaths` mostantól
  szerkeszthető +/− lista, nem vesszős string), `LocationSettingsView.swift`
  (T4, áthelyezve, tartalom változatlan), új `CalibrationSettingsView.swift`
  (mind a 8 `CalibRule` szám + a 4 `match*` toggle), új
  `RatingSettingsView.swift` (`outlierZScore`/`workers`/`sirilPath` +
  `Tallózás…` + élő zöld/piros Siril-verzió-indikátor, a 4 `rating.weights`
  csúszkaként MINDIG 1,00-ra normalizálva, `expose.*`), új
  `LibraryRulesSettingsView.swift` (`residuePatterns`/`residueDirNames`/
  `toolOutputDirNames`/`intentional.labels`+2 toggle/`wideField.*`/
  `stats.*`), és egy megosztott `SettingsShared.swift`
  (`SettingsResetRow` -- a generikus per-kulcs `↺` reset, csak ha az érték
  eltér az `AstroConfig()` defaulttól -- és `EditableStringListView`).
  Minden fülnek van "Alaphelyzetbe állítás…" (megerősítéssel) + "Mentés"
  láblábja. AstroCore-t ez a task nem módosította (all UI). 820 teszt zöld
  (változatlan).

- **Ma este + Naptár oldal, helyszín-beállítás** (R9-T4): új `Views/TonightPage.swift`
  egy `Picker(.segmented)`-tel ("Ma este" | "Következő 30 éjszaka") felváltja
  a törölt `OverviewView`-t ÉS a törölt `CalendarPage`-et (a havi terv most
  `AppState.tonightSegment == .calendar`, nem önálló oldal — a sidebar
  "Naptár" sora/⌘2 a "Takarítás"/`auditSegment` mintáját követve
  szegmenst preszelektál, nem külön `Page`-re navigál). 4 tile: **Sötét idő**
  (ÚJ `Planner.nightInfo(date:site:)` — `SunMoon.astronomicalTwilight` +
  Hold-magasság-sweep, `darkHours` nil-safe fehér-éjszaka/nautikus fallback
  esetén), **Hold** (illumináció % + "felkel HH:mm"/"nyugszik HH:mm"/"egész
  éjjel fent"/"egész éjjel lent"), **Ajánlott** (`verdict == "ma jó"`
  darabszám), **Helyszín** (`AppState.resolvedSite` formázva + "FITS-
  fejlécekből"/"kézzel beállítva" caption, kattintásra a Settings ▸ Helyszín
  fület nyitja meg). Terv-tábla: sortolható `Table` 10 kolonnával
  (Célpont/Állapot/Integráció/Cél/Hiányzik/Kulmináló/Max. mag./Látható/Hold/
  Döntés), sor context-menü (Célpont megnyitása/Cél beállítása…/Plate-
  solve…/Éjszaka-riport/Célpont-riport/Mappa Finderben), a "Cél beállítása…"
  ÚJ `GoalEditSheet`-et nyit (sheet, mert a context-menü tétel bezáródik
  mielőtt egy popovernek horgonya lehetne). Empty state-ek (0 célpont, 0
  koordináta -- ÚJ `AppState.runPlateSolveAll()`, az `astrotool solve --all`
  logikáját tükrözve) + sárga banner teljesen feloldhatatlan helyszínnél.
  Naptár szegmens: `List` helyett `Table` (Ma/Holnap + hu_HU hétköznap,
  arány-proporcionális Hold-glif, `displayName`-es "Legjobb 3 célpont"), sor
  context-menü "Terv erre az éjszakára" → `AppState.loadPlan(date:)` egy
  másik éjszakára (a "Ma este" szegmens ekkor "‹dátum› éjszakájára" caption +
  "Vissza a mai estéhez" gombot mutat).
  **B10 helyszín-fix**: `AppState.loadPlan()`/`loadTargetDetail()` korábban
  `config.site`-ot MUTÁLTA a FITS-fejléc-medián feloldott értékkel, amit egy
  utólagos Settings-mentés csendben perzisztált (mintha a felhasználó kézzel
  írta volna be). Új `AppState.resolvedSite` a feloldott értéket KIZÁRÓLAG
  memóriában tartja; `config.site` csak azt tartalmazza, amit a felhasználó
  tényleg elmentett. `Views/SettingsWindow.swift` mostantól `TabView`
  ("Könyvtár" + ÚJ "Helyszín" fül, `Views/LocationSettingsView.swift` --
  Automatikus/Kézi picker, "Beillesztés a vágólapról", Automatikus mentés
  `site: {}`-t ír). `MainShellView`'s Műveletek toolbar-menü kapott egy
  működő "DSS-döntések importálása" tételt (a törölt `OverviewView` gombja
  áthelyezve, bekapcsolva). **AstroCore (TDD, additív)**: `Planner.NightInfo`
  + `Planner.nightInfo(date:site:)`, 3 új teszt (`PlannerTests.swift`). 820
  teszt zöld (817 + 3 új).

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

### Fixed

- **R9 javítókör 1** (re-review D1-D20/D29): induláskor visszaáll az utolsó
  audit `findings`/`lastRunID`-ja a DB-ből (`Database.lastRunID(kind:)`,
  `AppState.openRoot`) újrafuttatás nélkül; `AppState.loadDashboardData(date:)`
  egyesíti a stats/terv/projekt-állapot/takarítási-riport betöltést EGY
  háttérműveletbe -- a különálló `loadStats()`/`loadPlan()`/egy sosem hívott
  `loadProjects()` egymás után hívva versenyhelyzetet okozott
  (`currentTask` cancel-el a korábbi hívást), ezért a sidebar
  fázis-pontok/"Ma este" Állapot-Hiányzik oszlopok, illetve a Takarítható
  szegmens gyakran üresen jelentek meg egy friss indításnál; hívva
  `openRoot`/`TonightPage.onAppear`/`AllTargetsPage.onAppear`-ből (kisebb
  `loadCleanup()` az `AuditPage.onAppear`-ből). ⌘F most a menüsorból is
  fókuszálja a keresőmezőt (`.focusSearchField` végre posztolva). Minőség
  szegmens dátum-menüjének "Minden session" gombja a szűrő visszaállítására.
  ÚJ `Rater.cachedScores(target:date:db:config:)` a perzisztált pontszámok
  visszaolvasására Siril/fájlrendszer nélkül (`AppState.loadFrameScores`) --
  a Minőség szegmens megnyitáskor most a korábban mért pontszámokat mutatja,
  nem a hamis "Nincsenek pontozott keretek" állapotot.
  `CalibrationPage.CoverageRow.id` determinisztikus (a szükséglet mezőiből),
  nem `UUID()` minden render-en -- helyreállítja a sor-kiválasztást/
  jobbklikk-menüt. `StatsView` → `AllTargetsPage` (`Views/AllTargetsPage.
  swift`): 4 fejléc-tile, "Fázis" és "Stackek" oszlop, a "Címkék" oszlop
  read-only (a szerkesztés a sor jobbklikk-menüjébe került), célpont-/
  session-menü kiegészítve ("Cél beállítása…", "Kész stackek…", "Mozaik-
  panelek…", "Keretek pontozása" -- a Minőség szegmensre ugrik a session
  dátumával előválasztva, ÚJ `AppState.pendingQualityDate`), valódi
  `ContentUnavailableView` üres állapotok, a korábban holt `selection`
  `@State` bekötve a táblázat `.contextMenu(forSelectionType:primaryAction:)`
  -jébe. ⌘6 = Takarítás (a sidebar "Takarítás" sorával egyező preselect),
  ⌘7 = Szenzor; a végig letiltott "Minden célpont exportálása…" placeholder
  törölve mindkét menüből. "Ma este"/"Naptár" táblák sor-szintű
  `.contextMenu(forSelectionType:primaryAction:)`-ot kapnak (korábban csak a
  név-cella saját `.contextMenu`-je reagált). Elgépelés ("feleslegleges" →
  "felesleges") a Fogalomtárban; duplikált Karantén-script toolbar-gomb
  törölve (a "Script…" menüben marad). A Plate-solve… gomb megjelenik
  `sourceLabel == "nincs"` esetén is, nem csak `nil` koordinátánál; az
  Áttekintés "Szenzor mérése…" gombja a navigáció mellett a mérést is
  elindítja. `docs/features.html` átírva a jelenlegi sidebar-IA szerint.

- **R9 javítókör 2** (re-review D12-D33): ÚJ `Database.fitsMetaBatch(fileIDs:)`
  (500-as chunkolt `WHERE file_id IN (...)`) a célpont-oldal megnyitásakor és
  a "Plate-solve mindenre" futáskor korábban file-onként lefutó `fitsMeta`
  hívás-sorozat (a legnagyobb célpontnál ~9000 lekérdezés) helyett, plusz
  per-target koordináta-memo (`AppState.coordinateInfoCache`) -- egy már
  megnyitott célpont újranyitása most azonnali. Helyszín mentése a
  Beállításokban most újraszámolja a betöltött tervet (vagy a
  `resolvedSite`-ot, ha még nem volt terv-betöltés) -- korábban a terv
  változatlan maradt mentés után. A duplikált `describeSettingsError` törölve
  a `LocationSettingsView`-ból. "Kulmináló" → "Kulminál" a "Ma este"
  terv-táblában. "Mappastruktúra súgó" gomb a hozzáférés-megtagadva/kötet-
  hiányzik képernyő mindkét változatán. A kereső fájl-találatai mutatják a
  fájl `kind`-ját (capsule a méret mellett). Enter a keresőben egyenesen a
  célpont-oldalra navigál, ha a keresés pontosan egy célpontot talál (és
  session/fájl-találat nincs mellette). ÚJ `AppState.runScan(subpath:)` +
  "Minden célpont" oldal mappa-drop -- egy Finderből húzott almappa
  megerősítés után szűkített (nem teljes-könyvtár) beolvasást indít. A
  Stackek szegmens "Műveletek" oszlopa törölve, a három művelet
  (Megnyitás/Finderben/Nagy előnézet) sor-jobbklikk-menübe került. A sidebar
  "Naptár"/"Takarítás" sora (és ⌘2/⌘6) ismét kiválasztás-highlightol --
  `Page` ÚJ `.calendar`/`.cleanup` esetei valódi routolt oldalak, nem csak
  egy `Button`-oldalhatás. `ThumbnailCell` betöltés közben `ProgressView`-t
  mutat, csak a generálás befejezése után vált a "nincs kép" ikonra.
  `FirstScanView` mappaszerkezet-ellenőrzése kikerült a view body-ból egy
  `.onAppear`-be. 22 elavult doc-comment retargetelve a törölt fülek/
  popoverek/oldalak helyett a jelenlegiekre (`AppState.swift`,
  `AllTargetsPage.swift`). Az app most figyeli a `didBecomeActive`
  eseményt is (a kötet-csatlakozás mellett) -- a 24 órás "Új fájlok
  lehetnek" banner ezután akkor is megjelenik, ha az app nyitva maradt
  éjszakán át. 4 további táblán ⓘ metrika-magyarázat gomb ("Ma este"
  terv-tábla, Kalibráció lefedettség-tábla, Szenzor-profilok tábla, Audit
  Takarítható tábla). "Minden célpont pontozása…" a futás végén újratölti a
  statisztikákat (és a nyitva lévő célpont-oldal pontszámait/minőség-
  összegzését, ha van ilyen) -- korábban semmit sem frissített.

- **R9 javítókör 3** (re-review N1-N13): `AppState.loadTargetDetail` reset
  blokkja mostantól `frameScores`-t is nullázza -- célpont-váltásnál a
  Minőség szegmens korábban a KORÁBBI célpont frame-tábláját mutatta, amíg
  az új célpontnak nem volt saját pontozott adata. ÚJ
  `AppState.loadCalibrationData()` (a `CalibAnalyzer.coverage`/
  `CalibHealth.report`/`db.allSensorProfiles()` hármas EGY háttérműveletben,
  megosztva `loadDashboardData()`-val is) -- a Kalibráció oldal
  `onAppear`/"Újraszámolás" korábban a `loadCalib()`+`loadCalibHealth()`
  páros egymást törölte (`currentTask` verseny), a Teendők/lefedettség-tábla
  gyakran üresen maradt; a sidebar Kalibráció/Szenzor-profilok badge-ei
  most induláskor is helyesek, nem csak a Kalibráció oldal megnyitása után.
  `runPlateSolve`/`runPlateSolveAll` a záró `loadStats()`+`loadPlan()` páros
  helyett egy bundled `loadDashboardData()`-t hív (ugyanaz a verseny-fix).
  `AppState.coordinateInfoCache`-be írás `updateValue(_:forKey:)`-jal (a
  korábbi subscript-írás egy `nil` ÉRTÉKKEL törölte a kulcsot, így a "nincs
  koordináta" eset sosem cache-elődött); `openRoot` mostantól ezt a cache-t
  is teljesen törli gyökérváltásnál (korábban átszivárgott egy azonos nevű
  célpont az előző könyvtárból). ÚJ `Database.ratingsBatch(fileIDs:)`
  (500-as chunkolt `WHERE file_id IN (...)`, mirror `fitsMetaBatch`) --
  `Rater.cachedScores` a korábbi per-frame `rating`/`fitsMeta` páros (egy
  nagyobb célponton ~18k lekérdezés) helyett ezt + a meglévő
  `fitsMetaBatch`-et hívja. A "Ma este"/Audit szegmens-picker mostantól egy
  számított `Binding`en megy, ami `currentPage`-et is írja a szegmenssel
  együtt -- kézi szegmens-váltás korábban elcsúsztatta a sidebar
  kiválasztás-highlightját a tényleges tartalomtól. `TonightPage`/
  `AllTargetsPage.onAppear` `!appState.isBusy`-t is megkövetel a
  `loadDashboardData()` induláshoz -- induláskor ez korábban duplán futott
  le (`openRoot` már elindította). "Minden célpont" oldal: launch-load
  közben középre igazított `ProgressView` az "Nincs célpont a könyvtárban"
  üres állapot helyett; a duplikált "Összes integráció:" lábsor törölve (a
  tile-sor már mutatja); a célpont-kontextmenü "Mozaik-panelek…" tétele
  törölve (szó szerint ugyanazt csinálta, mint "Megnyitás"). A kereső
  egy-találatos auto-navigációja most a jegyzet-találatokat is figyeli --
  korábban egy célpont-találat mellett érkező jegyzet-találatot némán
  elnyelt.

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
