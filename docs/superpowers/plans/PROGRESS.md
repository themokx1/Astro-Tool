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
| T9 Audit motor | – | |
| T10 Duplikátum | – | |
| T11 Suggestion script | – | |
| T12 Stats + wide-field | – | |
| T13 Calib | – | |
| T14 Session-párosítás | – | |
| T15 Rate | – | |
| T16 CLI | – | |
| T17 SwiftUI app | – | |
| T18 build.sh + DMG | – | |
| T19 CI + README | – | |
| T20 Pages + v0.1.0 | – | |

Nyitott, kötet-hozzáférés után: add_new_session.sh és tools/rate/ verifikáció
(spec 2. szakasz); user teendő: Teljes lemezhozzáférés a Claude appnak.
