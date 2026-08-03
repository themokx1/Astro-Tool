# Changelog

Minden lényegi változás ebben a fájlban van dokumentálva.

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elvein
alapul, a verziószámozás a [Semantic Versioning](https://semver.org/) szerint
történik.

## [Unreleased]

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
