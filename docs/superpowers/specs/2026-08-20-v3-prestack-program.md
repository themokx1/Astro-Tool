# AstroTool V3 — a stackelés előtti program

**Dátum:** 2026-08-20
**Ág:** `codex/v2.0.0-ui-rework` (kutatás a `.worktrees/v200-ui-rework` munkakönyvtárban)
**Kiindulási alap:** AstroTool V2.0.0 (végleges kiadás, 55741d1, build 20035)
**Állapot:** mind a hat jóváhagyott funkció implementálva a fejlesztési ágon; integrációs review és V3 release-előkészítés hátravan

## Implementációs pillanatkép — 2026-08-20

| Funkció | Állapot | Fő commitok |
|---|---|---|
| Ingest-figyelő | Implementálva | `6aab0e3`, `7a4fc49` |
| Kalibrációs automata | Implementálva | `18e81a1`, `221ae1e`, `cd9e481`, `3701648`, `78616f9` |
| Irányított rendrakó | Implementálva | `ae49eec` |
| Metaadat-javító | Implementálva | `74d478a` |
| Derült-trigger | Implementálva | `ac42262`, `f89cc8b` |
| Élő éjszaka-mód | Implementálva | `c2c429c`, `66593e5`, `93cd418` |

A V2.0.0 tag (`831e084`) óta ez a program 16 commitban, 74 fájlban
9833 hozzáadott és 90 törölt sort tett a fejlesztési ágra. A branch neve és
a `ProductInfo` még V2/2.0.0 maradt; a V3 verzió-, ág- és release-stratégiája
tulajdonosi döntést igényel, ezért ez a dokumentációfrissítés nem módosítja őket.

## 1. Cél és keret

A V2 megoldotta a *"mi történt a könyvtárammal"* kérdést: natív, objektumközpontú felület,
egyetlen bizonyított AstroCore-motor felett. A V3 témája más: **"minden, ami a stackelés
ELŐTT kellhet"** — szervezés, munkafolyamat-előkészítés, automatizálás. Nem stacking, nem
feldolgozás, nem posztprodukció. Hat funkció, a tulajdonos által szó szerint jóváhagyott
scope-ban:

1. Ingest-figyelő
2. Kalibrációs automata
3. Irányított rendrakó
4. Metaadat-javító
5. Derült-trigger
6. Élő éjszaka-mód

Ez a dokumentum funkciónként ad terméktörténetet, motorlistát, adatmodell-hatást, hibás/üres
állapotokat, tesztvázlatot és kockázatot, majd egy hullámtervet a párhuzamos
implementációhoz.

## 2. Nem alku tárgya (V2-ből öröklött, V3-ra kiélezve)

- A felhasználó képfájljaihoz **soha** nem nyúlunk közvetlen törléssel vagy mozgatással.
  Minden fájlrendszeri írás a meglévő `WriteGuard` egyetlen, engedélyezett metódusán megy
  keresztül; minden könyvtár-mutáló művelet `LibraryAccessMode.mutationEnabled` mögött van,
  és tételes, visszavonható, `MutationConfirmationSheet`-es megerősítést kér.
- **Karantén, soha törlés.** Az Irányított rendrakó a meglévő
  preview → karantén → nyugta → visszavonás rituálét használja, egy az egyben — nem hoz létre
  új mutációs útvonalat.
- **Read-only alapértelmezés.** Egyetlen V3 funkció sem kapcsolja be automatikusan az írást;
  a felhasználónak minden egyes műveletet külön jóvá kell hagynia.
- **V2 UI only.** A V1 alkalmazás és felülete érintetlen marad; minden új funkció a
  `V2RootView` / `PrimarySection` / `AstroTokens` rendszerbe illeszkedik.
- **Ugyanaz a motor, sosem másolt predikátum.** Ahol van már bizonyított AstroCore-logika
  (pl. `CaptureBurstGrouper`, `CaptureResolver`, `ResidueMatcher`, `CalibAnalyzer`,
  `GoalTag`), a V3 azt hívja meg — nem írja újra a szabályt egy másik rétegben (ez pontosan
  az a hiba, amit a Metaadat-javító ki is javít a `ScanWorkflowMaterializer`-ben).
- **Nincs daemon, nincs launch-at-login helper a V3.0-ban.** A kártya-figyelés, a délutáni
  értesítés és az élő éjszaka-módú lekérdezés kizárólag az App **futó folyamatán belül**
  élhet (`NSWorkspace` kötet-értesítés, `Timer`/`NSBackgroundActivityScheduler`,
  in-process FS-figyelés). Ha az app nincs nyitva, a funkció nem működik — ez tudatos
  V3.0-korlátozás, nem hiba, és a specifikáció minden érintett funkciónál kimondja.
- **Piros-elsőre, swift-testing.** Minden új motor és Command réteg swift-testing
  (`@Suite`/`@Test`/`#expect`) piros-elsőre tesztekkel készül, ahogy a `docs/superpowers/plans/`
  alatti tervek is dokumentálják.
- **Lokalizáció: angol kulcs + hu tail.** Minden új felhasználó felé menő szöveg angol
  literálként a Swift-kódban, magyar fordítás a `Sources/AstroToolApp/Resources/hu.lproj/
  Localizable.strings`-ben. Az `OperationHost.localized(_:)` dokumentált csapdája (dinamikus
  adatot a feloldott literál KÖRÉ kell interpolálni, sosem a fordítási kulcson keresztül) és
  az, hogy `AstroApplication` nem importálhatja `AstroUI`-t (lásd a `2ea64a3` javítást a
  kártya-importnál), minden új réteg tervezésénél kötelező szempont.

## 3. Valós könyvtár — bizonyíték

Egy korábbi menetből a scratchpadban maradt egy **read-only** index-DB másolat
(`idx.sqlite`, séma v12) és egy különálló, második állapot-DB
(`real.sqlite`, séma v8: `projects, nights, series, frame_decisions, review_states,
mutation_journal, legacy_imports, project_annotations, audit_acknowledgements,
audit_run_history, planning_saved_targets, scan_completions`). **A valós `/Volumes/images`
kötet ebben a menetben nem is volt csatlakoztatva** — az eredetit nem érintettük, csak a már
létező, ártalmatlan másolatokat kérdeztük le. A két adatbázis-réteg léte fontos ténymegállapítás
a 6. fejezet séma-kérdéseihez: az AstroCore index (`files/fits_meta/ratings/…`, v12) és egy
másik, feltehetően AstroApplication/V2-állapot DB (v8) **külön verziózási ciklusban** él — ezt
implementáció előtt validálni kell (lásd 8. Nyitott kérdések).

Konkrét számok az `idx.sqlite`-ból:

- Két rig: **ZWO ASI2600MC Pro** (5585 FITS-keret) és **Canon EOS R8** (2463 CR3-keret).
- **A CR3-keretek egyikének sincs `fits_meta` vagy `ratings` sora** — a CR3-statisztika hiánya
  totális, nem részleges.
- **5782 keretnél üres a `FILTER` mező** (túlnyomórészt a CR3-éjszakák), miközben a ZWO
  éjszakákon explicit `Ha`/`OIII` cím van — pontosan ez a duoband-öröklési rés, amit a
  Metaadat-javító céloz.
- A séma **már tartalmazza** a `capture_groups`, `capture_sources`, `file_capture_assignments`
  (benne `filter_manufacturer_override`/`filter_model_override`/`filter_name_override`/
  `assignment_source` oszlopok) és `filter_profiles` táblákat — a kézi felülbírálás
  DB-oldali vázát tehát **nem kell megépíteni**, csak V2-ből elérhetővé tenni (lásd 5.4).
- Kalibrációs mappa-konvenció: `calibration_library/darks/120sec_-20deg/
  Dark_4deg_120.0s_Bin1_2600MC_gain100_20251228-151504_-20.1C_0001.fit` — valós
  exptime/gain/set_temp kombinációk Dark/Flat/Bias-ra, ez adja az 5.2 gap-lista tesztadatát.
- Session-elrendezés: `sessions/<cél>/<dátum>/lights/*.CR3|*.fit`, a fények dátumtartománya
  2025-12-27 – 2026-08-12.

## 4. Közös infrastruktúra minden funkcióhoz

| Réteg | Hely | Amit a V3-nak tudnia kell |
|---|---|---|
| `OperationHost` | `Sources/AstroUI/Operations/OperationHost.swift` | `run(kind:title:cancellation:work:) -> UUID`, `relayProgress`/`reportProgress`, `cancel(id:)`, `outcome(of:)`. Minden új háttérművelet (mesterkép-építés, élő-mód figyelés) ide regisztrál, saját `OperationKind` esettel. |
| `OperationKind` | `Sources/AstroApplication/Operations/OperationState.swift` | Zárt enum — új eset hozzáadása **minden kimerítő switch-ágat** érint (cím, ikon). Ez a fő ütközési pont a hullámtervben. |
| `WriteGuard` | `Sources/AstroCore/WriteGuard.swift` | "Az egyetlen fájlrendszer-író komponens" — minden write egy explicit, jóváhagyott metóduson megy át, soha nem ír felül, temp+rename atomikus. Új írási kategória (pl. mesterkép fájl) = új, dedikált metódus, nem általános "write" hívás. |
| `LibraryAccessMode` / mutáció | `Sources/AstroApplication/Mutations/LibraryAccessMode.swift`, `LibraryMutationAuthorizer.swift`, `MutationConfirmationSheet.swift` | `.readOnly`/`.mutationEnabled`; minden `*Command` ezt őrzi; a UI tételes, gépelt megerősítést kér (`confirmationToken`), nyugtával és visszavonással. |
| `AstroConfig` | `Sources/AstroCore/Config/AstroConfig.swift` | Nincs numerikus séma-verzió — additív mező + `decodeIfPresent(...) ?? default` mintával bővül, sosem törlünk/nevezünk át mezőt. Új beállítás-csoport (pl. `NotificationRule`) ugyanígy, a `WeatherRule` (egyetlen `enabled: Bool`) a legközelebbi minta. |
| Index DB séma | `Sources/AstroCore/DB/Database.swift` | Numerikus `schema_version` tábla, szigorúan additív `schemaSQLvN` blokkok, jelenleg v12. |
| Design tokenek | `Sources/AstroUI/DesignSystem/AstroTokens.swift` | Szigorú `data*` (kategória) vs. `ok/attention/critical` (státusz) szétválasztás, tesztben kikényszerítve — új UI ezt használja, nem nyers színt. |
| Lokalizáció | `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings` | Angol literál kulcs, `LocalizationCoverageTests` minden UI-literálra hu bejegyzést követel (allowlist kivétel: márkanevek, mértékegységek). |
| V2 shell | `Sources/AstroUI/App/V2RootView.swift`, `AppRoute.swift` (`PrimarySection: home, projects, nights, planning, library, insights`) | Új top-level felület = új `PrimarySection` + `ContentRoute` + sidebar-sor; a legtöbb V3 funkció NEM kap újat, hanem meglévő szekcióba (Home kártya, Library részlet, Archive lépés) illeszkedik — ezt a specifikáció funkciónként rögzíti. |
| Tesztelés | `Tests/*` | swift-testing (`import Testing`), piros-elsőre, `docs/superpowers/plans/` alatti terv-dokumentumok mintája szerint. |

## 5. Funkciók

### 5.1 Ingest-figyelő

**Felhasználói történet.** A tulajdonos hazaér a rigtől, bedugja a memóriakártyát (vagy
felcsatolja a hálózati megosztást). Ma ehhez neki kell megnyitnia a Library ▸ "Import kártyáról"
varázslót. A V3-ban az app észreveszi az új kötetet, felajánlja az importot egy Home-bannerrel,
és a varázslót **előretöltve** nyitja meg: burst-csoportok már megvannak, session-javaslat és
projekt-hozzárendelés már ki van töltve, csak jóvá kell hagyni.

**V2 UI otthon.** Nincs új képernyő. Egy Home-kártya/banner ("Új felvétel-forrás található:
`/Volumes/EOS_DIGITAL` — 214 fájl, 3 burst") a meglévő `CaptureImportView` sheetet nyitja meg,
`CaptureImportStore`-t előretöltött állapotban indítva (a `.source` lépés már lezajlott, a
`.classify` lépéssel indul). Opt-in kapcsoló: Settings ▸ Könyvtár, az meglévő
`autoScanOnMount` melletti új "Ingest-figyelő" toggle (ugyanaz a `UserDefaults`-mintát követő
kapcsoló).

**Motorok — újrahasznosítva.** `CaptureBurstGrouper.group` és `CaptureExposureRoleHint.suggest`
(`Sources/AstroCore/Import/CaptureBurstGrouper.swift`) tiszta, statikus függvények, UI-függés
nélkül — közvetlenül hívhatók a figyelőből. `CaptureImportScanner.scan(sourceRoot:)` a
fájlrendszer-bejárás. `ImportSourceVolumeLister.filter` a kötet-szűrés. `CaptureImportCommand.copy`
(SHA-ellenőrzött, WriteGuard-on át történő) másolás — változatlanul. A meglévő
`NSWorkspace.didMountNotification` figyelő mintája (`AppState.swift:1562`,
opt-in `UserDefaults` boolean) a kötet-észlelés kiinduló mintája.

**Motorok — új.** (a) **Kötet-osztályozás**: ma semmi nem különbözteti meg a memóriakártyát egy
tetszőleges USB-kulcstól — az `ImportSourceVolumeLister` csak `/Volumes/*`-ot listáz, a
"kártya-e" kérdést utólag a `CaptureImportScanner` üres találata dönti el. A figyelőnek előbb
kell tudnia: gyors mintavételes ellenőrzés (néhány tucat fájl `.fit/.fits/.cr3` kiterjesztésre)
mielőtt bannert dobna — ez új, kis logika. (b) **Session-javaslat és projekt-hozzárendelés**:
ma **nem létezik** ilyen motor — a cél/dátum/slug 100%-ban kézi a `NewSessionStore`-on
keresztül. Ez valódi, új terméklogika: cél-egyeztetés a `ProjectRecord.catalogId`/`displayName`
ellen (fuzzy/substring egyezés a mappanévvel vagy — ha van — a legutóbbi projekt aktivitásával),
konfidencia-küszöb felett automatikus előtöltés, alatta a mai, üres `NewSessionStore` marad az
alapértelmezés.

**Adat/séma.** Nincs új tábla. Az `IngestWatcher` állapota (utoljára látott kötetek, hogy ne
ajánlja fel ugyanazt kétszer) memóriában vagy egy kis `UserDefaults`/`.astro_tool` JSON-ban él,
nem az index DB-ben.

**Hibás/üres/őszinte állapotok.** Üres kötet (nincs `.fit/.fits/.cr3`) → nincs banner, csendben.
Alacsony konfidenciájú cél-egyeztetés → a varázsló a projekt-mezőt üresen hagyja, nem tippel
találomra. Kötet lecsatolása import közben → a meglévő `CaptureImportCommand.copy` hibakezelése
(SHA-eltérés → törli a rossz másolatot, jelenti a `receipt.failed`-ben) változatlanul érvényes.

**Tesztterv-vázlat.** `IngestWatcherTests`: szintetikus kötet-mountolás szimulációja (protokoll
mögé rejtett `NSWorkspace`), gyors-mintavétel logika unit tesztje (kártya vs. nem-kártya kötet).
`IngestSuggestionEngineTests`: cél-egyeztetés determinisztikus esetei (pontos egyezés, fuzzy
egyezés, nincs egyezés → üres marad).

**Kockázatok.** A cél-egyeztetés hamis pozitívja rossz projekthez importálna — ezért a
küszöb felett is **mindig** megerősítendő UI-mezőként jelenik meg, sosem néma auto-assign.
Az `AppState.swift`-beli `autoScanOnMount` és az új ingest-toggle együtt két hasonló, de eltérő
felelősségű kapcsolót ad Settingsben — UX-copy-t élesen kell elválasztani.

---

### 5.2 Kalibrációs automata

**Felhasználói történet.** A `CalibrationView` régóta mutatja, mely exptime/temp/gain
kombinációkhoz nincs friss dark/flat/bias master. Ma ez csak lista — a tulajdonosnak kézzel
kell Sirilben megépítenie a mestert. A V3-ban egy gombbal sorba állítható a mesterkép-építés,
a dark-könyvtár lejárati szabályai (kor + hőmérséklet-tolerancia) automatikusan jelzik az
avulást, és a Home preflight-ellenőrzőlista megkapja a "ma este flat kell" sort.

**V2 UI otthon.** `CalibrationView` (Library ▸ Kalibráció) hiány-sorain új "Mesterkép építése"
akció. Home ▸ Preflight új sora: `.flatNeeded(missingCount:)`.

**Motorok — újrahasznosítva.** `CalibAnalyzer.coverage`/`CalibCombo` a gap-lista számítása
(`Sources/AstroCore/Calib/CalibAnalyzer.swift`) — változatlan. `CalibRule` már tartalmazza a
lejárati infrastruktúrát: `tempToleranceC` (1.0°C alapértelmezett), `darkMaxAgeMonths` (12),
`flatMaxAgeDays` (30), `exposureToleranceS/Fraction`, `matchGain/Offset/Binning/Camera` —
**ez a funkció ezt bővíti, nem újraépíti.** `CalibHealth.report` már számol `isStale`/`ageDays`-t.
A `PreflightChecklist.build(...)` tiszta statikus factory, zárt `Kind` enummal és 3-állapotú
`Status`-szal (`.ready/.attention/.notApplicable`) — az új `.flatNeeded` eset pontosan úgy
illeszkedik, mint a meglévő `.calibrationCurrent(missingCount:)`.
`ProjectRatingRunner.swift:175` a minta a `OperationHost.run(kind:title:cancellation:)`
hívásra egy Siril-hátterű, hosszan futó munkához.

**Motorok — új, jelentős munka.** **Ma nem létezik Siril-alapú mesterkép-építés** — a
`SirilCLI` kizárólag csillag-metrikára (`StarMetricsProvider`) és plate-solve-ra van használva;
a `CalibrationLinkCommand`/`CalibLinker` csak *linkeli* a már meglévő mesterfájlokat, sosem
építi őket. Ez a funkció súlypontja: egy új Siril-script-építő (stack parancsok
dark/flat/bias-ra), egy új `WriteGuard`-metódus (pl. `writeCalibrationMaster(kind:slug:tempURL:)`,
a `copyCaptureFile` temp+rename mintáját követve, `calibration_library/`-re korlátozva), és egy
új `CalibrationMasterBuildCommand` (`AstroApplication`), amely `accessMode == .mutationEnabled`
mögött, `LibraryMutationAuthorizer`-en át fut, `OperationHost`-tal jelentkezik progresszel.

**Siril CLI állapot — őszinte megállapítás.** A jelen worktree `SirilCLI.swift`
(`Sources/AstroCore/Rate/SirilCLI.swift`) implementációja **nem mutat nyitott broken-pipe
hibát**: stdin-írás majd zárás, háttérszálon blokkoló olvasás szemaforral, 120s timeout — ez
pont az a minta, ami elkerüli a klasszikus readabilityHandler/terminationHandler versenyhelyzetet.
Sem a fájl `git log`-ja, sem a teljes repó `--grep="pipe"` keresése nem talált ide vonatkozó
javító commitot vagy nyitott branch-et. **Ez nem jelenti, hogy a jelzett hiba nem létezik** —
lehet, hogy egy másik, ehhez a worktree-hez nem kapcsolódó menetben, vagy még nem landolt
javításként. A Kalibrációs automatának ezért **explicit degradációs útvonalat** kell
tartalmaznia, függetlenül attól, hogy a hiba ma reprodukálható-e: ha a Siril-hívás időtúllépést
kap, folyamat-hibát dob, vagy a bináris nem elérhető, a sor állapota őszintén
"Automata építés sikertelen — nyisd meg kézzel Sirilben" marad, **sosem** jelöli a hiányt
megoldottnak, és sosem hagy félkész/sérült mesterfájlt a `calibration_library/`-ban (a
WriteGuard temp+rename mintája ezt amúgy is kizárja).

**Adat/séma.** `AstroConfig.CalibRule` egy új, additív mezővel bővül (pl.
`autoMasterBuildEnabled: Bool = false`) — nincs DB-séma-bővítés, a gap-lista és a
mester-leltár már a meglévő táblákból számolható.

**Hibás/üres/őszinte állapotok.** Nincs elég forrás-keret a mesterkép-építéshez → a gomb
letiltva, tooltip indokolja ("csak 3 dark van, minimum 10 kell"). Siril nincs beállítva
(`RatingSettingsView`-ban üres path) → a build-akció ugyanazt a hibaüzenetet adja, mint amit a
`SirilHelpSheet` ma is mutat csillag-metrikánál. Sikeres build után a gap-lista sora eltűnik
(mert a `CalibAnalyzer.findMatch` újra lefut és talál mestert) — nincs külön "kész" jelző,
a lista maga az igazságforrás.

**Tesztterv-vázlat.** `CalibrationMasterBuildCommandTests`: sikeres build (mock Siril),
időtúllépés → honest failure state, hiányzó bináris → honest failure state,
`.readOnly` mód → `LibraryMutationError.readOnly`. `PreflightChecklistFlatNeededTests`:
`.flatNeeded` megjelenik/eltűnik a `flatCoverage()` bemenet függvényében.

**Kockázatok.** Ez a hat funkció közül a legkockázatosabb: új subprocess-orchestration réteg,
amely valódi fájlt ír a kalibrációs könyvtárba. A Siril-verziók közti script-szintaxis-eltérés
(a `SirilCLI` már ma is kezel egy `--version` kimenet-idioszinkráziát) újra felütheti a fejét
stack-parancsoknál. Javaslat: a build-motor első verziója **csak** azokra a kombinációkra
ajánlja fel az automatizálást, ahol a bemenet homogén (azonos gain/offset/binning), és minden
más esetben a "nyisd meg kézzel" útvonalra terel.

---

### 5.3 Irányított rendrakó

**Felhasználói történet.** Az Archive tab ma egy összesítő listát mutat ("33 rosszul elhelyezett
kalibrációs fájl"), és a részletnézet egy táblázat tömeges kijelöléssel. A tulajdonos gyakran
nem akar egy 33-elemes táblázatot bogarászni — inkább végigmenne egyesével, "ez menjen
karanténba / ezt hagyd" döntésekkel, ugyanazzal a biztonsági rituáléval, mint ma.

**V2 UI otthon.** Az `ArchiveView` "Needs you" kártyáin (`ArchiveTaskCard`) egy új "Vezetett
rendrakás" belépési pont, ami egy új, lépésenkénti `GuidedCleanupView` sheetet nyit — a
`CaptureImportView` `CaseIterable` lépés-enum + egyetlen `@Observable` store mintáját követve
(`.selectCategory → .reviewFinding → .decide → .confirmBatch → .quarantine → .receipt`).

**Motorok — újrahasznosítva, változtatás nélkül.** `ArchiveTaskKind`/`ArchiveTaskQuery`
(`Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift`) adja a talált kategóriákat
(`.intermediateFiles, .osMetadata, .duplicateContent, .misplacedCalibration, .brokenNames,
.corruption, .unverified, .auditNeverRun`). `CleanupReport`/`ResidueMatcher` — a 3-rétegű
modell (univerzális config-minta, session-scoped minta, kód-vezérelt `StackDiscovery`-guard)
változatlan, ahogy a `Scanner.swift`-beli "heal" (DB-metaadat, nem fájlrendszer) is. **A
tényleges mutáció útja bit-azonos marad**: `CleanupPreviewQuery.plan` →
`MutationConfirmationSheet` (gépelt `confirmationToken`) → `QuarantineApplyCommand.apply` →
`MutationReceipt`, visszavonással. A vezetett folyamat **csak a bemutatás sorrendjét és
granularitását** változtatja (egyesével/kis kötegben, nem egy nagy táblázat), a mögöttes
plan/confirm/apply hívást literálisan újrahasznosítja.

**Motorok — új.** Csak a lépésenkénti UI-orchestráció (`GuidedCleanupStore`) új; nincs új
motor a döntéshez. Opcionális, V3.1-re halasztható bővítés: egy "ez nem szemét" visszajelzés
gomb, ami — mivel a `ResidueMatcherRealLibraryTests` szerint **3 a 53-ból ismerten** egyik
réteg által sem fogható hamis pozitív/negatív eset — egy könnyű `residue_feedback(path,
marked_not_residue_at)` táblába naplózná a felhasználói korrekciót jövőbeli mintafinomításhoz
(nem módosítja élőben a matchert).

**Adat/séma.** Alap verzióban nincs séma-változás. A visszajelzés-bővítéshez egy új, önálló
tábla (`residue_feedback`) — additív, más táblát nem érint.

**Hibás/üres/őszinte állapotok.** `accessMode == .readOnly` → a karantén-lépés gombja
letiltva, ugyanaz a felirat, mint ma a `noQuarantineActionRow`-ban. Egy kategóriának nincs
`supportsBulkQuarantinePreview` (pl. `.unverified`, `.auditNeverRun`) → a vezetett folyamat ezt
a kategóriát kihagyja a lépésindexből, és a meglévő "Run Check" akcióra mutat, nem hamisítja a
karantén-lépést. A design-dokumentum (`2026-08-16-archive-map-ux-redesign-design.md`) elve —
"ha nincs végrehajtható akció, az nem finding, hanem információ" — a vezetett flow
lépés-generálásának is szabálya: csak akkor kap saját lépést egy kategória, ha valóban van
végrehajtható döntés.

**Tesztterv-vázlat.** `GuidedCleanupStoreTests`: lépés-sorrend helyesség, kategória nélküli
állapot (nincs finding → azonnal "kész" képernyő), `.readOnly` gate. Az alapul szolgáló
`CleanupPreviewQuery`/`QuarantineApplyCommand` tesztjei változatlanok maradnak — nem írjuk
újra őket.

**Kockázatok.** A legalacsonyabb kockázatú a hat közül: nulla új mutációs útvonal, nulla új
motor. A fő veszély UX-jellegű — ha a lépésenkénti flow lassabbnak érződik, mint a mai
táblázatos tömeges kijelölés, a tulajdonos vissza fog váltani; ezért a `GuidedCleanupView`-nak
kínálnia kell egy "ugorj a táblázatos nézetre" kilépési pontot bármelyik lépésnél.

---

### 5.4 Metaadat-javító

**Felhasználói történet.** A Canon-éjszakák (CR3, duoband szűrő nélküli EXIF-cím) ma
láthatatlanok a szűrő szerinti bontásokban, mert a `FILTER` mező üresen marad. A tulajdonos
akarja: szabály-alapú kitöltés mappa/dátum/rig szerint, kézi felülbírálási lehetőséggel, hogy a
Canon-éjszakák első osztályú állampolgárok legyenek a statisztikában.

**V2 UI otthon.** Library ▸ session/sorozat részletnézet kap egy "Metaadat javítása" akciót;
emellett egy dedikált "Hiányzó szűrők" kötegelt nézet (`MetadataFixerView`) a Library
szekcióban, ami mappa/dátum/rig szerint csoportosítja az érintett kereteket.

**A legfontosabb felfedezés: a motor és az adatmodell nagyrészt már létezik, csak V2 nem
használja.** Két párhuzamos rendszer fut ma:

- **V1, érett, eredet-nyomkövetéssel**: `Sources/AstroCore/Capture/CaptureResolver.swift`,
  `resolve(file:meta:) -> ResolvedCaptureMetadata`. Precedencia tengelyenként (sensor mode,
  signal mode, filter): kézi felülbírálás → capture-group deklarált érték → FITS-fejléc →
  útvonal/legacy-címke következtetés → `.unknown`. Minden tengely eredete
  `CaptureMetadataOrigin` (`.manualOverride/.captureGroup/.fitsHeader/.pathInference/.unknown`)
  — ezt a UI-nak pontosan erre a célra szánták ("hogy a felhasználó meg tudja különböztetni a
  tényleges FITS-értéket egy kézi vagy következtetett értéktől"). A kézi felülbírálás DB-táblája
  (`file_capture_assignments`, séma v11) **már létezik**, és V1-ben már van rá író útvonal
  (`AppState.assignCaptureMetadata`, CLI `Commands.swift:4426`).
- **V2, ad hoc, eredet-jelölés nélkül**: `Sources/AstroApplication/Library/
  ScanWorkflowMaterializer.swift` a saját, "W7-D" precedencia-láncát futtatja: FITS `filter`
  szöveg → `capture_groups.signal_mode` (**nyers SQL-lel, közvetlenül a scan-indexből, megkerülve
  a `CaptureResolver`-t és a `file_capture_assignments`-et**) → slug-mappanév szövegegyezés →
  alapértelmezett `ImagingSetupProfile.defaultFilterSignalMode` → találgatás. A kódkommentár
  explicit módon kimondja: V2 "sosem oszt meg `CaptureResolver`-példányt." **Ennek
  következménye: egy V1-ben tett kézi felülbírálás ma láthatatlan a V2 session-csoportosítás és
  szűrő-cím számára.**

**Motorok — cselekvés.** Ez elsősorban **refaktor, nem új motor**: a
`ScanWorkflowMaterializer`-t át kell kötni a meglévő `CaptureResolver`-re (vagy replikálni
kell a felülbírálás-tudatos precedenciát), hogy a V2 UI is lássa a kézi felülbírálásokat és az
eredet-vonalat. A "szabály-alapú kitöltés mappa/dátum/rig szerint" új terméklogika a
`CaptureResolver` `pathInference`/`captureGroup` ágára épül: a UI felajánlja "minden ebben a
mappában/ezen a dátumon/ezen a rigen legyen X" szabályt, amit a felhasználó jóváhagy, mielőtt
tömegesen beírja a `file_capture_assignments`-be.

**Adat/séma — nincs új tábla.** A `file_capture_assignments` (felülbírálás-oszlopok) és a
`CaptureMetadataOrigin` szótár már megvan; csak egy **új V2 Command wrapper** kell
(`AstroApplication`), ami a V1 CLI/`AppState` logikájával azonos UPSERT-et végzi
`file_capture_assignments`-en. Mivel ez DB-sor-írás, nem fájlrendszer-írás, a `WriteGuard`
nem érintett közvetlenül — de a downstream hatás (minden statisztikai lekérdezés
megváltozik) miatt a specifikáció **explicit módon LibraryAccessMode-gate-et és
naplózott visszavonhatóságot ír elő erre a Command-ra is**, konzisztensen a többi mutációval,
nem csak a nyers DB-hozzáférés miatt.

**CR3 "első osztályú a statisztikában" — pontosítás, nem teljes megoldás.** A `80d4943`
commit (`Sources/AstroApplication/Features/Review/RatingCoverageQuery.swift`) és a
`NativeStats.compute`/`Rater.processFrame` kód megerősíti: a CR3 mérhetetlensége **strukturális
fal**, nem hiányzó feature. A `NativeStats` kizárólag FITS-bájtformátumot tud olvasni; a
`StarMetricsProvider`/Siril maga NEM az akadály (Siril tud CR3-at betölteni), de a
`background`/`saturatedFraction` natív számítás mindig lefut és eldobja a keretet, ha nem FITS.
**A Metaadat-javító tehát a szűrő/objektív/expozíció-alapú összesítésekben (FilterBreakdown,
InsightsQuery, session-riportok) teszi elsőosztályúvá a Canon-éjszakákat — nem ad
FWHM/minőség-pontszámot CR3-kereteknek.** Ez utóbbi (natív CR3-pixel-dekódolás egy új
minőség-motorhoz) külön, nagyobb K+F-feladat, kifejezetten **nincs** V3.0 scope-ban — a
specifikáció ezt nyíltan kimondja, hogy elkerülje a "CR3 most már mérhető" félreértést.

**Hibás/üres/őszinte állapotok.** Ellentmondó eredet (pl. FITS-fejléc mást mond, mint a
kézi felülbírálás) → `ResolvedCaptureMetadata.conflicts` már gyűjti ezeket; a UI-nak ezt
látható figyelmeztetésként kell mutatnia, nem csendben az egyik forrást választani. Nincs
elég kontextus a szabály-javasláshoz (pl. vegyes mappa) → a UI üres javaslattal, csak kézi
mezővel jelenik meg.

**Tesztterv-vázlat.** `ScanWorkflowMaterializerCaptureResolverParityTests`: a régi W7-D
kimenet és az új `CaptureResolver`-alapú kimenet közti eltérések explicit dokumentálása
(különösen a felülbírálás-tudatosság). `MetadataFixerRuleSuggestionTests`: mappa/dátum/rig
szabály-javaslat determinisztikus esetei. `CaptureAssignmentCommandTests`: gate, journal,
visszavonás.

**Kockázatok.** A `ScanWorkflowMaterializer` cseréje viselkedés-változás minden meglévő
session-csoportosításban — regressziós kockázat mindenre, ami ma a W7-D logikára támaszkodik.
Javaslat: a csere mögé feature-flag, és egy párhuzamos-futtatásos parity-teszt (mindkét
logika ugyanazon valós fixture-ön), mielőtt a régi ágat törölnénk.

---

### 5.5 Derült-trigger

**Felhasználói történet.** Amikor a délutáni előrejelzés kitisztulásra fordul mára estére, a
tulajdonos szeretne egy natív macOS-értesítést kapni, benne a preflight-státusszal (mi hiányzik
+ egy javasolt célpont), hogy még időben eldönthesse, kimegy-e.

**V2 UI otthon.** Nincs önálló képernyő. Settings ▸ Értesítések új szakasz (engedélykérés +
"Szólj, ha kitisztul ma este" kapcsoló). A tényleges felület egy macOS `UserNotification`,
amire kattintva a Home nyílik meg a Preflight-kártyára görgetve.

**Motorok — újrahasznosítva.** `WeatherService`
(`Sources/AstroApplication/WeatherService.swift`, actor, Open-Meteo, felhőzet-only,
1 órás memória-cache) és `PreflightChecklist.build(...)` (csak olvasva — nem kell hozzá új
`Kind` eset). A javasolt célpont a meglévő Planner `topRecommendation`-ből jön (ugyanaz, amit a
Home ma is mutat).

**Motorok — új.** (a) **"Kitisztulás" trend-észlelés**: a `WeatherService` ma **csak
pillanatnyi** felhőzet-előrejelzést ad (`NightForecast.cloudPercent`, `DailyCloudSummary`) —
**nincs** benne trendfigyelés. Új logika kell: egy korábbi (pl. déli) mérés eltárolása, és a
délutáni ellenőrzéskor összevetése a friss előrejelzéssel ("ma délelőtt még felhős volt az
éjszakai ablak, most már tiszta"). (b) **`UserNotifications` integráció**: a teljes repóban ma
**sehol** nincs `UNUserNotificationCenter` használat — ez teljesen új réteg: engedélykérés
(explicit opt-in, `.denied` esetén csendes visszavonulás, sosem zaklatás), és az értesítés
összeállítása/időzítése.

**Adat/séma.** `AstroConfig` új, additív `NotificationRule` struktúra (`enabled: Bool = false`,
ellenőrzési időablak, pl. `checkHourLocal`), a `WeatherRule` mintáját követve. A trend-észlelés
korábbi mérésének tárolása egy kis, önálló állapot (nem index-DB-tábla — inkább egy
`.astro_tool/` alá írt kis JSON, `WriteGuard.writeToolFile`-lal, a `config.json`
mechanizmusával azonos módon).

**In-process korlátozás — kimondva.** Mivel V3.0-ban nincs launch-at-login/helper daemon, a
délutáni ellenőrzés **csak akkor fut le, ha az AstroTool.app éppen nyitva van** ekkor. A
tervezett mechanizmus: amikor az app aktívvá válik (pl. reggel megnyitják), egy
`NSBackgroundActivityScheduler`-rel ütemezett, alacsony prioritású periodikus ellenőrzés fut,
amíg az app folyamata él, és a megadott délutáni ablakban (pl. 14:00–16:00) tényleg lefut —
de ha a felhasználó bezárja az appot ez előtt, **nem lesz értesítés**. Ez tudatos, dokumentált
V3.0-korlátozás; launch-at-login/menü-sáv-jelenlét egy jövőbeli verzió (lásd 8. Nyitott
kérdések) témája lehet.

**Hibás/üres/őszinte állapotok.** Értesítési engedély megtagadva → a Settings-kapcsoló
inaktívvá válik, magyarázó szöveggel ("Engedélyezd a Rendszerbeállításokban"), sosem ismételt
rendszerprompt. Nincs internet/Weather API-hiba → `WeatherService` már ma is stale cache-re
esik vissza; a trigger ilyenkor csendben kihagyja a napi ellenőrzést, nem küld hamis
"kitisztult" üzenetet bizonytalan adatból.

**Tesztterv-vázlat.** `ClearSkyTriggerTests`: trend-észlelés (borult→tiszta, tiszta→tiszta,
borult→borult mátrix), engedély-állapotok, app-nem-fut szcenárió dokumentálva mint ismert
korlát (nem tesztelhető unit szinten, de a döntési logika egységtesztelt). `NotificationContent
Tests`: a preflight hiányok + javasolt célpont helyes szöveggé alakítása, lokalizációs
kulcsokkal.

**Kockázatok.** Ez az egyetlen funkció, ami valódi macOS-rendszerengedélyt kér — az
engedélykérés UX-időzítése kritikus (ne az első indításkor kérjen, hanem amikor a felhasználó
tényleg bekapcsolja a funkciót). A trend-észlelés hamis pozitívja ("kitisztult" üzenet, ami
aztán mégsem az) frusztrációt okozna — érdemes konzervatív küszöböt választani.

---

### 5.6 Élő éjszaka-mód

**Felhasználói történet.** Amíg a rig éjszaka fényez a hálózati megosztáson, a tulajdonos
szeretné élőben látni a keretszámlálót, egy gyors FWHM-közelítést és a cél-teljesítés
becslését — majd reggelre a triázs már készen várja.

**V2 UI otthon.** Nincs új `PrimarySection` (elkerülve a sidebar-bővítést és az ezzel járó
fájl-ütközést). Egy Home-kártya ("Élő éjszaka: 42 fény, cél 68%, becslés kész 03:40") jelenik
meg automatikusan, amikor a figyelő aktív éjszakát észlel; a `NightWorkspaceView` egy "ÉLŐ"
jelvényt kap, ha a megnyitott éjszaka éppen a figyelt session.

**Motorok — újrahasznosítva.** `SessionTimeline`/`NightRibbonBuilder`
(`Sources/AstroCore/Stats/SessionTimeline.swift`,
`Sources/AstroApplication/Features/Nights/NightRibbonModel.swift`) — ma kizárólag utólagos
(már beszkennelt DB-ből épül), de a renderelő logika közvetlenül újrahasznosítható egy
folyamatosan frissülő, részleges timeline felett. `GoalTag.parse`/`parseFilterGoals`
(`Sources/AstroCore/Stats/GoalTag.swift`) adja a cél-másodperceket; a haladás ma is egyszerű
"eddigi integrációs másodperc / cél-másodperc" (nincs kész ETA-számítás, azt új logika adja).
`NativeStats` (`Sources/AstroCore/Rate/NativeStats.swift`) a natív, Siril nélküli
FITS-pixel-olvasás mintája — ez az architektúra otthona egy gyors proxy-metrikának, nem a
`SirilCLI`.

**Motorok — teljesen új.** (a) **Fájlrendszer-figyelés**: a repóban ma **sehol** nincs
FSEvents/`DispatchSourceFileSystemObject`/`NSFilePresenter` — ez tiszta lapról induló munka.
Hálózati megosztás (SMB) felett az FSEvents megbízhatósága nem garantált; a tervnek tartalmaznia
kell egy poll-alapú tartalékot (pl. 15–30 másodpercenkénti directory-stat), ha az FSEvents nem
tüzel megbízhatóan a tulajdonos konkrét rig-megosztásán — **ezt a valós rigen kell validálni**,
mielőtt az FSEvents-útvonalra épülünk kizárólagosan. (b) **Gyors csillag-proxy**: ma **nincs**
könnyű FWHM-közelítés — a pontos FWHM kizárólag a `SirilCLI` teljes subprocess-hívásán át
érhető el, ami egy még író fájlon kockázatos/lassú. Új, tisztán Swift, natív modul
(`QuickStarProxy`, a `NativeStats` mellé, nem abba építve) — lokális maximum-keresés
háttér+k×szigma küszöb felett, durva sugár-alapú HFR-közelítés. **A UI-nak őszintén
"közelítő, nem Siril-pontos" címkével kell jelölnie**, hogy ne keveredjen a rating-folyamat
véglegesnek szánt Siril-metrikájával. (c) **Cél-teljesítés ETA-becslés**: új aritmetika a
meglévő `GoalTag` másodperc-számlálásra építve (hátralévő keretek × medián expozíció + medián
kereszti szünet).

**CR3-korlát élő módban is.** A Canon-éjszakák megkapják a keretszámlálót és a
cél-teljesítés-becslést (ezek fájlnév/EXIF/mtime alapúak), de **nem** kapják meg a
FWHM-proxyt, mert az natív pixel-dekódolást igényel, ami CR3-ra strukturálisan nem elérhető
(lásd 5.4) — a UI ezt is őszintén jelzi ("FWHM: n/a — CR3").

**Adat/séma.** Új, önálló élő-session állapot (`LiveNightSessionModel`) — memóriában él a
figyelés alatt; reggeli lezáráskor a session **normál `Scanner.scan` + rating-sorba kerül**,
ugyanazon az úton, mint egy manuálisan importált éjszaka. Nincs szükség új tartós DB-táblára,
ha az élő állapotot nem kell túlélnie egy app-újraindításnak (lásd 8. Nyitott kérdések — ha
igen, egy kis állapot-tábla kell a második, v8-as DB-rétegben).

**Hibás/üres/őszinte állapotok.** A figyelő X percig nem lát új fájlt a várt kadencia felett →
a kártya "vége az éjszakának?" kérdést tesz fel, nem tűnik el csendben. Hálózati megosztás
lecsatolása → a kártya explicit "kapcsolat megszakadt" állapotba vált, nem próbál végtelenített
újrapróbálkozást csendben. Reggeli lezárás után a normál `Scanner.scan` bármit másképp
osztályoz, mint amit élőben mutattunk (pl. egy keretet a `ResidueMatcher` szemétnek jelöl) →
a végleges, beszkennelt állapot az igazságforrás, az élő becslés csak előzetes volt.

**Tesztterv-vázlat.** `LiveNightWatcherTests`: szintetikus fájl-érkezés szimuláció (mock
figyelő-protokoll), poll-tartalék aktiválása FSEvents-hiba esetén. `QuickStarProxyTests`:
ismert szintetikus FITS csillagmezőn a proxy és egy referencia (ha elérhető, Siril-eredmény)
összevetése — dokumentált tűréssel, nem egyezés-követelménnyel. `LiveNightGoalEstimateTests`:
ETA-számítás determinisztikus esetei.

**Kockázatok.** Ez a másik legkockázatosabb funkció a hattal: teljesen új figyelő-infrastruktúra,
bizonytalan hálózati-megosztás-viselkedés, és egy új, sosem validált közelítő metrika. Javaslat:
az első verzió induljon **poll-only** móddal (egyszerűbb, kiszámíthatóbb hálózati megosztáson),
és az FSEvents-optimalizáció csak validáció után kerüljön be.

## 6. Hullámterv

### Megosztott fájl-ütközési pontok

| Fájl | Kit érint | Ütközés jellege |
|---|---|---|
| `OperationState.swift` (`OperationKind` enum) | 5.2 (`.buildMaster`), 5.6 (`.liveNightWatch`) | Zárt enum, kimerítő switch-ágak — egyszerre szerkesztve összefésülési kockázat. |
| `PreflightChecklist.swift` (`Kind` enum) | 5.2 (`.flatNeeded`) | Csak egy funkció érinti — önmagában nem ütközési pont, de érdemes egy menetben stabilizálni. |
| `AstroConfig.swift` | 5.2 (`CalibRule` mező), 5.5 (`NotificationRule`) | Additív mezők, de ugyanaz a fájl — sorrendezés kell. |
| Home-kompozíció (pl. `HomeView.swift`) | 5.1 (banner), 5.6 (élő kártya) | Két funkció akarja bővíteni ugyanazt a Home-testet. |

### Hullám 0 — előkészítés (1 agent, kis, gyorsan review-olható commit)

Cél: minden megosztott ütközési pontot **egyszer** nyitunk meg, üres/stub logikával, hogy a
következő hullámok sosem érjenek egymáshoz.

- `OperationState.swift`: `.buildMaster(combo: String)` és `.liveNightWatch` esetek + minden
  kimerítő switch-ág (cím, ikon) kitöltése helyőrző, de helyes szöveggel.
- `PreflightChecklist.swift`: `.flatNeeded(missingCount: Int)` eset + switch-ágak.
- `AstroConfig.swift`: üres `NotificationRule` struct (`enabled: Bool = false`) és
  `CalibRule.autoMasterBuildEnabled: Bool = false` mező hozzáadása.
- Home-kompozíció: egy általános "kártya-szolgáltató" seam (pl. egy
  `[HomeCardProviding]` lista, amit a Home iterál), hogy 5.1 és 5.6 saját fájlban regisztráljon
  kártyát, ne a közös Home-testet szerkessze.
- Elfogadási kritérium: zöld build, viselkedés-változás nulla, csak varratok.

### Hullám 1 és Hullám 2 — párhuzamos implementáció (Hullám 0 után)

Technikailag mind a hat funkció párhuzamosítható Hullám 0 után, mivel a valódi ütközési pontok
már varratokká alakultak. Reviewer-kapacitás és kockázat-elkülönítés miatt két, egyenként
párhuzamos batch-re javasolt bontás:

**Hullám 1 (alacsonyabb kockázat, 4 agent párhuzamosan):**
- 5.1 Ingest-figyelő
- 5.3 Irányított rendrakó
- 5.4 Metaadat-javító
- 5.5 Derült-trigger

**Hullám 2 (magasabb kockázat/újdonság, 2 agent párhuzamosan, futhat Hullám 1-gyel egyidőben is,
ha van kapacitás 6 egyidejű Sonnet agentre):**
- 5.2 Kalibrációs automata
- 5.6 Élő éjszaka-mód

Mindkét hullámbeli feladat kizárólag saját, új fájlokat hoz létre, és a Hullám 0-ban nyitott
varratokat tölti ki — más funkció fájljába nem nyúl. A feladatbontás Sonnet implementációs
agenteknek:

| Funkció | Fő új fájlok | Fő módosított fájlok |
|---|---|---|
| 5.1 | `IngestWatcher.swift`, `IngestSuggestionEngine.swift` | `CaptureImportView.swift` (előretöltött indítás), Settings-nézet, Home-kártya-provider |
| 5.2 | `SirilMasterBuilder.swift`, `CalibrationMasterBuildCommand.swift` | `WriteGuard.swift` (új metódus), `CalibrationView.swift`, `PreflightChecklist.swift` (varrat kitöltése) |
| 5.3 | `GuidedCleanupView.swift`, `GuidedCleanupStore.swift` | `ArchiveView.swift` (belépési pont) |
| 5.4 | `MetadataFixerView.swift`, `CaptureAssignmentCommand.swift` | `ScanWorkflowMaterializer.swift` (csere `CaptureResolver`-re) |
| 5.5 | `ClearSkyTrigger.swift`, `UserNotificationScheduler.swift` | `AstroConfig.swift` (varrat kitöltése), Settings-nézet |
| 5.6 | `LiveNightWatcher.swift`, `QuickStarProxy.swift`, `LiveNightSessionModel.swift` | `NightWorkspaceView.swift` (ÉLŐ jelvény), Home-kártya-provider |

## 7. Összefoglaló kockázati rangsor

1. **5.2 Kalibrációs automata** — új subprocess-orchestration, valódi fájlírás, Siril-verzió-
   érzékenység, a jelzett (de ebben a worktree-ben nem reprodukált) broken-pipe kockázat.
2. **5.6 Élő éjszaka-mód** — teljesen új figyelő-infrastruktúra, validálatlan hálózati-
   megosztás-viselkedés, új, sosem tesztelt proxy-metrika.
3. **5.4 Metaadat-javító** — alacsony új-kód kockázat, de a `ScanWorkflowMaterializer` csere
   viselkedés-regressziós kockázatot hordoz mindenre, ami ma a W7-D logikára épül.
4. **5.5 Derült-trigger** — új rendszerengedély-kérés, in-process-only korlátozás miatt
   megbízhatósági elvárás-kezelési kockázat.
5. **5.1 Ingest-figyelő** — új terméklogika (cél-egyeztetés), de jól izolált, alacsony
   fájlrendszeri kockázat.
6. **5.3 Irányított rendrakó** — legalacsonyabb kockázat, nulla új mutációs útvonal.

## 8. Nyitott kérdések a tulajdonosnak

1. **Két adatbázis-réteg.** A scratchpad-bizonyíték egy második, v8-as sémájú DB-t mutatott
   (`projects, nights, series, frame_decisions, mutation_journal, …`) az AstroCore index DB
   (v12) mellett. Melyik réteg a helyes otthona az új V3-állapotnak (kalibráció-sor, élő-mód
   session)? Ezt implementáció előtt kódból kell megerősíteni, nem csak DB-fájlból.
2. **Siril broken-pipe.** A jelen worktree kódja nem mutat nyitott hibát — van-e konkrét
   reprodukciós lépés vagy másik ág/session, amit meg kell néznünk, mielőtt a Kalibrációs
   automata ráépít?
3. **Launch-at-login jövő.** A Derült-trigger és az Élő éjszaka-mód in-process korlátozása
   (nincs értesítés/figyelés, ha az app zárva van) elfogadható-e V3.0-ra, vagy ez elég komoly
   ahhoz, hogy egy V3.1 helper-daemon/launch-agent napirendre kerüljön hamarabb?
4. **Hálózati megosztás valós viselkedése.** Melyik protokollt használja ténylegesen a rig
   (SMB/AFP/NFS), és van-e lehetőség egy rövid, valós teszt-ablakra az FSEvents megbízhatóságának
   ellenőrzésére a tényleges megosztáson, mielőtt az Élő éjszaka-mód erre épít?
5. **Cél-egyeztetés küszöb (Ingest-figyelő).** Van-e a tulajdonosnak preferenciája a
   konfidencia-küszöbre (mennyire magabiztos legyen az app, mielőtt kitölti a projekt-mezőt),
   vagy induljunk konzervatívan (mindig üres, csak javaslat-szövegként mutatva)?
6. **Élő-mód állapot-tartósság.** Ha az app összeomlik/bezárul egy futó élő-éjszaka közben,
   elvárás-e, hogy újraindításkor folytassa a figyelést (ami tartós DB-állapotot igényelne), vagy
   elfogadható, hogy csak a fájlrendszeri tények maradnak meg, és a live-kártya egyszerűen
   újraindul üresen?
