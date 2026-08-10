# v0.16.0 onboarding/reference/archive — megvalósítási terv

1. Domain-adatmodell tesztek: `IntegrationReferenceRule`, setup f-szám/hatékonyság, katalógus-felületi-fényesség és `IntegrationGoalCalculator`; majd visszafelé kompatibilis implementáció.
2. Célpontkatalógus tesztek és implementáció: angol/magyar/katalógusszám keresés, aliasok, kanonikus mappanév és meglévő azonos célpont újrahasználata az új-session felületen.
3. Goal-folyam tesztek: explicit címke elsőbbsége, célpontfüggő automatikus ProjectState/Planner cél; majd egységes bekötés és forrásjelölés.
4. Archive domain tesztek: útvonalterv, FrameSet-kizárás, no-overwrite, apply/restore/rollback; majd `WriteGuard`, DB útvonalfrissítés és executor.
5. AppState archív művelet és Minőség UI: kontextusgomb, előnézet/megerősítés, ARCHÍV jelzés, visszaállítás, frissítés/toast.
6. Onboarding draft/state tesztek: verziózott megjelenés, oldal-kihagyás, config merge; majd többoldalas SwiftUI-varázsló és Beállításokból újranyitás.
7. Felszerelés/cél UI: f-szám és hatékonyság mezők, relatív órák előnézete, automatikus cél forrásának és felületi-fényesség becslésének felirata.
8. Dokumentáció és v0.16.0 release note, verzióemelés.
9. Teljes regressziós teszt, release build, csomagolás, commit/push/PR/merge/tag/GitHub release, majd a kész app telepítése és indítási ellenőrzése.

## Folyamatos megvalósítási napló

- 2026-08-10: elkészült a visszafelé kompatibilis integrációs referencia és a setupok f-szám/hatékonyság modellje.
- 2026-08-10: elkészült a felületi fényességhez kötött, 0,5–3× közé korlátozott automatikus célidő; az explicit `goal:` elsőbbsége megmaradt.
- 2026-08-10: elkészült az offline katalóguskeresés katalógusszám, angol és magyar név szerint, kanonikus mappanévvel és meglévő célpontmappa újrahasználatával.
- 2026-08-10: elkészült a többoldalas, oldalanként és teljesen is kihagyható onboarding; a rendes Beállításokból újraindítható, az integrációs referencia később külön is szerkeszthető.
- 2026-08-10: elkészült az egy-frame-es fizikai archíválás és visszaállítás: pontos előnézet, no-overwrite, DB-azonosság megőrzése, kizárt-de-látható állapot.
- 2026-08-10: a teljes debug app és CLI lefordult. Az új/kapcsolódó katalógus-, célidő-, onboarding-, archívum-, session- és FrameSet-csomag 59/59 tesztje hibamentes.
- 2026-08-10: a Planner/Project/report regressziók, majd a review-javításokkal bővített teljes soros tesztcsomag 1532/1532 teszttel hibamentesen lefutott.
- 2026-08-10: elkészült a v0.16.0 arm64 release app és CLI; az app ad-hoc aláírása, bundle-verziója, CLI-verziója, DMG checksumja és ZIP-tartalma ellenőrzött.
- 2026-08-10: a végső kód-review symlink-, preflight-, hibás referencia-, scan előtti mappa- és onboarding-versenyhelyzet findingjai regressziós tesztekkel javítva; az ismételt review nem talált Critical/Important hibát, az utolsó preview-eltérés is megszűnt.
- Következő: commit/push/PR/merge/tag/GitHub-kiadás, majd telepítés és natív indítási smoke.
