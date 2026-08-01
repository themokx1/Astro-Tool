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
| T2 Sanitizer + SessionDateParser | – | |
| T3 Config | – | |
| T4 WriteGuard | – | |
| T5 SQLite réteg | – | |
| T6 PathClassifier + Scanner | – | |
| T7 FITS parser | – | |
| T8 ImageIO meta | – | |
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
