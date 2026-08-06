# UX + termék-review — R9

**Dátum:** 2026-08-05
**Tárgy:** IA-redesign, hiányzó funkciók, build-terv

---

# Astro-Tool — R9 review: UI információs-architektúra + hiányzó funkciók

## Ground truth (a valós könyvtáron mérve, read-only)

| Mérés | Érték | Miért fontos |
|---|---|---|
| files / célpont / session | 14 675 / **12** / 36 | 12 célpont → sidebar-navigáció ideális; a mostani 8-kolonnás tábla túltervezett |
| legutóbbi audit (run 12) | 3 627 találat: **3 198 residue**, 324 duplicate-content, **41 sure_error** | az Áttekintés „Gyanús: 3 545" badge 88%-ban `.DS_Store` + Siril-köztes fájl |
| findings tábla összesen | 32 074 sor / 12 run, **soha nem takarítva** | DB-hízás |
| `tags` tábla | **0 sor** | a Statisztika egy teljes kolonnát (≈200pt) szentel egy sosem használt funkciónak |
| `session_notes` | 119 sor, **7 kulcs, mind `new-session` boilerplate** (`Target folder`, `Catalog prefix`, `Created at`…) | a „kereshető éjszaka-napló" (R6-4) **valós adat nélkül** van: nincs Bortle, SQM, seeing, semmi |
| `ratings` | 732 / 9 308 FITS = **7,9%** | a pontozás gyakorlatilag nincs használva |
| `config.json` | **nem létezik** | minden default; `site` üres → a Tervező a FITS-fejlécekre támaszkodik, láthatatlanul |
| NGC2237 | 8 967 fájl / 13 session = a könyvtár 61%-a | egy domináns projekt — a „célpont-részletek" oldal a legfontosabb felület |
| tesztek | **808 `@Test`, mind `AstroCore`** (`Package.swift`: a testTarget csak `AstroCore`-ra függ) | **nulla app-layer teszt → a teljes UI-átépítés zéró teszt-kockázat** |

### macOS-konvenció audit (grep, `Sources/AstroToolApp/`)

`contextMenu: 0` · `.commands/CommandGroup: 0` · `Settings(scene): 0` · `.searchable: 0` · `onDrop/draggable: 0` · `NavigationSplitView: 0` · `refreshable: 0` · `toolbar: 1` (csak MonthPlanSheet) · `ContentUnavailableView: 2` (csak MonthPlanSheet) · `keyboardShortcut: 6` (mind `.defaultAction` sheetekben).

**Nincs menüsáv, nincs egyetlen jobb-klikk menü, nincs egyetlen gyorsbillentyű, a Beállítások egy TAB a ⌘, Settings scene helyett, és minden empty state egy szürke `Text`.** Ez nem „hiányos", ez a platform-konvenció teljes megkerülése.

### Hét konkrét defekt, ami a redesignt vezérli

1. **BLOCKER — `AccessDeniedView`-nak nincs mappaválasztója.** `.notMounted` esetén csak „Újrapróbálás" van (`AccessDeniedView.swift:38-47`). Ez a tesztelő zsákutcája: ha a bookmark egy lecsatolt kötetre mutat, **az appból nincs kiút**.
2. `AppState.loadPlan()` **mutálja** `config.site`-ot (`AppState.swift:651`), majd a Settings→Mentés csendben perzisztálja az automatikusan detektált helyszínt véglegesen.
3. A cél (`goal`) egy mágikus **`goal:Xh` címke** (`GoalTag.parse`). Nincs UI, ami említené → 0 címke a DB-ben → a „Hiányzik" kolonna és a `ProjectState.missingSeconds` **örökre `—`**.
4. `CalibNeed.kind` / `.requiredGain` / `.requiredCamera` ki van számolva, de **nincs megjelenítve** — a Lefedettség táblában nem lehet megállapítani, hogy egy sor dark vagy flat.
5. `session_notes` írás nincs → a `search` (CLI-only) csak boilerplate-et találhat.
6. `site.latitudeDeg/longitudeDeg` **sehol nem szerkeszthető a GUI-ban**, pedig az egész Tervező ezen áll. Egy csak-Canon-CR3 kezdő nem kap tervet, és nem tudja megjavítani.
7. Settings: **7 kulcs szerkeszthető a ~40-ből**. Hiányzik a `rating.weights` (maga a pontozási modell!), az `expose.*`, a `stats.*`, a `calib.match*`, a `residuePatterns`.

---

# A) UI információs-architektúra újratervezés

## A.0 Váz

```swift
WindowGroup { RootView() }.frame(minWidth: 1100, minHeight: 700)
Settings { SettingsWindow() }          // ⌘, standard scene
.commands { AstroToolCommands() }
```

`RootView` = `NavigationSplitView(sidebar:detail:)`, sidebar `.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)`.
A `TabView` és az `AppTab` enum megszűnik; helyette `enum Page: Hashable { tonight, calendar, allTargets, target(String), calibration, audit, cleanup, sensor, searchResults }`.

**Ablak-toolbar** (a detail kolonnán, minden oldalon):
- `principal`: `Menu` a gyökér utolsó path-komponensével címkézve (pl. „Astro") → `Mappa választása…` / `Legutóbbi könyvtárak ▸` / — / `Megnyitás Finderben` / `config.json megjelenítése`
- `primaryAction`: **`Beolvasás`** (`arrow.clockwise`, ⌘R). Foglaltság alatt `ProgressView` + `progressText` + `Mégse`. Mellette caption: „Utolsó: 2 órával ezelőtt" (relatív, `runs` tábla).
- `+` `Menu` → `Új session…` (⌘N)
- `ellipsis.circle` `Menu` → batch műveletek (lásd B17)

**Sidebar** `.searchable(text: $query, placement: .sidebar, prompt: "Célpont, session, fájl, jegyzet")` — ⌘F fókuszál.

```
┌ (nincs fejléc)
│  🌙 Ma este                      [3]
│  📅 Naptár
├ KÖNYVTÁR
│  ▦ Minden célpont                [12]
│  ● NGC 7000 · Észak-Amerika-köd        ← fázis-pont (4px kör)
│  ● NGC 2237 · Rozetta-köd
│  … (mind, rendezés: fázis, majd utolsó session desc)
├ ÁLLAPOT
│  🌡 Kalibráció                    [3]  ← piros, ha van „hiányzik"
│  🛡 Audit                         [41] ← piros, CSAK sure_error
│  🗑 Takarítás                     [12,4 GB]
├ ESZKÖZÖK
│  ⚙ Szenzor-profilok              [1]
```
Badge csak `> 0` esetén. Fázis-pont színek: gyűjtés=kék, stackelhető=sárga, feldolgozásra vár=narancs, kész=zöld; tooltip = fázis-címke. A „Beállítások" tab és a redundáns „Ugrás" box **megszűnik**.

## A.1 Ma este

`Picker(.segmented)`: `Ma este` | `Következő 30 éjszaka`.

**Azonnal látszik — 4 tile:**
| Tile | Tartalom | Megjegyzés |
|---|---|---|
| Sötét idő | „6,2 óra" | **ma nincs sehol** megjelenítve, csak a havi nézetben |
| Hold | „34% · felkel 23:41" | |
| Ajánlott | `verdict == "ma jó"` darabszám | |
| Helyszín | „47,50° N 19,04° E" + caption „FITS-fejlécekből" \| „kézzel beállítva" | klikk → Settings ▸ Helyszín. **Ez teszi láthatóvá a láthatatlan configot.** |

**Tábla** (`Table`, sortolható, `score` desc):
`Célpont` (displayName bold + folder caption, min 200) · `Állapot` (fázis-chip, 130) · `Integráció` (h:mm, 90) · `Cél` (h:mm vagy `Cél beállítása…` link, 110) · `Hiányzik` (h:mm, piros ha >0, 90) · `Kulminál` (`culminationLocal`, 80) · `Max. mag.` (`maxAltitudeDeg` „62°", 80) · `Látható` (`visibleWindowLocal` + „(7,3 ó)", 150) · `Hold` (`moonIlluminationPercent` + „· 78°" szeparáció, 110) · `Döntés` (verdict-chip, 140).

**Sor context menu:** `Célpont megnyitása` ⏎ · `Cél beállítása…` (popover: óra-stepper → `goal:Xh` címke) · `Plate-solve…` (csak `raDeg == nil`) · — · `Éjszaka-riport a legutóbbi sessionről` · `Célpont-riport` · — · `Mappa megnyitása Finderben`

**Empty states:**
- 0 célpont: `ContentUnavailableView("Még nincs célpont", systemImage: "moon.stars", description: Text("Olvasd be a könyvtárat, vagy hozz létre egy új sessiont."))` + `Beolvasás` / `Új session…`
- 0 koordináta: ugyanaz, description „Egyik célpontnak sincs koordinátája." + `Plate-solve mindenre…`
- nincs helyszín: sárga inline banner a tábla felett — „Nincs megfigyelési helyszín beállítva — a magasság/kulmináció a FITS-fejlécekből becsült. **[Beállítás…]**"

**Következő 30 éjszaka** (`Table`, a mostani `List` helyett): `Dátum` (hétköznap + dátum; az első kettő „Ma"/„Holnap", 130) · `Sötét` (`astroDarkHours`; `note` narancs captionként ha nil, 90) · `Hold` (kis kitöltött kör-glif + „34%", 100) · `Legjobb 3 célpont` (flexibilis) · ▲ zöld marker (a mostani `isHighlighted`, 30).
Sor context menu: **`Terv erre az éjszakára`** → az Ma este szegmens újraszámolása erre a dátumra (ez teszi elérhetővé a `plan --date`-et, ma CLI-only).

## A.2 Minden célpont

A mostani Statisztika. **A `Műveletek` kolonna teljesen megszűnik** → minden context menube kerül. A `Címkék` kolonna read-only chipekre szűkül (0 valós használat).

**4 tile:** `Célpontok` 12 · `Sessionök` 36 · `Összes integráció` 128:40 · `Kész / folyamatban` 3 / 9

**Kolonnák:** `Célpont / Session` (mint ma, min 240) · **`Fázis`** (fázis-chip, csak target sor — ma csak az Áttekintésen van, 130) · `Integráció` (90) · `Cél` (80) · `Keretek` (mint ma, min 140) · `Expozíciók / Utolsó dátum` (min 140) · `Kamera` (min 100) · `Részletek` (min 140) · **`Stackek`** („3 csoport", 90) · `Címkék` (read-only, min 100).
A `.stacksSummary` gyerek-sor **törlendő** (duplikálja az új Stackek kolonnát). Dupla-klikk → Célpont-részletek. Toolbar: `Újraszámolás`.

**Target sor context menu**
```
Megnyitás                        ⏎
Megnyitás Finderben
─────
Cél beállítása…                  (popover: óra-stepper)
Címke hozzáadása…
Címke eltávolítása            ▸  (a meglévők submenuja)
─────
Kész stackek…                    (csak ha van stack)
Mozaik-panelek…                  (csak ha isMosaic)
Plate-solve…                     (csak ha raDeg == nil)
─────
Exportálás                    ▸  AstroBin CSV / CSV / Markdown
Célpont-riport készítése
```
**Session sor context menu**
```
Megnyitás Finderben
─────
Kalibráció linkelése…
Stackelés előkészítése…          ← átnevezve „Stack-lista…"-ról
─────
Keretek pontozása
Éjszaka-riport készítése
Éjszaka-jegyzet szerkesztése…    ← ÚJ (B4)
```
**Empty states:** beolvasva de 0 célpont → `ContentUnavailableView("Nincs célpont a könyvtárban", systemImage: "square.grid.2x2", description: Text("A beolvasás nem talált sessions/<célpont>/<dátum>/ struktúrát."))` + `Mappa választása…` / `Új session…` / `Mappastruktúra súgó`. Keresés nulla találat → `ContentUnavailableView.search(text: query)`.

## A.3 Célpont-részletek — **a legértékesebb új oldal**

Beolvasztja a teljes Minőség tabot, és feleslegessé teszi a target-report HTML-t képernyőn.

**Fix fejléc (nem gördül), 3 sor:**
- **1.** `NGC 7000 · Észak-Amerika-köd` (title2 bold) · folder caption · `wide-field` badge · fázis-chip · trailing: `Riport…` Menu + `Exportálás…` Menu
- **2.** 5 tile: `Valós integráció` 12:40 / caption „bruttó 18:05" · `Cél` 20:00 + inline ✏️ popover (nil → „Nincs cél · Beállítás") · `Hiányzik` 7:20 (narancs) · `Sessionök` 4 / caption „2026-05-29 → 2026-08-01" · `Legjobb session` „2026-06-12 · FWHM 2,31″"
- **3.** `Következő lépés:` + `todos.first` mondatként, mellette akció-gomb ahol leképezhető (flat-hiány → `Kalibráció linkelése…`). Disclosure: „További 3 teendő".

**Belső `Picker(.segmented)`:** `Áttekintés` · `Sessionök` · `Minőség` · `Stackek` · `Jegyzetek`

- **Áttekintés** — Koordináták blokk (RA/Dec h m s + fok, forrás: „WCS fejléc" / „plate-solve" / „nincs" + `Plate-solve…` gomb) · Setup-ujjlenyomat (kamera / fókusz / gain / szűrő, egy sor per eltérő setup + session-szám) · a célpont mai láthatósága (ugyanaz a sor, mint a Ma este táblában) · **Expozíció-tanácsadó** (ide kerül a Minőség tabról — célpont-specifikus): `advice` minden sora bulletként; `notAvailableReason` őszinte szürke jegyzetként + `Szenzor mérése…` gomb ha a profil hiányzik · Mozaik-panel tábla inline (nem popover) ha `isMosaic` · a célpontra szűrt kalibráció-státusz.
- **Sessionök** — `Table`: `Dátum` · `Keretek` · `Integráció` · `Expozíciók` · `FWHM″` · `Háttér e⁻/s/″²` · `Rang` (chip) · `Hűtés` · `Fókusz` · `README`. Sor kiválasztásra **inline detail-sáv** a tábla alatt: az idővonal-sor („Ablak 3:42 · integráció 2:11 · hatékonyság 59% · 2 kiesés (37m, 12m)") **+ vízszintes idővonal-sáv** (100% széles, kitöltött szegmensek = keretek, szürke kiesések perc-címkével — az éjszaka-riport HTML koncepciójának újrahasznosítása) + hardver-egészség sor + README-jegyzetek. Context menu = az A.2 session-menü.
- **Minőség** — a mostani 10-kolonnás keret-`Table` változatlanul. **A vezérlősáv átépítve:** egyetlen primary `Keretek pontozása` gomb `Menu`-chevronnal → `Újra minden keret mérése (lassú)` (= `--force`), `Siril nélkül (csak natív)` (= `--no-siril`, ma GUI-ból elérhetetlen). A szabadszöveges dátum-`TextField` helyett `Menu` a célpont session-dátumaival + `Minden session`. A tábla felett a summary sor **+ pontszám-hisztogram** (10 bucket), hogy „melyik keret rossz" sortolás nélkül látszódjon. Keret-sor context menu: `Megnyitás` · `Finderben` · `Quick Look` (Space).
- **Stackek** — a mostani `StackGroupSheet` tartalma **oldalba ágyazva** (nem sheet), + thumbnail-kolonna (B7). Toolbar: `Stackelés előkészítése…`.
- **Jegyzetek** — session-enkénti jegyzetek, **szerkeszthetően** (B4). Alul „Riportok": minden generált HTML ehhez a célponthoz `.astro_tool/reports/`-ból, `Megnyitás` / `Finderben` / `Újragenerálás`.

**Empty states:** 0 session → `ContentUnavailableView("Nincs session ehhez a célponthoz")`. Minőség 0 rating → `ContentUnavailableView("Nincsenek pontozott keretek", systemImage: "star", description: Text("Futtass pontozást a FWHM / kerekség / csillagszám metrikákhoz."))` + a gomb. Stackek üres → „Nincs kész stack" + hol keresi.

## A.4 Kalibráció

`Picker(.segmented)`: `Lefedettség` | `Egészség`. (A Szenzor önálló oldalra kerül.)
**4 tile:** `Hiányzó` N (piros) · `Elavult` N (narancs) · `Friss` N (zöld) · `Master darkok` N

- **Lefedettség** — a `Teendők` **felülre** kerül, akció-kártyaként (`Linkelés…` gombbal ahol értelmes). Alatta a tábla, **három új kolonnával a modellből, amit ma nem jelenítünk meg**: `Típus` (`CalibNeed.kind`) · `Gain` (`requiredGain`) · `Kamera` (`requiredCamera`). Teljes kolonna-lista: `Típus` / `Exp. (s)` / `Hőm. (°C)` / `Gain` / `Kamera` / `Light-ok` / `Master` / `Kor (nap)` / `Állapot` / `Megjegyzés`.
  Context menu: `Kalibráció linkelése…` · `Master mappa megnyitása Finderben` · `Érintett sessionök megjelenítése`
- **Egészség** — a három `DisclosureGroup` mint ma, de a fejlécben státusz-bontás („Flat-fegyelem — 2 hibás / 34 rendben"), és minden problémás sorra `Megnyitás Finderben` context menu.
- **Egyetlen `Újraszámolás`** a page-toolbaron (a mostani három azonos „Frissítés" helyett).

## A.5 Audit — **a rettegett szám átkeretezése**

`Picker(.segmented)`: `Hibák (41)` | `Gyanús (347)` | `Takarítható (3 198 · 12,4 GB)`

Definíció: `Takarítható` = a `CleanupSummary` csoportok + `duplicate-content`. `Gyanús` = suspicious **mínusz** residue **mínusz** duplicate-content. `Hibák` = sureError.
**Ez a review legfontosabb egyetlen változtatása:** a residue kilép a „gyanús" vödörből és „takarítható"-vá válik — a félelmetes 3 545-ből 347 valódi gyanú és 12,4 GB visszanyerhető hely lesz.

**4 tile:** `Biztos hiba` 41 (piros) · `Gyanús` 347 (sárga) · `Takarítható` 12,4 GB (kék) · `Szándékos` 35 (szürke)

- **Hibák / Gyanús** — a mostani csoportosított `DisclosureGroup` lista, de: minden csoport-fejléc kap egy `⋯` menüt (`Csoport megjelölése rendben lévőként` → B5, `Első fájl megnyitása Finderben`, `Összes útvonal másolása`); a szabadszöveges `Kategória szűrő` **többválasztós `Menu`** lesz a tényleg jelen lévő kategóriákkal + darabszámmal; toolbar-toggle `Rendben-jelöltek megjelenítése`.
- **Takarítható** — `Table`: `Kategória` / `Fájlok` / `Méret`, kinyitva a `paths` lista + „…további N" sor. Toolbar: `Karantén-script (takarítható)…` + `Limit` stepper (= `cleanup --limit`, ma GUI-ból elérhetetlen). **Állandó magyarázó banner:** „A script `mv`-vel karanténba mozgat, soha nem töröl. A karantént te ürítesz ki kézzel." — a Vasszabály látható helyre való, nem a README-be.
- Toolbar: `Audit futtatása` Menu-with-primary-action → menüben `Duplikátum-keresés nélkül (gyors)` (= `--no-duplicates`).
- A két script **egy `Script…` menübe**, megkülönböztető nevekkel: `Javító script (hibák)…` és `Karantén-script (takarítható)…`.

**Empty states:** nincs eredmény → `ContentUnavailableView("Nincs audit-eredmény", systemImage: "checkmark.shield", description: Text("Futtass auditot az elrontott mappanevek, félrekerült kalibráció és duplikátumok megtalálásához."))` + gomb. Minden rendben → zöld `ContentUnavailableView("Minden rendben", systemImage: "checkmark.seal.fill")`.

## A.6 Szenzor-profilok (önálló oldal — a mérés kiásása)

**3 tile:** `Profilok` 1 · `Kamerák` 1 · `Legutóbbi mérés` 2026-08-05
A mostani tábla + `Mért` (dátum) kolonna + **`Frissesség` figyelmeztetés**: sárga sor + „Újramérés javasolt — a leolvasási zaj becslő javult a 0.7.0-ban" azoknál a profiloknál, amik a fix előttiek (a CHANGELOG `[Unreleased]` „re-measure needed" TODO-ja megérdemel egy UI-jelet).
Primary toolbar: **`Szenzor mérése…`** → confirm sheet: mit tesz, meddig tart, mit olvas (`calibration_library` bias/dark), és hogy **csak egy DB-sort ír**.
**Állandó magyarázó blokk a tábla felett:** „Mire jó? A mért bias-szint, leolvasási zaj és dark-áram nélkül az Expozíció-tanácsadó és a valós égi háttér (e⁻/s/″²) nem számolható." — összekapcsolja ezt az eltemetett oldalt azzal a funkcióval, ami rá épül.
Empty: `ContentUnavailableView("Még nincs mért szenzor-profil", systemImage: "cpu", description: <a fenti szöveg>)` + a gomb.

## A.7 Settings (⌘, standard scene, belső `TabView`)

| Tab | Kulcsok |
|---|---|
| **Könyvtár** | `rootPath` + `Mappa választása…` + legutóbbi gyökerek + `config.json megjelenítése`; `excludedDirNames` és `excludedPaths` **szerkeszthető `List`-ként (+/−)**, nem vesszős stringként |
| **Helyszín** ← ÚJ | `Szélesség (°)` / `Hosszúság (°)`; `Használat` picker: `Automatikus (FITS-fejlécekből)` \| `Kézi`. Automatikus módban read-only, a feloldott értékkel + caption „a könyvtár SITELAT/SITELONG mediánja". `Beillesztés a vágólapról` („47.5000, 19.0400"). Magyarázat: „Ez határozza meg a kulminációt, a magasságot és a csillagászati szürkületet a Ma este oldalon." |
| **Kalibráció** | `darkMaxAgeMonths`, `tempToleranceC`, `exposureToleranceS`, `exposureToleranceFraction`, `coolerToleranceC`, `flatMaxAgeDays`, `rotatorToleranceDeg`, `gainTolerance` + a négy `match*` toggle. Mindegyik egysoros captionnel. |
| **Pontozás & expozíció** | `outlierZScore`, `workers`, `sirilPath` + `Tallózás…` + **élő zöld/piros „Siril megtalálva (1.4.0) / nem található" indikátor**; a négy `rating.weights` **sliderként, mindig 1,00-ra normalizálva** (%-kal); `expose.maxSubSeconds`, `expose.noiseContributionC` |
| **Könyvtár-szabályok** | `residuePatterns`, `residueDirNames`, `toolOutputDirNames`, `intentional.labels` + 2 toggle, `wideField.*`, `stats.excludeLabels`, `stats.gapThresholdSeconds` (caption: „0 = automatikus, 3× a medián expozíció"), `stats.collectingThresholdSeconds` |

Minden sor: trailing `↺` **csak akkor látszik, ha az érték eltér a beépített defaulttól** (ez orvosolja a 0.4.0-as csapdát, hogy egy régi mentés örökre befagyaszt egy elavult defaultot). Footer: `Alaphelyzetbe állítás…` + `Mentés`.
**Kritikus:** Automatikus helyszín-módban a mentés `site: {}`-t írjon — ma a `loadPlan()` által mutált `config.site` csendben perzisztálódik.

## A.8 Menüsáv (`.commands`)

```
AstroTool  Névjegy · Beállítások… ⌘,
Fájl       Új session… ⌘N | Mappa választása… ⇧⌘O | Legutóbbi könyvtárak ▸ | Beolvasás ⌘R
Szerkesztés (standard) + Keresés ⌘F
Nézet      Ma este ⌘1 · Naptár ⌘2 · Minden célpont ⌘3 · Kalibráció ⌘4 · Audit ⌘5 ·
           Takarítás ⌘6 · Szenzor ⌘7 | Oldalsáv ⌃⌘S
Műveletek  Audit futtatása ⌘⌥A · Duplikátum-keresés nélkül auditálás
           ─ Minden célpont pontozása… · Plate-solve minden koordináta nélküli célpontra… ·
             Szenzor mérése… · DSS-döntések importálása
           ─ Expozíció-tanácsadó minden célpontra…
Súgó       Mappastruktúra súgó · Fogalomtár · Tutorial (web) · CLI-referencia (web)
```

## A.9 First-run flow (a zsákutca megszüntetése)

`resolveRootOnLaunch()` négy kimenete:

1. **Nincs bookmark** → `WelcomeView` (teljes ablak, a split view helyett): app-ikon, `Üdv az AstroToolban` (largeTitle), 3 bullet ikonnal — „Végigolvassa a képkönyvtáradat, és megmondja mi hiányzik." / „**Soha nem töröl és nem mozgat semmit** a könyvtáradban." / „Minden a te gépeden fut, semmi nem megy ki az internetre." Primary: `Képkönyvtár kiválasztása…`. Secondary link: `Milyen mappastruktúrát vár?` → sheet a várt fával monospace-ben (`sessions/<célpont>/<dátum>/lights|flats|darks|biases`, `calibration_library/`, `stacks/`, `processed/`) — a szöveg a `docs/tutorial.html`-ből kiemelve. **Az egész ablak drop-target: mappát ráhúzva kiválasztja.**
2. **Mappa kiválasztva, még nincs beolvasás** → `FirstScanView`: „Készen áll: /Volumes/images/Astro" + a talált top-level mappák **checklistje ✓/✗ a várt struktúra ellen** (`sessions ✓`, `calibration_library ✓`, `stacks ✓`, `processed ✓`, `tools (kizárva)`) — azonnali diagnózis egy 15 perces scan ELŐTT. Primary `Beolvasás indítása` (determinate progress + aktuális path caption). Secondary `Kihagyom, később`. Végén result-kártya („14 675 fájl · 12 célpont · 36 session") + `Tovább a Ma este oldalra` + checkbox `Auditot is futtassunk most?` (default be).
3. **Bookmark van, kötet nincs csatlakoztatva** → `AccessDeniedView(.notMounted)` **+ `Másik mappa választása…` gomb** (a hiányzó kiút) + „Vár a kötetre…" spinner, ami 5 s-onként auto-retry-zik és automatikusan továbbmegy, amikor a kötet megjelenik (B6).
4. **Bookmark van, TCC megtagadva** → a mostani nézet **+ ugyanaz a `Másik mappa választása…` gomb**.

Mindkét AccessDenied-variáns: az érintett útvonal `.textSelection(.enabled)`-del, plusz `Súgó` link.

## A.10 Elnevezések — a névütközések feloldása

| Hely | Mostani | **Új** | Miért |
|---|---|---|---|
| session sor | `Stack-lista…` | **`Stackelés előkészítése…`** | pre-stack keret-válogatás. Sheet alcím: „A legjobb keretek kiválasztása és exportálása DSS/Siril-hez" |
| target sor | `Stackek…` | **`Kész stackek…`** | már elkészült fájlok böngészése — a pipeline **másik vége** |
| Statisztika toolbar | `Frissítés` | `Újraszámolás` | nem cache-refresh |
| Kalibráció ×3 | `Frissítés` | egyetlen `Újraszámolás` | három azonos címkés gomb egy oldalon |
| Áttekintés | `Könyvtár beolvasása` | `Beolvasás` (toolbar, ikon) | |
| Áttekintés | `DSS-adatok beolvasása` | **`DSS-döntések importálása`** | különválik a scan-től |
| Minőség | `Pontozás` + `Újrapontozás` checkbox | `Keretek pontozása` (Menu-with-primary) → `Újra minden keret mérése (lassú)`, `Siril nélkül (csak natív)` | a checkbox gombnak látszik |
| Kalibráció | `Mérés` | **`Szenzor mérése…`** | puszta ige, tárgy nélkül |
| Audit | `Javaslat-script generálása` | **`Javító script (hibák)…`** | vs. a takarítási script |
| Áttekintés | `Takarítási script generálása` | **`Karantén-script (takarítható)…`** | megnevezi, hogy `mv` karanténba |
| Áttekintés | `Hónap…` | `Naptár` (saját oldal) | a gomb nem rejtekhely |
| tab | `Statisztika` | `Minden célpont` | nem statisztika, hanem célpont-lista |
| tab | `Minőség` | beolvad a Célpont-részletekbe | célpont-specifikus, nem globális |

---

# B) Hiányzó funkciók

| # | Funkció | Pontos működés | Mire jó | Hol lakik | Effort |
|---|---|---|---|---|---|
| **B1** | **Mappaválasztó a hiba-képernyőkön** | `AccessDeniedView` mindkét variánsa kap egy `Másik mappa választása…` gombot, ami `appState.chooseRoot()`-ot hív | **Blocker-fix.** Ma egy lecsatolt kötet bookmarkja teljesen kizárja a felhasználót az appból | `AccessDeniedView.swift` | **S** |
| **B2** | **Guided onboarding** | A.9 szerinti 2 lépés (Welcome + FirstScan) a struktúra-checklisttel | Kezdő nem néz üres tabokat; azonnal látja, hogy jó mappára mutat-e | `WelcomeView.swift`, `FirstScanView.swift` (új) | **M** |
| **B3** | **Globális keresés ⌘F** | `.searchable` a sidebaron. Négy szekcióban ad találatot: **Célpontok** (`target`, `displayName`, `tags`), **Sessionök** (dátum + célpont), **Fájlok** (`files.path` `LIKE`, típus + méret + Finder-akció), **Jegyzetek** (a mostani `Database.searchNotes`). Új `Database.searchAll(query:) -> SearchResults`. Enter → az első találatra navigál | A `search` ma CLI-only; a Statisztika `TextField`-je csak célpont-nevet és címkét szűr. **A fájl-keresés a valódi napi igény**: „hol van az az `NGC2237_145x120s` fájl?" 14 675 fájlnál | Sidebar + `SearchResultsPage` | **M** |
| **B4** | **Éjszaka-jegyzet szerkesztő** | Session context menu → sheet `Kulcs: érték` sorokkal, előre kitöltött üres sablonnal: `Bortle`, `SQM`, `Seeing`, `Átlátszóság`, `Szél`, `Páralecsapódás`, `Megjegyzés`. **Írás `.astro_tool/notes/<target>-<date>.txt`-be**, NEM a könyvtár `README.txt`-jébe; olvasáskor merge-öl a README-ből parse-olt jegyzetekkel (README nyer ütközéskor) | **Ez a legnagyobb hiányzó darab.** A `session_notes` 119 sora mind `new-session` boilerplate — nincs egy valós észlelési jegyzet sem. Emiatt az R6-4 „kereshető napló", az AstroBin-export `bortle`/`meanSqm` kolonnái és a `search` **mind üresek**. Nincs UI, ami jegyzetet kérne | Célpont-részletek ▸ Jegyzetek + session context menu | **M** |
| **B5** | **Audit-találat elfogadás (ack)** | Új tábla `finding_acks(ack_key TEXT PRIMARY KEY, category TEXT, group_key TEXT, acked_at REAL, note TEXT)`. **Kulcs = `(category, groupKey)`, nem `findings.id`** — így túléli az újra-auditot. Az ack-elt csoportok default rejtve, toolbar-toggle-lel megjelenítve, és **nem számítanak bele a sidebar badge-be** | Enélkül minden audit-futás ugyanazt a 41 hibát mutatja, amiből a felhasználó 30-at már tudatosan elfogadott → a badge megtanul lármázni, és a felhasználó megtanulja ignorálni | Audit oldal, csoport-fejléc `⋯` menü | **M** |
| **B6** | **Auto-scan kötet-csatlakozásra / app-aktiválásra** | `NSWorkspace.didMountNotification` figyelése: ha a felcsatolt kötet a gyökér köteté, `retryRootAccess()` majd — ha a beolvasás >24 h-s — nem-blokkoló banner „Új fájlok lehetnek. [Beolvasás]". `NSApplication.didBecomeActiveNotification`-re csak a banner, automatikus scan nélkül | Egy külső kötetes könyvtárnál ez a leggyakoribb súrlódás: bedugod a diszket és kézzel kell újraindítani/retry-olni | `AppState` observer | **S** |
| **B7** | **Thumbnail + Quick Look** | `QuickLookThumbnailing` (`QLThumbnailGenerator`) 64×64 thumbnail-kolonna a Stackek táblában és a Kész stackek nézetben, memóriában cache-elve path+mtime kulccsal. `Space` → `QLPreviewPanel` a kijelölt fájlra. Egy `Nagy előnézet` context-menü elem | Egy `starless_` és egy `_HOO_Improved` variáns nevéből nem derül ki, melyik a jó. **Ez az egyetlen dolog, ami ezt a szoftvert képnézővé is teszi** — jelenleg semmilyen képi visszajelzés nincs | Célpont-részletek ▸ Stackek; Minőség keret-tábla | **M** |
| **B8** | **Menüsáv + gyorsbillentyűk + ⌘, Settings scene** | A.8 szerint | Ma nulla menü és nulla gyorsbillentyű. A Beállítások tabként való megjelenítése az egyik legfeltűnőbb nem-macOS-jelleg | `AstroToolApp.swift` | **S** |
| **B9** | **Sor-context menük mindenhol** | A.1–A.6 szerinti menük; a `Műveletek` kolonna törlése | ~240pt apró kék linkszöveg helyett a natív jobb-klikk. Egyben megoldja a „két hasonló gomb egymás mellett" problémát azzal, hogy egyszerre csak egy sor menüje látszik | minden `Table` | **S** |
| **B10** | **Helyszín-beállítás + auto/kézi jelzés** | A.7 „Helyszín" tab; a Ma este `Helyszín` tile; `site: {}` mentése automatikus módban | A Tervező **minden** száma ezen áll, és ma sehol nem szerkeszthető, nem is látható. Egy csak-Canon felhasználó (nincs SITELAT fejléc) tervet sem kap, és nem tudja megjavítani | Settings ▸ Helyszín + Ma este tile | **S** |
| **B11** | **Cél (goal) UI** | Inline óra-stepper popover a Célpont-részletek fejlécében és a context menükben; `goal:Xh` címkét ír. Célpont-listában `Cél` kolonna | A `goal:Xh` mágikus címke-string a `Hiányzik`, a `ProjectPhase` és a Planner-score bemenete — de **0 címke van a DB-ben**, mert semmi nem említi. Három funkció halott zóna | Célpont-fejléc, context menük | **S** |
| **B12** | **Teljes config-szerkesztő** | A.7 összes tabja, per-kulcs `↺` reset | 7 kulcs / ~40. A `rating.weights` maga a pontozási modell, és csak fájlból állítható | Settings | **M** |
| **B13** | **Drag-and-drop** | Mappa dobása a Welcome ablakra vagy a toolbar gyökér-menüjére → gyökér-választás. Mappa dobása a Minden célpont oldalra → `scan --path SUB` arra a részfára | Részfa-scan ma GUI-ból elérhetetlen; egy új session gyors beolvasása 15 perc helyett 20 másodperc | `WelcomeView`, `AllTargetsPage` | **S** |
| **B14** | **Batch műveletek menü** | `Műveletek` toolbar/menüsáv: `Minden célpont pontozása…` (sorosan, összesített progresszel), `Plate-solve minden koordináta nélküli célpontra…` (= `solve --all`), `Expozíció-tanácsadó minden célpontra…` (= `expose` `--target` nélkül, tábla-sheet), `DSS-döntések importálása` | A CLI-nak megvan mindhárom; a GUI egyenként kényszerít. 7,9%-os rating-arány részben ezért van | Menüsáv + toolbar | **S** |
| **B15** | **Művelet-napló** | `AppState.activityLog: [ActivityEntry]` (utolsó 50: időpont, művelet, eredmény/hiba). Popover a toolbar óra-ikonjáról | Ma `lastError` egyetlen String, amit a következő művelet felülír — egy háttérben elszállt export nyomtalanul eltűnik | Toolbar popover | **S** |
| **B16** | **In-app súgó (3 szint)** | (1) Minden számított metrika-fejléc mellé `ⓘ` popover: mit jelent, hogyan számoljuk, mikor hazudik (pl. „Háttér e⁻/s/″² — mért szenzor-profil nélkül nem számolható"). (2) `Súgó ▸ Fogalomtár` sheet: FWHM, kerekség, z-score, e⁻/s/″², airmass, karantén, hardlink. (3) Minden empty state **tanít**, nem csak közli az ürességet | 3 tudásszintet kell szolgálni ugyanazon a felületen. Ma 12 szórványos `.help()` van és nulla magyarázat | globális | **M** |
| **B17** | **Könyvtár-váltó (multi-root helyett)** | `Legutóbbi könyvtárak ▸` max 5 bookmarkkal a toolbar gyökér-menüjében; váltás újranyitja a DB-t. **NEM** javaslok egyidejű több gyökeret — az egész séma, a `WriteGuard` és minden riport egyetlen `rootPath`-ra épül; L-es refaktor S-es haszonért | SSD munkakészlet + NAS archívum váltogatása ma mappaválasztást igényel minden alkalommal | Toolbar gyökér-menü | **S** |
| **B18** | **HU/EN — NEM egy toggle** | A valódi blokkoló: az `AstroCore` **domain-adatként** ad magyar stringeket (`verdict` „ma jó", `ProjectPhase.rawValue` „gyujtes", `CalibNeed.todo`, `FlatDiscipline.status` „rendben", `StackVariantKind` „szerkesztett"), és ezek **DB-be és JSON-ba is így mennek**. Egy UI-toggle félig magyar appot adna. Helyes sorrend: (1) minden ilyen típus kapjon stabil, nem-lokalizált `code` mezőt és a magyar szöveg legyen prezentáció; (2) `String Catalog` (`.xcstrings`) HU+EN. **Javaslat: most ne**, előbb az IA | — | **L** — halasztani |
| **B19** | **Menüsáv-mini mód — NEM javaslom** | Az app nem monitoroz semmit valós időben (nincs élő hűtő/fókusz feed, nincs mount-watch a scan előtt). Egy menüsáv-item statikus számokat mutatna, amik csak scan után változnak | — | — | **skip** |
| **B20** | **findings-retenció** | A `findings` tábla 32 074 sort tart 12 futásból. Scan/audit után az utolsó 3 run-on kívüli findings törlése (a `runs` sor maradhat) | DB-hízás; egy 12-run-os könyvtár már 31 MB | `AuditEngine` / `Database` | **S** |

---

# C) Prioritizált build-terv

**Kockázati alaphelyzet:** `Package.swift` `testTarget` **csak** `AstroCore`-ra függ → mind a 808 `@Test` AstroCore-teszt, **nulla app-layer teszt**. Minden `Sources/AstroToolApp/**`-ra szorítkozó task **zéró teszt-kockázatú**. AstroCore-t csak T2 és T6 érint, ott jelölve.

### T1 — Navigációs váz + first-run + menüsáv  ← **kezdd ezzel**
**Scope:** `NavigationSplitView` + `Page` enum + sidebar (fix sorok + célpont-lista fázis-pontokkal + badge-ek) · ablak-toolbar (gyökér-`Menu`, `Beolvasás`, `+`, `Műveletek`) · `.commands` menüsáv (A.8) · `Settings` scene (a mostani `SettingsView` átmozgatva, még tartalmi bővítés nélkül) · `WelcomeView` + `FirstScanView` (A.9) · **B1 mappaválasztó mindkét AccessDenied-variánsra** · B6 mount-observer · B13 drop-target · B15 művelet-napló popover.
**Fájlok:** `AstroToolApp.swift`, `Views/RootView.swift`(új), `Views/SidebarView.swift`(új), `Views/WelcomeView.swift`(új), `Views/FirstScanView.swift`(új), `Views/AccessDeniedView.swift`, `Views/Commands.swift`(új), `AppState.swift` (`Page`, `recentRoots`, `activityLog`, mount observer).
**Acceptance:** ⓐ lecsatolt kötet bookmarkjával indítva `Másik mappa választása…` látszik és működik; ⓑ üres `~/Library/…` állapotból indítva Welcome → mappaválasztás → struktúra-checklist → scan → Ma este; ⓒ ⌘1–⌘7 navigál, ⌘R beolvas, ⌘N új session, ⌘, Beállítások; ⓓ a sidebar badge-ek a valós számokat mutatják (Audit badge **csak** `sureError`); ⓔ mappa ráhúzása a Welcome-ra kiválasztja a gyökeret; ⓕ `swift build` warning-mentes, 808 teszt zöld.

### T2 — Audit háromszegmenses átépítés + ack + Takarítás oldal
**Scope:** A.5 teljes egészében · a `Takarítható` szegmens (a `CleanupSummary` táblája + `--limit` stepper + Vasszabály-banner) · **B5 ack** · **B20 findings-retenció** · a két script átnevezése és egy `Script…` menübe vonása · `--no-duplicates` kitétele.
**Fájlok:** `Views/AuditPage.swift` (a mostani `AuditView` átírva), `AppState.swift` (`ackFindingGroup`, `unackFindingGroup`, `ackedKeys`, `loadCleanup` már megvan), **`AstroCore/DB/Database.swift` + `schema_version` bump** (`finding_acks` tábla, `pruneFindings(keepRuns:)`).
**Acceptance:** ⓐ a valós könyvtáron a fejléc-tile-ok `41 / 347 / 12,4 GB / 35`-öt mutatnak (a residue **nincs** a „Gyanús"-ban); ⓑ egy csoport ack-elése után újra-audit után is rejtve marad és nem számít a badge-be; ⓒ a `Limit` stepper valóban vágja a listát; ⓓ retenció után `select count(*) from findings` ≤ 3 run.
**Kockázat:** `DatabaseTests` sémalista-/migrációs assertek. Additív tábla + verzió-emelés, `IF NOT EXISTS`-szel. Régi DB-t migrálni kell (nem újat építeni).

### T3 — Célpont-részletek oldal (a Minőség tab beolvasztása)
**Scope:** A.3 teljes egészében (fix fejléc + 5 belső szegmens) · a `StackGroupSheet` inline oldallá alakítása · az Expozíció-tanácsadó átmozgatása · a `--force` / `--no-siril` Menu-with-primary-action · dátum-`Menu` a szabadszöveges TextField helyett · pontszám-hisztogram · inline idővonal-sáv · **B11 cél-UI** · keret- és session-context menük.
**Fájlok:** `Views/TargetDetailPage.swift`(új, ~700 sor), `Views/TargetDetail/*.swift` (Overview/Sessions/Quality/Stacks/Notes szegmensek), `Views/QualityView.swift` (**törlendő**), `Views/StatsView.swift` (a `StackGroupSheet`, `PanelsPopoverButton` innen kiemelve), `AppState.swift` (`runRate(noSiril:)` paraméter, `setGoal(target:hours:)`).
**Acceptance:** ⓐ NGC2237-re megnyitva a fejléc mutatja: valós/bruttó integráció, cél, hiányzik, 13 session, legjobb session FWHM-mel; ⓑ session kiválasztásra inline idővonal-sáv + hardver-egészség; ⓒ „Siril nélkül" pontozás natív metrikát ad, Siril-kolonnák `-`; ⓓ cél beállítása után a `Hiányzik` mindhárom helyen (fejléc, Ma este, célpont-lista) megjelenik; ⓔ a `Minőség` tab nem létezik többé.

### T4 — Ma este + Naptár oldal + helyszín
**Scope:** A.1 teljes egészében · a 4 tile (benne a **ma este sötét idő**, ami ma sehol nincs) · a `Table`-alapú terv-lista 10 kolonnával · `Terv erre az éjszakára` context menu (= `plan --date`) · a Naptár szegmens `Table`-ként · **B10 helyszín** (Settings ▸ Helyszín tab + a `site: {}` mentési fix) · a helyszín-banner.
**Fájlok:** `Views/TonightPage.swift`(új), `Views/SettingsWindow.swift` (Helyszín tab), `AppState.swift` (`loadPlan(date:minAltDeg:)` paraméterek, a `config.site` mutáció leválasztása egy külön `resolvedSite` property-be).
**Acceptance:** ⓐ a `Helyszín` tile a feloldott koordinátát mutatja „FITS-fejlécekből" captionnel; ⓑ kézi módra váltva és mentve a `config.json` `site`-ot tartalmaz, automatikus módban `{}`-t; ⓒ egy naptár-sor context menüjéből a Ma este tábla arra a dátumra számol újra; ⓓ üres/koordináta-nélküli állapotok a specifikált `ContentUnavailableView`-kat adják.
**Kockázat:** `PlannerTests` / `PlannerMonthTests` — csak akkor, ha a `Planner` szignatúrája változik. **Ne változzon**: a `date`/`minAlt` paraméterek már léteznek a CLI-nak.

### T5 — Kalibráció + Szenzor oldal + teljes Settings
**Scope:** A.4 (a `Típus`/`Gain`/`Kamera` kolonnákkal, egyetlen `Újraszámolás`, akció-kártyás teendők) · A.6 (önálló Szenzor oldal, `Szenzor mérése…` confirm sheet, frissesség-figyelmeztetés, „mire jó" blokk) · **B12** A.7 mind az 5 Settings-tabja per-kulcs `↺`-tal, normalizált weight-sliderekkel, élő Siril-detektálással.
**Fájlok:** `Views/CalibrationPage.swift` (a mostani `CalibrationView` szétvágva), `Views/SensorPage.swift`(új), `Views/SettingsWindow.swift` + `Views/Settings/*.swift`.
**Acceptance:** ⓐ a Lefedettség táblában megkülönböztethető egy dark és egy flat sor; ⓑ a 4 rating-weight slider mindig 1,00-ra összegződik és a `config.json` így mentődik; ⓒ minden módosított kulcs mellett megjelenik a `↺`, defaultra visszaállítva eltűnik; ⓓ hibás Siril-útvonalnál piros „nem található", helyesnél zöld + verzió.

### T6 — Kereső (⌘F) + jegyzet-szerkesztő + thumbnailek
**Scope:** **B3** globális keresés 4 szekcióval + `SearchResultsPage` · **B4** jegyzet-szerkesztő `.astro_tool/notes/`-ba (a Vasszabály sértése nélkül) + merge olvasáskor · **B7** thumbnail-kolonna + Quick Look · **B14** batch-műveletek menü · **B16** ⓘ popoverek + Fogalomtár sheet.
**Fájlok:** `Views/SearchResultsPage.swift`(új), `Views/SessionNoteSheet.swift`(új), `Views/ThumbnailCell.swift`(új), `Views/GlossarySheet.swift`(új), **`AstroCore/DB/Database.swift`** (`searchAll`), **`AstroCore/Scan/ReadmeNotesParser.swift`** vagy új `SessionNoteStore.swift` (merge-logika), **`AstroCore/WriteGuard.swift`** (`.astro_tool/notes/` engedélyezése).
**Acceptance:** ⓐ ⌘F + „2237" célpont-, session-, fájl- és jegyzet-találatot ad, Enter az elsőre navigál; ⓑ egy session jegyzeteinek szerkesztése `Bortle: 5`-tel: a fájl `.astro_tool/notes/`-ban jön létre, a könyvtár `README.txt`-je **bit-azonos marad**, és a `search bortle` megtalálja; ⓒ AstroBin CSV-export a `bortle` kolonnát kitöltve adja; ⓓ Space-re Quick Look nyílik a kijelölt stackre.
**Kockázat:** `WriteGuardTests` (új engedélyezett útvonal-prefix → additív assert), `ScannerTests`/`ReadmeNotesParserTests` (a merge-olvasás nem változtathatja a README-parse eredményét). **A `README.txt` írása kifejezetten tilos** — ez a Vasszabály, és a `.astro_tool/notes/` megkerülés szándékos.

---

## Sorrend és párhuzamosítás

**T1 kötelezően először** (minden más a `Page` enumra és a shellre épül). Utána **T2, T3, T4, T5, T6 egymástól független**, párhuzamosítható. Hatás szerinti sorrend, ha sorosan mennek: **T1 → T2 → T3 → T4 → T5 → T6**.
T2 (a 3 545-es hamis szám) és T3 (a napi munkafelület) a két legnagyobb érzékelt nyereség; T1 az egyetlen, ami **blokkolót** javít.

**Két dokumentációs mellékhatás, amit bármelyik task során rendbe kell tenni:** `docs/features.html` „az app 5 füle" szerint épül (6 van, hamarosan 7 oldal), `docs/cli.html` „mind a 24 CLI-alparancs" (26 van — `stacks`, `target-report` hiányzik).
