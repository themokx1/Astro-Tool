# AstroTool 2.1 — „Archívum-térkép": teljes UX-újratervezés

**Dátum:** 2026-08-16
**Ág:** `codex/v2.0.0-ui-rework` (worktree: `.worktrees/v200-ui-rework`)
**Kiindulás:** 2.0.0 (20026), 2300 teszt zöld
**Kiváltó ok:** a tulajdonos visszajelzése — „tökre hányás a UX, nagyon szar kezelni ezt a programot, olyan mintha nem embereknek lenne szánva"
**Jóváhagyott irány:** teljes újratervezés új vizuális nyelvvel; a hős-pillanat a **könyvtár-rendrakás**; platform **macOS 26**

---

## 1. Kiinduló probléma

A V2 funkcionálisan gazdag és technikailag rendben van (a `2026-08-14`-i és `2026-08-15`-i auditok kritikus találatai javítva, 2300 teszt zöld). A napi élmény mégis rossz, és a mostani auditok ezt nem fogták meg, mert **hibalistát írtak, nem termékdiagnózist**. Az öt szerkezeti ok:

1. **A navigáció az adatmodellt tükrözi, nem a munkamenetet.** `Home / Projects / Nights / Planning / Library / Insights` — hat szekció, 18 `ContentRoute`, és egyik sem egyetlen felhasználói kérdésre felel. Egy asztrofotósnak négy pillanata van: *mit fotózzak ma este*, *mi jött be reggelre*, *hol tartok egy célponttal*, *rendben van-e az archívumom*. Mindegyik pillanat ma 3–5 oldalra van szétkenve.

2. **Az app nyersanyagot tesz le, nem választ ad.** 12 tábla, 68 oszlop. A `Sources/AstroUI/Features/Home/HomeView.swift:180` fejléce három sor tölteléket ír („OBSERVATORY WORKSPACE" / „Prepare the next clear night" / „Keep plans, observing nights, and library health in one quiet workspace"), alatta két számláló-kártya (`Projects`, `Nights`), amelyek semmilyen döntést nem támogatnak.

3. **Számok, amelyek mellé mentegetőzés kell.** `HealthView.swift:133` kiírja, hogy `Calibration: N`, majd `:138`-on saját bekezdésben elmagyarázza, hogy ez csak a *nulla flat/dark fájlú* sessionöket számolja, és hogy hőmérséklet, fókusztáv, szűrő, rotátorszög és master-öregedés **nincs ellenőrizve**. Ha egy szám mellé cáfolat kell, a szám a hibás.

4. **Feliratok gomb helyett.** A Health találat-tábla `Next step` oszlopa (`HealthView.swift:209`) statikus szöveget rajzol („Preview cleanup"). Az integritás-találatoknál a vizsgálat sosem tanul meg fájlútvonalat (`HealthView.swift:381` saját doc-kommentje mondja ki), így az app „állítsd vissza biztonsági mentésből" tanácsot ad anélkül, hogy megmondaná, **melyik fájlt**.

5. **A karbantartást kézzel kell elindítani.** `Rescan`, `Run Audit`, `Verify Integrity…`, `Cleanup Preview` — négy gomb. A piac (FitsInsight, Athenaeum) háttérben figyeli a mappát, és éjszaka magától lefuttatja a pontozást és a kalibráció-párosítást. Egy könyvtár-karbantartó eszköznek nem *kérnie* kell a karbantartást.

Az ok nem hiányzó funkció. **Túl sok funkció van, és mindegyik a felhasználóra hagyja a gondolkodást.**

---

## 2. Mérési alap (a valódi könyvtár, nem fixture)

Forrás: `/Volumes/images/Astro/.astro_tool/astrotool.sqlite`, utolsó audit-futás (2026-08-13), read-only lekérdezéssel.

| Mérés | Érték |
|---|---|
| Archívum | **611,9 GB** · 11 185 fájl · 13 célpont · 38 éjszaka |
| Szerep szerint | stack 233,4 GB · light 191,5 GB · besorolatlan 109,2 GB · feldolgozott 49,6 GB · flat 15,3 GB · dark 8,7 GB · bias 4,2 GB |
| `residue` (Siril-köztes) | **142,1 GB** · 3 228 fájl |
| `duplicate-content` | **27,1 GB** · 326 fájl |
| `sure_error` | 41 (32 `calib-in-wrong-dir`, 4 `duplicated-catalog-prefix`, 3 `nested-session-tree`, 1 `orphan-calib-dir`, 1 `placeholder-name`) |
| Visszanyerhető összesen | **169,2 GB — az archívum 27,7%-a** |
| Legrosszabb célpont | `M42_Orion`: 143,0 GB-ból **101,8 GB köztes fájl** (egyetlen éjszaka anyagából) |

Ez a mérés dönti el a hős-képernyőt: a felhasználó legnagyobb, legkonkrétabb, ma láthatatlan problémája az, hogy **az archívuma több mint negyede szemét, és ezt semmilyen képernyő nem mondja meg neki.**

---

## 3. Célok és nem-célok

### Célok

1. Minden szekció **egyetlen felhasználói kérdésre** feleljen, és a válasz legyen mondat, ne táblázat.
2. Az Archívum szekció **egy pillantás alatt** mutassa meg, hol van a 612 GB és mi belőle a visszanyerhető.
3. Minden probléma mellett ott legyen a **gomb, ami megoldja** — ugyanazzal a biztonsági rítussal, mint ma (előnézet → karantén → bizonylat → visszavonás).
4. Legyen **saját vizuális nyelv**, amelyben minden szín pontosan egy dolgot jelent az egész appban.
5. A könyvtár **magát tartsa karban**: kötet-csatlakozásra és aktiválásra néma inkrementális scan, utána háttér-audit.
6. Egyetlen szám se jelenjen meg mértékegység, hatókör és magyarázat nélkül.

### Nem-célok

- Nem írunk új asztrofizikát. Minden számítás a meglévő `AstroCore` motorokra épül.
- Nem lazítunk a vasszabályon: a képkönyvtárban továbbra sem törlünk és nem mozgatunk automatikusan.
- Nem építünk hardvervezérlést, saját stacking motort, felhő-fiókot.
- A CLI felülete **nem változik**. Az `AstroCore` publikus API-ja csak additívan bővül.
- A V1 app (`Sources/AstroToolApp/Views/**`, `main` ág) érintetlen marad.

---

## 4. Tervezési alapelvek

Ez az öt mondat dönt el minden későbbi vitát.

1. **Előbb az ítélet, aztán a bizonyíték.** Minden képernyő tetején egy mondat áll, amit el lehet olvasni és be lehet zárni az appot. A táblázat alatta van, nem helyette.
2. **A szín jelentés.** Hat adat- és állapotszín, mindegyik egyetlen fogalomhoz kötve, az egész appban. Nincs dekoratív szín.
3. **Ha egy szám mellé cáfolat kell, a szám nem jelenik meg.** Sekély vizsgálat nem kap főcím-számot; kap egy őszinte mondatot vagy semmit.
4. **Minden probléma mellett gomb van, nem felirat.** Ha nincs végrehajtható akció, akkor a találat nem találat, hanem információ, és nem a teendőlistában a helye.
5. **Amit a gép meg tud csinálni, azt ne kérje.** A scan és az audit magától fut; a gombok megmaradnak, de nem kötelezőek.

---

## 5. A vizuális nyelv

A mostani `AstroTokens` öt rendszerszín, négy távolság és egy sarok-lekerekítés — nincs karaktere. A csere teljes rendszer.

### 5.1 Paletta

A színek a keskenysávos hamisszín-leképezés logikájából jönnek: ami a képen a gyűjtött jel, az az UI-ban a gyűjtött adat.

| Token | Sötét | Világos | Jelentés — kizárólag ez |
|---|---|---|---|
| `ground` | `#070A10` | `#F6F7FB` | Az ablak alapja. Kékbe hajló grafit, nem fekete, nem semleges szürke. |
| `surface` | `#10151F` | `#FFFFFF` | Kártya, panel. |
| `surfaceRaised` | `#161D29` | `#FFFFFF` + árnyék | Kiemelt kártya, popover. |
| `edge` | `#232C3C` | `#DFE4EE` | Hajszálvonal. |
| `ink` / `inkDim` / `inkFaint` | `#E9EDF6` / `#7B89A3` / `#55607A` | `#131824` / `#5C6884` / `#8E99AE` | Szöveg három szinten. A szürkék kékbe hajlanak — választott semleges, nem örökölt. |
| `dataLight` | `#46CDD6` | `#0E9AA4` | **Light frame.** Egyben az elsődleges akció színe. |
| `dataStack` | `#F0B429` | `#B87B0C` | **Stack.** |
| `dataProcessed` | `#C78F1D` | `#8E5E08` | **Feldolgozott kép.** |
| `dataCalibration` | `#9B87E8` | `#6A54C4` | **Dark / flat / bias.** Sosem jelent státuszt. |
| `dataUnclassified` | `#48536B` | `#98A3B8` | **Amit az app nem ismert fel.** Szürke, mert nem tud róla semmit. |
| `critical` | `#FF6455` | `#D0392A` | Hiba, duplikátum, visszanyerhető hely. Az egyetlen hangos szín — ezért ritka. |
| `attention` | = `dataStack` | = `dataStack` | Figyelmet kér, de nem hibás. |
| `ok` | `#3FB58F` | `#1E8464` | Rendben. Desaturált, OIII-ból származtatott — nem rendszerzöld. |

**Megkötés:** a `dataLight`…`dataUnclassified` ötös **csak** adatkategória-kódolásra használható (sáv, jelmagyarázat, chip). Státuszt kizárólag `ok` / `attention` / `critical` jelöl. A meglévő `V2PolishSurfaceTests.noBareStatusColorLiterals` kapu kiterjesztendő: `Features/` és `Settings/` alatt nyers `.green/.orange/.red/.purple/.blue/.teal` literál tilos, és `AstroTokens.Color.data*` nem szerepelhet státusz-kontextusban (`severity`, `isHealthy`, `verdict` nevű kifejezés mellett).

Mindkét megjelenés `NSColor(name:dynamicProvider:)`-rel készül, ahogy a mostani tokenek is. Emellett a Beállítások ▸ Általános kap egy **„Mindig sötét felület"** kapcsolót, alapból **be** — az éjszakai használat ezt indokolja, de nem vesszük el a platform választását.

### 5.2 Tipográfia

Nincs letöltött betűtípus (a `.lproj`-csapda után nem viszünk be új erőforrás-kockázatot). Az arculatot két rendszerfaj kontrasztja adja: **szoros betűközű, nagy méretű sans fejlécek** és **tabular monospace adat**.

| Szerep | Meghatározás | Hol |
|---|---|---|
| `display` | `.system(.title, weight: .semibold)`, `tracking(-0.5)` | Az ítélet-mondat a képernyő tetején |
| `sectionTitle` | `.system(.title3, weight: .semibold)`, `tracking(-0.2)` | Kártyacím, szekciófejléc |
| `body` | `.system(.body)` | Magyarázó szöveg |
| `dataHero` | `.system(size: 30, weight: .medium, design: .monospaced).monospacedDigit()`, `@ScaledMetric` alap | Kártya fő értéke („142,1 GB") |
| `data` | `.system(.callout, design: .monospaced).monospacedDigit()` | Táblacella, sor-érték |
| `micro` | `.system(.caption2, design: .monospaced)`, `tracking(1.4)`, `.textCase(.uppercase)` | Mikrocímke („UTOLSÓ ELLENŐRZÉS · 4 PERCE") |

Minden szám `monospacedDigit()`. Minden fejléc `text-wrap: balance` megfelelője: `.multilineTextAlignment(.leading)` + `.fixedSize(horizontal: false, vertical: true)`. A pont-alapú méretek `@ScaledMetric`-en keresztül skálázódnak, hogy az akadálymentességi szövegméret ne törje szét a sávokat.

**Mértékegység-szabály (a `P2` minta felszámolása):** egyetlen `AstroFormat` enum az `AstroUI`-ban — `duration(_:)` → `12:40 ó`, `bytes(_:)` → `142,1 GB`, `count(_:)` → `3 228`. A `String(format: "%d:%02d")` tíz példánya (hat fájlban) erre cserélődik. Kapu-teszt: `Features/` alatt nyers `String(format:` tilos.

### 5.3 Felületek és Liquid Glass

Egy szabály: **az üveg a keret, nem a tartalom.** Az anyagot a rendszer adja a shellnek; a tartalmi kártyák tömör felületek.

| Réteg | Anyag |
|---|---|
| Sidebar, ablak-toolbar, menük | Rendszer-Liquid Glass (macOS 26-on újrafordításból jön) |
| Az Archívum fejléc-sáv | `surface` + `.backgroundExtensionEffect()`, hogy az archívum-sáv színe a toolbar alá fusson |
| Kártyák, táblák, listasorok | `surface` / `surfaceRaised` + `edge` hajszálvonal, `ConcentricRectangle` sarokkal |
| Lebegő akciósáv (kijelölés esetén) | `GlassEffectContainer` + `.buttonStyle(.glassProminent)` az elsődleges gombra |
| Görgetési él | `.scrollEdgeEffectStyle(.soft, for: .top)` a listákon |

Ellenőrzött, SDK 26.5-ben létező API-k: `glassEffect(_:in:)`, `Glass.regular/.clear/.identity`, `Glass.tint(_:)`, `Glass.interactive(_:)`, `GlassEffectContainer`, `glassEffectID(_:in:)`, `glassEffectUnion(id:in:)`, `glassEffectTransition(_:)`, `backgroundExtensionEffect()`, `scrollEdgeEffectStyle(_:for:)`, `.buttonStyle(.glass)` / `.glassProminent`, `ConcentricRectangle`.

**Tilos:** üveg olvasandó szöveg vagy adatsáv alatt. A kontraszt nem tárgyalható.

### 5.4 Mozgás

A mozgás állapotváltozást közöl, nem hangulatot.

- A visszanyerhető-sín szélessége **animálva** csökken, amikor egy karantén lefut (`withAnimation(.snappy(duration: 0.45))`).
- Egy célpont-sor vörös síne kifakul, amikor tisztává válik.
- A teendő-kártyák `glassEffectTransition`-nel tűnnek el a listából.
- Beolvasás közben a fejléc mikrocímkéje él („BEOLVASÁS · 4 210 / 11 185").
- **Minden animáció mögött `@Environment(\.accessibilityReduceMotion)` kapcsoló**, kikapcsolva azonnali állapotváltás.
- Semmilyen dekoratív, folyamatos animáció. (Lásd az antipattern-jegyzet 6. pontját: feltétel nélküli időzített ciklus megosztott állapoton tilos.)

### 5.5 Nyelvi szabályok

- A felület a felhasználó szavait használja, nem a típusnevekét. Tiltólistán: *Triage, Frame fill, Photographable, Combo, Phase, Series, Usable, Residue, Finding*. Helyettük: *átnézendő, képkivágás-kitöltés, fotózható, beállítás, szakasz, sorozat, használható, köztes fájl, találat*.
- Minden gomb azt mondja, ami történni fog, és a visszajelzés ugyanazt a szót használja múlt időben („Karanténba mozgatás" → „Karanténba mozgatva").
- Hibaüzenet elmondja, mi történt és mit lehet tenni. Nincs bocsánatkérés.
- Motor-rétegbeli magyar szöveg **soha** nem jelenik meg közvetlenül (`P1` minta) — a prezentációs határon fordul, ahogy a `SkyVerdict.parse(_).english` már teszi.

---

## 6. Információs architektúra

### 6.1 Négy szekció

| Szekció | A kérdés, amire felel | Mit olvaszt magába |
|---|---|---|
| **Ma este** | „Mit fotózzak, mivel, meddig?" | `planning`, `savedTargets`, a `home` terv-része |
| **Reggel** | „Mi jött be, mi jó belőle?" | `nights`, `night`, `review`, `reviewFrame` |
| **Célpontok** | „Hol tartok?" | `projects`, `project`, `projectSeries`, `result`, `resultsWorkspace`, `insights` |
| **Archívum** | „Rendben van a könyvtáram?" | `library`, `health`, `calibration`, `cleanup`, `conversion` |

A `home` route megszűnik: nincs olyan kérdés, amire a mai Home felel. Indításkor az app a **Reggel** szekcióra nyílik, ha az utolsó beolvasás óta új éjszaka érkezett, egyébként a **Ma estére**; a választás felülírható a Beállításokban.

Az `insights` önálló oldalként megszűnik — a trendek oda kerülnek, ahol a kérdés felmerül (célpont-áttekintő, éjszaka-áttekintő). A `sensorProfiles` a Beállítások ▸ Felszerelés alá kerül: konfiguráció, nem napi munka.

### 6.2 Route-leképezés

Új `PrimarySection`: `tonight`, `morning`, `targets`, `archive`.

| Mai `ContentRoute` | Új |
|---|---|
| `.home` | **törlés** |
| `.planning`, `.savedTargets` | `.tonight`, `.tonightSaved` |
| `.nights`, `.night(_)` | `.morning`, `.night(_)` |
| `.review(projectID:)`, `.reviewFrame(_)` | változatlan, `morning` alá |
| `.projects`, `.project(_)`, `.projectSeries(_)` | `.targets`, `.target(_)`, `.targetSeries(_)` |
| `.result(_)`, `.resultsWorkspace(projectID:)` | változatlan, `targets` alá |
| `.insights` | **törlés** — tartalma a célpont/éjszaka áttekintőkbe |
| `.library` | `.archive` (**az új térkép-oldal**) |
| `.health` | **beolvad** `.archive`-ba (teendő-kártyák) |
| `.calibration` | `.archiveCalibration` |
| `.cleanup` | **beolvad** `.archive`-ba; a részletes előnézet `.archiveQuarantinePreview` |
| `.conversion` | `.archiveConversion` |
| `.sensorProfiles` | **törlés** — Beállítások ▸ Felszerelés |
| — | **új:** `.archiveTarget(String)` — egy célpont archívum-bontása |
| — | **új:** `.archiveQuarantinePreview` — a tételes karantén-előnézet (a mai `cleanup` tartalma) |

**Az Archívum sidebar-gyerekei** (a mai `Health`/`Calibration` mintája szerint, `DisclosureGroup`-ban): **Kalibráció** (`.archiveCalibration`) és **Rendezés** (`.archiveConversion`). „Épség" nevű aloldal **nincs** — a mai `health` teljes tartalma a térkép teendő-kártyáiba olvad. A karantén-előnézet és a célpont-bontás pusholt route, nem sidebar-sor.

A `WindowRestorationState` sémája bővül; a régi blob dekódolása **nem törhet el** — ismeretlen `primarySection`/`contentRoute` esetén az `AppRouter` restoring `init`-je az alapértelmezett szekcióra esik vissza (a mai `projectTab`/`nightTab` `Optional`-kezelés mintája szerint). A `astrotool://` mélylinkek régi hoszt-nevei (`home`, `library/health`, `insights`) **megmaradnak** átirányításként, hogy a kiadott dokumentáció ne törjön.

---

## 7. Az Archívum szekció (1. hullám — részletes terv)

### 7.1 Adatréteg

Új fájlok az `AstroApplication`-ben:

- `Features/Archive/ArchiveMapQuery.swift`
- `Features/Archive/ArchiveTaskQuery.swift`

Olvasási minta: `SQLiteDB(readOnlyPath:)` az index-adatbázisra, ahogy a `LibraryHealthQuery.readSnapshot` teszi; az `AppStoragePaths.production(libraryID:libraryRoot:)` adja az útvonalat. **Új tábla nem kell, séma-emelés nincs.**

```swift
public enum ArchiveClass: String, CaseIterable, Codable, Sendable {
    case light, calibration, stack, processed, unclassified
}

public struct ArchiveSlice: Equatable, Sendable {
    public let archiveClass: ArchiveClass
    public let fileCount: Int
    public let bytes: Int64
}

public struct ArchiveTargetRow: Equatable, Sendable, Identifiable {
    public let id: String              // a célpont mappaneve
    public let displayName: String     // ember-olvasható név
    public let nightCount: Int
    public let fileCount: Int
    public let totalBytes: Int64
    public let slices: [ArchiveSlice]  // bájt szerint csökkenő
    public let reclaimableBytes: Int64
    public let reclaimableFiles: Int
}

public struct ArchiveMapSnapshot: Equatable, Sendable {
    public let totalBytes: Int64
    public let fileCount: Int
    public let targetCount: Int
    public let nightCount: Int
    public let slices: [ArchiveSlice]
    public let rows: [ArchiveTargetRow]
    public let reclaimableBytes: Int64
    public let reclaimableFiles: Int
    public let lastScanAt: Date?
    public let lastAuditAt: Date?
    /// `true`, ha van beolvasás, van audit, de a beolvasás újabb —
    /// ilyenkor a visszanyerhető-adat elavult, és a felület ezt kimondja.
    /// Audit nélkül `false`: az „még nem néztem át" külön, saját ága a
    /// felületnek, nem elavultság.
    public var isAuditStale: Bool {
        guard let lastScanAt, let lastAuditAt else { return false }
        return lastScanAt > lastAuditAt
    }
}
```

**Szerep → osztály leképezés:** `light` → `.light`; `flat`/`dark`/`bias` → `.calibration`; `stack` → `.stack`; `processed` → `.processed`; minden más → `.unclassified`. A leképezés egyetlen `ArchiveClass.init(role:)`-ban él, és unit teszt pinneli — a `files.role` értékkészlete az `AstroCore` `Scanner` felelőssége, ismeretlen érték `.unclassified`-ba esik, nem crashel.

**Fő lekérdezés** (egy menetben, `GROUP BY`):
```sql
SELECT target, role, COUNT(*), SUM(size), COUNT(DISTINCT session_date)
FROM files WHERE missing = 0 GROUP BY target, role;
```

**Visszanyerhető-lekérdezés** — a legutóbbi audit-futás `residue` és `duplicate-content` találatai, méretre kötve:
```sql
SELECT f.target, COUNT(*), SUM(f.size)
FROM findings d JOIN files f ON f.path = d.path
WHERE d.run_id = (SELECT MAX(id) FROM runs WHERE kind = 'audit')
  AND d.category IN ('residue', 'duplicate-content')
  AND f.missing = 0
GROUP BY f.target;
```
A nyugtázott (`finding_acks`) csoportok kimaradnak — ugyanaz a `(category, groupKey)` kulcs, amit a `MetadataStore.acknowledgements()` ad.

**Teendők** (`ArchiveTaskQuery`): a legutóbbi audit-futás találatait **kategóriánként összevonja**, nem soronként listázza.

```swift
public enum ArchiveTaskKind: String, Sendable {
    case intermediateFiles      // residue
    case duplicateContent       // duplicate-content
    case misplacedCalibration   // calib-in-wrong-dir, orphan-calib-dir
    case brokenNames            // placeholder-name, duplicated-catalog-prefix,
                                // nested-session-tree, noncanonical-subdir
    case integrity              // ellenőrzőösszeg-eltérés
    case auditNeverRun          // őszinte állapot, nem hiba
}

public enum ArchiveTaskSeverity: String, Sendable { case reclaim, error, attention, info }

public struct ArchiveTask: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: ArchiveTaskKind
    public let severity: ArchiveTaskSeverity
    public let headlineValue: String        // „142,1 GB" vagy „32"
    public let title: String
    public let explanation: String          // egy mondat, ember-nyelven
    public let evidencePaths: [String]      // legfeljebb 3 valódi útvonal
    public let affectedFileCount: Int
    public let bytes: Int64
    public let action: ArchiveTaskAction
}

public enum ArchiveTaskAction: Equatable, Sendable {
    case previewQuarantine(categories: [String])
    case compareDuplicates
    case revealInFinder(path: String)
    case runAudit
}
```

**Fontos megkötés:** `ArchiveTask` csak akkor jön létre, ha az `action` valóban végrehajtható. Nincs olyan kártya, aminek a gombja nem csinál semmit — ez a 4. alapelv gépi kikényszerítése, és egységteszt pinneli.

Ebből következik két, ebbe a hullámba tartozó járulékos munka:

- Az `integrity` kártya konkrét fájlútvonalat igényel. Az `AuditRunCommand` verify-ága ezért az eltéréseket `integrity` kategóriájú `Finding` sorokként is kiírja az útvonallal együtt (ma csak toastol — a `2026-08-15`-i audit 3(b) pontja). Amíg egy eltérés útvonal nélküli, kártya **nem** készül belőle; a fejléc-mondat viszont kimondja, hogy sérülés van.
- A „Move to Archive…" sheet (`ResultsView`) egyetlen gombja a Close, és semmilyen kódút nem alkalmaz archív tervet (`2026-08-15`-i audit 3(5) pontja). Ez **hamis ígéret**, ezért ebben a hullámban **törlendő**, nem elrejtendő.

### 7.2 A képernyő

`Sources/AstroUI/Features/Archive/ArchiveView.swift` + `ArchiveStore.swift`, `ArchiveStripView.swift`, `ArchiveTaskCard.swift`, `ArchiveTargetRowView.swift`.

Nem-görgető gyökér `VStack` (a `WorkspaceTablePage` mintája szerint — a `Table`/`List` görgető konténerben tilos, lásd antipattern 5.):

```
┌ RÖGZÍTETT FEJLÉC ────────────────────────────────────────────┐
│  Három dolog vár rád.                    ELLENŐRIZVE · 4 PERCE│
│  Semmi nem sérült. 169,2 GB nyerhető vissza —                 │
│  ebből 101,8 GB egyetlen célpontnál.                          │
│                                                               │
│  ARCHÍVUM · 611,9 GB                            11 185 FÁJL   │
│  ████████████████ ██████████████ ████████ ███ ██              │
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬                                              │
│  169,2 GB VISSZANYERHETŐ — AZ ARCHÍVUM 27,7%-A                │
│  ● Light  ● Stack  ● Feldolgozott  ● Kalibráció  ● Besorolatlan│
└───────────────────────────────────────────────────────────────┘
┌ EGYETLEN GÖRGETŐ LISTA ──────────────────────────────────────┐
│  TEENDŐK                                                      │
│  [142,1 GB  Siril-köztes fájlok       → Karantén előnézete…]  │
│  [ 27,1 GB  Bájtra azonos másolatok   → Példányok…        ]   │
│  [     32   Flat rossz helyen         → Megnyitás Finderben]  │
│  CÉLPONTOK                                                    │
│  M42 · Orion-köd    ████████ ███ ██      143,0 GB  −101,8 GB  │
│  …                                                            │
└───────────────────────────────────────────────────────────────┘
```

**Az ítélet-mondat** (`display` fokozat) determinisztikus:

| Feltétel | Mondat |
|---|---|
| `tasks.isEmpty && !isAuditStale` | „Rendben van a könyvtárad." |
| `tasks.count == 1` | „Egy dolog vár rád." |
| `tasks.count > 1` | „{N} dolog vár rád." |
| `isAuditStale` | „A legutóbbi ellenőrzés régebbi, mint a beolvasásod." |
| nincs audit-futás | „Még nem néztem át a könyvtáradat." |

A második sor: mindig kimondja, sérült-e valami (`integrity`), és mennyi nyerhető vissza.

**Az archívum-sáv** (`ArchiveStripView`): `HStack(spacing: 1.5)` osztályonként egy `Rectangle`, szélesség = bájtarány. 30pt magas, 5pt sarok. Alatta 5pt magas sín, benne a visszanyerhető arány `critical` színnel. Egy osztály akkor kap saját szeletet, ha ≥0,5%; az ez alatti maradék egy „egyéb" szeletbe olvad, hogy ne keletkezzen 1px-es, kattinthatatlan sáv.

- **Hover:** `.help()` — „Stack · 233,4 GB · 5 626 fájl".
- **Kattintás:** szűri az alatta lévő célpont-listát arra az osztályra; a szelet kiválasztott állapotot kap; újrakattintás feloldja.
- **Akadálymentesség:** a sáv `accessibilityElement(children: .contain)`, minden szelet saját `accessibilityLabel` + `accessibilityValue`, `accessibilityIdentifier: "v2.archive.strip.<class>"`.

**A célpont-sorok** `List`-ben (nem `Table`): három oszlop-szerű elrendezés (`210pt` név / rugalmas sávok / `92pt` érték), a sávok az **archívum legnagyobb célpontjához** normalizálva, hogy a sorok összehasonlíthatók legyenek. Sor kontextusmenü: `Megnyitás Finderben`, `Célpont-riport…`, `Karantén előnézete erre a célpontra…`, `Megnyitás a Célpontok között`. Dupla kattintás → `.archiveTarget(id)`.

**Teendő-kártya**: bal oldalon `dataHero` érték + `sectionTitle` cím + egy mondat + legfeljebb 3 valódi útvonal `code` stílusban; jobb oldalon egyetlen gomb. `severity == .error` esetén `critical` keret és halvány színátmenet. Több gomb nincs; a másodlagos műveletek a kártya kontextusmenüjében.

### 7.3 Állapotok

| Állapot | Mit mutat |
|---|---|
| Nincs könyvtár | `ContentUnavailableView` + „Képkönyvtár kiválasztása…" |
| Beolvasás fut | A fejléc mikrocímkéje él, a sáv a részleges adatból már rajzolódik |
| Beolvasva, audit sosem futott | **A térkép rendes rajzolódik** (csak a `files` tábla kell); a visszanyerhető-sín rejtve; egyetlen `auditNeverRun` kártya: „Még nem néztem át a könyvtáradat. Az ellenőrzés semmit nem módosít." + `Ellenőrzés futtatása` |
| Minden rendben | Ítélet-mondat + térkép + „Nincs teendő." — a térkép **nem** tűnik el, mert önmagában is hasznos |
| Hozzáférési hiba | `LibraryAccessProblemBanner` a fejléc alatt, `Újra` + `Másik mappa…` |
| Lekérdezési hiba | A `store.errorMessage` **megjelenik** (a `P5` minta felszámolása), `Újra` gombbal |

### 7.4 Teljesítmény és stabilitás

Kötelező, a fagyás-sorozat tanulságai szerint (`astro-tool-swiftui-antipatterns`):

- Minden lekérdezés `async load()`-ban, az eredmény tárolt `private(set)` property, **generation-guarddal**. Semmilyen számítás nem kerülhet computed getterbe vagy `body`-ba.
- `ArchiveStore.init` mellékhatás-mentes; aktiválás explicit `activate()`-ből, a nézet `.task`-jából.
- Minden setter/`didSet` `guard oldValue != newValue else { return }`-cel kezdődik.
- A célpont-lista `List`, korlátos magassággal, soha nem `ScrollView`-ban.
- Nincs időzített ciklus; a frissítés esemény-vezérelt (scan/audit befejezés, kötet-csatlakozás).
- Elfogadási mérés: a valódi könyvtárral, `-UITestInitialSection archive` kapcsolóval indítva a CPU 25 s és 115 s után is **<15%**.

---

## 8. Platform: macOS 26

A `Package.swift` deployment targetje `.macOS(.v14)` → **`.macOS(.v26)`**. Ez ad hozzáférést a teljes Liquid Glass API-készlethez `if #available` őrök nélkül.

Érintett helyek — mind egy commitban, különben a build szétcsúszik:

| Fájl | Változás |
|---|---|
| `Package.swift` | `platforms: [.macOS(.v26)]` |
| `project.yml:5` | `deploymentTarget.macOS: "26.0"` |
| `build.sh:113` | `LSMinimumSystemVersion` → `26.0` |
| `.github/workflows/ci.yml:12` | `runs-on: macos-15` → `macos-26` |
| `.github/workflows/release.yml:13` | `runs-on: macos-15` → `macos-26` |
| `README.md:56,186` | „macOS 14 vagy újabb" → „macOS 26 vagy újabb" |
| `docs/index.html`, `docs/support.html`, `docs/tutorial.html` | ugyanaz |
| `CHANGELOG.md` | **Breaking change** rovat a 2.1.0-hoz |

A `macos-26` GitHub-futtató 2026 februárja óta általánosan elérhető, Xcode 26-tal. A Universal (arm64 + x86_64) release-építés változatlanul működik — a macOS 26 SDK továbbra is fordít Intelre.

**Kockázat és mérséklés:** a minimum-emelés kizárja a macOS 14/15-ön lévő felhasználókat. Mivel a v2.0.0 még prerelease (`rc.2`), ez a legolcsóbb pillanat rá. A `main` ágon lévő **v1 kiadás macOS 14-es marad**, és a letöltőoldal mindkettőt kínálja, a v1-et „macOS 14–15" címkével.

---

## 9. Hullámok

Egy design, négy szállítható hullám. Mindegyik önálló implementációs tervet kap.

| # | Tartalom | Miért ebben a sorrendben |
|---|---|---|
| **1** | **Archívum-térkép** — `ArchiveMapQuery`, `ArchiveTaskQuery`, az `ArchiveView` és a teendő-kártyák; a meglévő `.library` route helyére. A `QuarantineApplyCommand` és a `CleanupPreviewQuery` **változatlanul** újrahasznosul. | Ez az egyetlen hullám, ami önmagában megváltoztatja a napi élményt, és nem igényel se séma-emelést, se navigáció-átszabást. |
| **2** | **Vizuális nyelv** — az `AstroTokens` teljes cseréje, `AstroType`, `AstroFormat`, `ConcentricRectangle`/glass szabályok, majd végigsöprés minden nézeten (`GroupBox`-egymásba ágyazás kivezetése, mentegetőző feliratok törlése, `P2`/`P8`/`P10` minták felszámolása). A platform-emelés macOS 26-ra ennek a hullámnak a **első** lépése. | A térkép már az új tokeneket használja, de azok bevezetése önmagában is egy teljes, tesztelhető söprés — nem szabad összekeverni az új funkcióval. |
| **3** | **Négy szekció** — `PrimarySection` átszabása, route-leképezés, mélylink-átirányítás, restoration-kompatibilitás, `insights`/`sensorProfiles` felszámolása. | A legkockázatosabb rész, és a `wave 4`-ben épített útvonal-verem már működik — csak a bejárati pontok változnak. Ezért jön a térkép **után**. |
| **4** | **Magától karbantartja magát** — `NSWorkspace.didMountNotification` és `didBecomeActiveNotification` figyelése, néma inkrementális scan, utána háttér-audit; a „Rescan"/„Run Audit" gomb megmarad, de nem kötelező. Plusz a `triageState` végleges javítása és az explicit „ezt az éjszakát átnéztem" művelet. | Ez teszi igazzá a „4 perce ellenőrizve" mikrocímkét, amit az 1. hullám kiír. Addig a mikrocímke az utolsó **kézi** futás idejét mutatja, őszintén. |

**A nyitva maradt korábbi tételek**, amelyeket ez a terv magába olvaszt: helyszín-szerkesztő (kész), Planning-pontszám ⓘ és dinamikatartomány (3. hullám), Review néma hibái és tömeges megerősítés (3. hullám), archív-zsákutca (1. hullám — a hamis „Move to Archive…" ígéret törlése), Planning tábla 8→5 oszlop (3. hullám), jegyzetírás elválasztása a fájlmutációtól (4. hullám).

---

## 10. Kockázatok

| Kockázat | Mérséklés |
|---|---|
| A platform-emelés eltöri a CI-t | A `macos-26` futtató váltása ugyanabban a commitban, mint a `Package.swift`; a CI teljes zöldje a hullám kapuja |
| Az `ArchiveMapQuery` lassú 11 185 fájlon | Egyetlen `GROUP BY` menet, nem soronkénti olvasás; a mérés a valódi könyvtáron elfogadási kritérium (<300 ms) |
| A `residue` kategória téves pozitívja valódi adatot minősít szemétnek | A kártya **soha nem töröl**: karantén, bizonylat, visszavonás. A gomb neve „Karantén **előnézete**…", és az előnézet tételes forrás→cél listát mutat |
| A route-átszabás eltöri a mentett ablakállapotot | Ismeretlen `primarySection`/`contentRoute` esetén alapértelmezettre esés; teszt a régi blob dekódolására |
| A `SkyVerdict`-szerű motor-magyar újra beszivárog | A meglévő lokalizációs kapu-teszt (`LocalizationCoverageTests`) kiterjesztése az új felületekre |
| A vizuális söprés regressziót hoz 61 nézetben | A `V2PolishSurfaceTests` kapuk bővítése (nyers színliterál, nyers `String(format:`, `GroupBox`-mélység) — a söprés gépi ellenőrzéssel, nem szemrevételezéssel zárul |

## 11. Tesztelés

- **`AstroApplicationTests`** (új): `ArchiveClass.init(role:)` teljes leképezése; `ArchiveMapQuery` fixture-adatbázison — összegzés, arányok, üres könyvtár, hiányzó `findings` tábla, nyugtázott csoportok kihagyása; `isAuditStale` mindkét ága; `ArchiveTaskQuery` — nincs kártya végrehajthatatlan akcióval.
- **`AstroUITests`** (új): az ítélet-mondat mind az öt ága; a sáv-szeletek összege 100%; a 0,5% alatti szeletek összevonása; `accessibilityIdentifier`-ek jelenléte.
- **Kapu-tesztek** (bővítés): nyers státuszszín-literál, nyers `String(format:`, tiltólistás motor-szavak a felületen.
- **XCUITest**: az `archive` szekció navigációja 12 s válaszidő-küszöbbel, a meglévő harness mintája szerint.
- **Futásidejű mérés**: `-UITestInitialSection archive` a valódi könyvtárral, CPU <15% 25 s és 115 s után.
- A meglévő 2300 tesztnek **zöldnek kell maradnia** (`swift test --no-parallel`).

## 12. Amit szándékosan nem csinálunk

- Nem vezetünk be letöltött betűtípust — a `.lproj` erőforrás-csapda után nem viszünk új bundle-kockázatot.
- Nem építünk kincstári treemapet (DaisyDisk-utánzat): a lineáris, osztály szerint bontott sáv **összehasonlítható** sorokat ad, a treemap nem.
- Nem adunk automatikus törlést semmilyen formában, semmilyen kapcsoló mögött.
- Nem migráljuk a V1 appot. A `main` ág v1 kiadása változatlan marad.
