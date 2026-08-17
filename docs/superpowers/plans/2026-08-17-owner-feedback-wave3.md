# Tulajdonosi visszajelzés (3. hullám) — implementációs terv

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zoltán tizenegy pontja a 2.0.0-rc.3 kipróbálása után. Nem funkciókérések: **négy szerkezeti hiba** megnyilvánulásai.

**Forrás:** a tulajdonos képernyőképekkel és tételes listával, 2026-08-17.

**Ág / worktree:** `codex/v2.0.0-ui-rework` a `.worktrees/v200-ui-rework` worktree-ben.

**Kiindulás:** 2399 teszt zöld (`swift test --no-parallel`). Terhelés alatt az `OperationHost`/toast-időzítés tesztek ingadoznak — ismert, nem regresszió.

---

## A négy tő

1. **Az app olyat ajánl, amiről tudja, hogy lehetetlen.** (T1, T2)
2. **Az akcióknak nincs otthonuk.** (T4, T5, T6)
3. **A szám nem célállomás.** (T3)
4. **Üres szobák.** (T5, T7)

---

## Task 1: A „Ma éjjel legjobb célpontok" ne ajánljon fotózhatatlant

**Mérve:** a `HomeStore.productionTonight` a `Planner.plan(db:config:)`-ot hívja és `prefix(8)`-at vesz belőle — **szűrés nélkül**. A `PlanningQuery` ezzel szemben a `DiscoveryPlanner`-t használja, `isLowAltitude` jelöléssel és (wave 5 óta) alapértelmezett kieséssel.

A wave-5-ös javítás — amit épp a tulajdonos váltott ki azzal, hogy a Planning a Lófej-ködöt ajánlotta, miközben az Orion 7°-on állt — **soha nem került át a Home-ra**. Ez az a képernyő, amit minden indításnál elsőnek lát.

A képernyőképen a lista tartalmaz: egy üstököst `comet — stored coordinate is from capture time, not valid for tonight` felirattal, két célpontot `no coordinates`-szel, és az Oriont `low (max 9°)`-cel. **Az app kiírja az indokot, amiért nem használható, és közben „legjobb célpontnak" nevezi.**

**Files:** `Sources/AstroUI/Features/Home/HomeStore.swift`, `Sources/AstroApplication/Features/Home/` (ha a lekérdezés ott él), `Tests/…`

- [ ] **Step 1: Teszt először** — egy tervben szereplő üstökös / koordináta nélküli / alacsony célpont **nem** kerülhet a `tonightRecommendations`-be.
- [ ] **Step 2:** a Home ugyanazt a szűrést használja, mint a Planning. **Ne** másold a logikát — hívd ugyanazt a motort (`DiscoveryPlanner`), különben a két képernyő megint elcsúszik egymástól. Ez a hiba pont abból keletkezett, hogy két út van ugyanarra a kérdésre.
- [ ] **Step 3:** ha a szűrés után **üres** a lista, az őszinte üres állapot kell (`ContentUnavailableView`), ami megmondja, miért — nem egy lista tele fotózhatatlan sorokkal.
- [ ] **Step 4:** a „Folytasd, ahol számít" ugyanígy: a „legkevésbé gyűjtött aktív projekt" nem lehet olyan, amit **nem lehet folytatni** (üstökös elavult koordinátával). Ha nincs folytatható, mondja ki.

```bash
git commit -m "fix: stop recommending targets the app knows cannot be shot"
```

---

## Task 2: Az Insights ne számoljon duplán

**Mérve a valós könyvtáron:** az Insights **51h 31m**-et ír. **207 light frame ugyanazzal a fájlnévvel több helyen szerepel az indexben, ez 7,63 óra duplán számolt expozíció.**

Az `InsightsQuery` „usable" fogalma mindössze `frameCount − rejectedFrameCount` — **nincs benne deduplikáció**. Az `AstroCore`-ban viszont létezik a valódi, dedupolt integráció, és a termék máshol (README, `TargetStats`) **azt** nevezi „valós integrációnak". Az Insights megkerüli a saját terméke igazságát.

- [ ] **Step 1:** teszt, ami két azonos nevű light frame-et tesz a fixture-be, és elvárja, hogy egyszer számítson.
- [ ] **Step 2:** az Insights a meglévő dedupolt integrációt használja. **Ne írj új dedup-logikát** — ha az `AstroCore`-é nem hívható innen, azt jelentsd, ne másold le.
- [ ] **Step 3:** a felület mondja meg, **melyik számot** mutatja. Ha van „bruttó" és „valós", mindkettő látszódjon, vagy a felirat mondja ki, melyik ez.

```bash
git commit -m "fix: stop counting the same frame twice in Insights"
```

---

## Task 3: A kártya vigyen valahová, ne egy útvonalra

**A tulajdonos szavaival:** „értem hogy 33 kalibráció rossz mappában van, de mit jelent a megnyitás finderben, 33 elemnél mit csinál egy gomb… annak valami page-re kellene hogy vigyen, ahol már egyesével megnyithatom finderben vagy másik gombbal törölhetem archiválhatom".

Ez az **1. hullám tervezési hibája**: a `revealInFinder(path:)` az **első** útvonalat kapta. Egy elemnél jó, harmincháromnál önkényes.

- [ ] **Step 1:** új route: a teendő-kártya részletei — a kártya **összes** találata listában, útvonallal.
- [ ] **Step 2:** soronként művelet (Finderben megjelenítés), és a listán tömeges művelet ott, ahol értelmes (karantén-előnézet erre a halmazra).
- [ ] **Step 3:** a kártya elsődleges gombja **ide** visz, ha a találatszám > 1. Egyetlen találatnál maradhat a közvetlen Finder-megnyitás.
- [ ] **Step 4:** a gombfelirat mondja meg, mi történik: „33 fájl megtekintése" nem „Megjelenítés a Finderben".

```bash
git commit -m "fix: give every finding card a destination, not one arbitrary path"
```

---

## Task 4: Az akcióknak legyen otthonuk

**A tulajdonos három külön ponton mondta ugyanazt:** „nem tetszik hogy az akció gomb, mint értékelés fent van a jobb sarokban, nem a page része"; „a sorok gombjain nincs tooltip, nem tudom mit csinálnak"; „nights oldal … kellene akció gomb, amivel lehet őket értékelni és row button is akcióknak".

**Ez egy korábbi döntés visszavonása.** A `wave 4` szándékosan vitte a lap-akciókat a rögzített shell-toolbarba (`WorkspaceActions`), hogy a drill-down alatt is elérhetők maradjanak. A gyakorlatban ez elszakította az akciót attól, amin dolgozik. A tulajdonos ítélete a mérvadó.

- [ ] **Step 1:** minden sor-ikon kapjon `.help()` tooltipet. Ez a legolcsóbb és azonnal érezhető.
- [ ] **Step 2:** a lap elsődleges akciója **a lapon** legyen, a tartalom fölött, ne csak a toolbarban. A toolbar maradhat másodpéldányként ott, ahol a drill-down alatt is kell.
- [ ] **Step 3:** hiányzó akciók pótlása: **egész projekt értékelése** (minden éjszaka, minden sorozat), és **az összes projektre** ráengedve. Az `Éjszakák` lapon éjszaka-értékelés és sor-műveletek.
- [ ] **Step 4:** a sorozat-nézetből legyen **látható visszaút** (a tulajdonos: „nem tudom hogy megyek vissza").

```bash
git commit -m "fix: put a page's actions on the page"
```

---

## Task 5: A Projektek sorrendje és üres tabjai

- [ ] **Step 1:** az alapértelmezett rendezés a **legutóbbi gyűjtés** szerint, csökkenő. Ma nem az; a tulajdonos: „az kell előre kerüljön, amiben az utolsó gyüjtés van".
- [ ] **Step 2:** a projekt `Nights` és `Series` tabja („butucskák") kapjon annyi információt, amiből dönteni lehet, és sor-műveleteket.
- [ ] **Step 3:** a `Results` tab üres állapota ma helyes szöveget ad, de **semmilyen utat** nem kínál. Ha nincs eredmény, mondja meg, mi hozza létre.

```bash
git commit -m "fix: sort projects by recency and fill the empty tabs"
```

---

## Task 6: Insights elrendezés

A tulajdonos: „nagyon szűk hasábban van zsúfolva". A `WorkspacePage` 920pt-os oszlopa a hosszú szövegnek jó, egy három-diagramos elemző lapnak nem.

- [ ] Az Insights kapjon szélesebb, a rendelkezésre álló helyet kihasználó elrendezést.

```bash
git commit -m "fix: let Insights use the width it has"
```

---

## Sorrend

**T1 először** — az a képernyő, amit minden indításnál lát, és az a hiba, ami a legrosszabbat állítja. Aztán **T2** (mért, rossz szám), **T3** (az én 1. hullámos hibám), majd T4, T5, T6.

A **Liquid Glass nem ebben a hullámban van** — az a 2. hullám 6. taskja, még nem futott le. A tulajdonos helyesen látta, hogy nincs ott.

---

## Task 5b: A sor-műveletek legyenek olvashatók hover nélkül

**Kiváltó ok:** a tulajdonos azt írta, „a sorok gombjain nincs tooltip, nem tudom mit csinálnak". Utánanézve **a tooltipek megvannak, és magyarul is** (`.help("Review frames")` → „Képkockák áttekintése"). A 4. task ügynöke ezért azt jelentette, hogy nincs mit javítani.

**Technikailag igaz, gyakorlatilag nem válasz.** A `ProjectsView` névtelen oszlopa 58 pont széles, benne két címke nélküli SF Symbol (`checklist`, `square.stack.3d.up`). Hogy bármit megtudj róluk, rá kell mutatnod és **várnod** kell a rendszer tooltip-késleltetését. A tooltip nem felfedezhetőség — végszükség. Ha egy funkció csak azon keresztül létezik, akkor gyakorlatilag rejtve van, és a felhasználó panasza pontos, még ha az ok nem az volt is, aminek látszott.

**Ez a tanulság általánosítható:** „már van rá tooltip" soha nem elég válasz arra, hogy „nem tudom, mit csinál".

**Files:** `Sources/AstroUI/Features/Projects/ProjectsView.swift`, `Sources/AstroUI/Features/Nights/NightsView.swift`, `hu.lproj`

- [ ] **Step 1: Válaszd az affordanciát, és indokold**

Két védhető út van; válassz egyet, és írd le a kommentben, miért:
- **Szöveges címke az ikon mellé** — szélesebb oszlop, de nulla felfedezési költség.
- **Egyetlen `⋯` menügomb soronként** — keskeny marad, és a három pont mindenki számára ismert „itt vannak a műveletek" jel; a menü elemei már szövegesek.

A második valószínűleg jobb, mert a sor-műveletek száma nőni fog (a jobbklikk-menüben ma három van, az ikonsorban kettő — **ez maga is zavaró: két különböző készlet ugyanarra a sorra**). Egy menü egyesíti őket.

- [ ] **Step 2:** a jobbklikk-menü és a sor-menü **ugyanazt** a készletet adja. Ma nem ugyanazt adják, és ez önmagában hiba.
- [ ] **Step 3:** a tooltipek maradjanak — csak ne ők legyenek az egyetlen út.

```bash
git commit -m "fix: make row actions legible without hovering"
```
