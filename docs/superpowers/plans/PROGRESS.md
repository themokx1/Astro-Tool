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
