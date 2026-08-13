# V2 Workspace Parity Design

## Cél

A V2 ne összefoglaló dashboardok gyűjteménye legyen, hanem teljes értékű natív
macOS munkafelület. A felhasználó a Project → Night → Series → Frame → Result
hierarchiában kattintással, kijelöléssel, billentyűzettel és kontextusmenüvel
mozogjon, és minden szinten végezhessen valós munkát.

## Navigációs modell

- A bal sidebar termékterületet választ: Home, Projects, Nights, Planning,
  Library, Insights.
- A középső oszlop az adott terület navigátora és szűrője.
- A detail oszlop valódi workspace: toolbar, összefoglaló, natív Table, inspector.
- A projekt megnyitása stabil kiválasztás; nem inline kártyát nyit ki.
- A Night és Series sorok dupla kattintással mélyebb részletre visznek.
- A selection megmarad frissítés és sidebar-váltás után, ha az objektum létezik.

## Műveleti nyelv

Minden adatlista ugyanazt a mintát használja:

1. felső toolbar az oldal- és tömegműveletekhez;
2. sor végén legfeljebb két gyakori, látható művelet;
3. jobb klikkes menü a teljes műveletkészlethez;
4. dupla kattintás az elsődleges „Megnyitás” művelethez;
5. veszélyes vagy fizikai fájlművelet csak külön előnézet és megerősítés után.

## Első függőleges munkalánc

### Projects

Natív, rendezhető Table a projekt, fázis, éjszakák, integráció, használható és
kizárt frame-ek, legutóbbi session és következő lépés oszlopokkal. Toolbar:
új projekt, frissítés, keresés. Sorakciók: megnyitás, Review, Results.

### Project workspace

Önálló detail nézet, nem inline kibontás. Fejlécében állapot és integráció;
alatta szegmentált Overview / Nights / Series / Results / Notes. A Nights és
Series natív táblák. Felső műveletek: Review frames, Results, export/report
menü, Finder megnyitás, cél szerkesztés. Csak már létező, biztonságos
use-case-ek kapcsolhatók; a hiányzó fizikai művelet nem kap ál-gombot.

### Night workspace

Projekt(ek), dátum, integration, triage és series-tábla. Soronként Review és
projektmegnyitás. Toolbarból night report, session conversion és Finder.

### Series workspace

Setup, sensor mode, passband, filter, exposure, gain/offset/binning, frame
státuszok és minőségi összegzés. Frame Table kijelöléssel; Accept, Reset,
Reject és Archive Preview a már meglévő Review use-case-en keresztül.

## V1 paritás további sorrendje

1. Project/Night/Series/Frame/Result függőleges lánc.
2. Library Health: audit history, kategóriák, acknowledgement, Finder.
3. Calibration: coverage table, masterválasztás és linkelési felület.
4. Planning: valódi Table, sorakciók, új session előtöltés.
5. Notes, goals, report/export műveletek egységesítése.
6. Sensor acquisition, filter import és library management.
7. Engedélyezett fizikai mutationök külön preview/confirm/journal rétegen.

## Vizuális rendszer

- Rendszerbetűk és natív Table/List/Toolbar/Inspector komponensek.
- Spektrális kék csak selection/primary action; ibolya csak acquisition
  hierarchia és filter/passband jelzés.
- Monospaced digit idő, expozíció, gain és minőségi metrikákhoz.
- Kártyák csak összefoglaló metrikára; navigáció és munkavégzés táblázatban.
- Az egyetlen karakteres gesztus az acquisition-breadcrumb: Project › Night ›
  Series, amely minden mély workspace tetején megjelenik.

## Biztonság és ellenőrzés

- A képgyökér alapértelmezetten read-only.
- Minden új művelet célzott RED → GREEN teszttel készül.
- Minden mérföldkő külön commit és push.
- Minden béta előtt teljes Swift regresszió, universal build, checksum,
  codesign, telepítési ellenőrzés és GitHub prerelease szükséges.
