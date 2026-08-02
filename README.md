# AstroTool

<img src="icon/AppIcon_1024.png" width="128" alt="AstroTool ikon">

Asztrofotó-könyvtár auditálása, minőség-pontozás és kalibráció-követés macOS-en — CLI-vel és natív SwiftUI alkalmazással.

## Mit tud

- **Audit** — végigpásztázza a képkönyvtárat, és három súlyossági szintbe sorolja a talált problémákat:
  - **biztos hiba** (`sureError`) — pl. sérült/hiányos FITS fejléc, üres fájl,
  - **gyanús** (`suspicious`) — pl. szokatlan méret/metaadat, ami hibára utalhat,
  - **valószínűleg szándékos** (`probablyIntentional`) — pl. ismert reziduum-minta vagy tudatosan meghagyott fájl.

  Emellett duplikátum-keresés (`--no-duplicates` kikapcsolja), és opcionálisan javaslat-script generálás (`--suggest`).
- **Minőség-pontozás (rate)** — light frame-ek pontozása natív metrikákkal, opcionálisan Siril CLI hibriddel (FWHM, kerekség, csillagszám, háttér), kiugró (outlier) keretek jelölésével.
- **Statisztika (stats)** — célpontonkénti integrációs idő, session-szám, utolsó felvétel dátuma, wide-field/deep-sky besorolás.
- **Kalibráció-hiánylista (calib)** — mely expozíciós idő/hőmérséklet kombinációkhoz van lefedettség (dark/flat/bias), és mihez kell még kalibrációs keretet készíteni.
- **Session-párosítás (match)** — egy adott célpont+dátum session-höz tartozó kalibrációs keretek és light frame-ek összerendelése, problémákkal.
- **Új session létrehozás (new-session)** — kanonikus `YYYY-MM-DD` könyvtárstruktúra és README-sablon létrehozása egy célponthoz.

## ⛔ Vasszabály

**Az eszköz a képkönyvtárban SOHA nem töröl és nem mozgat semmit.** Az audit és a hozzá kapcsolódó parancsok kizárólag *jelölnek* (találatok listája) és — kérésre — egy `.sh` **javaslat-scriptet** generálnak a `<ROOT>/.astro_tool/suggestions/` mappába. Ezt a scriptet a felhasználó nézi át és futtatja le saját belátása szerint; az eszköz maga soha nem hajt végre fájlműveletet a könyvtáron kívül a saját `.astro_tool/` munkakönyvtárán.

## Telepítés

1. Töltsd le a legfrissebb DMG-t a [Releases](../../releases) oldalról.
2. Nyisd meg a DMG-t, és húzd az `AstroTool.app`-ot az `Applications` mappába.
3. **Első indításkor jobbklikk → Megnyitás** az app ikonján (nem az egyszerű dupla kattintás!) — az app nincs notarizálva (nincs Apple Developer fiók mögötte), így Gatekeeper alapból blokkolná egy sima dupla kattintást.

### CLI telepítése

Kétféleképpen:

- **Release zip**: töltsd le az `astrotool.zip`-et a Releases oldalról, csomagold ki, majd tedd a `PATH`-ra (pl. `mv astrotool ~/.local/bin/`).
- **Forrásból**: `./build.sh` — ez a helyi gépen build-eli az appot és a CLI-t, majd a CLI-t automatikusan tükrözi `~/.local/bin/astrotool` névvel (szimlink), az appot pedig `~/Applications`-be másolja.

## Teljes lemez-hozzáférés (TCC)

A képkönyvtár egy külső köteten van (`/Volumes/images/Astro`), ehhez macOS **Teljes lemez-hozzáférés** jogosultság kell:

1. **Rendszerbeállítások → Adatvédelem és biztonság → Teljes lemezhozzáférés**
2. Engedélyezd az `AstroTool.app`-nak (illetve a terminálnak, ha a CLI-t onnan futtatod).
3. **Indítsd újra az appot/terminált** az engedélyezés után — enélkül a jogosultság nem lép életbe.

Ha a hozzáférés hiányzik vagy a kötet nincs csatlakoztatva, a CLI **exit code 2**-vel tér vissza, és útmutató szöveget ír a hibakimenetre; az app pedig egy dedikált képernyőt mutat ugyanezzel az útmutatással a fő felület helyett.

## CLI használat

Minden alparancs támogatja a `--json` kapcsolót gépi olvasható kimenethez (snake_case kulcsok, rendezett, pretty-printed).

```bash
astrotool scan --root /Volumes/images/Astro
# Bejárja a könyvtárat, frissíti a belső SQLite indexet (hozzáadott/frissült/változatlan/hiányzó fájlok).

astrotool audit --suggest --include-suspicious
# Lefuttatja az audit szabálymotort, és javaslat-scriptet ír a gyanús találatokra is (alapból csak a biztos hibákra).

astrotool audit --no-duplicates --json
# Audit duplikátum-keresés nélkül, JSON kimenettel (pl. szkriptből feldolgozáshoz).

astrotool rate --target M31 --date 2026-03-15
# Az adott célpont/dátum light frame-jeinek minőség-pontozása (Siril, ha elérhető).

astrotool rate --target M31 --no-siril
# Pontozás csak natív metrikákkal, Siril nélkül.

astrotool stats --target M31
# Integrációs idő, session-szám, utolsó felvétel, wide-field státusz egy célponthoz.

astrotool stats
# Statisztika az összes célpontra táblázatos formában.

astrotool calib
# Kalibrációs lefedettség és hiánylista (mely expozíció/hőmérséklet kombinációhoz kell még dark/flat/bias).

astrotool match --target M31 --date 2026-03-15
# Egy adott session light/flat/dark/bias készletének összerendelése és a talált problémák listája.

astrotool new-session --catalog M --name 31 --date 2026-03-15
# Új session könyvtár létrehozása (YYYY-MM-DD) README sablonnal a célponthoz.

astrotool config show
# A jelenleg érvényes (fájlból betöltött + alapértelmezésekkel kiegészített) konfiguráció kiírása.

astrotool config path
# A config.json elérési útjának kiírása.
```

Minden parancs elfogadja a `--root <PATH>` kapcsolót az alapértelmezett könyvtár felülbírálására.

## Konfiguráció

A konfiguráció a `<ROOT>/.astro_tool/config.json` fájlban van; hiányzó kulcsok esetén az eszköz beépített alapértékeket használ, így egy régebbi config fájl is mindig érvényes marad.

| Kulcs | Jelentés |
|---|---|
| `rootPath` | A képkönyvtár gyökere (alapértelmezés: `/Volumes/images/Astro`). |
| `excludedDirNames` | Könyvtárnevek, amelyeket a scan teljesen kihagy (pl. `tools`). |
| `excludedPaths` | Gyökérhez képest relatív, konkrét kizárt útvonalak. |
| `residuePatterns` | Glob-minták, amelyek "szándékos maradvány" fájlokat jelölnek (pl. `*.seq`, `*_conv*`, `.DS_Store`). |
| `residueDirNames` | Könyvtárnevek, amelyek tartalma reziduumnak számít (pl. `process`). |
| `intentional` | Session-dátum minták, amelyeket az eszköz szándékosnak ismer fel: `runSuffix` (pl. `-2` végű dátum), `dateRange` (két dátum összekötve), `labels` (ismert szöveges címkék, pl. `hibas`, `OSC`). |
| `wideField` | Wide-field/deep-sky besorolás szabálya: `extensions`, `maxFocalLengthMM`, `nameMarkers`, és célpontonkénti `overrides`. |
| `calib` | Kalibráció-illesztés tűrései: `tempToleranceC`, `exposureToleranceS`, `darkMaxAgeMonths` (mikor számít elévültnek egy dark). |
| `rating` | Minőség-pontozás beállításai: `workers` (párhuzamos worker-ek száma), `outlierZScore`, `sirilPath`, `weights` (metrikánkénti súlyok: `fwhm`, `roundness`, `starCount`, `background`). |

## Fejlesztés

```bash
swift build            # debug build
swift test              # teljes teszt-szuit (214 teszt)
./build.sh              # release build + app bundle + DMG + CLI zip
```

Projektstruktúra dióhéjban:

- `Sources/AstroCore/` — a teljes üzleti logika (scan, audit, rate, stats, calib, match, new-session, config, write-guard) mint könyvtár, UI-tól függetlenül.
- `Sources/astrotool/` — a parancssori felület (`ArgParser`, `Commands`, `main`), amely csak `AstroCore`-ra épít.
- `Sources/AstroToolApp/` — a SwiftUI alkalmazás (`AppState` + `Views/`), szintén `AstroCore`-ra épülve.
- `Tests/AstroCoreTests/` — a teszt-szuit.
- `icon/`, `build.sh` — app-ikon generálás és a release-csomagolás.

## Licenc

MIT — lásd a [LICENSE](LICENSE) fájlt.
