# v0.16.0 onboarding/reference/archive — megvalósítási terv

1. Domain-adatmodell tesztek: `IntegrationReferenceRule`, setup f-szám/hatékonyság és `IntegrationGoalCalculator`; majd visszafelé kompatibilis implementáció.
2. Goal-folyam tesztek: explicit címke elsőbbsége, automatikus ProjectState/Planner cél; majd egységes bekötés és forrásjelölés.
3. Archive domain tesztek: útvonalterv, FrameSet-kizárás, no-overwrite, apply/restore/rollback; majd `WriteGuard`, DB útvonalfrissítés és executor.
4. AppState archív művelet és Minőség UI: kontextusgomb, előnézet/megerősítés, ARCHÍV jelzés, visszaállítás, frissítés/toast.
5. Onboarding draft/state tesztek: verziózott megjelenés, oldal-kihagyás, config merge; majd többoldalas SwiftUI-varázsló és Beállításokból újranyitás.
6. Felszerelés/cél UI: f-szám és hatékonyság mezők, relatív órák előnézete, automatikus cél forrásának felirata.
7. Dokumentáció és v0.16.0 release note, verzióemelés.
8. Teljes regressziós teszt, release build, csomagolás, commit/push/PR/merge/tag/GitHub release, majd a kész app telepítése és indítási ellenőrzése.
