# AstroTool

<img src="icon/AppIcon_1024.png" width="128" alt="AstroTool app icon">

Natív macOS alkalmazás és CLI asztrofotós könyvtárak, sessionök,
capture-gyűjtések, minőség, kalibráció és észlelési tervek átlátható
kezeléséhez.

[Weboldal](https://themokx1.github.io/Astro-Tool/) ·
[Első lépések](https://themokx1.github.io/Astro-Tool/tutorial.html) ·
[Funkciók](https://themokx1.github.io/Astro-Tool/features.html) ·
[CLI referencia](https://themokx1.github.io/Astro-Tool/cli.html) ·
[Adatvédelem](https://themokx1.github.io/Astro-Tool/privacy.html)

## Miért AstroTool?

Az asztrofotós fájlok nem csak dátumok és FITS-fejlécek. Egyetlen éjszakán,
egyetlen célponthoz is készülhet több expozíciós sorozat, szélessávú és
keskenysávú anyag, másik kamera, külön flat, több stack és eltérő
feldolgozás. Az AstroTool ezeket egy közös, de nem összemosott
munkafolyamatban tartja.

- **Session + capture modell** — egy célpont/dátum alatt tetszőleges számú
  OSC, monó, szélessávú, dual-band vagy keskenysávú gyűjtés.
- **Valós integráció** — deduplikált, nem archivált, nem elvetett light
  frame-ekből számol.
- **Minőség** — FWHM, háttér, kerekség, csillagszám és kiugrók a megfelelő
  capture kontextusában.
- **Kalibráció** — dark/flat/bias lefedettség kamera, gain, offset,
  expozíció, hőmérséklet és optikai konfiguráció szerint.
- **Tervezés** — setupból számolt látómező, ma esti láthatóság, Hold,
  célidő és 30 éjszakás naptár.
- **Trendek és riportok** — integráció, fotózási éjszakák, hatékonyság,
  célpont- és szűrőrangsor, önálló HTML riportok.
- **Offline célpontkatalógus** — katalógusszám, angol vagy magyar név
  alapján kereshető új session felület.
- **Natív app + CLI** — ugyanaz az AstroCore adatmodell interaktív és
  automatizálható felülettel.

## Biztonsági modell

Az audit, beolvasás, pontozás, riport és normál könyvtárműveletek
**nem törlik és nem mozgatják a képfájlokat**.

Két szándékos fájlmozgató munkafolyamat van:

1. egyetlen session fizikai átalakítása capture-struktúrára;
2. egy már elvetett frame áthelyezése a saját gyűjtése archívumába.

Mindkettő szűk hatókörű, tételes előnézetet és megerősítést kér, nem ír
felül meglévő fájlt, bizonylatot készít és visszaállítható. A
session-konverter alapértelmezett logikai módja egyetlen fájlt sem mozgat.

## Telepítés

Követelmény: **macOS 26 vagy újabb**. A kiadási DMG Universal, ezért Apple
Silicon és Intel Macen is fut.

1. Töltsd le a legújabb DMG-t a [Releases](../../releases) oldalról.
2. Nyisd meg, és húzd az `AstroTool.app`-ot az `Applications` mappába.
3. Indítsd el, majd válaszd ki a képkönyvtárad.

A publikus release-folyamat Developer ID aláírást és Apple-notarizációt
követel; ezek nélkül a release script hibával leáll. A helyi, forrásból
készült build fejlesztői/ad-hoc aláírású.

### Első indítás

Az első képernyő csak a képkönyvtárat kéri. Az első beolvasás után
opcionálisan megadható:

- megfigyelési hely és külön engedélyezhető időjárás;
- több kamera–optika setup és zoomtartomány;
- saját szűrők;
- minőségpontozás és opcionális Siril;
- integrációs referencia.

Minden részletes oldal kihagyható és később a Beállításokból újranyitható.
Tiszta telepítéskor nincs előre felvett felszerelés, szűrő, helyszín vagy
képkönyvtár.

## Integrációs cél

Explicit `goal:` címke hiányában az alap referencia:

- 10 óra;
- APS-C szenzor;
- f/5 optika;
- 1,0 relatív rendszerhatékonyság;
- 22,0 mag/arcsec² becsült felületi fényesség.

A célpont fényessége és látszó mérete, valamint a beállított szenzor,
f-szám és hatékonyság ehhez képest skálázza a javasolt időt. A kézzel
megadott cél mindig elsőbbséget élvez.

## Capture-gyűjtések

Ajánlott struktúra:

```text
sessions/<cél>/<dátum>/captures/<slug>/lights
sessions/<cél>/<dátum>/captures/<slug>/flats
sessions/<cél>/<dátum>/captures/<slug>/darks
sessions/<cél>/<dátum>/captures/<slug>/biases
stacks/<cél>/<dátum>/<slug>
processed/<cél>/<dátum>/<slug>
```

Régi könyvtárat nem szükséges kézzel átnevezni. Az egy-session konverter
először felismeri a forrásokat, külön gyűjtést javasol expozíció és metadata
szerint, megmutatja a bizonytalan döntéseket, majd logikai vagy külön
engedélyezett fizikai tervet készít.

## CLI gyorsstart

A CLI ZIP a kiadás assetjei között található. Minden fontos parancs
támogatja a `--json` kimenetet.

```bash
astrotool --version
astrotool scan --root /path/to/Astro
astrotool audit --root /path/to/Astro
astrotool stats --root /path/to/Astro
astrotool plan --root /path/to/Astro

astrotool capture create \
  --root /path/to/Astro \
  --target M31 --date 2026-09-14 \
  --name "Broadband · 120 s" --slug broadband-120s \
  --sensor osc --signal broadband

astrotool session-convert plan \
  --root /path/to/Astro \
  --target M31 --date 2026-09-14 \
  --out conversion-plan.json

astrotool stacklist \
  --root /path/to/Astro \
  --target M31 --date 2026-09-14 \
  --capture broadband-120s
```

A részletes referencia: [docs/cli.html](docs/cli.html).

## Adatvédelem

- Nincs AstroTool-fiók, saját felhő vagy telemetria.
- A képek, FITS-metaadatok, index, pontozások és jegyzetek helyben maradnak.
- Az Open-Meteo időjárás alapból ki van kapcsolva; bekapcsolásakor csak a
  kiválasztott hely koordinátája kerül az időjárási szolgáltatáshoz.
- A bővített célpont-katalógus (SIMBAD/VizieR) alapból ki van kapcsolva;
  bekapcsolásakor és a "Katalógus frissítése" művelet futtatásakor kizárólag
  katalógusnevek és koordináták kerülnek a szolgáltatáshoz, a könyvtár
  fájljai, elérési útjai vagy jegyzetei soha. Az első letöltés után a
  Planning offline is működik a letöltött adatokkal. Lásd
  [docs/DATA-SOURCES.md](docs/DATA-SOURCES.md) az ellenőrzött katalógus-
  azonosítókért és a kötelező CDS-attribúcióért.
- A támogatási diagnosztika nem tartalmaz könyvtárútvonalat, fájlnevet,
  célpontot, koordinátát, jegyzetet, FITS-fejlécet vagy hibaüzenetet.

## Forrásból buildelés

```bash
swift test --no-parallel
./build.sh
```

Az `./build.sh` Universal appot, DMG-t, CLI ZIP-et és
`SHA256SUMS.txt`-t készít a `build/` mappában, de **nem telepít semmit**.

Explicit helyi telepítés:

```bash
scripts/install-local.sh
```

Ha már van `/Applications/AstroTool.app`, a telepítő előbb időbélyeges
backupba mozgatja a `/private/tmp` alatt. A publikus, aláírt és notarizált
csomagot a `scripts/release.sh` készíti, érvényes Apple hitelesítő adatokkal.

## Fejlesztés

- Swift 6 / Swift Package Manager
- SwiftUI + Observation
- SQLite
- minimum macOS 26
- `AstroCore`, `AstroToolApp` és `astrotool` termékek

A változtatásokhoz kérünk tesztet, különösen fájlművelet, migráció,
adatvédelem és kiadási csomagolás esetén.

## Licenc

[MIT](LICENSE)
