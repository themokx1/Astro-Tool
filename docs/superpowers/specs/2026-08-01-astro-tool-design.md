# Astro-Tool — design spec (2026-08-01)

macOS app + Swift CLI, ami az asztrofotós képkönyvtárat (`/Volumes/images/Astro`)
tartja karban: felderít, pontoz, nyilvántart, hiánylistát ad. **Semmit nem töröl
és nem mozgat** — csak jelöl és javasol.

## 0. Vasszabályok (nem tárgyalhatók)

1. A tool a képkönyvtárban **soha nem töröl, nem mozgat, nem ír felül** semmit.
2. Írás kizárólag két additív művelet: új session-mappák létrehozása, és a tool
   saját fájljai a `<ROOT>/.astro_tool/` alatt.
3. Ezt a kód **szerkezetileg** kényszeríti ki: egyetlen `WriteGuard` komponens
   végezhet fájlrendszer-írást, fehérlistás művelettípusokkal; minden más kódút
   read-only API-t kap.
4. Javítás = a `.astro_tool/suggestions/` alá generált, kommentezett `.sh`
   script, amit a felhasználó néz át és futtat. A tool sosem futtatja.

## 1. Lezárt döntések (Q&A a felhasználóval, 2026-08-01)

| Kérdés | Döntés |
|---|---|
| `-2`/`-3` suffix, `_hibas`, dátum-tartomány, `-OSC` | Mind **szándékos konvenció** — "valószínűleg szándékos" besorolás, konfigurálható minta-listával |
| `M42_Orion*` család | **Nincs összevonási javaslat** — a tool csak jelzi a hasonló célpontneveket |
| Scope | **Csak `<ROOT>/Astro`**, a `tools/` alapból kizárva; egyéb kötet-mappák nem |
| Kamera-setupok | **FITS headerből** derüljön ki (INSTRUME, GAIN, OFFSET, SET-TEMP, EXPTIME) |
| Biztos hibák (pl. `Please_enter_a_value.._Milkyway`, `bias/` árva) | Javaslat + generált `.sh` script |
| Strukturális anomáliák (session-fa a `stacks/` alatt, flat a `lights/`-ban) | Ugyanaz a javaslat+script mechanizmus; a "gyanús" tételek külön kapcsolóval |
| Projekt-felépítés | **SwiftPM, zéró third-party függőség** |
| GUI ↔ motor | **Az app közvetlenül linkeli az `AstroCore`-t**; a CLI ugyanabból a core-ból ad `--json` kimenetet |
| Pontozás | **Hibrid**: Siril CLI (csillag-metrikák) + saját FITS-statisztikák, SQLite-cache |

## 2. Ground truth és nyitott verifikációk

Konvenciók forrása: a repo `PROMPT.md`-je (célpont-sanitize, `YYYY-MM-DD` dátum,
session/stack/processed/calibration_library elrendezés, kalibrációs
`<exp>sec_<temp>deg` nevek, README.txt mezők).

**Verifikálva (2026-08-02)**, miután a `/Volumes/images` TCC-engedélye
megérkezett és a valódi `add_new_session.sh` + `tools/rate/LightFrameRater.py`
elolvasható lett:

- **`sanitize()`**: a valós script sorrendje `tr ' ' '_'` ELŐSZÖR, utána
  `tr -cd 'A-Za-z0-9._-'` — a nem engedélyezett karakterek TÖRLŐDNEK, nem
  `_`-ra cserélődnek (a portolt `Sanitizer` korábban tévesen cserélt).
  Javítva: `Sources/AstroCore/NewSession/Sanitizer.swift` +
  `SanitizerTests.swift` (`"a///b   c"` → `"ab_c"`, nem `"a_b_c"`).
- **Session-fa**: a script minden új sessionhöz a teljes
  `sessions/<T>/<D>/{lights,flats,darks,biases}` + `README.txt` mellett
  `stacks/<T>/<D>/`-t és `processed/<T>/<D>/`-t is létrehoz, és biztosítja a
  bázis-mappákat (`sessions/`, `stacks/<T>`, `processed/<T>`,
  `calibration_library/{darks,flats,biases}`) — mkdir -p szemantikával.
  Javítva: `WriteGuard.createSessionTree` bővítve; új
  `Sources/AstroCore/NewSession/SessionCreator.swift` fogja össze a
  sanitize+dátum-validáció+README+fa-létrehozás logikát egy helyen (a CLI
  `new-session` és az app `AppState.createSession` mostantól ezt hívja,
  nem duplikálja).
- **README.txt sablon**: a valós script pontos szövege (fejléc, "Folder map",
  "Fill in metadata", "Calibration reminder" szakaszok) most szó szerint a
  `SessionCreator`-ban van, interpolációkkal (`target_folder`, `target_raw`,
  `catalog_raw`, dátum, létrehozási időbélyeg).
- **`tools/rate/LightFrameRater.py`**: döntés — **egymás mellett élnek**, nem
  egymást helyettesítik. Az `astrotool rate` gyors, DB-hátterű indexelés
  exportálható JSON-nal és per-exponálási-csoport z-score-okkal (lásd alább);
  a `LightFrameRater` a részletes, stack előtti triázs-eszköz (Stack/Review/
  Reject mappák Best/Good/Ok alkategóriákkal). Ezek a kimenetek szándékos
  tool-kimenetek, nem rendetlenség — az audit motor `tool-output` kategóriával
  ismeri fel őket (`AstroConfig.toolOutputDirNames`,
  `Sources/AstroCore/Audit/Rules.swift`'s `ToolOutputRule`), és a
  `noncanonical-subdir`/`assets-without-date`/`loose-frames-in-date-dir`
  szabályok kifejezetten kihagyják ezeket.
- **Pontozás per exponálási csoport**: a `LightFrameRater` fixen külön
  hasonlítja össze az azonos expozíciós idejű képeket ("Azonos expo idok
  kulon osszehasonlitasa. Ez fixen be van kapcsolva.") — ezt a viselkedést a
  saját `Rater` is átvette: a z-score-ok mostantól exptime-csoporton belül
  (0.1s-re kerekítve; exptime nélküli képek egy közös csoportot alkotnak)
  számolódnak, nem a teljes batch-en át.
- A régi audit tool riportjai (`/Volumes/images/.astro_audit_reports/`) —
  formátum-ötletek gyűjtve, nem épült rájuk közvetlen függőség.

## 3. Architektúra

```
Package.swift                — SwiftPM, csak Apple SDK + rendszer-libsqlite3
Sources/
  AstroCore/                 — minden logika; tesztelhető könyvtár
    Config/                  — JSON config (betöltés/mentés/defaultok/validálás)
    Scan/                    — fájlrendszer-bejáró, kizárások, inkrementalitás
    FITS/                    — FITS header parser (.fit/.fits/.fz), CR3 ImageIO-val
    Model/                   — Target, Session, Frame, CalibrationMaster, Finding
    DB/                      — SQLite wrapper + séma + migráció
    Audit/                   — szabálymotor, besorolás, hasonlóság-jelzés
    Rate/                    — Siril illesztő + saját statisztika + cache
    Calib/                   — lefedettség, hiánylista, elévülés
    Suggest/                 — .sh javaslat-generátor (sosem futtat)
    NewSession/              — sanitize, dátum-validálás, mappa+README létrehozás
    WriteGuard.swift         — az egyetlen író komponens
  astrotool/                 — CLI main + alparancsok + JSON/emberi kimenet
  AstroToolApp/              — SwiftUI app (AstroCore linkelve)
Tests/AstroCoreTests/        — unit tesztek fixture-fákon (temp könyvtár)
build.sh                     — swift build + .app bundle + DMG + CLI symlink
docs/                        — GitHub Pages letöltőoldal
icon/                        — ikon-generáló Swift scriptek (HDRHeic-minta)
.github/workflows/release.yml — v* tagre build + Release (DMG + zip)
```

- CLI alparancsok: `scan`, `audit`, `rate`, `stats`, `new-session`, `config`.
  Mindegyiknél `--json` a gépi kimenethez; kilépési kód: 0 siker, 1 hiba,
  2 = "hozzáférés megtagadva (TCC)".
- Az app egy ablak, fülek: Áttekintés / Audit / Minőség / Kalibráció /
  Statisztika / Beállítások. Hosszú futásokhoz progress + megszakíthatóság.

## 4. Adatmodell (SQLite: `<ROOT>/.astro_tool/astrotool.sqlite`)

```
files(id, path, size, mtime, ext, kind, target, session_date, role,
      content_hash NULL, scanned_at)           -- kind: light/flat/dark/bias/
                                               --   master/stack/processed/other
fits_meta(file_id, exptime, gain, offset, set_temp, ccd_temp, instrume,
          focallen, filter, date_obs, naxis1, naxis2, header_json)
targets(id, name, canonical_guess, is_wide_field)
sessions(id, target_id, date_raw, date_start, date_end, label,
         readme_json NULL)
ratings(file_id, fwhm, roundness, star_count, background, score,
        rated_at, siril_version, input_sig)    -- input_sig = size+mtime kulcs
findings(id, run_id, severity, category, path, detail_json, suggestion NULL)
        -- severity: sure_error | suspicious | probably_intentional
runs(id, kind, started_at, finished_at, root, config_snapshot_json)
calib_masters(file_id, kind, exposure_s, temp_c, gain NULL, created_date)
```

Inkrementalitás: a scan a (path, size, mtime) hármast hasonlítja — változatlan
fájlnál se FITS-olvasás, se hash, se újra-pontozás. Hash (SHA-256) csak
duplikátum-kereséskor és csak méret-egyezés esetén számolódik.

## 5. Komponensek

### Scan
Bejárja a konfigurált gyökeret (alap: `<ROOT>` = `/Volumes/images/Astro`), a
kizárási listával (`tools/` alapból; `.astro_tool/` mindig). Tetszőleges
almappára szűkíthető (`astrotool scan --path stacks/M42_Orion`). Kimenet: DB-be
írt fájl-leltár + összefoglaló. Párhuzamos feldolgozás korlátozott I/O-val
(konfigurálható worker-szám, alap 4 — külső lemez!).

### FITS
Saját parser: 2880 bájtos blokkok, 80 karakteres kártyák; `.fz`-nél a
primary + első bináris tábla extension headerét olvassa (a Rice-tömörített adat
kihagyásával). CR3/TIF metaadat a macOS ImageIO-ból (`CGImageSource`), csak a
wide-field heurisztikához szükséges mezők (gyújtótávolság, dátum, kamera).

### Audit (besorolás: biztos hiba / gyanús / valószínűleg szándékos)
Szabályok, mindegyik configból kapcsolható/hangolható:
- **biztos hiba:** placeholder-név (`Please_enter_a_value*`), üres célpont-
  komponens, `bias`↔`biases` árva, session-fa nem `sessions/` alatt, kalibrációs
  frame rossz role-mappában (FITS `IMAGETYP` ≠ mappa), duplikált katalógus-
  prefix a névben (`C2025_R3_C2025_R3_*`);
- **gyanús:** nem kanonikus almappa (`collected_lights/`, `process/`), riport-
  asset dátum-mappa nélkül, hiányzó session↔stack↔processed pár, hasonló
  célpontnevek (normalizált név: kisbetű, `_` összevonás, katalógus-prefix
  kiemelés — csak **jelzés**, összevonási javaslat nélkül);
- **valószínűleg szándékos:** `-N` suffix, `_hibas`, dátum-tartomány, `-OSC`
  és társaik (konfigurálható minta-lista).
Javaslat-script csak sure_error-ra készül alapból; `--include-suspicious`
kapcsolóval a gyanúsakra is.

### Rate
1. saját, olcsó kör: háttér-medián, csúcs-szaturáció arány, header-adatok;
2. Siril kör: `/Applications/Siril.app/Contents/MacOS/siril-cli -s -` script
   (teljes útvonal, nincs PATH-on), batch-enként temp munkakönyvtárral a
   scratch területen — **soha nem a képkönyvtárban**; FWHM, roundness,
   csillagszám kinyerése a kimenetből;
3. normalizált pontszám session-en belül (z-score alapú, konfigurálható súlyok
   és kiugró-küszöb). Eredmény cache-elve `input_sig` kulccsal.
Siril hiánya = a rate alparancs érthető hibával leáll, a többi funkció él.

### Calib
A lightok (exp, set_temp, gain) kombinációit veti össze a
`calibration_library` masterek `<exp>sec_<temp>deg` készletével (tűrések
configból: pl. ±0.5 °C, exp pontos egyezés). Kimenet: lefedettségi mátrix +
teendő-lista ("készíts 300 s / −10 °C darkot") + elévülés-jelzés
(alap: dark 6 hónap, flat optika-változásig — configból).

### Session-párosítás
Adott célpont+éjszaka lightjaihoz flat/dark/bias keresés dátum + FITS header
alapján; rossz helyre keveredett frame-ek jelzése (Audit-finding lesz belőle).

### NewSession
Az `add_new_session.sh` logikájának portja: `sanitize()` (szóköz→`_`, csak
`[A-Za-z0-9._-]`, `_` összevonás, trim), szigorú `YYYY-MM-DD` valós dátum,
`sessions/<TARGET>/<DATE>/{lights,flats,darks,biases}` + README.txt sablon.
GUI-ban meglévő célpontok autocomplete-tel (DB-ből). Írás a WriteGuard-on át.

### Config
`<ROOT>/.astro_tool/config.json` (+ GUI Beállítások fül): gyökér, kizárások,
minőség-küszöbök, wide-field szabály (`.cr3`/`.tif`, FOCALLEN < küszöb,
`wide` a névben — felülbírálható célpontonként), szándékos-minta lista,
kalibrációs tűrések és elévülés, worker-szám, Siril útvonal.

### Wide field vs deep sky
Heurisztika a fentiek szerint; az eredmény a `targets.is_wide_field` mezőbe
kerül, statisztikában külön bontás, kézi felülbírálat configból/GUI-ból.

## 6. Adatfolyam

`scan` → DB fájl-leltár + FITS meta → ebből dolgozik minden más:
`audit` (findings + opcionális suggestion script), `rate` (ratings), `stats`
(lekérdezések: össz-integráció célpontonként, utolsó session, hiányzó adat),
kalibrációs hiánylista. A GUI ugyanezeket a core API-kat hívja közvetlenül,
progress-callbackekkel; minden hosszú művelet Task-ként fut, megszakítható.

## 7. Hibakezelés

- **TCC-megtagadás** (a fő eset): a core megkülönbözteti az "üres könyvtár"-t
  az "Operation not permitted"-től; az app dedikált képernyőt mutat a
  Rendszerbeállítások-teendővel (+ gomb a Privacy panel megnyitására), a CLI
  exit 2 + útmutató. Sosem mutatunk néma nullát.
- Kötet nincs felcsatolva: explicit üzenet, nem "0 fájl".
- Sérült/csonka FITS: finding lesz belőle, a scan nem áll le.
- Siril hiba/timeout: frame kihagyva+jelölve, batch folytatódik.
- DB-migráció: verziózott séma, ismeretlen verziónál biztonsági mentés
  (`.astro_tool` alá) és tiszta újraépítés felajánlása.

## 8. Tesztelés

- Unit tesztek fixture-fákon: a tesztek temp könyvtárban felépítik a PROMPT.md
  szerinti "rendetlenség-katalógust" (placeholder-név, 4-es M42 család,
  bias/biases, dátum-variánsok, beágyazott session-fa, hiányzó párok) — az
  audit mindet a várt kategóriába sorolja.
- FITS parser: kézzel gyártott minimális header-blokkok + csonka fájlok.
- Sanitize/dátum: property-jellegű esetlisták.
- Suggest: a generált script *szövegét* assertáljuk (mv-k, kommentek), futtatás
  soha.
- WriteGuard: teszt bizonyítja, hogy fehérlistán kívüli útvonalra írás hibát
  dob.
- Valós könyvtáron csak read-only futás, szűk almintán, a TCC-engedély után.

## 9. Szállítandók

- `build.sh`: `swift build -c release` → `.app` bundle (Info.plist, ikon,
  ad-hoc codesign) → DMG (drag-to-Applications) → `astrotool` symlink
  `~/.local/bin`-be.
- GitHub Actions: `v*` tagre macOS runneren build, Release DMG+zip assettel.
- `docs/`: letöltőoldal (favicon, OG-kártya), Download → `releases/latest`.
- MIT LICENSE, CHANGELOG.md, README (jobbklikk→Open a Gatekeeperhez, TCC-
  engedély leírása, CLI példák).

## 10. Mérföldkövek

1. **M1 — Core váz:** SPM skeleton, Model, Config, WriteGuard, DB séma,
   sanitize/dátum + tesztek.
2. **M2 — Scan+FITS:** bejáró kizárásokkal, FITS/CR3 meta, inkrementális DB.
3. **M3 — Audit:** szabálymotor + besorolás + findings riport + suggest
   scriptek; fixture-teszt a teljes rendetlenség-katalógusra.
4. **M4 — Stats+Calib:** integrációs statisztikák, kalibrációs hiánylista,
   session-párosítás.
5. **M5 — Rate:** saját statisztikák + Siril illesztő + cache + pontszám.
6. **M6 — CLI polish:** minden alparancs, `--json`, emberi kimenet, exit kódok.
7. **M7 — App:** SwiftUI, 6 fül, progress, TCC-képernyő, new-session GUI.
8. **M8 — Csomagolás:** build.sh, DMG, ikon, CI release, docs oldal, README.

Minden mérföldkő végén: tesztek zöldek, commit + push.

## 11. Kiegészítés — 2. kör (2026-08-02, user-kérés)

1. **Audit memory-hiba javítása**: az `audit` a valós könyvtáron másodpercek
   alatt ~40 GB RAM-ot eszik. Gyanú: a duplikátum-hash-elés (a) autoreleasepool
   nélkül olvas chunkokat, (b) az azonos szenzorról jövő FITS-ek mind azonos
   méretűek → gyakorlatilag minden frame hash-jelölt lesz (200+ GB olvasás).
   Elvárás: konstans (< pár száz MB) memóriahasználat + értelmes előszűrés.
2. **Session-részletek**: célpontonként session-bontású nézet és CLI kimenet:
   dátum, frame-számok szerepenként, expozíció-bontás, gyújtótávolság
   (FOCALLEN/EXIF), kamera, gain/ISO, szenzor-hőmérséklet, szűrő, össz-idő.
3. **Tagelés**: szabad címkék célpontra ÉS sessionre (DB séma v2: `tags`
   tábla + kapcsolótáblák vagy egyszerű (kind, key, tag) séma). CLI:
   `astrotool tag add|remove|list`; app: tag-chipek + szűrés.
4. **Kalibráció-linkelés (ÚJ írási művelet — user által engedélyezve)**:
   gombra/parancsra a tool megkeresi a session lightjaihoz illő master darkot
   (exp/temp tűréssel), a flatokhoz illő flat-darkot és a bias mastert, és
   **hard linkeli** őket a session megfelelő mappájába
   (`darks/`, `biases/`). Szabályok: kizárólag a WriteGuard új, fehérlistás
   `linkCalibration` műveletén át; hard link (azonos kötet), létező cél-fájlt
   SOHA nem ír felül (skip + jelzés); forrás mindig a `calibration_library`;
   a vasszabály többi része (nincs törlés/mozgatás) változatlan.
   **(megvalósítva 2026-08-03)**: `WriteGuard.linkCalibrationFile` (fehérlistás
   hard-link, forrás/cél útvonal-validáció a `writeToolFile`-éval azonos
   stílusban), `CalibLinker.plan`/`apply` (a `SessionMatcher`/`CalibAnalyzer`
   meglévő illesztési logikáját újrahasználva, nem duplikálva), CLI
   `astrotool link-calib --target T --date D [--dry-run] [--yes] [--json]`,
   app: „Kalibráció linkelése…" gomb a session-részletek panelen
   (`StatsView`) → megerősítő sheet.
