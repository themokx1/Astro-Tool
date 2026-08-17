# Vizuális nyelv + macOS 26 (2. hullám) — implementációs terv

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Az appnak legyen saját vizuális nyelve — olyan, amiben minden szín pontosan egy dolgot jelent, minden szám ugyanabban a formátumban jelenik meg, és a felület a macOS 26 anyagait ott használja, ahol a rendszer adja őket.

**Architecture:** Az `AstroTokens` teljes cseréje egyetlen forrássá (szín, tipográfia, felület, mozgás), majd végigsöprés mind a 35 fogyasztó fájlon. A Liquid Glass **kizárólag a keretre** kerül (sidebar, toolbar, lebegő akciósáv), a tartalmi kártyák tömör felületek maradnak. Minden változás mögé gépi kapu kerül, hogy a következő nézet ne tudja visszahozni.

**Tech Stack:** Swift 6.3, SwiftUI a macOS 26 SDK-val (`glassEffect`, `backgroundExtensionEffect`, `scrollEdgeEffectStyle`, `ConcentricRectangle`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-08-16-archive-map-ux-redesign-design.md` — az **5. fejezet** tartalmazza a teljes palettát (mindkét megjelenéssel), a típusskálát és az üveg-szabályokat. Az ott lévő értékek a mérvadók; ez a terv nem ismétli meg őket.

**Ág / worktree:** `codex/v2.0.0-ui-rework` a `.worktrees/v200-ui-rework` worktree-ben.

**Kiindulás:** 2388 teszt zöld csendes gépen. Terhelés alatt az `OperationCenterTests`/toast-időzítés tesztek nem determinisztikusan buknak — ez ismert, nem regresszió; izoláltan mindig átmennek.

---

## Mérés, amire ez a terv épül

| Mérés | Érték |
|---|---|
| `AstroTokens` fogyasztó fájlok | **35** |
| Létező tokenek | 13 (5 szín + 3 státusz + 4 távolság + 1 sarok) |
| Token-használatok | 265 |
| `String(format:` előfordulás | **20**, ebből 5 ugyanaz a `%d:%02d` időtartam |
| `GroupBox` a legsűrűbb nézetben | 6 (`InsightsView`), több nézetben 3 |
| Toolbar-felirat `String`-ként | **36** literál, minden munkatér |

---

## Task 1: A platform emelése macOS 26-ra

**Ez fut először**, mert minden későbbi task a macOS 26 API-kra épülhet, és ha ez bukik, az egész hullám alakja más.

**Előre lemérve (2026-08-16):** a `.macOS(.v26)` **nem elég önmagában** — a `PackageDescription` `v26`-ot csak `swift-tools-version: 6.2`-től ismeri, a manifest viszont `6.0`-n van. Csak a platform-sort átírva a csomag **nem értelmezhető** (`error: 'v26' is unavailable`). A kettő együtt viszont tisztán fordul: teljes build 44 s alatt, hiba és új warning nélkül. Ez mért tény, nem feltételezés.

**Files:**
- Modify: `Package.swift`, `project.yml:5`, `build.sh:113`
- Modify: `.github/workflows/ci.yml:12`, `.github/workflows/release.yml:13`
- Modify: `README.md` (2 hely: „macOS 14 vagy újabb" és „minimum macOS 14")
- Modify: `docs/index.html`, `docs/support.html`, `docs/tutorial.html`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: A manifest, mindkét sora**

```swift
// swift-tools-version: 6.2
…
platforms: [.macOS(.v26)],
```

- [ ] **Step 2: Build és teljes suite**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`, nulla új warning

Run: `swift test --no-parallel 2>&1 | tail -5`
Expected: 2388 teszt zöld

**Ha a tools-version emelése bármit elront** (a SwiftPM 6.0 → 6.2 megváltoztathat alapértelmezéseket, pl. nyelvi módot vagy erőforrás-kezelést): **állj meg és jelentsd**, ne kezdd el egyesével javítani a következményeket. A manifest viselkedésének változása tervezési döntés, nem hibajavítás.

- [ ] **Step 3: A többi hely, egyetlen commitban**

`project.yml` → `macOS: "26.0"`; `build.sh` → `LSMinimumSystemVersion` `26.0`; mindkét workflow → `runs-on: macos-26` (2026 februárja óta általánosan elérhető, Xcode 26-tal); README és a három docs-oldal → „macOS 26 vagy újabb".

**A `CHANGELOG.md` kapjon kifejezett „Breaking change" bejegyzést**, ami kimondja, hogy a v2 mostantól macOS 26-ot igényel, és hogy a **macOS 14–15 felhasználók a v1 kiadáson maradnak**. Ez nem apró betű: a letöltőoldalnak mindkettőt kínálnia kell.

- [ ] **Step 4: Commit**

```bash
git commit -m "build: require macOS 26"
```

---

## Task 2: Az `AstroTokens` cseréje

**Files:**
- Rewrite: `Sources/AstroUI/DesignSystem/AstroTokens.swift`
- Delete: `Sources/AstroUI/Features/Archive/ArchivePalette.swift` (beolvad)
- Modify: `Sources/AstroUI/Features/Archive/*.swift` (a paletta-hívások átírása)
- Test: `Tests/AstroUITests/AstroTokensTests.swift` (új), `V2PolishSurfaceTests.swift`

- [ ] **Step 1: A kapu előbb**

```swift
@Test("Every semantic color token defines both appearances")
func everyColorDefinesBothAppearances() throws {
    let source = try contents("Sources/AstroUI/DesignSystem/AstroTokens.swift")
    // A token whose only definition is a single NSColor never adapts: it
    // renders one appearance's ink on the other appearance's ground. Every
    // token here is built from a dynamic provider with two distinct values.
    let singleValued = source.components(separatedBy: "static let")
        .filter { $0.contains("SwiftUI.Color(") && !$0.contains("dynamicProvider") && !$0.contains("dynamic(") }
    #expect(singleValued.isEmpty, "a token is defined for one appearance only")
}

@Test("Data-category colors are never used to express status")
func dataColorsAreNotStatus() throws {
    for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
        let source = try strippingComments(contents(file))
        for line in source.split(separator: "\n") where line.contains("AstroTokens.Color.data") {
            #expect(!line.contains("severity") && !line.contains("isHealthy") && !line.contains("verdict"),
                    "\(file): a data-category color is carrying status meaning")
        }
    }
}
```

- [ ] **Step 2: A tokenek**

A spec **5.1** táblázata a forrás. Minden token `NSColor(name:dynamicProvider:)`-rel készül, két értékkel, ahogy az `ArchivePalette.dynamic(dark:light:)` már ma is csinálja — azt a segédfüggvényt emeld be ide, és onnan töröld.

Név-leképezés a mai tokenekről (a söprés ezt követi):

| Mai | Új | Megjegyzés |
|---|---|---|
| `graphite` | `ground` | |
| `elevatedGraphite` | `surface` | |
| `hairline` | `edge` | |
| `spectralBlue` | `accent` | **az elsődleges akció színe**, nem dekoráció |
| `spectralViolet` | **törlendő** | 11 használat; mindegyik vagy `accent`, vagy `dataCalibration` — hívási helyenként kell eldönteni, nem tömegesen |
| `success` / `warning` / `danger` | `ok` / `attention` / `critical` | jelentés változatlan, a `danger`→`critical` átnevezés szándékos: a „veszély" a művelet tulajdonsága, a „kritikus" az állapoté |
| — | `ink` / `inkDim` / `inkFaint` | **új**, ma mindenhol `.secondary`/`.tertiary` |
| — | `dataLight`/`dataStack`/`dataProcessed`/`dataCalibration`/`dataUnclassified` | az `ArchivePalette`-ből |

A `Spacing` és a `CornerRadius` **változatlan marad** — működik, és 120 hívási helye van; egy jó rendszer nem cserél le működő részt.

- [ ] **Step 3: Söprés, fájlonként**

35 fájl. **Ne** globális keresés-csere: a `spectralViolet` minden hívási helye külön döntés. Fájlonként fordíts és futtasd a suite-ot, hogy egy elrontott csere ne keveredjen tíz jóval.

- [ ] **Step 4: Suite + commit**

```bash
git commit -m "feat: replace the design tokens with a real system"
```

---

## Task 3: `AstroType` — a típusskála

**Files:**
- Create: `Sources/AstroUI/DesignSystem/AstroType.swift`
- Test: `Tests/AstroUITests/V2PolishSurfaceTests.swift`

A spec **5.2** táblázata a forrás: `display`, `sectionTitle`, `body`, `dataHero`, `data`, `micro`.

**Két megkötés, amit a kód szintjén kell tartani:**

1. Minden mérőszám `monospacedDigit()`. Egy oszlopban álló szám, ami ugrál, olvashatatlan.
2. A pont-alapú méretek (`dataHero`) `@ScaledMetric`-en keresztül skálázódjanak. A rendszer akadálymentességi szövegmérete nem törheti szét a sávokat.

- [ ] **Step 1: Kapu**

```swift
@Test("Numeric display text is always tabular")
func numbersAreTabular() throws {
    // A proportional digit column jitters as values change -- unreadable in
    // a table and dishonest in a bar chart, where width reads as magnitude.
    for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
        let source = try strippingComments(contents(file))
        #expect(!source.contains(".font(.system(size:") || source.contains("monospacedDigit"),
                "\(file): fixed-size numeric text without monospacedDigit")
    }
}
```

- [ ] **Step 2–4:** implementáció, söprés, commit (`feat: add the type scale`).

---

## Task 4: `AstroFormat` — egy formátum mértékegységenként

20 `String(format:` van az `AstroUI`-ban, köztük **ötször ugyanaz a `%d:%02d`** öt fájlban (`InspectorView` ×2, `HomeView`, `NightsStore`, `SeriesWorkspaceView`). Ez a spec **P2** mintája.

**Files:**
- Create: `Sources/AstroUI/DesignSystem/AstroFormat.swift`
- Modify: a 12 hívó fájl
- Test: `Tests/AstroUITests/AstroFormatTests.swift` (új), `V2PolishSurfaceTests.swift`

- [ ] **Step 1: Tesztek először**

```swift
@Test("Durations render as h:mm with a unit, never bare")
func durationCarriesItsUnit() {
    #expect(AstroFormat.duration(seconds: 45_600) == "12:40 h")
    #expect(AstroFormat.duration(seconds: 0) == "0:00 h")
    #expect(AstroFormat.duration(seconds: 59) == "0:00 h", "under a minute rounds down, it does not vanish")
}

@Test("Byte sizes are locale-formatted and never raw")
func bytesAreFormatted() {
    #expect(AstroFormat.bytes(0) == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
}

@Test("Coordinates keep four decimals, the precision the site editor stores")
func coordinatePrecision() {
    #expect(AstroFormat.degrees(47.4979) == "47,4979°" || AstroFormat.degrees(47.4979) == "47.4979°")
}
```

A koordináta-teszt mindkét tizedesjelet elfogadja, mert a formázás **lokalizált** — egy magyar gépen vessző. Ha egy teszt egy adott elválasztóra hasonlít, az a teszt a saját gépén múlik.

- [ ] **Step 2: Kapu**

```swift
@Test("No feature view formats a value by hand")
func noHandRolledFormatting() throws {
    for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
        #expect(!(try strippingComments(contents(file))).contains("String(format:"),
                "\(file): use AstroFormat -- a second format for the same unit is a second truth")
    }
}
```

- [ ] **Step 3–4:** implementáció, söprés, commit (`refactor: give every unit one format`).

---

## Task 5: A toolbar-feliratok lefordulnak

Ez a korábbi hullám **Task 16**-ja, ide áthelyezve, mert közös infrastruktúrát érint és a söpréssel egy időben olcsóbb.

A teljes leírás: `docs/superpowers/plans/2026-08-16-archive-map-wave1.md`, „## Task 16" szakasz. **Olvasd el onnan** — beleértve a `LocalizedStringKey` egyenlőség-csapdáját (kulcs szerint egyezik, nem szöveg szerint; a tesztek azonossága az `id`-ra kell hogy váltson).

Commit: `fix: localize every workspace toolbar action title`

---

## Task 6: Liquid Glass — lebegő panelek, üveg kártyák

**A tulajdonos döntése (2026-08-17), a korábbi terv felülírása.** Az eredeti szöveg azt mondta: „az üveg a keret, nem a tartalom", és a tartalmi kártyákat tömör felületen hagyta. Megkérdeztem, mert a „liquid glasst sem látok sehol" visszajelzés után tudni akartam, mennyit vár — és **többet kért**: lebegő panelek, üveg kártyák.

Ez tehát nem mulasztás pótlása, hanem irányváltás. A visszafogottság indoka viszont **valós marad**, ezért nem törlöm, hanem korlátozom: üveg alatt a sűrű adat olvashatatlan. A megoldás nem az, hogy kevesebb üveg legyen, hanem hogy **az üveg a tartót kapja, a sűrű tartalom pedig tömör belső felületen üljön benne**.

### Amit előre lemértem

A telepített build **már macOS 26-os** (`minos 26.0`), tehát a rendszer a sidebart és a toolbart **kód nélkül** üvegesíti. Amit a tulajdonos „nem látok üveget"-ként érzékel, azt részben **mi magunk takarjuk el**:

```
WorkspaceComponents.swift:35   .background(AstroTokens.Color.ground.opacity(0.36))
WorkspaceComponents.swift:96   .background(AstroTokens.Color.ground.opacity(0.36))
V2RootView.swift:1547          .background(AstroTokens.Color.ground.opacity(0.36))
```

Egy 36%-os tónus az ablak anyaga fölött. **Ez megy először**, mert enélkül minden további üveg is tompa marad.

### A szabály, ami marad

| Réteg | Anyag |
|---|---|
| Sidebar, toolbar, menük | rendszer-üveg (újrafordításból, nincs kód) |
| **Kártyák, panelek, inspector — a TARTÓ** | `glassEffect(.regular, in:)`, `ConcentricRectangle` sarokkal |
| **Sűrű tartalom a tartón belül** (táblasorok, hosszú szöveg, adatsáv) | **tömör** `surface`, az üvegen ülve |
| Lebegő akciósáv | `GlassEffectContainer` + `.buttonStyle(.glassProminent)` |
| Görgetési él | `.scrollEdgeEffectStyle(.soft, for: .top)` |
| Fejléc-sáv | `.backgroundExtensionEffect()` |

Vagyis: a **kártya lebeg**, de a benne lévő 3 231 soros lista nem üvegen fut. Ez adja a látványt anélkül, hogy egy táblázat olvashatatlanná válna.

Használd a `GlassEffectContainer`-t, ahol több üvegelem van egymás mellett — külön-külön alkalmazva nem olvadnak össze, és a rendszer sem tudja optimalizálni.

**Files:** `Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift`, `Sources/AstroUI/App/V2RootView.swift`, `Sources/AstroUI/Features/Archive/*.swift`, `Sources/AstroUI/Inspector/*.swift`, `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1: Le a saját tónussal** — a három `.background(...opacity(0.36))` törlése. Utána nézd meg, mennyi rendszer-üveg válik láthatóvá magától; ez a kiindulás, amihez a többit mérni kell.

- [ ] **Step 2: A tartók kapnak üveget** — kártyák, panelek, inspector. `ConcentricRectangle` a sarokhoz, hogy az ablak lekerekítésével egyezzen.

- [ ] **Step 3: A sűrű tartalom tömör marad** — a táblák, a hosszú magyarázó szövegek és az archívum-sáv a tartón **belül**, `surface` háttéren. **Kapu:** a `Table`/`List` közvetlen szülője soha ne legyen `glassEffect`-es.

- [ ] **Step 4: Lebegő akciósáv és görgetési él.**

- [ ] **Step 5: A kontrasztot ember nézi meg.**

Ezt gép nem tudja eldönteni, és ez a task nem tesz úgy, mintha tudná. Építs, telepíts, és **készíts a tulajdonosnak egy rövid listát arról, mit nézzen meg**: a sűrű táblák olvashatóságát világos és sötét módban, a kártyaszöveget világos háttér előtt, és hogy a lebegés nem zavaró-e görgetés közben.

Írd meg azt is a jelentésben, **hogyan lehet visszafogni**, ha sok — melyik egyetlen helyen kell a `.regular`-t `.clear`-re vagy tömörre váltani. Ez irányváltás volt; legyen olcsó visszafordítani.

```bash
git commit -m "feat: float the panels on the system's glass"
```

## Task 7: A söprés — dobozok, mentegetőzések, ismétlések

**Files:** minden `Sources/AstroUI/Features/**` nézet, ami érintett.

Három konkrét minta, mindegyik a spec 6. fejezetéből:

1. **Dobozban-doboz.** Az `InsightsView`-ban 6 `GroupBox` van, több nézetben 3. Egy fogalom = egy felület. A beágyazott `GroupBox`-ok kivezetendők; a csoportosítást térköz és fejléc adja, nem keret a kereten.
2. **Mentegetőző felirat.** Ha egy szám mellé cáfolat kell (a `HealthView:138` a példa), akkor **a szám megy el**, nem a cáfolat marad. Sekély vizsgálat kap egy őszinte mondatot vagy semmit — de nem főcím-számot.
3. **`N / M` oszlopok, ahol a nevező képernyőnként mást jelent** (P10, 4 hely). Minden ilyen oszlop mondja meg a fejlécében vagy a `.help()`-jében, mi a nevező.

- [ ] **Step 1: Kapu a dobozmélységre**

```swift
@Test("No view nests a GroupBox inside a GroupBox")
func noNestedGroupBoxes() throws {
    // Two frames around one idea reads as two ideas. Grouping is spacing
    // and a heading, not a border on a border.
    for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
        #expect(maxGroupBoxDepth(in: try contents(file)) <= 1, "\(file) nests GroupBoxes")
    }
}
```

A `maxGroupBoxDepth` segédfüggvény zárójel-egyensúlyt számol; írd meg a tesztfájlban, és **igazold, hogy tényleg fog**: adj hozzá ideiglenesen egy beágyazott `GroupBox`-ot, nézd meg, hogy bukik, vond vissza.

- [ ] **Step 2–3:** söprés fájlonként, commit (`refactor: one surface per idea`).

---

## Task 8: Mozgás — állapotváltozás, nem hangulat

**Files:** `Sources/AstroUI/Features/Archive/ArchiveStripView.swift`, `ArchiveView.swift`, `Sources/AstroUI/DesignSystem/AstroMotion.swift` (új)

A spec **5.4** a forrás. Négy mozgás, több nem:

- a visszanyerhető-sín szélessége animálva csökken karantén után (**már kész** a T7-ben)
- egy célpont-sor vörös síne kifakul, amikor tisztává válik
- a teendő-kártyák `glassEffectTransition`-nel tűnnek el
- beolvasás közben a fejléc mikrocímkéje él

**Minden animáció mögött `@Environment(\.accessibilityReduceMotion)`.** Nulla dekoratív, folyamatos animáció — és **nulla időzítő**: a projekt fagyás-történetének 6. pontja pont egy feltétel nélküli időzített ciklus volt megosztott állapoton.

- [ ] **Step 1: Kapu**

```swift
@Test("Every animation respects reduce-motion")
func animationsRespectReduceMotion() throws {
    for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
        let source = try strippingComments(contents(file))
        guard source.contains(".animation(") else { continue }
        #expect(source.contains("accessibilityReduceMotion"),
                "\(file) animates without checking reduce-motion")
    }
}
```

- [ ] **Step 2–3:** implementáció, commit (`feat: animate state changes, nothing else`).

---

## Task 9: Futásidejű ellenőrzés — és ezúttal emberi szemmel is

**A gép itt elfogy.** A kontraszt, az olvashatóság és az, hogy „szép-e", nem eldönthető forráskód-vizsgálattal, és ez a terv nem tesz úgy, mintha az lenne.

- [ ] **Step 1: Build, telepítés**

```bash
./build.sh && ./scripts/install-local.sh
```

- [ ] **Step 2: CPU-mérés a valódi könyvtáron**

**Előbb állítsd le az appot, és ne futtass semmilyen automatizmust vele párhuzamosan** — az 1. hullámban pont ez gyártott egy fals 99%-os csúcsot és egy hibás következtetést.

```bash
open -a AstroTool --args -UITestInitialSection library
# 25 s és 115 s múlva:
ps -o %cpu,rss,comm -p "$(pgrep -x AstroTool)"
```

Elvárás: **<15%** mindkettőnél. Referencia az 1. hullámból: 3,5% / 0,0%.

- [ ] **Step 3: Mindkét megjelenés, majd add át a tulajdonosnak**

Váltsd a rendszert világos és sötét közé, ellenőrizd, hogy nem omlik össze és nem logol hibát. Aztán **készíts egy rövid listát arról, mit kell emberi szemmel megnézni** — kontraszt a sávon, olvashatóság világos módban, az üveg a sidebaron —, és mondd ki a jelentésben, hogy ez a rész nyitott.

- [ ] **Step 4: Commit**

```bash
git commit --allow-empty -m "chore: verify the visual language on the real library"
```

---

## Elfogadási kritériumok

- ⓐ `swift build` és a teljes suite zöld macOS 26 deployment targettel, csendes gépen.
- ⓑ Egyetlen `String(format:` sincs a `Features/` alatt; az időtartam mindenhol ugyanúgy néz ki.
- ⓒ Egyetlen szín-literál sincs a `Features/` alatt, és adatkategória-szín sehol nem jelöl státuszt.
- ⓓ Nincs egymásba ágyazott `GroupBox`.
- ⓔ A toolbar-feliratok magyar felületen magyarul jelennek meg — **futó appban ellenőrizve**, nem csak `hu.lproj`-bejegyzésként.
- ⓕ Minden animáció tiszteletben tartja a reduce-motion beállítást.
- ⓖ CPU <15% a valódi könyvtáron, 25 s és 115 s után.
- ⓗ A CHANGELOG kimondja a breaking change-et, és a letöltőoldal a macOS 14–15 felhasználókat a v1-re irányítja.
- ⓘ A vizuális ellenőrzés emberi része **kimondva nyitott** — nem elhallgatva.

---

## Task 2b: A paletta szabályai legyenek tényleg kikényszerítve

**Kiváltó ok:** a 2. task söprése után három, egymással összefüggő hiba maradt a fában — mindhárom arról szól, hogy a szabály ki van mondva, de nincs betartatva.

### 1. Státuszszín egy mérési görbén

Az `InsightsView` három egymás melletti trend-diagramja: FWHM → `accent`, Background → `accent`, Efficiency → **`ok`**.

Az `ok` azt jelenti: „rendben van". Egy mérési görbén ez **értékítéletet mond az adatról**, függetlenül attól, mit mutat — a diagram olyat állít, amit a szám nem. Ez ugyanaz a hiba, mint a régi Health oldal „0 calibration issues"-a, csak grafikonon.

Emellett a `trendChart` **három külön diagramot** épít, mindegyiknek saját címe és tengelye van (small multiples), egyetlen sorozattal. Köztük a szín **semmilyen információt nem hordoz** — a különböző szín különbséget sugall, ami nincs.

**Döntés:** mind a három `accent`-et kap, az `ok` eltűnik innen. Nem kell új token: egy hue a small multiples-hez őszinte, és megszűnik a hamis ítélet.

### 2. A kapu csak egy irányba néz

Az `AstroTokensTests.dataColorsAreNotStatus` azt őrzi, hogy adatkategória-szín ne jelentsen státuszt. **Visszafelé nem néz** — ezért nem szólt az `ok`-ra egy grafikonon.

**Bővítés:** ugyanaz a teszt fogja el a másik irányt is — `ok`/`attention`/`critical` nem jelenhet meg olyan sorban, ami adat-sorozatot rajzol (`LineMark`, `PointMark`, `BarMark`, `AreaMark`, `foregroundStyle` egy `Chart` blokkon belül). Ha ez forrás-vizsgálattal nem fejezhető ki tisztán, gateld a leszűkített, védhető részhalmazt, és **mondd ki a teszt doc-kommentjében, mit nem fog el** — ne írj olyan tesztet, ami véletlenül megy át.

### 3. Lejárt felmentés a nyers színliterál-kapuban

A `V2PolishSurfaceTests.noBareStatusColorLiterals` **két fájlt véglegesen felment** (`Features/Planning/PlanningView.swift`, `Features/Planning/SkyPathChart.swift`), ezzel az indoklással: „Planning is intentionally excluded: it is under a separate, currently-frozen read-only audit and was not part of this sweep."

Az az audit **2026-08-15-én lezárult** (wave 5, Planning workbench). Az indok lejárt, a felmentés maradt — két fájl azóta korlátlanul megszegheti a szabályt. Egy indok nélkül maradt felmentés csendben állandó lyukká válik; a projekt saját auditja pont ezt kifogásolta a lejárat nélküli nyugtázásoknál.

**Teendő:** a felmentés **törlendő**, és a két találat javítandó:
- `SkyPathChart.swift:22` — a `RuleMark` a fotózhatósági küszöböt jelöli („ez alatt nem éri meg"). Ez **valódi figyelmeztetés**, tehát `attention`.
- `PlanningView.swift:357` — döntsd el a kontextusból; ha státusz, `attention`/`critical`, ha adat, akkor a megfelelő adat-token.

**Files:** `Sources/AstroUI/Features/Insights/InsightsView.swift`, `Sources/AstroUI/Features/Planning/SkyPathChart.swift`, `Sources/AstroUI/Features/Planning/PlanningView.swift`, `Tests/AstroUITests/AstroTokensTests.swift`, `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1:** a bővített kaput és a felmentés törlését **előbb** — mindkettőnek buknia kell a jelenlegi fán. Igazold.
- [ ] **Step 2:** a három javítás.
- [ ] **Step 3:** teljes suite csendes gépen, majd commit:

```bash
git commit -m "fix: enforce the palette's own rules"
```

---

## Task 2c: Egy kapu, ami tényleg minden színt lát

**Kiváltó ok:** a 2b. task jelentése talált egy nyers `.yellow`-t a `SkyPathChart`-ban, ami „kívül esik a kapu regexén". Utánanézve **kilenc** ilyen van, hét fájlban — és ez nem a fejlesztők hanyagsága, hanem a kapuké:

| Kapu | Mit fed le |
|---|---|
| `noHardcodedColorLiterals` | `Color(red:` és `Color(#colorLiteral` — csak **numerikus** literálok |
| `noBareStatusColorLiterals` | `green`, `orange`, `red`, `purple` — **négy** név |

A SwiftUI-nak ennél sokkal több beépített színe van. Ami átcsúszott:

```
.yellow   NightNoteSheet.swift:130        figyelmeztető háromszög
.yellow   SkyPathChart.swift:30           kulmináció-jelölő a diagramon
.blue     InsightsView.swift:307          oszlop-gradiens
.blue     SensorProfilesView.swift:26,142,144   ikonok
.gray     FrameBlinkReview.swift:219      placeholder kitöltés
.gray     ReviewWorkspace.swift:542       kis mintaszám jelzése
.white    ConversionWorkspace.swift:295   kiválasztott elem előtere
```

**A legbeszédesebb a `NightNoteSheet:130`:** egy figyelmeztető háromszög sárgában, miközben mindenhol máshol a figyelmeztetés `attention` (narancs). Ugyanaz a jelentés, két szín, két képernyőn — pontosan az az S9-minta, ami miatt a kapu készült. Azért élte túl, mert a kapu neveket sorolt fel, nem szabályt fogalmazott meg.

**Files:** a hét forrásfájl + `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1: A két kapu egyesítése, teljes névlistával**

Vond össze a kettőt egyetlen `noInlineColorsInFeatureViews` tesztté, ami elfog **minden** beépített SwiftUI-színnevet (`black white gray grey red orange yellow green mint teal cyan blue indigo purple pink brown clear primary secondary`) **és** a numerikus literálokat. A `.primary`/`.secondary`/`.clear` **engedélyezett** — ezek szemantikus rendszerszerepek, nem konkrét színek; a doc-komment mondja ki, miért.

A regex ne találjon bele azonosítókba (`.redacted`, `.grayscale`), és kommenteket előbb szűrj ki. **Igazold, hogy bukik**: futtasd a javítás előtt, és sorolja fel mind a kilencet.

- [ ] **Step 2: A kilenc javítása**

Mindegyiknél a **jelentés** dönt, nem a mai szín:

- `NightNoteSheet:130` → `attention` (figyelmeztetés, ahogy mindenhol máshol)
- `SkyPathChart:30` → `accent` (a kulmináció adat-jelölő, nem státusz)
- `InsightsView:307`, `SensorProfilesView` ×3 → `accent`
- `FrameBlinkReview:219` → `inkFaint` vagy `edge` (üres hely jelzése)
- `ReviewWorkspace:542` → `dataUnclassified` (kevés minta = „nem tudok róla eleget", nem státusz)
- `ConversionWorkspace:295` → a kiválasztott elem előtere; ha a háttér `accent`, akkor a rendszer saját kontraszt-párja kell, nem nyers fehér — döntsd el a kontextusból és indokold

- [ ] **Step 3: Suite + commit**

```bash
git commit -m "fix: let the colour gate see every colour"
```

---

## Task 5b: A hibaosztály elkapása, nem a hetedik előfordulás javítása

**Kiváltó ok:** az 5. task lezárása után az `ExportMenu` ugyanazzal a hibával maradt, amit épp javítottunk. Ez a **hetedik** előfordulása ennek ebben a projektben:

1. `MetricCard.title` (korábbi hullám)
2. `ArchiveClass.displayName` (7b)
3. `ArchiveTargetRow.displayName` — motorrétegben (8)
4. `ArchiveStripView.reclaimHelpText` (10)
5. `LibraryWelcomeView.actionableMessage` (14)
6. `WorkspaceAction/Menu/MenuItem.title` + `help` (5)
7. `ExportMenu`/`ExportMenuItem.title`

Hét azonos hiba után a javítandó nem a hetedik előfordulás, hanem az, hogy **semmi nem akadályozza meg a nyolcadikat.** A `String`-ként tipizált felületi szöveg lefordul, működik, tesztel átmegy — és soha nem fordul magyarra.

**Mérés:** 24 `String`-ként tipizált, felületi nevű property az `AstroUI`-ban. **Nem mind hiba** — vannak köztük valódi adatok (keresési találat címe = célpontnév). Ezért ez a task nem tömeges csere.

**Files:** `Tests/AstroUITests/V2PolishSurfaceTests.swift`, plus a valódi szivárgások fájljai

- [ ] **Step 1: A kapu, ami az osztályt fogja**

```swift
@Test("No user-facing text in AstroUI is typed as String")
func uiTextIsNeverAPlainString() throws {
    // A String selects SwiftUI's verbatim overload and produces no
    // extraction key, so it compiles, renders, passes every test -- and
    // never translates. Seven separate instances of this shipped before
    // this gate existed; it is the class, not any one of them, that needs
    // holding. Anything on the allowlist is DATA (a target name, a file
    // path, a catalog designation), not prose, and each entry says which.
    let uiNames = ["title", "help", "label", "caption", "subtitle",
                   "explanation", "actionTitle", "message", "placeholder"]
    …
}
```

Az allowlist **soronként indokolt** legyen, és az indoklás mondja meg, **miért adat** az a mező — nem azt, hogy „egyelőre így maradt". Egy indok nélküli felmentés fél év múlva állandó lyuk (lásd a 2b. task lejárt Planning-felmentését).

**Igazold, hogy bukik**: futtasd a jelenlegi fán, és sorolja fel a 24-et.

- [ ] **Step 2: Döntsd el mindegyikről, adat-e vagy szöveg**

Az egyértelműen felhasználói szövegek, amiket javítani kell:

- `WorkspaceComponents.swift:6,7,67,68` — a `WorkspacePage`/`WorkspaceTablePage` **oldalcíme és alcíme**. Ez minden munkatér fejléce.
- `App/BreadcrumbBar.swift:11`
- `App/V2RootView.swift:1484,1485,1487,1515` — az üres állapotok címe, üzenete és gombfelirata
- `Features/Exports/ExportMenu.swift:79` (+ az `ExportMenuItem` saját `title`-je)
- `Settings/SettingsStore.swift:10`, `App/V2RootView.swift:1553,1579`, `Features/Review/ReviewWorkspace.swift:617` — `String`-et visszaadó `switch`-ek

Amikről **külön dönts, és indokold** (adat vagy szöveg?): `GlobalSearchStore.swift:19,20` (találat címe/alcíme — célpontnév?), `Help/GlossaryView.swift:22` (`name` — szakkifejezés?), `Help/MetricInfoButton.swift:14,15`, `Operations/OperationHost.swift:23,43,54` (művelet-nevek a toastokban).

Ha egy mezőről nem tudod eldönteni, **ne találgass** — hagyd, tedd az allowlistre „eldöntetlen" indoklással, és jelentsd.

- [ ] **Step 3: Fordítások**

A `switch`-alapúak és a nem-első-argumentumú literálok a kinyerő script számára láthatatlanok — kézzel a `hu.lproj` végi csoportba, ahogy az eddigiek.

- [ ] **Step 4: Suite + commit**

```bash
git commit -m "fix: gate the whole class of untranslatable UI text"
```

---

## Task 5c: A három eldöntetlen mező, és a halott cím kivezetése

Az 5b. task három mezőt **szándékosan** hagyott eldöntetlenül, ahelyett hogy megtippelte volna. Itt vannak a döntések, plusz egy halott mező, amit ugyanaz a task talált.

### 1. A halott `title` kivezetése

`WorkspacePage.title` és `WorkspaceTablePage.title` (`Features/Workspace/WorkspaceComponents.swift:6,67`) tárolt property, mind a **hét** hívási hely átadja — és **egyik `body` sem olvassa**. A képernyőn látszó cím valójában minden hívási hely saját `.navigationTitle(...)`-jéből jön.

Egy mező, amit hét helyen kitöltenek és sehol nem használnak, nem ártalmatlan: a következő olvasó azt hiszi, ez rajzolja a fejlécet, és oda írja a javítást, ahol semmi nem történik. **Törlendő**, mind a hét hívási helyről is. Az `eyebrow` paramétert is nézd meg ugyanezzel a szemmel — ha szintén nem rajzolódik, az is megy.

### 2. `OperationHost.title` és `message` → fordítandó

Ezek a **toastokban és a haladásjelzőn** jelennek meg — „Verifying integrity finished.", „Scanning library…". Ez a felhasználóhoz szóló próza, nem adat. Fordítandó.

- `title` (23., 54. sor): 8 hívási hely, mind literál — egyenes átalakítás.
- `message` (43. sor): ~25 hívási hely, és **néhány `error.localizedDescription`-t interpolál**. Ez a nehéz része: a hibaleírás futásidejű adat, tehát a mondat lefordítható fele és az interpolált hiba **külön** kell hogy maradjon. Ne egyetlen formátumkulcsba told — ha egy hívási hely nem bontható szét tisztán, hagyd `String`-en, tedd az allowlistre indoklással, és jelentsd.

Az `OperationHost` `Sendable`; ha a `LocalizedStringKey` (ami nem `Sendable`) ezt eltöri, **állj meg és jelentsd** — az típusrendszer-szintű döntés, nem a te hívásod. A `ProjectWorkspaceRow` precedense ilyenkor `NSLocalizedString` eager feloldás.

### 3. `GlobalSearchStore.subtitle` → szétválasztás, nem formátumkulcs

Ma egy kategória-szót („Project", „Night", …) és interpolált adatot kever egyetlen `String`-be, hat hívási helyen.

**Ne** csinálj belőle `"%@ · %@"` formátumkulcsot — az a kategóriát is adattá fokozná le, és a fordító nem látná a szavakat. Helyette a rekord hordozzon **kettőt**: egy `kind`-ot (lefordítható kulcs) és egy `detail`-t (nyers adat, marad `String`). A nézet két `Text`-ként rajzolja.

**Files:** `Features/Workspace/WorkspaceComponents.swift` + a 7 hívási hely, `Operations/OperationHost.swift` + hívási helyei, `Features/Search/GlobalSearchStore.swift` + a nézete, `hu.lproj`, `V2PolishSurfaceTests.swift`

- [ ] **Step 1:** a halott mezők törlése, suite zöld
- [ ] **Step 2:** `OperationHost`, a `message` interpolációit egyesével átnézve
- [ ] **Step 3:** a keresési találat szétválasztása
- [ ] **Step 4:** az allowlist szűkítése azokra, amik tényleg maradnak, indoklással
- [ ] **Step 5:** suite + commit

```bash
git commit -m "fix: translate the operation and search text, drop the dead titles"
```
