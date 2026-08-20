# Localization Implementation Plan (magyar + angol)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A V2 alkalmazás felülete teljesen működjön **magyarul és angolul is**. Alapból a rendszernyelvet követi; a Beállításokban felülírható (Magyar / Angol / Rendszer szerint), a váltás újraindítást kér — ez a macOS szabványos viselkedése.

**Felhasználói döntés (2026-08-15):** nyelvválasztás = rendszernyelv + felülírás; hatókör = **első körben a V2 alkalmazás felülete**. A `astrotool` CLI és az exportált riportok NEM tartoznak bele — azok maradnak a jelenlegi nyelvükön, mert szkriptek épülnek rájuk.

---

## A megoldás alakja (fontos, mert ez spórol ~545 hívási hely átírásán)

A SwiftUI `Text("Projects")`, `Button("…")`, `Label("…")`, `Toggle("…")`, `Picker("…")`, `TableColumn("…")`, `.help("…")`, `.accessibilityLabel("…")` mind **`LocalizedStringKey`**-t vesz át, amit futásidőben a **`Bundle.main`**-ben keres ki. A `Bundle.main` az **alkalmazás** bundle-je (`AstroToolApp`), nem az `AstroUI` library-é.

Ebből következik:
1. A fordítási fájlokat az **`AstroToolApp` targetbe** kell tenni — így az `AstroUI` összes literálja **hívási hely módosítása nélkül** lefordul.
2. **Az angolhoz nem kell fájl.** A kulcs maga az angol literál; ha nincs találat, a literál jelenik meg — vagyis az angol az alapértelmezett fallback. **Csak `hu.lproj/Localizable.strings` kell.**
3. Ami **nem** literál — futásidőben előálló `String` (motorból jövő szöveg) — az így nem fordul le. Ezeket a motornak **strukturált értékként** (enum + társított adat) kell visszaadnia, és a nézet állítja elő belőlük a lokalizált szöveget.

Formátum: klasszikus `.lproj/Localizable.strings`. Indok: a `swift build` (a `./build.sh` fő útvonala) ezt garantáltan feldolgozza a `.process()` resource-szabállyal; a String Catalog (`.xcstrings`) kinyerése Xcode-függő, a projekt viszont parancssorból épül.

---

### Task 1: Lokalizációs alapok + a nyelvválasztó

**Files:**
- Modify: `Package.swift` (`defaultLocalization: "en"`, resources az `AstroToolApp` targeten)
- Create: `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings` (kezdetben üres/kevés kulccsal)
- Create: `Sources/AstroUI/App/AppLanguage.swift` (a választás típusa + olvasás/írás)
- Modify: `Sources/AstroUI/Settings/V2SettingsView.swift` (General fül: nyelvválasztó)
- Test: `Tests/AstroUITests/AppLanguageTests.swift` (új)

- [ ] Failing teszt: `AppLanguage` három állapota (`.system`, `.hungarian`, `.english`); a mentés az `AppleLanguages` kulcsot írja a `UserDefaults`-ba (`.system` esetén **törli**, nem üres tömböt ír); az olvasás visszaadja a mentettet.
- [ ] Implementáld; `defaultLocalization: "en"` a `Package`-be, `resources: [.process("Resources")]` az `AstroToolApp` targetre.
- [ ] Failing surface-teszt: a General fülön van nyelvválasztó (`v2.settings.language`) és egy őszinte felirat, hogy a váltás **újraindítás után** lép életbe.
- [ ] Implementáld a pickert; váltáskor jelezze, hogy újra kell indítani (alert vagy inline felirat — ne állítsa, hogy azonnal életbe lép).
- [ ] Teljes suite + build; commit `feat: add a language preference with system default`; push.

### Task 2: A motorból jövő szövegek strukturálttá tétele

**Files:** `Sources/AstroCore/Sky/NightSweep.swift` (`SkyVerdict`), `Sources/AstroCore/Capture/*` (`displayNameHU`, `humanSummaryHU`, ambiguitás-szövegek), `Sources/AstroApplication/Features/Projects/ProjectsQuery.swift` (`ProjectNextAction`), `Sources/AstroApplication/Features/Planning/PlanningQuery.swift`; a megjelenítő nézetek.

Egy futó munka ezt már elkezdte (magyar → angol a megjelenítési határon). Ez a task **befejezi** és lokalizálhatóvá teszi.

- [ ] Failing tesztek: minden érintett motor-típus **strukturált** értéket ad (enum + társított adat: `maxAltitudeDeg`, `separationDeg`, `illuminationPercent`, fázis stb.), nem kész mondatot.
- [ ] Implementáld; a V1 app és a CLI kapja meg a maga (magyar) rendererét, hogy a kimenetük **ne változzon** — a rájuk épülő tesztek maradjanak zöldek.
- [ ] A V2 nézetek a strukturált értékből építsenek `LocalizedStringKey`-t (interpolált számokkal).
- [ ] Kapu-teszt: `Sources/AstroUI` alatt **egyetlen** nézet sem jelenít meg `*HU` végű property-t, és nem tartalmazza a korábbi magyar mondatokat.
- [ ] Teljes suite + build; commit `refactor: return structured verdicts instead of prebuilt sentences`; push.

### Task 3: A magyar fordítás elkészítése

**Files:** `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings`, `scripts/extract-localizable-strings.swift` (vagy shell), `Tests/AstroUITests/LocalizationCoverageTests.swift` (új)

- [ ] Írj **kinyerő scriptet**, ami végigmegy a `Sources/AstroUI`-n és összegyűjti a `Text/Button/Label/Toggle/Picker/TableColumn/help/accessibilityLabel/navigationTitle/confirmationDialog` literáljait. A script legyen reprodukálható és commitolva — a fordítás karbantartása enélkül elsorvad.
- [ ] Failing lefedettség-teszt: minden kinyert kulcsnak **van** magyar bejegyzése (kivéve egy explicit, indokolt allowlistát — pl. márkanevek, „FITS", „AstroBin", mértékegységek).
- [ ] Készítsd el a magyar fordítást. **Szakmai szótár kötelezően követendő** (ne gépi fordítás):
      integration = integráció · frame = képkocka · light/dark/flat/bias = light/dark/flat/bias (nem fordítjuk) · stack = stack · calibration = kalibráció · target = célpont · night = éjszaka · session = session · culmination = delelés · altitude = magasság · surface brightness = felületi fényesség · quarantine = karantén · audit = audit · usable = használható · excluded = kizárt · rejected = elvetett · verdict = ítélet/verdikt · framing = képkivágás · field of view = látómező · narrowband = keskenysáv · broadband = szélessáv · mono = monokróm.
- [ ] A magyar szöveg **stílusa** kövesse a macOS magyar konvencióit: gombok felszólító módban („Mentés", „Mégse"), címek főnévi alakban, tegeződés a magyarázó szövegekben (ahogy a projekt eddigi magyar szövegei is).
- [ ] Teljes suite + build; commit `feat: add the Hungarian localization`; push.

### Task 4: Formátumok és ellenőrzés

- [ ] Számok, dátumok, időtartamok: a `.formatted()`/`FormatStyle` hívások a **locale**-t kövessék (tizedesvessző magyarul), a fix `String(format: "%d:%02d")` helyeket pedig egyetlen közös `AstroFormat.duration` váltsa ki (a termékaudit P2 mintája is ezt kéri).
- [ ] Ellenőrzés magyar nyelven indítva: `open -n build/AstroTool.app --args -AppleLanguages '(hu)' -UITestInitialSection planning` — a felület magyar, a CPU 0% marad.
- [ ] Ugyanez angolul (`-AppleLanguages '(en)'`).
- [ ] Screenshot-mentes ellenőrzés: a lefedettség-teszt + a kapu-tesztek adják a bizonyítékot; kattintani nem tudunk (nincs accessibility-engedély).

---

## Végső kapu

- [ ] Teljes suite zöld (--no-parallel), app build zöld.
- [ ] `hu` és `en` indítás 0% CPU-val, a valódi könyvtárral.
- [ ] A CLI kimenete **változatlan** (a rá épülő tesztek zöldek).
- [ ] A lefedettség-teszt zöld: nincs lefordítatlan felületi szöveg az allowlisten kívül.
- [ ] Build-szám emelés, `./build.sh`, `./scripts/install-local.sh`.
