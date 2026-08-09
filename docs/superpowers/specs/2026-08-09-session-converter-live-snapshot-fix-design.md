# Session-konverter élő snapshot és egységes menük — v0.15.1 design

**Dátum:** 2026-08-09
**Célverzió:** v0.15.1
**Állapot:** jóváhagyott a felhasználó korábbi „ajánlott, csináld, ne kérdezz” munkamódja alapján

## Bizonyított gyökérok

Az IC 1396 `2026-08-08` session konverziós terve az SQLite-index 178 aktív
rekordjából készült, miközben a végrehajtó csak 174 valódi regular file-t
látott. A négy, összesen 586 bájtos eltérés törött Siril `stars_aligned` /
`osc_nb_stars` szimbolikus link volt: a scanner fájlként indexelte magukat a
linkeket, a végrehajtó helyesen nem tekintette őket session-adatnak. Emellett
egy valódi feldolgozott FITS módosult a legutóbbi scan után. Vagyis két réteg
adódott össze: elavult DB-snapshot és eltérő symlink-kezelés. A végrehajtó
helyesen az élő fájlrendszert ellenőrizte, ezért az alkalmazás a döntések után
stale-fingerprint hibával leállt.

## Tervezett működés

### 1. Célzott élő szinkron a terv előtt

A DB-alapú `SessionConversionPlanner.plan(target:date:db:config:mode:)`
közvetlenül a terv elkészítése előtt csak ezt a három pontos scope-ot
szinkronizálja:

- `sessions/<target>/<date>`;
- `stacks/<target>/<date>`;
- `processed/<target>/<date>`.

Létező ág esetén a meglévő `LibraryScanner.scan(subpath:)` frissíti az új,
módosult és eltűnt rekordokat, valamint az új képek FITS-metaadatait. Egy
nem létező opcionális stack/processed ág korábbi rekordjai missing állapotba
kerülnek. Teljes könyvtárscan nem fut, képfájl nem változik.

A scanner a szimbolikus linkeket nem indexeli sessionfájlként. Ez a Siril
feldolgozási munkafáiból hátramaradó törött linkeket is kiveszi a fingerprintből,
és egyező fájlkészletet ad a regular-file-only végrehajtónak. A valódi hard
linkek továbbra is rendes fájlok: a kalibrációs könyvtár linkelési workflow-ja
nem változik.

Ezután a terv és a végrehajtó ugyanabból az élő állapotból számol fingerprintet.
A terv **után** bekövetkező tényleges fájlváltozás továbbra is blokkol: a
meglévő stale-snapshot biztonsági teszt változatlanul megmarad.

### 2. Egyértelmű hiba és újratervezés

Ha a fájlrendszer a terv elkészítése után változik, a konverter nem alkalmaz
régi döntést. Az üzenet megtartja a biztonsági blokkolást, de világosan jelzi,
hogy külső program vagy új scan módosította a sessiont, és az előnézetet újra
kell tölteni.

### 3. Egységes session-műveleti menük

A közös `SessionActionMenu` opcionális, de minden sessionlistán bekötött
`Új capture-gyűjtés…` és `Session átalakítása gyűjtésekre…` callbacket kap.
A `Minden célpont`, `Éjszakák`, `Ma este/előző éjszaka` és a célpont
`Sessionök` nézete ugyanazokat a sheeteket nyitja meg, mindig az adott sor
pontos target/date hatókörével.

## Biztonsági invariánsok

- Az előnézet logikai módja nem mozgat képfájlt.
- A célzott scan csak az AstroTool indexet szinkronizálja.
- A konverter továbbra is pontosan egy target/date sessionre korlátozott.
- Terv utáni tartalmi, méret- vagy mtime-változás blokkol.
- Fizikai módban felülírás továbbra sem engedélyezett.
- A valós IC 1396 sessionön automatikus teszt/előnézet során apply nem fut.

## Tesztelés

1. Regressziós RED teszt: scan után eltűnő és módosuló sessionfájlokkal a
   tervnek az élő snapshotot kell használnia, majd változatlan állapotban
   alkalmazhatónak kell lennie.
2. Meglévő stale teszt: a terv után módosított forrást továbbra is el kell
   utasítani.
3. Forráskód-szintű app regressziós teszt: minden fő sessionlista beköti a két
   capture-műveletet és a hozzájuk tartozó sheeteket.
4. Scanner regressziós teszt: a dangling symlink ne legyen fájlrekord, a hard
   linkek meglévő inode/nlink tesztje maradjon zöld.
5. Teljes Swift tesztcsomag, debug/release build, DMG és telepített app smoke.
6. Read-only IC 1396 terv: a fingerprint fileCount/bytes/mtime egyezzen az élő
   fájlrendszerrel.
