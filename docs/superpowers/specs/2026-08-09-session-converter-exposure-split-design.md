# Session-konverter expozíció szerinti szétválasztás — v0.15.2 design

**Dátum:** 2026-08-09
**Célverzió:** v0.15.2
**Branch:** `codex/v0.15.2-exposure-split`

## Probléma

Az IC 1396 2026-08-08 sessionben a 30 másodperces képek a `lights_osc`, a
120 és 300 másodperces képek együtt a `lights` mappában voltak. A v0.15.1
session-konverter elsődlegesen forrásmappa szerint képzett gyűjtést, ezért a
32 darab 30 s-es frame külön `osc-30s` gyűjtést kapott, míg a 3 darab 120 s-es
és 46 darab 300 s-es frame egy `capture-120s-300s` gyűjtésbe került.

Ez adatvesztést nem okozott, de a valós asztrofotós workflow-ban hibás
határvonal: eltérő névleges expozíciók külön audit-, stack- és process-egységet
igényelhetnek akkor is, ha az adatgyűjtő szoftver ugyanabba a mappába írta őket.

## Döntés

A konverter a light forráscsoportokat a duplikációszűrés után névleges
expozíció szerint is particionálja. A `NominalExposure` kerekítési szabálya
marad az egyetlen forrás, ezért például a 119,9 és 120,0 másodperc ugyanahhoz a
120 s-es gyűjtéshez tartozik.

- Egyetlen expozíció esetén a jelenlegi viselkedés változatlan.
- Több expozíció esetén minden névleges expozíció külön detektált csomag és
  külön capture-gyűjtés.
- Ismeretlen expozíció külön `unknown` csomagba kerül, nem keveredik ismert
  expozícióval.
- Az ugyanabban a forrásmappában maradó logikai csoportok nem kapnak egymással
  ütköző mappaszintű source mappinget; a korábbi túl tág mapping explicit
  eltávolításként jelenik meg, és az egzakt fájlhozzárendelés az igazság.
- A felismerhető `Stacked*` artifact a saját expozíciós csomagjához kerül;
  expozíció nélkül a domináns csomag örökli.

## Már konvertált session javítása

Ha a lightok már egy meglévő, vegyes expozíciójú gyűjtéshez vannak rendelve,
a legnagyobb frame-számú expozíciós csomag megtartja a meglévő group ID-t és
slugot. A többi csomag új gyűjtést kap. Így nincs árva, üres régi gyűjtés, és a
korábbi stack/process hivatkozások a domináns gyűjtésen maradnak.

A megtartott gyűjtés megjelenített neve az új, egyetlen expozícióra frissül.
Az új gyűjtések öröklik a meglévő szenzor-, fénysáv- és filtermetaadatot — az
IC 1396 példában az `OSC / Dual-band / SV220` értékeket. A terv a meglévő
gyűjtés frissítését ugyanúgy szerkeszthető javaslatként mutatja, mint az új
gyűjtést.

## Biztonság és rollback

Logikai módban egyetlen képfájl sem mozog. A konverziós terv előre felsorolja
az új és frissítendő gyűjtéseket, valamint minden fájl célgyűjtését. Az executor
tranzakcióban menti a módosított meglévő gyűjtés teljes korábbi rekordját; hiba
vagy explicit visszavonás esetén az eredeti név, metadata és valamennyi
fájlhozzárendelés helyreáll.

## Elfogadási kritériumok

1. Az IC 1396 fixture 30 s, 120 s és 300 s frame-jei három külön detektált
   csomagba kerülnek: 32, 3 és 46 nyers lighttal.
2. A 119,9 és 120,0 s egyetlen 120 s-es csomag marad.
3. Egy már létező `capture-120s-300s` gyűjtés újratervezésekor a 300 s-es
   domináns csomag megtartja a group ID-t, a 120 s-es új gyűjtést kap.
4. Az új 120 s-es gyűjtés örökli az `OSC / Dual-band / SV220` adatokat.
5. Logikai apply után a fájlok helye változatlan; rollback után a DB pontosan
   az alkalmazás előtti állapotra tér vissza.
6. Az 1470 meglévő teszt és az új regressziós tesztek is sikeresek.
7. A v0.15.2 kiadás teljes magyar release note-tal, DMG-vel és CLI ZIP-pel
   jelenik meg, majd a verifikált app települ a gépre.
