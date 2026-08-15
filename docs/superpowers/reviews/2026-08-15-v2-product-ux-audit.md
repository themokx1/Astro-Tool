# AstroTool V2 — termékaudit: kezelhetőség és átláthatóság

**Dátum:** 2026. augusztus 15.
**Vizsgált állapot:** `codex/v2.0.0-ui-rework`, 2.0.0 (20022), 2187 teszt zöld.
**Kérés:** „mehet egy új product audit UI UX oldalról, kezelhetőség, átláthatóság és ezek javítása"
**Módszer:** mind a 61 V2 nézetfájl elolvasása, plusz a megjelenített `AstroApplication`/`AstroCore` típusok; az öt valós munkafolyamat végigjárása a kódban; a motorok szövegeinek visszakövetése a megjelenítési helyükig.
**Mérce:** a tulajdonos korábbi mondata — „a V1 átláthatóbb és kényelmesebb volt, csak rondább".

---

## 1. Vezetői összefoglaló

A V2 **kezelhetőségben** ma már felülmúlja a V1-et: szekciónkénti navigációs verem működő breadcrumbbal és Vissza-val, egyetlen stabil toolbar a munkatér akcióival, közös műveleti gerinc progress/mégse/toasttal, begépelt tokenes megerősítés valódi visszavonással a karanténra és a konverzióra, billentyűzetes szekcióváltás, mindenre kiterjedő globális keresés, és egy `MetricInfoButton`+fogalomtár magyarázó minta, ami — ahol alkalmazva van — jobb bárminél a V1-ben.

**Átláthatóságban viszont a felhasználó szemszögéből még nem előzi meg a V1-et, három konkrét ponton pedig visszalépés.** A V1 mutatta a fixity-ellenőrzés összegzését; a V1 hőmérséklet, fókusztáv, szűrő és master-öregedés szerint vizsgálta a kalibrációt; a V1-ben volt helyszín-megadó lépés. A V2 sikerüzenetet ír egy ellenőrzésre, ami semmit nem jelent vissza; „0 kalibrációs hibát" közöl egy vizsgálatból, ami csak fájlokat számol egy mappában; és arra utasítja a felhasználót, hogy állítson be helyszínt egy Beállítások-fülön, **ami nem létezik**. Ráadásul a V2 hozott egy nyelvi regressziót, ami a V1-ben nem volt: a saját tanács-oszlopa, a ma esti verdiktjei és a konverziós varázslója **magyarul beszél egy angol felületen**.

**A legnagyobb megmaradt hiányosság: az app leghatározottabb állításai a legkevésbé alátámasztottak.** „Read only." „0 calibration issues." „Verification finished." „Score 0,98." „Folytasd a gyűjtést." Mindegyik lezárt tényként jelenik meg, út nélkül a *miért*-hez — és több közülük bizonyíthatóan nem az, aminek látszik. Minden más a jelentésben olyan súrlódás, amit egy gondos felhasználó kikerül; ez az, amitől megszűnik hinni az appnak a pótolhatatlan adatairól.

---

## 2. Három hiba, ami egy-egy teljes munkafolyamatot tesz tönkre

### 2.1. Az app olyat kér, ami lehetetlen — KRITIKUS

`Features/Planning/PlanningView.swift:282` üres állapota: *„This library has no observing site configured… **Set a site in Settings** to rank targets by tonight's sky."*

`Settings/V2SettingsView.swift:17-23` — a Beállításoknak pontosan öt füle van: General, Libraries & Safety, Planning, Equipment, Support. **Egyikben sincs szélesség/hosszúság mező.** Az egész `Sources/AstroUI`-ban nincs helyszín-megadó felület; az `AstroConfig.site` egyedüli írója a `<root>/.astro_tool/config.json`, amit csak az appon kívül lehet szerkeszteni. A V1-ben ez létezett (`OnboardingWizardView.swift:459-460`); a V2 elhagyta a lépést, de megtartotta az utasítást.

Következmények, mind zsákutca: a Planning örökre üres táblát mutat; a Home éjszaka-sávja tartósan „Site not set"; a „Next 30 nights" azt írja, „Add an observing site", de nincs hova; a scan-összegző pedig azt állítja, a helyszín „később beállítható" — ami nem igaz.

**Akinek a FITS-eiben nincs `SITELAT`/`SITELONG`, annak az 1. munkafolyamat (mit fotózzak ma este) 100%-ban elérhetetlen, és az app soha nem mondja meg használható módon, hogy miért.**

### 2.2. Az indulási beolvasás láthatatlan, a hibája néma — KRITIKUS

Induláskor a `restoreSavedLibrary()` → `openAndScan()` fut (`App/V2RootView.swift:148-155`), de: az onboarding nem látszik éles módban (`:119`), az `openAndScan` **nem regisztrál** az `OperationHost`-ba (csak a `rescan` teszi), és a `phase.isScanning`/`scanProgress`/`accessProblemMessage` mezőket **a `LibraryWelcomeView`-n kívül egyetlen nézet sem olvassa**.

Vagyis indításkor a felhasználó ezt látja: Home, „No library open", „Choose Image Library…" — ameddig a beolvasás tart. Ha pedig elbukik (nincs csatolva a kötet, elavult a bookmark), az `accessProblem` beáll, és **senki nem jeleníti meg**: az app egyszerűen üresnek és romlottnak látszik.

### 2.3. A „Needs review" azokat az éjszakákat számolja, amiket már átnéztél — KRITIKUS

`Features/Nights/NightsStore.swift:31-35`: `excludedFrames = totalFrames - usableFrames`, és `triageState = excludedFrames > 0 ? .needsReview : .ready`.

**Attól lesz egy éjszaka „átnézendő", hogy elvetettél benne képkockákat.** Végigcsinálod rendesen a reggeli triázst, kidobsz négy felhős subot — és az éjszaka `Ready`-ből `Needs review`-ba fordul, örökre. Nincs sehol „ezt az éjszakát átnéztem" művelet.

Ez a szám négy helyen felnagyítva jelenik meg (triázs-kártya, Triage oszlop, sidebar-badge, éjszaka-inspector). **Az app fő „mi vár még rám" jelzése fordítva működik, és aki tényleg használja a Review-t, annak soha nem érheti el a nullát.**

---

## 3. Bizalom — sorrendben aszerint, mekkora kárt okoz a téves hit

1. **A Health feltétel nélkül „Read only"-t ír** (`HealthView.swift:101` ← `LibraryHealthQuery.swift:219` beégetett `isReadOnly: true`), miközben egy kattintásnyira a Calibration helyesen „Writable"-t mutat. Aki a Healthnek hisz, azt hiszi, az írás ki van kapcsolva, amikor be van.
2. **A fixity-ellenőrzés a felhasználó szemszögéből no-op**: a `lastVerifySummary`-t **egyetlen V2 nézet sem olvassa**, és a `readSnapshot` soha nem bocsát ki integritás-eltérés találatot. Egy sérülést találó futás eredménye: egy általános „Verifying integrity finished." toast, és semmi más. Közben a Health azt ígéri, hogy eltérésnél „Restore from backup" a teendő — olyan találatra, ami meg sem jelenhet.
3. **A Health kalibráció-vizsgálata sokkal sekélyebb, mint a neve sugallja**: nyers SQL azt nézi, van-e flat/dark fájl a mappában. Soha nem hívja a `CalibAnalyzer`/`CalibHealth` motort, így a **hőmérséklet-, fókusztáv-, szűrő- és rotátor-eltérés, valamint a master-öregedés** — mind létezik a motorban, mind mutatta a V1 — **egyszerűen nincs ellenőrizve**. A „Calibration: 0 needs attention" olyasmiről nyugtat meg, amit a vizsgálat meg sem nézett.
4. **A Review verdikt-írásának hibája néma** (`ReviewWorkspace.swift:452`): `try?`, majd a kijelölés törlődik. 300 képkocka elvetése sikertelenül pontosan úgy néz ki, mint sikeresen.
5. **A „Move to Archive…" azt ígéri, írási joggal működni fog — de soha nem fog**: a sheet egyetlen gombja a Close, és semmilyen kódút nem alkalmaz archív tervet. A 2. munkafolyamat utolsó lépése egy fal, ami kapunak álcázza magát.
6. **A „Preview Link…" egyetlen sessionre tervez, miközben a sor többet sorol fel** (`CalibrationView.swift:220`) — az előnézet alulmutatja egy írás hatókörét.
7. **Az írás-kapcsoló mindent-vagy-semmit**: egy éjszakai jegyzet begépelése és a master darkok hardlinkelése a képkönyvtárba **ugyanaz a kapcsoló**. A felhasználó bekapcsolva hagyja a jegyzeteléshez, és egy kattintásra lesz egy valódi fájlművelettől.
8. **A Home visszaszámlálója az app megnyitásának pillanatában megfagy** — a `HomeView`-nak nincs `.task`-ja, a `HomeStore.configure` egyszer fut. Este 20:00-kor nyitod meg, hajnali 2-kor is a 20:00-s állapotot mutatja.

---

## 4. Nyelvi regresszió: magyar szövegek az angol felületen — KRITIKUS

Hat motor-forrásból hét megjelenítési helyre:

| Forrás | Hol látszik | Mit lát a felhasználó |
|---|---|---|
| `ProjectsQuery.swift:145-166` `ProjectNextAction` | Projects „Next" oszlop, részletpanel, projekt-Overview | „Folytasd a gyűjtést" / „A következő jó éjszakán bővítsd a hiányzó sorozatokat." |
| `NightSweep.swift:133-148` `SkyVerdict` | Planning ⚠ címke, Home verdikt-badge | „alacsony (max 7°)", „ma jó", „Hold zavar (30°, 88%)" |
| `PlanningQuery` `SkyVerdictText.noCoordinate` | ugyanott | „nincs koordináta" |
| `SessionConversionPlanner.swift:458` `humanSummaryHU` | konverzió Review lépés | teljes magyar mondat |
| `CaptureModels.swift:47,67` `displayNameHU` | konverzió pickerek | „Monokróm", „Szélessáv", „Keskenysáv" |
| `SessionConversionPlanner.swift:742-756` | ambiguitás-feloldás | magyar címek és magyarázatok |

Az **app legfontosabb tanácsa** — a Projects „Next" oszlopa — magyarul szól egy angol felületen.

---

## 5. A Planning-pontszám: strukturálisan nem különböztet meg

`PlanningScore.composite` = `0,45·photographable + 0,40·frameFill + 0,15·moon`. Végigszámolva a szállított alapértékekkel:

- **`photographableFactor`** = `clamp(visibleHours / darknessHours)`. Bármely célpont, ami az egész csillagászati éjszakán fent van — a rejtett alacsony sorok után **a túlélő sorok többsége** — pontosan **1,0**-ra telítődik. Hozzájárulás: állandó **0,45**.
- **`moonFactor`** = `1 − megvilágítottság·közelség`, és a megvilágítottság **az egész éjszakára egyetlen szám**. Vékony vagy távoli Holdnál ez majdnem minden sorra ≈1,0. Hozzájárulás: közel állandó **0,13–0,15**.
- **`frameFillFactor`** az egyetlen, ami soronként érdemben változik.

**Vagyis minden pontszám ~0,60-a azonos, és amit a felhasználó háromtényezős ítéletnek olvas, az a gyakorlatban egy frame-kitöltés szerinti rendezés állandó eltolással** — nagyon közel ahhoz a csak-kivágás rangsorhoz, amit az átépítés le akart váltani. A két tizedesjegy egy összenyomott sávon tucatnyi vizuális holtversenyt szül, amit láthatatlanul a `skyScore`, majd a `frameCoverage` tör meg — egyik sem oszlop.

Ráadásul a `PlanningScore.swift:13` doksija azt állítja, a Score oszlop ⓘ-popovere elmagyarázza a képletet. **Nem létezik.** A 0,45/0,40/0,15 súlyok, a 90%-os ideál, a 90°-os Hold-küszöb és a 30°-os magassági küszöb mind láthatatlan.

**A tábla sem átlátható:** 8 oszlop, és ugyanaz a három tény akár háromszor is ki van írva (látható órák kétszer, Hold-távolság háromszor, frame-kitöltés kétszer, két szomszédos oszlopban, más szóhasználattal). ~730 sorral ez olvashatatlan. És vegyes: öt oszlop rendezhető, három nem — **magasság és integrációs idő szerint nem tudsz rendezni**, pedig egy asztrofotós épp azok alapján dönt.

---

## 6. Rendszerszintű minták (3+ fájl — egy helyen javítandó)

| # | Minta | Előfordulás |
|---|---|---|
| **P1** | Motor-rétegbeli magyar szövegek közvetlen megjelenítése | 6 forrás → 7 hely |
| **P2** | `String(format: "%d:%02d")` duplikálva, mértékegység nélkül | 10 hely, 6 fájl, +2 versengő formátum |
| **P3** | „Enable write operations in Settings" — 10 helyen, egyik sem visz oda | 7 fájl |
| **P4** | `accessMode` a store `.task`-jába pillanatképként, soha újra nem olvasva | 3 fájl |
| **P5** | Store `errorMessage` beírva, de soha nem megjelenítve | 5 store |
| **P6** | Két különböző oldal-váz eltérő fejléccel/háttérrel | 7 route vs. 5 route |
| **P7** | Sheet-korszaki `minWidth` pusholt route-okon | 5 fájl |
| **P8** | Beégetett szemantikus színek | 12+ fájl |
| **P9** | Táblák vegyesen rendezhető/nem rendezhető oszlopokkal | 6 tábla |
| **P10** | `N / M` oszlopok, ahol a nevező képernyőnként mást jelent | 4 hely |

---

## 7. Javítási sorrend

1. **Helyszín-szerkesztő** (Beállítások ▸ Location fül + lépés az első indításban), ami az `AstroConfig.site`-ot írja. Enélkül a Planning, a Home éjszaka-sávja és a 30 éjszakás naptár tartósan halott minden olyan könyvtárnál, aminek a FITS-eiben nincs koordináta — miközben az app épp egy nem létező vezérlőhöz küld.
2. **Az indulási beolvasás és a hibái legyenek láthatók** — `OperationHost`-on át, `accessProblem` megjelenítve Retry-jal.
3. **A `triageState` javítása** — az „átnézendő" a *még el nem döntött* képkockákból jöjjön, ne a kizártakból; plusz explicit „éjszaka átnézve".
4. **A hat magyar forrás fordítása** az angol felületre (P1).
5. **A Health legyen őszinte** — valós `isReadOnly`, integritás-eltérés találatok, `lastVerifySummary` megjelenítve, és a kalibráció-vizsgálat kösse be a `CalibHealth` motort.
6. **A jegyzetírás váljon el a fájlmutációtól** — éjszakai jegyzet és projekt-annotáció mehessen a globális írás-kapcsoló nélkül.
7. **Planning-pontszám: ⓘ + dinamikatartomány** — ne telítődjön 1,0-ra, és a szám legyen magyarázható.
8. **Cél-haladás ott, ahol projekteket hasonlítasz** — oszlop a Projects táblában, kártya az Overview-n.
9. **A Review hibái ne nyelődjenek el**, és a tömeges művelet kapjon darabszámos megerősítést.
10. **Az archív-zsákutca feloldása** — vagy bekötni az írás-kapuhoz, vagy eltávolítani a hamis ígéretet.
11. **A Planning tábla öt oszlopra szűkítése**, a három résztényező a kiválasztott sor részleteibe.
12. **Üres/betöltő állapotok a Projects és Nights oldalra**, és „N elrejtve szűrő miatt" kiút a Planning üres találatához.

---

## 8. Ami kifejezetten jól sikerült

Nem csak hibalista: a karantén-apply begépelt tokenes megerősítése valódi visszavonással, a konverzió bizonylat+rollback útja, a `MetricInfoButton` a Review hat minőségi metrikáján és az éjszaka-jegyzet mezőinél, a Planning őszinte üres állapota helyszín nélkül, az integrációs becslés visszautasítása a modell tartományán kívül, a SIMBAD/VizieR adatvédelmi szövege és a beépített katalógusra való visszaesés — ezek mind jobbak bárminél, amit a V1 tudott. A minta létezik; csak nincs mindenhol alkalmazva.
