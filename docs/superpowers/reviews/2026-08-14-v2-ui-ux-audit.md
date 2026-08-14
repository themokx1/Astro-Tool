# AstroTool V2 — UI/UX audit és teljesítmény-diagnózis

**Dátum:** 2026. augusztus 14.
**Vizsgált állapot:** `codex/v2.0.0-ui-rework`, 2.0.0 (20017), 2086 teszt zöld.
**Kiváltó ok:** felhasználói visszajelzés — „a Planning kifagy", illetve korábban „a V1 átláthatóbb és kényelmesebb, csak rondább".
**Módszer:** (1) az élő, befagyott folyamat mintavételezése (`sample`), (2) XCUITest-futás időbélyegeinek elemzése, (3) mind az 59 V2 nézetfájl kódszintű átvizsgálása hat dimenzió mentén.

---

## 1. A fagyás bizonyított oka

A fagyás **nem crash és nem véletlen** — két, egymást szorzó rendszerhiba determinisztikus következménye.

### 1.1. Mérési bizonyíték

A UI-teszt naplójának időbélyegei egyetlen futásból:

| Szekcióváltás | Eltelt idő |
|---|---|
| Home | ~2 s |
| Projects | ~2 s |
| Nights | ~2 s |
| **Planning** | **73 s** (19,67 s → 92,64 s), majd a lekérdezés 3× időtúllépéssel elhalt |

A befagyott folyamat `sample`-je a főszálon 100% CPU-t mutatott egyetlen, soha véget nem érő `NSDisplayCycleFlush → layoutIfNeeded → NSHostingView.layout` rekurzióban.

### 1.2. Az ok-lánc

1. **Feltétel nélküli 1 Hz-es invalidálás.** `Operations/ToastOverlay.swift:32-37` egy `while !Task.isCancelled` ciklusban másodpercenként meghívja az `expireToasts(now:)`-t — **akkor is, ha nulla toast van**. A `ToastOverlay` a gyökérnézetre van felfüggesztve, így ez másodpercenként invalidálja a teljes shellt.
2. **Elveszett sor-virtualizáció.** `Features/Workspace/WorkspaceComponents.swift:23` — a `WorkspacePage` egy `ScrollView`. Öt nézet `Table`-t ágyaz bele: Planning (**a teljes, 217 elemű célpontkatalógus**), Nights (2 tábla), Calibration (2), Projects, Health. A `ScrollView` korlátlan magasságot ajánl a táblának, ezért az AppKit nem tud sorokat újrahasznosítani: **minden layout-menet mind a 217 sort felépíti és elrendezi**.

A kettő szorzata: másodpercenként indul egy teljes, 217 soros layout, ami tovább tart egy másodpercnél → a következő tick már sorban áll → a ciklus soha nem zárul. Ez a fagyás.

### 1.3. Miért nem oldotta meg a korábbi három javítás

A 20013–20017 buildekben javított hibák (nehéz query computed getterben, mellékhatásos `init`, `focusedSceneValue` body-ból, `didSet` azonosérték-őr nélkül) mind **valós, mintavételezéssel igazolt** invalidálási források voltak, és mind csökkentették a terhelést. De egyik sem szüntette meg a **layout költségét** (2. pont), így elég maradt egyetlen periodikus invalidálás (1. pont), hogy a hurok újra összeálljon. A tanulság a jövőre: az invalidálás *forrásait* és a layout *költségét* külön kell kezelni; amíg a költség O(217 sor), bármely új invalidáló forrás visszahozza a fagyást.

---

## 2. Rendszerszintű minták (3+ fájl — konténer szinten javítandó)

Ezek a legfontosabbak: egy helyen javítva több tucat nézet gyógyul.

| # | Minta | Előfordulás | Következmény |
|---|---|---|---|
| **S1** | Korlátlan `Table` görgető konténerben, `.frame(minHeight:)`-tal megtámasztva | **9 fájl, 13 tábla** | fagyás, görgetés-a-görgetésben, elgörgő fejlécek |
| **S2** | Időzített ciklus, ami megosztott `@Observable` állapotot mutál | **6 fájl** (1 Hz toast + négy **50 Hz**-es progress-poller + egy 50 ms-os onboarding-poller) | a felület pont a hosszú műveletek alatt a leglassabb |
| **S3** | Egykattintásos táblasor-kijelölés navigál, tetején dupla-kattintásos `primaryAction` | 4 fájl | dupla kattintás **kétszer** pushol; nem lehet sort kijelölni context-menühöz; nyílbillentyűs bejárás route-ot nyit soronként |
| **S4** | `focusedSceneValue` frissen allokált, nem-Equatable paranccsal a `body`-ból | 3 fájl, 5 érték | ugyanaz a mechanizmus, amit a `WorkspaceActionCenter` már kiváltott — a menüsorra maradt |
| **S5** | Fájlrendszer-`stat` a render-útvonalon (`resolvedURL` a `.disabled(...)`-ben) | 4 fájl, ~12 hívás/menet | folyamatos szinkron I/O a főszálon |
| **S6** | Háromszoros címkézés: breadcrumb + `WorkspacePage` eyebrow/nagy cím + `.navigationTitle` | 7 route | az első képernyő kétharmada díszlet — ez a „V1 átláthatóbb" érzés fő oka |
| **S7** | Rendezhetőnek látszó, de nem rendezhető oszlopfejlécek | **14 táblából 13** | a felhasználó kattint, semmi nem történik |
| **S8** | Nézet beégeti az egyébként injektálható store-t (`@State private var store = XStore()`) | 5 fájl + 3 teljesen privát store | három teljes képernyőnek nulla unit-teszt felülete |
| **S9** | Szemantikus státuszszínek beégetve (`.green`/`.red`/`.orange`/`.purple`) | 12+ fájl | az `AstroTokens`-ben nincs success/warning/danger, ezért minden nézet sajátot talál ki |
| **S10** | Sheet-korszakból maradt `minWidth`/`minHeight` most már pusholt nézeteken | 5 fájl | vízszintes levágás a detail oszlopban |

---

## 3. Kritikus egyedi találatok

**3.1. Gyökér-route önmagára pusholása** — `App/AppModel.swift:233-238`: a `navigate(toContent:)` visszaállítja a cél szekció stackjét, majd **feltétel nélkül** pushol, anélkül hogy ellenőrizné, a route maga a szekció gyökere-e. Elérési utak: „Open in Insights" az éjszaka-menüből, és **minden** `astrotool://` deep link. Következmény: „Insights › Insights" breadcrumb, hamis Vissza-nyíl egy vizuálisan azonos oldalra, és a szekció betöltése kétszer fut. Javítás: egyetlen `guard`.

**3.2. Katalógus-keresés a render-útvonalon** — `Features/Planning/PlanningStore.swift:151-162`: a `filteredRecommendations` teljes, 217 elemű `TargetCatalog.search`-öt futtat, és a `body` **három különböző helyen** olvassa. Ez pontosan az a hiba, amit a `recommendations`-nél már javítottunk — csak eggyel lejjebb, a fogyasztójában. Következmény: a Planning keresőmezőbe gépelve billentyűleütésenként **három teljes katalógus-keresés layout-menetenként**.

**3.3. Fájlrendszer-műveletek a body switchben** — `App/V2RootView.swift:1122`: a `ConversionUseCase.production(rootURL:)` a `DetailHost` body-switchjében fut, ami `resolvingSymlinksInPath()`-en keresztül **több tucat `stat`/`readlink` syscallt** jelent minden body-menetben, amíg a konverziós varázsló látszik.

**3.4. Az elsődleges létrehozó parancs halott a menüsorban** — `Views/Commands.swift:277-283`: a File ▸ **New Project…** `.disabled(true)`, „Available after library workflows arrive" tooltippel — miközben a funkció **működik** a toolbar `+` gombjáról. A ⌘N nem csinál semmit, a tooltip pedig valótlant állít az app saját képességéről.

**3.5. Exportok a főszálon, megszakíthatatlanul** — `Features/Exports/ExportMenu.swift:136-157`: minden export szinkron, a főaktoron rendereli a tartalmat, majd blokkoló `runModal()`-t nyit. Nagy projektnél kemény beachball, progress és Mégse nélkül — miközben a V2-ben minden más hosszú művelet az `OperationHost`-on megy.

---

## 4. Őszintétlen felületek

Ezek külön kiemelést érdemelnek, mert a termék hitelességét rombolják:

- **`Features/Planning/PlanningView.swift:75`** — a „Reference · 10 h · APS-C · f/5 · μ22" kártya **beégetett**. A felhasználó átállíthatja a tervezési alapértékeket a Beállításokban, a motor valóban azok szerint számol, a kártya viszont továbbra is a régi értéket állítja.
- **`Features/Library/LibraryView.swift:35`** — „Read-only access" **feltétel nélkül** megjelenik, akkor is, ha az írási mód be van kapcsolva. A Health és a Calibration helyesen „Writable"-t mutat. Épp az az oldal állít valótlant a fájlbiztonságról, amelyiknek ez a fő ígérete.
- **`Features/Library/HealthView.swift:255-260`** — az integritás-találatokra „No action needed" a javaslat. Ezek **checksum-eltérések**: ugyanezen a képernyőn a verify-sheet mondja ki, hogy ilyenkor backupból kell visszaállítani. A tábla azt tanácsolja, ne csinálj semmit az észlelt fájlsérüléssel.
- **`Features/Home/HomeView.swift:204-267`** — a kezdőképernyő második eleme egy **beégetett geometriájú** éjszaka-idővonal (fix arányok, mindig „Dusk / Observation window / Dawn"), ami valódi szürkület–delelés–hajnal ábrának néz ki, miközben soha nem kap valós adatot.
- **`Features/Library/ConversionWorkspace.swift:351, 381, 384`** — magyar szövegek (`humanSummaryHU`, `displayNameHU`) az egyébként **angol** felületen.
- **`App/V2RootView.swift:1183-1197`** — az `astrotool://settings/<tab>` deep link egy dokumentált útvonal, ami egy placeholder-falba fut („This workflow will become available…").

---

## 5. Hiányzó interakciók és tesztelhetőség

- **Rendezés**: 14 táblából **13** nem rendezhető, pedig a fejlécek kattinthatónak látszanak.
- **Dupla kattintás**: a Health, Calibration (mindkét tábla) és a Night-workspace series-táblája nem reagál, miközben a testvér-tábláik navigálnak.
- **Billentyűzet**: nincs ⌘-gyorsbillentyű a legfontosabb műveletekre; a blink-nézet `a`/`x`/`u` billentyűi módosító nélküliek; a pusholt munkaterekben az Escape nem csinál semmit (sheet-korukban még zárt).
- **Megerősítés nélküli törlés**: `Settings/V2SettingsView.swift:143` — szűrő törlése azonnal, visszavonás nélkül, miközben minden más destruktív út a V2-ben megerősítéshez kötött.
- **Tesztelhetetlen kulcsfelületek**: a három munkalap-tabválasztónak és a Review Accept/Reset/Reject gombjainak **nincs azonosítója** — az app két legfontosabb folyamata UI-teszttel nem vezérelhető. Öt azonosító pedig soronként ismétlődik, így többszörös találatot ad.
- **Végtelen töltő**: `App/V2RootView.swift:983-1031` — ha egy projekt/éjszaka betöltése hibára fut, a route **örökre** „Loading project…"-et mutat; a store hibaüzenetét egyetlen nézet sem jeleníti meg.

---

## 6. Javítási sorrend

**Első hullám — a fagyás megszüntetése (folyamatban):** S1 (táblák saját magasságot kapnak, nem görgetőben) + az 1 Hz-es toast-ciklus megszüntetése. Ez a kettő együtt szünteti meg az ok-láncot.

**Második hullám — teljesítmény és navigáció:**
1. Gyökér-route push-őr (3.1) — egyetlen `guard`, több látható hibát szüntet meg.
2. Az öt poller 50 Hz → ~200 ms, közös, throttle-olt segédben (S2).
3. `ConversionUseCase` ki a body-switchből (3.3).
4. `filteredRecommendations` gyorsítótárazása (3.2).
5. Egykattintásos navigáció megszüntetése (S3): a kijelölés jelöljön ki, a dupla kattintás navigáljon.

**Harmadik hullám — őszinteség és teljesség:**
6. New Project… bekötése a menüsorban (3.4).
7. Betöltési hibák megjelenítése Retry-jal a végtelen töltő helyett.
8. Exportok az `OperationHost`-ra (3.5).
9. A négy őszintétlen felület javítása (4. szakasz).
10. `WorkspacePage` eyebrow/cím-blokk törlése (S6) — hét route kap vissza ~120 pontot az első képernyőből.

**Negyedik hullám — polish és tesztelhetőség:**
11. Hiányzó azonosítók (tabválasztók, Review-gombok) + a soronként ismétlődő azonosítók egyedivé tétele.
12. Rendezés a táblákra (S7), szemantikus szín-tokenek (S9), sheet-korszaki méretkorlátok törlése (S10), injektálható store-ok (S8).

---

## 7. Regressziós védelem

A fagyás azért juthatott el a felhasználóig, mert **a 2086 unit-teszt egyike sem méri a felület válaszidejét**. Ezért a UI-harness minden navigációs lépése mostantól **válaszidő-küszöböt** kap (12 s): a „fagy" nem tud elrejtőzni egy nagyvonalú timeout mögé, hanem konkrét, mérhető hibaüzenet lesz belőle. A harness négy tesztre bomlik: shell-navigáció, Planning ismételt belépés + slider-húzás, Library-algyerekek + projekt-drilldown, inspector.

Emellett strukturális kapu-tesztek pinnelik a rendszerszintű javításokat (nincs `Table` görgető konténerben; nincs feltétel nélküli polling-ciklus), hogy a mintát ne lehessen véletlenül visszahozni.

---

## 8. Utólagos kiegészítés — az igazi gyökérok (2026-08-15)

Az 1. szakaszban leírt két hiba valós volt és javítva lett, de a fagyás **így is megmaradt**. A döntő mérés az volt, hogy az appot a `-UITestInitialSection` kapcsolóval, a **valódi könyvtárral**, szekciónként indítottam:

| Szekció | CPU 30 s-nál |
|---|---|
| Home | 0,0% |
| Projects | 0,0% |
| **Planning** | **99,1%** |

Tehát Planning-specifikus. (A fixture-könyvtárral azért mértünk korábban 0%-ot, mert ott egy onboarding-lap takarja a nézetet — hamis negatív.)

A mintavételezés a `PlanningStore.init`-et és a `handleDefaultsChange`-t mutatta forrónak. Az ok:

**`PlanningStore.init` meghívta a `UserDefaults.register(defaults:)`-t.** Ez `didChangeNotification`-t posztol. A SwiftUI viszont a `PlanningView`-ban lévő `@State private var store = PlanningStore()` alapérték-kifejezést **minden view-konstrukciónál** kiértékeli (csak az első példányt tartja meg). Így minden renderben született egy eldobott store, amely posztolt egy defaults-változást, ami **invalidálta az összes `@AppStorage`-ot** a felcsatolt fában (`V2RootView`, `HomeView`, `V2SettingsView`) → a shell újrarenderelt → a Planning újrarenderelt → újabb eldobott store → újabb notifikáció. Végtelen hurok.

A javítás: a regisztráció az egyszeri `activate()`-be került. Mérés utána: **0,0% 30 és 90 másodpercnél**, valódi könyvtárral, Planningon.

**Általánosítható szabály:** egy `@State`-ben tartott store `init`-je legyen teljesen néma — ne posztoljon notifikációt, ne írjon `UserDefaults`-ba, ne regisztráljon observert, ne indítson munkát. Minden ilyen az explicit, idempotens `activate()`-be való, amit a nézet `.task`-ja hív.
