# Több képalkotó setup és kézi látómező – design

## Cél

A Felfedezés oldal akkor is tudjon valós látómezővel tervezni, ha a könyvtárban nincs WCS-adat, illetve egy fotós több, egymástól lényegesen eltérő kamerát és optikát használ. A felhasználó névvel menthető setupok között válthat, és zoomobjektívnél megadhatja az adott tervhez használt fókusztávot.

Elsődleges valós példák:

- dedikált asztrokamera, APS-C méretű szenzor, 100–400 mm-es optika;
- Canon R8, nem asztromodifikált full-frame váz, 16 mm-es fix objektív;
- Canon R8, nem asztromodifikált full-frame váz, 28–70 mm-es zoomobjektív.

## Jelenlegi probléma

`FieldGeometry.dominantFOV` csak a már beszkennelt, használható light képek domináns felszerelés-ujjlenyomatából és WCS/pixelskála adataiból számol medián látómezőt. Ez jó automatikus tartalék, de nem felszerelés-tervező:

- üres vagy még nem plate-solve-olt könyvtárnál nincs eredmény;
- csak egy domináns setupot reprezentál;
- nem lehet előre megadni új kamerát vagy optikát;
- zoomtartomány esetén nincs mód megmondani, melyik fókusztávval készül a terv.

## Döntött megközelítés

### 1. Tartós setupmodell

Az `AstroConfig` új, additív `imagingSetups` listát kap. Egy `ImagingSetupProfile` tartalma:

- stabil, mentett azonosító;
- felhasználói név;
- kamera neve;
- kamerajelleg: dedikált asztrokamera, nem modifikált színes kamera, modifikált színes kamera vagy monokróm kamera;
- szenzor szélessége és magassága milliméterben;
- minimális, maximális és alapértelmezett tervezési fókusztáv milliméterben;
- alapértelmezett setup jelölés.

Fix optikánál a három fókusztávérték azonos. Zoomnál a tervezési érték a minimum és maximum között van. A kamerajelleg ebben a fejlesztésben az azonosítást és a korrekt megjelenítést szolgálja; a célpontok spektrális alkalmasságát nem módosítjuk pusztán ebből, mert ahhoz szűrő- és égboltadat is kellene.

A régi `config.json` fájlokban nincs `imagingSetups` kulcs, ezért dekódoláskor üres lista az alapérték. Ez teljes visszafelé kompatibilitást ad.

### 2. Fizikai FOV-számítás

A setup látómezeje a szenzor fizikai méretéből és az aktuális fókusztávból számolódik, külön a két tengelyen:

`FOV = 2 × atan(szenzorméret / (2 × fókusztáv))`

Az eredmény fokban jelenik meg. Nem használunk crop-faktort, mert a szenzor valódi szélessége és magassága közvetlenül és pontosabban meghatározza a látómezőt. Érvénytelen vagy nem pozitív méretből nem készül becslés.

### 3. Beállítások ▸ Felszerelés

Új, önálló beállításlap kezeli a setupokat. A lista összefoglaló sora megmutatja a setup nevét, kameráját, szenzorméretét és fix/zoom fókusztávját. Innen lehet:

- új setupot hozzáadni;
- meglévőt szerkeszteni;
- törölni;
- egy setupot alapértelmezettnek jelölni.

A szerkesztő támogatja a gyakori szenzorpreseteket:

- APS-C (23,5 × 15,7 mm, tipikus dedikált APS-C asztrokamera);
- Canon APS-C (22,3 × 14,9 mm);
- full frame (36 × 24 mm);
- egyedi méret.

A preset csak adatbeviteli gyorsítás; a config mindig a tényleges milliméterértékeket menti. Így egyedi asztrokamera-szenzor is pontosan beállítható.

Validáció mentés előtt:

- minden név egyedi és nem üres;
- a kamera neve nem üres;
- a szenzorméretek és fókusztávok pozitívak;
- a minimum nem nagyobb a maximumnál;
- az alapértelmezett fókusztáv a tartományba esik;
- nem üres listában pontosan egy setup az alapértelmezett.

### 4. Felfedezés workflow

Ha van mentett setup, a Felfedezés felső vezérlősorában megjelenik egy setupválasztó. A kiválasztás felhasználói beállításként megmarad az app következő indítására is; ha a setupot később törlik, az alapértelmezett, majd az első elérhető setup lesz az automatikus tartalék.

Fix optikánál a kiválasztás azonnal újraszámolja a katalógust. Zoomnál megjelenik egy kompakt tervezési fókusztáv-vezérlő a profil minimuma és maximuma között. A választott érték setup-onként megmarad, és a FOV-tábla minden sora erre az egyértelmű, konkrét fókusztávra épül.

A „Setup látómező” tile:

- első sorban a számolt szélesség × magasság értéket mutatja;
- kézi setupnál captionként a setup nevét és az aktuális fókusztávot mutatja;
- setup nélkül továbbra is a domináns könyvtári WCS-FOV-ot használja;
- csak akkor ír `n/a` és „nincs WCS-adat” értéket, ha se kézi setup, se automatikus adat nincs;
- az üres állapotból közvetlen „Setup beállítása…” gomb nyitja a Felszerelés lapot.

### 5. Állapot és adatfolyam

1. Az AppState feloldja a kiválasztott setupot a configból.
2. Kézi setupnál a profil és a setuphoz mentett tervezési fókusztáv adja a FOV-ot.
3. Kézi setup hiányában `FieldGeometry.dominantFOV` marad az adatforrás.
4. Ugyanaz a FOV kerül a `DiscoveryPlanner.discover` hívásba és a tile-ba, ezért a címke és a kijelzett szám sosem tér el.
5. Setup- vagy fókusztávváltás egyetlen új `loadDiscovery()` futást indít; a meglévő műveletmegszakítási szabály megakadályozza az elavult eredmény visszaírását.

## UI-irány

A meglévő natív macOS, sűrű és műszer-szerű felület marad. Nem készül új vizuális rendszer. A jellegzetes elem a setupválasztó mellett megjelenő `kamera · szenzor · fókusztáv` összefoglalás: ugyanazokat a fizikai adatokat mutatja, amelyekből a FOV ténylegesen számolódik. Billentyűzettel elérhető natív `Picker`, `Slider`, `TextField` és `Button` elemeket használunk.

## Hibakezelés

- Érvénytelen setupot a Beállítások nem ment el, a konkrét hibát magyarul jelzi.
- Kézzel szerkesztett, hibás configbejegyzés nem okoz összeomlást; a FOV-számítás `nil` eredményt ad és a felület beállításra irányít.
- Törölt kiválasztási azonosító nem marad aktív.
- A zoomtervezési fókusztáv minden felhasználói és visszatöltött értéknél a profil tartományára korlátozódik.

## Tesztelés

- modell: fix és zoom setup, alapértelmezett feloldás, tartományra korlátozás;
- geometria: APS-C 100/400 mm és full-frame 16/28/70 mm számszerű FOV-ellenőrzése;
- config: régi JSON kompatibilitás és új setupok teljes round-tripje;
- discovery adatforrás: kézi setup elsőbbséget élvez, setup nélkül a WCS-fallback változatlan;
- teljes AstroCore tesztcsomag;
- AstroToolApp debug és release build a SwiftUI/Swift 6 regressziók ellen.

## Nem része ennek a fejlesztésnek

- csillagtérkép téglalap-overlay és forgásszög;
- objektumonként automatikusan ajánlott zoomfókusztáv;
- optikai torzítás vagy objektívprofil-korrekció;
- a nem modifikált/modifikált kamera alapján automatikus célpontkizárás;
- gyártói online kamera- vagy objektívadatbázis.

Ezek külön fejlesztési egységek; a mostani adatmodell később kompatibilis alapot ad hozzájuk.
