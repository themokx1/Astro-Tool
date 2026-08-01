# Astro-Tool — projekt brief / indító prompt

> Ezt a fájlt add oda egy új Claude Code sessionnek a `~/PhpstormProjects/Astro-Tool`
> mappában (pl. „Olvasd el a PROMPT.md-t és kezdjük"), vagy másold be a tartalmát.

---

## Mit építünk

Egy **macOS app + CLI motor**, ami az asztrofotós képkönyvtáramat tartja karban:
felderíti a rendetlenséget, pontozza a light frame-eket, nyilvántartja az
integrációs időket, és megmondja, mi hiányzik a kalibrációs könyvtárból.
**Semmit nem töröl** — csak *jelöl* és *javasol*.

A repo már létezik és üres: **https://github.com/themokx1/Astro-Tool**
(lokálisan: `~/PhpstormProjects/Astro-Tool`, `main` branch, a `themokx1` GitHub
fiókkal van bejelentkezve a `gh`, van write jog.)

---

## ⛔ Vasszabályok

1. **SOHA ne törölj semmilyen fájlt vagy mappát a képkönyvtárban.** Se `rm`, se
   `trashItem`, se „takarítás". A tool **kizárólag jelöl**: listát/riportot ír,
   és legfeljebb *javaslatot* generál (pl. egy `.sh` scriptet, amit **én** futtatok,
   ha akarok). Ez a legfontosabb követelmény — ezek pótolhatatlan felvételek.
2. Írási művelet a könyvtárban csak kettő megengedett, és mindkettő additív:
   új (üres) mappák létrehozása új sessionhöz, és a tool saját riport/DB fájljai
   egy **dedikált mappában** (pl. `<ROOT>/.astro_tool/`).
3. **Ne találgass a szabályokról** — a lenti konvenciók a mérvadóak. Ha valami
   nem egyértelmű, kérdezz, ne döntsd el helyettem.
4. Ami nincs leellenőrizve, azt ne állítsd késznek. Ha nem tudtál valamit
   verifikálni (pl. engedély hiánya miatt), mondd ki nyíltan.

---

## A könyvtár — ground truth

**Gyökér:** `/Volumes/images/Astro` (külső APFS kötet, ~530 GB).
A gyökérben van a `add_new_session.sh` is: `/Volumes/images/add_new_session.sh` —
**ez definiálja a kanonikus struktúrát**, olvasd el először.

### Kanonikus elrendezés (a scriptből)

```
<ROOT>/
  sessions/<TARGET>/<YYYY-MM-DD>/{lights,flats,darks,biases}   + README.txt
  stacks/<TARGET>/<YYYY-MM-DD>/
  processed/<TARGET>/<YYYY-MM-DD>/
  calibration_library/{darks,flats,biases}/
```

- `sessions/` = **csak RAW adat**, soha nem felülírni, nem keverni
- `calibration_library/` = újrahasznosítható masterek (duplikátum kerülendő)
- `stacks/` = stackelési kimenetek (újra előállítható)
- `processed/` = végleges szerkesztés/export

**`<TARGET>` képzése:** `sanitize(<katalógus>)_sanitize(<név>)`
→ pl. `IC1805-1848_Heart-and-Soul_Nebula`, `NGC2237_Rosette_Nebula`, `M45_Pleiades`.
A `sanitize()`: szóköz → `_`, csak `[A-Za-z0-9._-]` marad, több `_` összevonva, trimmelve.

**`<DATE>`:** szigorúan `YYYY-MM-DD`, valós naptári dátum.

**Kalibrációs masterek névkonvenciója** (a `calibration_library/darks/` alatt látható):
`<expozíció>sec_<hőmérséklet>deg` → `60sec_-10deg`, `120sec_-20deg`, `6.8sec_-10deg`, `5.5sec_-10deg`.
A `flats/` és `biases/` alatt jelenleg nincs ilyen alábontás.

**A README.txt sablon mezői** (session-mappában): Camera, Sensor temp, Gain/Offset,
Exposure (lights), Filter, Optics, Mount, Guiding, Total integration, Location/Bortle,
Notes/issues. Ezt a tool tudja olvasni (metaadat-forrás) és generálni.

### Fájltípusok a könyvtárban

| Kiterjesztés | Db | Jelentés |
|---|---|---|
| `.fit` / `.fits` | ~2550 | FITS light/calibration frame (fő formátum) |
| `.fz` | ~3050 | Rice-tömörített FITS (ASIAIR) |
| `.cr3` | ~1550 | Canon RAW — jellemzően **wide field** |
| `.tif` | ~880 | export/köztes |
| `.png` | ~855 | riport-asset, preview |
| `.xmp` | ~315 | Lightroom sidecar |
| `.seq`, `.lst` | ~1200 | **Siril sequence / list — stackelési maradvány** |

Méretek: `sessions` 281 G · `stacks` 216 G · `processed` 30 G ·
`calibration_library` 5.8 G · `tools` 6.9 G.

### Amit NE bántson / NE indexeljen

- `<ROOT>/tools/` — külső programok (setiastro/CosmicClarity, StarNet, sirilic,
  syqon, Nastronomy, saját `rate` és `Fixes` scriptek). **13 191 fájl, tele
  `.fits` tesztadattal** (pl. `tools/setiastro/.../astropy/io/fits/tests/data/*.fits`).
  Ha ezt beindexeled, az összes statisztika hamis lesz. **Zárd ki alapból.**
- A kötet gyökerében (`/Volumes/images/`, tehát az `Astro`-n kívül) van:
  `.astro_audit_reports/`, `.astro_audit_state/`, `.astro_quarantine/` — egy
  **korábbi audit tool** nyomai. Olvasd el őket (read-only), tanulj belőlük,
  de a saját state-edet az új helyre írd.

---

## Valódi rendetlenség a könyvtárban — ezek a teszteseteid

Ezeket **én találtam a te tényleges fádban**; a toolnak mindet fel kell ismernie:

**Elrontott / duplikált célpont-mappák**
- `stacks/Please_enter_a_value.._Milkyway/` ← a script promptja üresen maradt,
  a szemét bekerült mappanévnek. Van mellette `M_Milky_Way/` is ugyanarra.
- `R3_C2025/` **és** `C2025_R3_C2025_R3_Panstarrs/` **és**
  `C2025_R3_C2025_R3_Panstarrs_Wide/` — ugyanaz az üstökös 3 néven, ráadásul a
  katalógusnév duplán van benne (`C2025_R3_` + `C2025_R3_`).
- `M42_Orion/`, `M42_Orion_Nebula/`, `M42_Orion_wide_field/`,
  `M42_Orion_Wide_Field_70MM/` — egy célpont 4 mappában, kisbetű/nagybetű eltéréssel.
- `calibration_library/biases/` **és** `calibration_library/bias/` — a script
  `biases`-t hoz létre, a `bias` árva.

**Szabálytalan dátum-mappák**
- suffix: `2026-04-06-2`, `2026-04-06-3`, `2026-05-24-2`
- tartomány: `2026-02-25_2026-03-15`, `2026-04-18-2026-04-19`
- címke: `2026-03-15-OSC`, `2026-03-15_hibas` (a „hibás" = általam rossznak jelölt)

**Nem kanonikus, beágyazott struktúra**
- `stacks/M42_Orion/2026-01-17/sessions/session1/{lights,flats}` ← egy teljes
  session-fa a `stacks/` alatt
- `stacks/M42_Orion/2026-01-17/collected_lights/`
- `stacks/M_Milky_Way/2026-04-19/paneled_mosaic_process/lights/`
- `stacks/NGC2237_Rosette_Nebula/light_frame_rating_report_assets/` ← célpont
  szinten, dátum-mappa nélkül (máshol dátum alatt van)

**Hiányzó párok** (session ↔ stack ↔ processed nincs szinkronban)
- `stacks/NGC_7000.../2026-06-06` és `2026-06-29`, de sessionben csak `2026-05-23`
- `processed/NGC2237.../2026-05-29`, `2026-07-01`, `2026-06-16` — se session, se stack
- `sessions/IC1805-1848_.../2026-01-17` — nincs hozzá stack

> Fontos: ezek egy része **szándékos** lehet (pl. `-2` = második futás, `_hibas`
> = szándékos jelölés, dátum-tartomány = több éjszaka együtt stackelve). A tool
> **ne javítson automatikusan** — sorolja be: *biztos hiba* / *gyanús* / *valószínűleg
> szándékos*, és kérdezzen, vagy adjon konfigurálható szabályt.

---

## Funkciók

### 1. Takarítás-jelölő (nem törlő!)
Tetszőleges mélységben, egy megadott almappa alatt is:
- Siril-maradványok: `.seq`, `.lst`, `*_conv*`, `*_bkg*`, `*_pp_*`, `r_*`, `bkg_*`,
  registrált/kalibrált köztes sorozatok, `process/` mappák
- átmeneti fájlok: `.DS_Store`, `tmp`, `Stack tmp`, félbehagyott export
- **duplikátumok** (azonos tartalom több helyen — hash-alapon, méret-előszűréssel)
- kimenet: riport + opcionális **javasolt** parancsfájl, amit én futtatok

### 2. Rendszerezés-audit
- eltérés a kanonikus elrendezéstől (lásd fent), súlyozva
- célpont-név duplikátumok/hasonlóságok felismerése (`M42_Orion*` család)
- árva mappák, hiányzó `session ↔ stack ↔ processed` párok
- **javasolt** átnevezés/áthelyezés (végrehajtás csak az én jóváhagyásommal)

### 3. Light frame minőség-pontozás (Siril CLI)
- **Siril 1.4.4 telepítve:** `/Applications/Siril.app/Contents/MacOS/siril-cli`
  (⚠️ **nincs PATH-on**, teljes útvonallal hívd; a `-s -` script-módot használd)
- metrikák: FWHM, roundness, csillagszám, háttér, gradiens/felhő, trailing
- normalizált pontszám célpontonként/sessionönként + **kiugróan rossz** frame-ek
  megjelölése (küszöb legyen konfigurálható, ne beégetve)
- ⚠️ Van már egy korábbi rating tool a `tools/rate/`-ben, és a kimenetei
  (`light_frame_rating_report_assets/`) ott vannak a `stacks/` alatt — **nézd meg,
  mit csinált**, és vagy építs rá, vagy tudatosan váltsd ki (mondd meg, melyik).
- **Teljesítmény számít:** ~5000 fájl / 281 GB külső lemezen. Kell cache
  (fájl-hash/mtime alapú), inkrementális futás, párhuzamosítás — de a lemez
  I/O-ra vigyázva.

### 4. Adatbázis + statisztika
Egy lokális DB (SQLite javasolt) a `<ROOT>/.astro_tool/` alatt:
- célpontonként: összes integrációs idő, sessionök száma/dátumai, frame-hosszak
  (pl. 60 s × 120 db), szűrő, gain/offset, hőmérséklet, kamera, optika
- forrás: **FITS header** (elsődleges), `README.txt`, mappanevek (fallback)
- lekérdezhető: „mennyi összidőm van M42-re", „mikor fotóztam utoljára X-et",
  „melyik célponthoz kell még adat"
- **deep sky vs wide field szétválasztás** — heurisztika: wide field jellemzően
  `.cr3`/`.tif`, rövidebb gyújtótáv (FITS `FOCALLEN`), mappanévben `wide`; a
  szabály legyen konfigurálható és felülbírálható

### 5. Kalibrációs könyvtár
- mi van meg: dark/flat/bias masterek `<exp>sec_<temp>deg` bontásban
- **mi hiányzik**: melyik lighthoz (exp/temp/gain kombináció) nincs megfelelő dark
- lejárat/elévülés jelzése (pl. „ez a dark 8 hónapos")
- konkrét teendő-lista: „készíts 300 s / −10 °C darkot"

### 6. Session-párosítás
- adott célpont adott éjszakájához keresse meg a hozzá tartozó
  **flat / dark / flat-dark / bias** felvételeket (dátum + FITS header alapján)
- jelezze, ha **rossz mappában** van (pl. flat a `lights/`-ban, vagy másik
  célpont alá keveredett), és javasoljon helyet

### 7. Új session létrehozása
- az `add_new_session.sh` **logikájának pontos megtartásával** (ugyanaz a
  `sanitize`, dátumellenőrzés, mappaszerkezet, README sablon), de a GUI-ból
- meglévő célpont felajánlása autocomplete-tel (ne szülessen 5. `M42_Orion*`)

### 8. Konfiguráció
Minden szabály állítható (GUI + JSON fájl): gyökér útvonal, kizárt mappák
(`tools/` alapból), minőségi küszöbök, wide-field szabály, maradvány-minták,
kalibráció elévülési ideje, dátum-formátum kivételek.

---

## Tech stack és szállítandók

Ugyanaz a felállás, mint a `themokx1/HDRHeic` projektemnél (nézd meg mintaként,
ha elérhető) — **natív, függőség-minimalizált**:

- **Motor:** Swift CLI (`astrotool`), alparancsokkal (`scan`, `audit`, `rate`,
  `stats`, `new-session`, `config`). Gépi olvasható kimenet (JSON) a GUI-nak.
- **App:** natív **SwiftUI** macOS app, rendes UI-jal — nem AppleScript.
  Egy ablak, több fül/szekció (Áttekintés / Audit / Minőség / Kalibráció /
  Statisztika / Beállítások). Táblázatok, szűrés, progressz hosszú futásokhoz.
  Ikon is kell.
- **Csomagolás:** `build.sh`, ami buildel + **DMG**-t gyárt (drag-to-Applications),
  és a CLI-t symlinkeli `~/.local/bin`-be.
- **CI:** GitHub Actions — `v*` tagre buildel és **Release-t publikál** (DMG + zip).
- **GitHub Pages:** `docs/` alól letöltő oldal (favicon + OG link-előnézeti kártya),
  a Download gomb a `releases/latest`-re mutasson.
- **LICENSE** (MIT), **CHANGELOG.md**, rendes **README**.
- Ne notarizáljunk (nincs Apple Developer fiók) — a README mondja meg a
  jobbklikk → Open lépést.

**Környezet:** macOS 26.5, Apple Silicon, Xcode/Swift 6.3 elérhető.
⚠️ A `/Volumes/images` külső kötet — a **TCC** megtagadhatja a hozzáférést egy
programtól, amíg nem kap „Teljes lemez-hozzáférés"/„Cserélhető kötetek"
engedélyt (és az engedély csak a folyamat újraindítása után él). Ezt kezelje
le az app értelmes hibaüzenettel, ne csak néma nullát mutasson.

---

## Hogyan dolgozz

1. **Előbb kérdezz, aztán tervezz, csak utána kódolj.** Ez sok apró döntést
   tartalmaz (mi számít „hibásnak", mi a rossz minőség küszöbe, mennyire legyen
   agresszív a duplikátum-felismerés) — ezeket beszéljük át.
2. **Olvasd el** a `/Volumes/images/add_new_session.sh`-t és nézd meg a
   `tools/rate/`, `tools/Fixes/`, `tools/zoli/` tartalmát (read-only), mielőtt
   bármit terveznél — lehet, hogy fél munkát már megcsináltam.
3. **Először read-only, dry-run mindenre.** Az első használható mérföldkő egy
   *riport*, ami megmutatja, mit talált — nulla írás a könyvtárban.
4. **Kis lépések, valódi ellenőrzés.** A könyvtár nagy és lassú (külső lemez):
   dolgozz egy szűk almintán, amíg a logika nem stabil.
5. Verzió-/commit-fegyelem: ticket-szerű commitok, minden lépés után push.

## Amit tisztázzunk az elején

- Mi számít nálam „szándékos" eltérésnek (`-2` suffix, `_hibas`, dátum-tartomány)?
- A `M42_Orion*` négyes közül melyik a helyes, és össze akarom-e vonni?
- A `Please_enter_a_value.._Milkyway` átnevezhető-e `M_Milky_Way`-re?
- Milyen kamerá(k), gain/offset, tipikus expók? (a kalibrációs hiánylistához)
- A `tools/` teljesen kizárható-e az indexelésből?
- Kell-e a `/Volumes/images/` egyéb mappáit is nézni (`ASI AIR/`, `Átnézni/`,
  `Stack tmp /`, `tmp/`), vagy csak az `Astro/`-t?
