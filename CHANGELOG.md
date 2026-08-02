# Changelog

Minden lényegi változás ebben a fájlban van dokumentálva.

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elvein
alapul, a verziószámozás a [Semantic Versioning](https://semver.org/) szerint
történik.

## [Unreleased]

### Javítva

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
