# Planning Workbench Implementation Plan (wave 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Planning oldal váljon valódi tervezőeszközzé: szűrősáv dátumválasztóval, láthatóság-alapú kiesés, egyetlen magyarázható pontszám három rendezhető részoszloppal, égi útvonal-ábra, menthető célpontok jegyzettel, és lényegesen tágabb katalógus.

**Kiváltó ok (felhasználói visszajelzés, 2026-08-15):** a Planning augusztus 15-én a Lófej-ködöt ajánlotta „Good framing, ≈4,4 h"-val, miközben az Orion-vidék hajnalban 7 fokon jár. A `DiscoveryPlanner` motor ezt tudja, a V2 Planning nem hívta meg. A felhasználó kérése ezen túl: „ami nem fotózható, essen ki teljesen", felül szűrő- és akciósáv, dátumválasztó (alapból ma), a rangsorban szerepeljen a **frame-kitöltés (90% a legjobb)**, a **valós fotózható idő** és a **Hold-közelség (kevésbé számít)**, egyetlen pontszámmal és mindhárom oszlop külön is rendezhetően; menthető célpontok, jegyzet, égi útvonal, és tág katalógus (Rho Ophiuchi, LBN 437 és társai).

**Előfeltétel:** a wave-5 munka a `2026-08-15` visibility-alapozásra épül (Planning a `DiscoveryPlanner`-re kötve, integrációs becslés érvényességi tartománnyal). Az alapozás külön commitokban landol; ez a terv onnan folytatja.

**Architektúra:** minden számítás a meglévő `AstroCore/Sky` motorokra épül (`DiscoveryPlanner`, `Planner`, `SunMoon`, `SkyScore`) — új asztrofizikát NEM írunk. A pontszám tiszta, tesztelhető függvény az `AstroApplication` rétegben. A mentett célpontok és jegyzetek a V2 metadata-adatbázisba kerülnek (schema v6). A UI a wave-4-ben bevezetett `WorkspaceTablePage` mintát követi: fix fejléc/szűrősáv + saját magasságú tábla.

**Kritikus megkötések (a fagyás-sorozat tanulságai — lásd `Sources/AstroUI/Features/Planning/PlanningStore.swift` fejlécét):** semmilyen számítás nem kerülhet a `body`-ba; `init` mellékhatás-mentes; minden setter azonosérték-őrrel; eredmények tárolt property-ben, generation-guarddal; a store aktiválása `activate()`-ből.

**Tech Stack:** Swift 6, SwiftUI macOS 14+, Swift Charts, Swift Testing, SQLite.

**Teszt-futtatás:** `set -o pipefail && swift test --disable-sandbox --no-parallel --filter <F> 2>&1 | tail -20`; teljes: `--quiet | tail -5`; build: `swift build --disable-sandbox --target AstroToolApp`.

---

### Task 1: Magyarázható pontszám + három rendezhető oszlop

**Files:**
- Create: `Sources/AstroApplication/Features/Planning/PlanningScore.swift`
- Modify: `Sources/AstroApplication/Features/Planning/PlanningQuery.swift`
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift`
- Test: `Tests/AstroApplicationTests/PlanningScoreTests.swift` (új)

A pontszám három, egyenként 0–1 tényezőből áll, súlyozva:

| Tényező | Súly | Alak |
|---|---|---|
| Frame-kitöltés | 0,40 | csúcs a rövid oldal **90%-ánál**; efölött (mozaik felé) és alatta is csökken |
| Valós fotózható idő | 0,45 | a ma éjszakai, `minAltitude` fölötti órák a teljes csillagászati sötétség arányában, telítődve |
| Hold-távolság | 0,15 | a Hold fázisával **súlyozva** — sötét Holdnál a közelség alig büntet |

- [ ] Írj failing teszteket a tiszta függvényre: 90%-os kitöltés magasabb pontot ad, mint 40% vagy 130%; több fotózható óra magasabb pontot ad; a Hold-tényező 13%-os Holdnál alig változtat, 95%-osnál érdemben büntet; a súlyok összege 1.
- [ ] Implementáld a `PlanningScore`-t (tiszta, `Sendable`, dokumentált képlettel).
- [ ] Kösd be a `PlanningQuery` vetítésébe: minden sor kapja meg a három résztényezőt ÉS az összesített pontot.
- [ ] Failing surface-teszt: a tábla négy rendezhető oszlopot ad — **Score**, **Frame fill**, **Photographable**, **Moon** —, mindegyik `sortOrder`-rel, alapértelmezés Score szerint csökkenő.
- [ ] Implementáld a táblát (`Table(..., sortOrder:)`, `TableColumn(..., value:)`), a Score oszlop mellé ⓘ popover a képlet magyarázatával (`MetricInfoButton` már létezik).
- [ ] Teljes suite + build; commit `feat: rank planning targets by an explainable composite score`; push.

### Task 2: Szűrő- és akciósáv dátumválasztóval

**Files:**
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift`, `PlanningStore.swift`
- Modify: `Sources/AstroApplication/Features/Planning/PlanningQuery.swift` (dátum-paraméter)
- Test: `Tests/AstroUITests/PlanningStoreTests.swift`, surface-teszt

- [ ] Failing store-tesztek: alapértelmezett dátum a **mai**; a dátum megváltoztatása újraszámol (egyszer, azonosérték-őrrel); a „nem fotózható elrejtése" szűrő **alapból BE**, kikapcsolva megjelennek az alacsony célpontok is (megjelölve).
- [ ] Implementáld a store-oldalt (a `refresh()` generation-guardos mintáját követve; a dátum a `DiscoveryPlanner.discover` hívás paramétere).
- [ ] Failing surface-teszt: a fix fejlécben (`WorkspaceTablePage` toolbar-slot) egyetlen sávban van a `DatePicker` (`v2.planning.date`), a „Hide targets that aren't photographable tonight" kapcsoló (`v2.planning.hide-unobservable`), a keresőmező, a setup-választó és az akciógombok (`v2.planning.save-target`, `v2.planning.plan-project`).
- [ ] Implementáld a sávot; a „ma" gomb egy kattintással visszaáll a mai dátumra.
- [ ] Teljes suite + build; commit `feat: give planning a filter and action bar with a date picker`; push.

### Task 3: Égi útvonal (magasság-görbe)

**Files:**
- Create: `Sources/AstroApplication/Features/Planning/SkyPathQuery.swift` (magasság mintavételezése a `Planner`/`SunMoon` motorral, szürkülettől hajnalig)
- Create: `Sources/AstroUI/Features/Planning/SkyPathChart.swift` (Swift Charts)
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift` (kiválasztott sor alatt/mellett)
- Test: `Tests/AstroApplicationTests/SkyPathQueryTests.swift` (új), surface-teszt

Referencia: a V1-ben ez létezett — `Sources/AstroToolApp/Views/SkyChartView.swift` (8 KB). Ugyanaz a tartalom natív V2 formában, a motor újrahasznosításával; a V1 fájlt NE importáld.

- [ ] Failing query-teszt rögzített dátummal és helyszínnel: a görbe a szürkület→hajnal ablakot fedi le, a maximum a delelésnél van, és a `maxAltitudeDeg` egyezik a `DiscoveryPlanner` által adott értékkel (ugyanaz a motor, nem külön számítás).
- [ ] Implementáld a query-t (mintavételezés ~5 percenként; a számítás a store async útján fut, nem a body-ban).
- [ ] Failing surface-teszt: `v2.planning.sky-path` chart jelen van, jelöli a delelést és a `minAltitude` küszöbvonalat, és a Hold pozícióját is mutatja, ha értelmezhető.
- [ ] Implementáld a chartot; üres állapot, ha nincs kiválasztott sor vagy nincs helyszín.
- [ ] Teljes suite + build; commit `feat: show the selected target's path across the night sky`; push.

### Task 4: Mentett célpontok és jegyzetek (metadata schema v6)

**Files:**
- Modify: `Sources/AstroApplication/Persistence/MetadataSchema.swift` (`currentVersion = 6`, `versionSixSQL`)
- Modify: `Sources/AstroApplication/Persistence/MetadataStore.swift` (CRUD)
- Create: `Sources/AstroUI/Features/Planning/SavedTargetsView.swift` (+ store)
- Modify: `Sources/AstroUI/Features/Planning/PlanningView.swift` (mentés-gomb, jegyzet-sheet), `Sources/AstroUI/App/AppRoute.swift` + `V2RootView.swift` (`.savedTargets` route a Planning alatt)
- Test: `Tests/AstroApplicationTests/MetadataStoreTests.swift`, `Tests/AstroUITests/SavedTargetsTests.swift` (új)

Séma:
```sql
CREATE TABLE IF NOT EXISTS planning_saved_targets (
    id TEXT PRIMARY KEY,
    designation TEXT NOT NULL UNIQUE,
    saved_at TEXT NOT NULL,
    note TEXT
);
CREATE INDEX IF NOT EXISTS idx_planning_saved_targets_saved_at ON planning_saved_targets(saved_at);
```

- [ ] Failing migrációs tesztek: v5 → v6 adatvesztés nélkül, tranzakcióban, forward-only (kövesd a meglévő `if version < N` mintát); a verzió 6-ot mutat; hibás migráció rollbackel.
- [ ] Implementáld a migrációt.
- [ ] Failing store-API tesztek: `saveTarget(designation:note:)` (idempotens a designationre), `updateNote`, `removeSavedTarget`, `savedTargets()` mentés szerint csökkenő.
- [ ] Implementáld.
- [ ] Failing UI-tesztek: mentés-gomb a kiválasztott sorra (`v2.planning.save-target`), jegyzet-szerkesztő sheet (`v2.planning.note`), mentett lista route (`v2.planning.saved`), törlés megerősítéssel; a mentett állapot a Planning táblában is látszik (jelölés).
- [ ] Implementáld.
- [ ] Teljes suite + build; commit `feat: save planning targets with notes`; push.

### Task 5: Tág katalógus online forrásból, helyi gyorsítótárral

**Felhasználói döntés (2026-08-15):** online lekérdezés SIMBAD/VizieR-ből, nem beépített adatfájl. **Felelős értelmezés:** a lekérdezés **letöltés + helyi gyorsítótár**, NEM minden tervezésnél futó hálózati hívás — különben a tervező lassú, hálózatfüggő és sérülékeny lenne. Az első letöltés után minden offline működik.

**Files:**
- Create: `Sources/AstroCore/Sky/CatalogFetcher.swift` (VizieR TAP/ASU lekérdezés, katalógusonként: Sh2, LBN, vdB, Barnard, Abell PN, Caldwell, NGC/IC bővítés)
- Create: `Sources/AstroCore/Sky/CatalogCache.swift` (letöltött katalógus az Application Support alatt, a képkönyvtáron KÍVÜL; verziózott, sérülés esetén visszaesik a beépítettre)
- Modify: `Sources/AstroCore/Sky/TargetCatalog.swift` (beépített 217 = offline alapkészlet; a gyorsítótár rámerge-elődik)
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift` (opt-in kapcsoló + „Katalógus frissítése" művelet az `OperationHost`-on, progress+Mégse)
- Create: `docs/DATA-SOURCES.md` (forrás + attribúció)
- Test: `Tests/AstroCoreTests/CatalogFetcherTests.swift`, `CatalogCacheTests.swift` (újak)

**Megkötések:**
- **Opt-in.** Alapból kikapcsolva, mint az Open-Meteo időjárás. Az app offline ígérete nem sérülhet csendben; a Beállítások mondja ki, mit és hova küld a lekérdezés (célpont-katalógus nevek, semmilyen személyes vagy könyvtáradat).
- **A hálózat soha nem blokkolhatja a UI-t:** a letöltés az `OperationHost`-on fut progress-szel és Mégsével; hiba esetén érthető üzenet, a beépített katalógus marad érvényben.
- **Attribúció kötelező** (`docs/DATA-SOURCES.md` + a Support fülön): „This research has made use of the SIMBAD database / VizieR catalogue access tool, CDS, Strasbourg, France."
- A tesztek **nem hálózhatnak**: a fetchert injektálható transport mögé kell tenni, rögzített minta-válaszokkal.

- [ ] Failing tesztek a parserre rögzített VizieR-válaszmintákkal: `IC 4604` (Rho Ophiuchi) és `LBN 437` helyes koordinátákkal áll elő; hiányzó méret/magnitúdó nem ejti el a sort; duplikált designation feloldva a beépített katalógus javára.
- [ ] Implementáld a fetchert + parsert (injektálható transport).
- [ ] Failing cache-tesztek: letöltött katalógus mentése/olvasása, verzió-ellenőrzés, sérült fájl → visszaesés a beépítettre, a képkönyvtáron kívüli útvonal.
- [ ] Implementáld a cache-t.
- [ ] Failing keresés-tesztek: alternatív jelölések (`Rho Ophiuchi`, `LBN437`, `LBN 437`) és magyar nevek is találnak.
- [ ] Failing settings/surface-teszt: opt-in kapcsoló (`v2.settings.extended-catalog`) és frissítés-művelet, alapból kikapcsolva.
- [ ] Implementáld a UI-t; `docs/DATA-SOURCES.md` + README.
- [ ] **Teljesítmény-kapu:** a bővített katalógussal a Planning szűrése/rendezése továbbra is gyorsítótárazott, és a CPU-mérés 0% marad a valódi könyvtárral.
- [ ] Teljes suite + build; commit `feat: fetch an extended target catalog on demand`; push.

---

## Végső kapu

- [ ] Teljes suite zöld (--no-parallel), app build zöld.
- [ ] CPU-mérés a **valódi** könyvtárral, mind a hat szekcióra: `open -n build/AstroTool.app --args -UITestInitialSection <szekció>` → 0% marad (a nagyobb katalógus nem hozhatja vissza a fagyást).
- [ ] Szakmai ellenőrzés a CLI-vel: `astrotool plan --root /Volumes/images/Astro` kimenete és a Planning rangsora ugyanazt az éjszakát mutassa (Orion-vidék alacsony, NGC 7000 / IC 1396 / Szív-Lélek jó).
- [ ] Paritás-CSV `discover` sor frissítve, `V2FeatureParityTests` zöld.
- [ ] Build-szám emelés, `./build.sh`, `./scripts/install-local.sh`.
