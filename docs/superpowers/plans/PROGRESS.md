# Astro-Tool — végrehajtási állapot

> **Folytatáshoz (új Claude session):** olvasd el a
> `docs/superpowers/plans/2026-08-01-astro-tool.md` tervet, ezt a fájlt, és a
> `docs/superpowers/specs/2026-08-01-astro-tool-design.md` specet. Végrehajtás:
> superpowers:subagent-driven-development — taskonként friss Sonnet implementer
> subagent (teljes task-szöveg a promptban), utána review; commit+push minden
> task után; utána EZT a fájlt frissíteni és pusholni. A main-en dolgozunk
> (user jóváhagyta). A /Volumes/images TCC-blokkolt — mindent fixture-fákon
> tesztelünk, a valós könyvtárhoz hozzá sem érünk. VASSZABÁLY: a képkönyvtárban
> semmit nem törlünk/mozgatunk soha.

| Task | Állapot | Megjegyzés |
|---|---|---|
| T1 SPM skeleton + Model | ✅ kész (1f427fe) | 3 teszt zöld |
| T2 Sanitizer + SessionDateParser | ✅ kész | 26 teszt zöld (3 T1 + 23 új) |
| T3 Config | ✅ kész | 37 teszt zöld (26 T1+T2 + 11 új) |
| T4 WriteGuard | ✅ kész | 46 teszt zöld (37 T1+T2+T3 + 9 új) |
| T5 SQLite réteg | ✅ kész | 69 teszt zöld (46 T1-T4 + 23 új) |
| T6 PathClassifier + Scanner | ✅ kész | 89 teszt zöld (69 T1-T5 + 20 új) |
| T7 FITS parser | ✅ kész | 102 teszt zöld (89 T1-T6 + 13 új) |
| T8 ImageIO meta | ✅ kész | 109 teszt zöld (102 T1-T7 + 7 új) |
| T9 Audit motor | ✅ kész | 124 teszt zöld (109 T1-T8 + 15 új) |
| T10 Duplikátum | ✅ kész | 138 teszt zöld (132 T1-T9+R1 + 6 új) |
| T11 Suggestion script | ✅ kész | 148 teszt zöld (138 T1-T10+R1 + 10 új) |
| T12 Stats + wide-field | ✅ kész | 163 teszt zöld (148 T1-T11 + 15 új) |
| T13 Calib | ✅ kész | 172 teszt zöld (163 T1-T12 + 9 új) |
| T14 Session-párosítás | ✅ kész | 179 teszt zöld (172 T1-T13 + 7 új) |
| T15 Rate | ✅ kész | 199 teszt zöld (179 T1-T14 + 20 új) |
| T16 CLI | ✅ kész | 214 teszt zöld (203 T1-T15 + 11 új) |
| T17 SwiftUI app | ✅ kész | 214 teszt zöld (UI-hoz nincs unit teszt); build+release build zöld, app elindul |
| T18 build.sh + DMG | ✅ kész | 214 teszt zöld; build.sh: swift build -c release → AstroTool.app + astrotool CLI, ad-hoc codesign, DMG + CLI zip, ~/Applications install, ~/.local/bin/astrotool symlink; ikon icon/make_icon.swift-ből (CoreGraphics, determinisztikus csillagmező + mappa-motívum) |
| T19 CI + README | ✅ kész | 214 teszt zöld; release.yml (macos-15, swift test → build.sh → gh release create), LICENSE (MIT), CHANGELOG.md (Keep-a-Changelog, 0.1.0), README.md; build.sh: `${CI:-}` guard az `~/Applications` install és `~/.local/bin` szimlink lépésekre |
| T20 Pages + v0.1.0 | ✅ kész (részben) | Release: https://github.com/themokx1/Astro-Tool/releases/tag/v0.1.0 (AstroTool.dmg + astrotool.zip, CI zöld); docs/ oldal kész és pusholva, de a GitHub Pages **nincs bekapcsolva** — a repo private, a jelenlegi GitHub plan nem támogatja Pages-t private repóhoz (API 422 "Your current plan does not support GitHub Pages for this repository"). Teendő: repo publikussá tétele VAGY plan-váltás, utána `gh api -X POST repos/themokx1/Astro-Tool/pages -f 'source[branch]=main' -f 'source[path]=/docs'`. |
| Review R1 (T6–T9) javítások | ✅ kész | 132 teszt zöld (124 + 8 új) |
| Review R2 (T10–T15) javítások | ✅ | 203 teszt zöld (199 + 4 új) |
| Final review javítás (TCC exit 2) | ✅ | 216 teszt zöld (214 + 2 új); WriteGuard (createSessionTree/writeToolFile) és astrotool Commands.makeDatabase most `AstroError.accessDenied`-re fordítja a permission-hibákat (EPERM/EACCES, `isPermissionError` publikussá téve), így a chmod 555 gyökér is exit 2 + magyar TCC útmutatót ad exit 1 helyett; AppState.endOperation stale-completion guard (UUID operation-id) |
| Valós-könyvtár javítások R1 | ✅ | 231 teszt zöld (216 + 15 új); `PathClassifier` sekély-útvonal mélységi javítás (sessions/stacks/processed) + egyes számú session role-alkönyvtárak (light/flat/dark/bias); `Scanner` lazán heverő dátum-mappa-frame szerep-finomítás FITS IMAGETYP-ből + EPERM-ellenálló bejárás (`ScanSummary.inaccessiblePaths`, `Database.markMissing(excludingPrefixes:)`); új `loose-frames-in-date-dir` audit szabály; `StatsQueries` regresszió (.DS_Store nem lesz célpont); `AppState.runScan()` a sikeres scan után frissíti a Stats/Calib fület is |
| Ground-truth verifikáció + javítások | ✅ kész | 238 teszt zöld (231 + 7 új); a valós `add_new_session.sh` + `tools/rate/LightFrameRater.py` alapján: `Sanitizer` törlés-szemantikára javítva (`tr -cd`, nem `tr -c ... _`); `WriteGuard.createSessionTree` mostantól a teljes fát építi (`stacks/<T>/<D>`, `processed/<T>/<D>`, `calibration_library/{darks,flats,biases}` mkdir -p); új `Sources/AstroCore/NewSession/SessionCreator.swift` (sanitize+dátum-validáció+valódi README-sablon+fa-létrehozás egy helyen, CLI+app rá van kötve, duplikált logika törölve); új `AstroConfig.toolOutputDirNames` + `ToolOutputRule` audit szabály (Stack/Review/Reject/light_frame_rating_report_assets felismerése `tool-output`/`probablyIntentional`-ként, a noncanonical-subdir/assets-without-date/loose-frames-in-date-dir szabályok kihagyják őket); `Rater` pontozás mostantól exptime-csoportonként (0.1s kerekítve) z-score-ol, nem a teljes batch-en át — a `tools/rate` proven viselkedését követve. |
| Valós-könyvtár javítások R2 | ✅ kész | 245 teszt zöld (238 + 7 új); `Scanner`: az `unchanged` gyors-út mostantól újraszámolja a `PathClassifier` kimenetét (area/target/sessionDate/role) + a `kind`-öt is a már meglévő fájlokra, és a DB-sort helyben gyógyítja, ha eltér a tároltól — így egy classifier-javítás után a korábban beolvasott sorok nem maradnak örökre elavult besorolással (a valós DB-ben talált `target=".DS_Store"` jellegű sorok esete); a lazán heverő keret (loose-frame) IMAGETYP-alapú szerep-finomítása védett: ha a tárolt szerep konkrét keret-szerep (light/flat/dark/bias) és a tiszta útvonal-osztályozó `.other`-t adna, a tárolt szerep megmarad (nem degradálódik vissza); új `ScanSummary.reclassified: Int` mező (additív, alapértelmezett 0), a CLI `scan` human kimenete `", reclassified N"`-t ír ki, ha N > 0. `ImageMetaReader`/`ImageMeta`: új `exposureSeconds`/`iso` mező (Exif `ExposureTime`/`ISOSpeedRatings`); a `Scanner.captureMeta` CR3/TIF ágon ezeket a `fits_meta.exptime`/`gain` oszlopokba menti (a DSLR-keretek FITS `EXPTIME` nélkül eddig `exposureBreakdown["unknown"]`-ban landoltak, 0 integrációs idővel) — a `StatsQueries` változtatás nélkül veszi figyelembe őket, mivel csak a `fits_meta.exptime`-ot nézi. |

## Zárás (2026-08-02)

Mind a 20 task kész. Kiadva: **v0.1.0** és **v0.1.1**
(https://github.com/themokx1/Astro-Tool/releases/tag/v0.1.1 — AstroTool.dmg +
astrotool.zip, CI zöld, 216 teszt). Négy review-kör futott (M1, T6–T9, T10–T15,
végső) — minden találat javítva és re-approve-olva.

**Nyitott tételek (user-döntés / engedély kell):**
1. GitHub Pages: a repo privát, a plan nem támogatja → tedd publikussá a repót
   (vagy fizetős plan), utána:
   `gh api -X POST repos/themokx1/Astro-Tool/pages -f 'source[branch]=main' -f 'source[path]=/docs'`
2. /Volumes/images TCC-engedély a Claude-nak → utána add_new_session.sh és
   tools/rate/ verifikáció a spec 2. szakasza szerint, plusz első valós
   (read-only) futtatás egy szűk almappán.
3. Az AstroTool appnak és a terminálnak is Teljes lemezhozzáférés kell majd az
   első éles futáshoz.
