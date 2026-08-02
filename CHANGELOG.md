# Changelog

Minden lényegi változás ebben a fájlban van dokumentálva.

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elvein
alapul, a verziószámozás a [Semantic Versioning](https://semver.org/) szerint
történik.

## [Unreleased]

### Added

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
