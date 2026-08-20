# V2 Parity Wave 3 Implementation Plan — a napi workflow és az Apple-minőségű UX

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A V2 érje el a V1 napi munkafolyamat-szintjét (frame-review méréssel és vizuális átnézéssel, exportok, session-műveletek, audit-futtatás, konverzió-apply), és a felület feleljen meg az Apple HIG-nek: koherens menüsor, súgóréteg, badge-ek, valódi inspector, gondos üres állapotok.

**Architecture:** Minden művelet meglévő core-motorra épül (`FrameRater`/rate pipeline, `AcquisitionExport`, `ReportExport`, `StackList`, `Audit`, `FixityVerify`, session-konverzió engine) az `AstroApplication` command/query rétegén és az `OperationHost` gerincen át. Fizikai írás kizárólag a meglévő authorizer/WriteGuard útvonalakon, `LibraryAccessMode.mutationEnabled` mellett. A `/Volumes/images/Astro` képfájlokat tilos módosítani; minden teszt izolált temp fixture-ben fut.

**UX-alapelvek (minden taskra kötelező):**
- Natív vezérlők (Table, inspector, sheet, toolbar, contextMenu, Commands) — semmi egyedi kontrol ott, ahol van natív.
- Minden művelet elérhető menüből ÉS kontextusból; destruktív/író művelet megerősítéssel; minden hosszú művelet az OperationHost-on (progress + Mégse + toast).
- Üres állapot mindig mond következő lépést (ContentUnavailableView), és soha nem hazudik.
- Billentyűzet: a V1 gyorsbillentyűk visszaadása (⌘F kereső, ⌥⌘A audit, a/x/u verdictek a blinkben).
- A meglévő `DesignSystem/AstroTokens.swift` tokenek használata; nincs hardcoded szín/spacing.

**Tech Stack:** Swift 6, SwiftUI macOS 14+, Observation, Swift Testing, SQLite, Swift Charts, QuickLook (Quartz).

**Teszt-futtatás:** `set -o pipefail && swift test --disable-sandbox --no-parallel --filter <Filter> 2>&1 | tail -20`; teljes suite `--quiet | tail -5`; app build `swift build --disable-sandbox --target AstroToolApp`. Kiindulás: f33e8fa, 1891 teszt zöld.

**Kulcs-referenciák (V1 oldal, az auditból):** mért oszlopok + pontozás `Sources/AstroToolApp/Views/TargetDetail/QualitySegment.swift:449-557` → `AppState.runRate:4676`; blink `Views/FrameReviewSheet.swift:230-263`; thumbnails/QuickLook `Views/ThumbnailCell.swift`, `QuickLookController.swift`; exportok `AppState.swift:2191,4308,4338,4269,3169,3183,3211` + `Sources/AstroCore/`-motorok; SessionActionMenu `Views/SharedComponents.swift:205-292`; éjszaka-jegyzet `Views/SessionNoteSheet.swift:28-320` → `saveSessionNotes:5187`; audit `AppState.runAudit:1914`, verify `runVerify:2077` + `Views/VerifyConfirmationSheet.swift`; konverzió-apply `AppState.applySessionConversion:5566`, rollback `:5590`; menük `Views/Commands.swift:47-262`; fogalomtár/súgó `Views/GlossarySheet.swift`, `FolderStructureHelpSheet.swift`, `MetricInfoButton.swift`; sidebar-badge-ek `Views/SidebarView.swift:96-123,286-326`.

---

### Task 1: Mért minőség-oszlopok + keret-pontozás a Review munkatérben

**Files:**
- Create: `Sources/AstroApplication/Features/Review/FrameQualityQuery.swift` (FWHM/HFR/háttér/excentricitás/score/percentilis a frame-ekhez az index DB-ből)
- Create: `Sources/AstroApplication/Features/Review/FrameRatingCommand.swift` (a V1 rate-pipeline wrapper: teljes újramérés vagy natív-only mód, progress + cancel)
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift` + `ReviewStore.swift` (oszlopok, session/capture-csoport szűrőmenük, „Rate Frames…" a toolbarban az OperationHoston át, kiugró-jelzés)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`target-detail` known_gap szűkítés)
- Test: `Tests/AstroApplicationTests/FrameQualityQueryTests.swift`, `Tests/AstroApplicationTests/FrameRatingCommandTests.swift`, `Tests/AstroUITests/ReviewStoreTests.swift`, surface a meglévő suite-ban

- [ ] Failing query-tesztek: fixture DB-ből frame-enkénti metrikák + könyvtár-percentilis; hiányzó mérés esetén nil-ek, nem 0-k.
- [ ] Implementálás (a V1 lekérdezési logika újrafelhasználásával, nem újraírásával).
- [ ] Failing command-tesztek: pontozás fixture-frame-eken lefut, upsertel, progress-t ad, cancel biztonságos; Siril-hiány esetén natív mód működik, a hiba érthető.
- [ ] Implementálás.
- [ ] Failing store + surface tesztek: oszlopok jelen vannak (`v2.review.quality-columns`), Rate Frames gomb (`v2.review.rate`), szűrőmenük; sortolható Table.
- [ ] UI implementálás.
- [ ] Teljes suite + build; commit `feat: add measured quality columns and frame rating to V2 review`; push.

### Task 2: Vizuális keret-átnézés — blink, thumbnails, QuickLook

**Files:**
- Create: `Sources/AstroUI/Features/Review/FrameBlinkReview.swift` (sheet: nagy képelőnézet, ←/→ lapozás, `a`/`x`/`u` verdict-gyorsbillentyűk, verdict-chip, metrika-sáv)
- Create: `Sources/AstroUI/Features/Review/FrameThumbnailCell.swift` (aszinkron thumbnail-cache, a V1 `ThumbnailCell` mintájára, de natív V2 komponensként)
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift` (thumbnail-oszlop, „Review Frames…" belépés a blinkbe, QuickLook space-re a kijelölt soron)
- Modify: `Sources/AstroUI/Features/Results/ResultsView.swift` (thumbnail + QuickLook a resultokra)
- Test: `Tests/AstroUITests/FrameBlinkReviewTests.swift` (store-szintű: lapozás, verdict-írás a metadata-store-ba, határok), surface tesztek

- [ ] Failing store-tesztek: blink-navigáció (első/utolsó határ), `a`/`x`/`u` a MetadataStore verdict-API-ját hívja, a lista frissül.
- [ ] Implementálás (a képbetöltés NSImage/QLThumbnailGenerator, csak olvasás; a képútvonal a library-rootból, containment-ellenőrzéssel — kövesd a Results „csak létező, rooton belüli útvonal" szabályát).
- [ ] Failing surface tesztek: thumbnail-oszlop, `v2.review.blink`, QuickLook-akció jelen van Review + Results felületen.
- [ ] Implementálás; teljes suite + build; commit `feat: add visual frame review with thumbnails and QuickLook`; push.

### Task 3: Egységes V2 exportszolgáltatás

**Files:**
- Create: `Sources/AstroApplication/Features/Exports/ExportService.swift` (acquisition AstroBin-CSV/CSV/MD az `AcquisitionExport`-tal; célpont- és éjszaka-riport a V1 riportmotorral; stack-lista; terv-CSV + vágólap; kalibrációs bevásárlólista markdown)
- Create: `Sources/AstroUI/Features/Exports/ExportMenu.swift` (újrahasznosítható Export menü/gombsor NSSavePanel-lel ill. pasteboarddal)
- Modify: `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift`, `Sources/AstroUI/Features/Nights/NightsView.swift` (+ night workspace), `Sources/AstroUI/Features/Home/HomeView.swift` (terv-export), `Sources/AstroUI/Features/Results/ResultsView.swift` (stack-lista)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (érintett sorok)
- Test: `Tests/AstroApplicationTests/ExportServiceTests.swift`, `Tests/AstroUITests/` surface tesztek

- [ ] Failing service-tesztek: mindegyik formátum fixture-adatból bájtra ellenőrizhető kimenetet ad (a meglévő `AcquisitionExportTests` mintái); unmapped AstroBin-szűrő figyelmeztetést ad vissza, nem csendben hiányos.
- [ ] Implementálás (motorhívások, semmi formátum-újraírás).
- [ ] Failing surface tesztek: Export menü a Project workspace-en (`v2.project.export`), éjszaka-riport a Nights context-menüben, terv-export a Home-on, stack-lista a Results-on.
- [ ] UI bekötés (NSSavePanel a fájloknak, pasteboard a vágólapnak, toast a sikerről).
- [ ] Teljes suite + build; commit `feat: add the unified V2 export service`; push.

### Task 4: Session-műveletmenü paritás + strukturált éjszaka-jegyzet

**Files:**
- Create: `Sources/AstroUI/Features/Nights/NightActionMenu.swift` (közös context-menü komponens: Finderben megnyitás, éjszaka-riport, éjszaka-jegyzet szerkesztése, kalibráció-linkelés megnyitása, keretek pontozása, megnyitás Insights-on setup-szűréssel)
- Create: `Sources/AstroUI/Features/Nights/NightNoteSheet.swift` (README kulcs-érték mezők + egyéni kulcsok, a V1 `SessionNoteSheet` funkcionális megfelelője natív V2 formában)
- Create: `Sources/AstroApplication/Features/Nights/NightNotesCommand.swift` (a V1 `saveSessionNotes` motor-útvonala V2-ből)
- Modify: `Sources/AstroUI/Features/Nights/NightsView.swift`, `Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift` (a menü bekötése minden session-sorra)
- Test: `Tests/AstroApplicationTests/NightNotesCommandTests.swift`, `Tests/AstroUITests/NightActionMenuTests.swift` (store-szint) + surface

- [ ] Failing command-tesztek: jegyzet-mentés fixture-ben a V1-gyel kompatibilis formába; olvasás vissza; érvénytelen kulcs elutasítva.
- [ ] Implementálás.
- [ ] Failing surface/store tesztek: a menü minden felsorolt művelete valódi handlerre kötött (nincs disabled stub), Finder-reveal az útvonal-containment ellenőrzésével.
- [ ] Implementálás; teljes suite + build; commit `feat: add night action menu parity and structured night notes`; push.

### Task 5: Audit-futtatás és integritás-ellenőrzés V2-ből

**Files:**
- Create: `Sources/AstroApplication/Features/Library/AuditRunCommand.swift` (teljes + gyors [duplikátum nélküli] audit a V1 motorral; a végén `MetadataStore.recordAuditRun` hívás; fixity verify külön műveletként, minta-móddal)
- Modify: `Sources/AstroUI/Features/Library/HealthView.swift` + `LibraryHealthStore.swift` („Run Audit" split-gomb + „Verify Integrity…" megerősítő sheettel [minta 10% / teljes], OperationHost-on át)
- Modify: `Sources/AstroToolApp/Views/Commands.swift` (V2 Actions menü kezdete: Audit futtatása ⌥⌘A)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv` (`audit` sor: a „run trigger" gap megszűnik)
- Test: `Tests/AstroApplicationTests/AuditRunCommandTests.swift`, `Tests/AstroUITests/LibraryHealthStoreTests.swift` bővítés + surface

- [ ] Failing command-tesztek: audit fixture-könyvtáron lefut, findings frissül, `recordAuditRun` bekerül (history nő, diff működik); gyors mód kihagyja a duplikátum-keresést; verify minta-módban a fájlok ~10%-át hash-eli.
- [ ] Implementálás.
- [ ] Failing UI tesztek: Run Audit gomb (`v2.health.run-audit`), progress + cancel, befejezéskor toast + lista-frissítés; ⌥⌘A menüparancs.
- [ ] Implementálás; teljes suite + build; commit `feat: run audit and integrity verify from V2`; push.

### Task 6: Konverzió-apply és visszavonás

**Files:**
- Modify: `Sources/AstroUI/Features/Library/ConversionWorkspace.swift` (szerkeszthető javaslatok: csoportnév/szenzor/jelzés/szűrő; kétértelműség-feloldó lépés; „Apply Conversion…" megerősítéssel; bizonylat + „Undo")
- Create: `Sources/AstroApplication/Features/Library/SessionConversionCommand.swift` (a V1 `applySessionConversion`/`rollbackSessionConversion` motor-útvonal V2-ből, write-mód kapuval, OperationHost-on)
- Modify: `docs/superpowers/reviews/v2-feature-parity.csv`
- Test: `Tests/AstroApplicationTests/SessionConversionCommandTests.swift`, `Tests/AstroUITests/ConversionWorkspaceTests.swift` + surface

- [ ] Failing command-tesztek fixture-ben: apply csak mutationEnabled-del; logikai mód fájlt nem mozgat; fizikai mód a V1 motor bizonylatát adja; rollback visszaállít; dupla-apply elutasítva.
- [ ] Implementálás.
- [ ] Failing UI tesztek: javaslat-szerkesztés state-je, ambiguity-lépés kötelező döntése, token/megerősítés, bizonylat + Undo.
- [ ] Implementálás; teljes suite + build; commit `feat: enable session conversion apply and rollback in V2`; push.

### Task 7: Menüsor + súgóréteg + sidebar-badge-ek (Apple-alap)

**Files:**
- Modify: `Sources/AstroToolApp/Views/Commands.swift` (V2: teljes Actions menü [pontozás mindenre, szenzormérés, audit — a már meglévő commandokra kötve], ⌘F kereső-fókusz, Súgó menü: Fogalomtár, Mappastruktúra, Első lépések, Dokumentáció/Support/Forrás linkek)
- Create: `Sources/AstroUI/Help/GlossaryView.swift`, `Sources/AstroUI/Help/FolderStructureHelpView.swift`, `Sources/AstroUI/Help/FirstStepsView.swift` (a V1 sheet-tartalmak natív V2 formában; a fogalomtár kereshető)
- Create: `Sources/AstroUI/Help/MetricInfoButton.swift` (ⓘ popover, fogalomtár-linkkel; bekötés a Home/Planning/Review metrikák mellé)
- Modify: `Sources/AstroUI/App/V2RootView.swift` (sidebar-badge-ek: figyelmet igénylő éjszakák, audit-hibák, kalibrációhiány, cleanup-méret — a meglévő query-kből)
- Test: `Tests/AstroUITests/HelpSurfaceTests.swift` (új) + `V2ShellSurfaceTests` bővítés

- [ ] Failing surface tesztek: Actions + Help menü elemek valódi akcióval; `v2.sidebar.badge.*` azonosítók; ⌘F.
- [ ] Implementálás (a fogalomtár szócikkeit a V1 `GlossarySheet` tartalmából emeld át).
- [ ] Failing store-teszt a badge-számokra (fixture-ből nem-nulla értékek).
- [ ] Implementálás; teljes suite + build; commit `feat: add V2 menus help layer and sidebar badges`; push.

### Task 8: Apple-HIG polish sweep

**Files:** (érintés szerint)
- Modify: `Sources/AstroUI/Inspector/InspectorView.swift` (a stub helyett kontextusfüggő valódi inspector: projekt/éjszaka/series/result kijelöléshez a meglévő `SeriesInspector`/`FrameInspector` + új összefoglaló panelek)
- Modify: üres állapotok egységesítése `ContentUnavailableView`-ra, következő-lépés gombbal (minden Features/* nézet)
- Modify: toolbar-konzisztencia (primary action balra, keresés/inspector jobbra, azonos ikonnyelv), fókuszsorrend és `.help()` tooltipek a fő vezérlőkön
- Modify: `Sources/AstroUI/DesignSystem/AstroTokens.swift` bővítés, hardcoded spacing/szín kigyomlálása
- Test: `Tests/AstroUITests/V2PolishSurfaceTests.swift` (új: inspector nem stub; minden fő nézetben van ContentUnavailableView-alapú üres állapot; nincs beégetett `Color(red:` a Features alatt; `.help(` jelen a fő toolbargombokon)

- [ ] Failing polish surface tesztek a fenti invariánsokra.
- [ ] Implementálás nézetenként, kis commitokban.
- [ ] Teljes suite + build; záró commit `feat: polish V2 toward HIG consistency`; push.

---

## Végső kapu

- [ ] Teljes suite zöld, app build zöld.
- [ ] Paritás-CSV konzisztens (`V2FeatureParityTests`).
- [ ] `/Volumes/images/Astro` érintetlen.
- [ ] Záró kódreview a teljes hullámra (biztonság: konverzió-apply, verify, exportok fájlírásai csak NSSavePanel-célba).
- [ ] `./build.sh` + `./scripts/install-local.sh` + kézi indítás-ellenőrzés.
