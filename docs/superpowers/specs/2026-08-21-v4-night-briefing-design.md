# AstroTool V4 — Éjszakai briefing design

**Dátum:** 2026-08-21  
**Célverzió:** AstroTool 4.0.0 stable  
**Állapot:** felhasználói irány és exportformátum jóváhagyva; részletes design felülvizsgálatra kész

## 1. Termékcél

A V4 nem terepi vezérlő és nem próbálja átvenni az ASIAIR, NINA vagy Ekos
szerepét. A Macen készít teljes, részletes megfigyelési tervet, amelyet a
felhasználó telefonon vagy kinyomtatva magával vihet.

Az egyetlen termékígéret:

> Az AstroTool még otthon összerakja az estédet: mikor, mit, mivel és hogyan
> fotózz, mire figyelj, és mi legyen a tartalék terved.

A V3 az első biztonságos sikerhez vezette el a kezdőt. A V4 célja az első
önállóan és magabiztosan előkészített fotózási este.

### Sikerkritérium

Egy nem műszaki felhasználó legfeljebb 15 perc alatt képes:

1. kiválasztani az estét, helyszínt és felszerelést;
2. összeállítani egy elsődleges és tartalék célpontokból álló idővonalat;
3. megérteni az időjárás, Hold, horizont, kalibráció és felszerelés kockázatait;
4. ellenőrizni, hogy mit vigyen magával és mit állítson be;
5. elkészíteni egy internet nélkül megnyitható PDF-et és igény szerint
   telefonos PNG-oldalakat.

## 2. Határok

### A V4 része

- menthető és újranyitható Éjszakai briefing;
- automatikusan előtöltött, de kézzel felülbírálható terv;
- több célpontos idővonal elsődleges és tartalék tervekkel;
- célpontonként felszerelés-, szűrő-, expozíció- és integrációs terv;
- időjárás-, Hold-, horizont-, kalibráció- és adatminőségi figyelmeztetések;
- testreszabható, magyarázatokkal ellátott indulási és helyszíni checklist;
- egyszerű vészforgatókönyvek;
- helyi, hálózat nélküli PDF-export;
- opcionális, a PDF-oldalakkal azonos PNG-export;
- magyar és angol dokumentum.

### Nem része

- mount, kamera, fókuszáló vagy kupola vezérlése;
- élő terepi mobilalkalmazás;
- felhőszinkron vagy felhasználói fiók;
- képfeldolgozás vagy stackelés;
- automatikus fájltörlés;
- az időjárás vagy a célpont láthatóságának biztos eredményként való ígérete;
- teljesen automatikus terv emberi ellenőrzés nélkül.

## 3. Megfontolt megközelítések

### A. Kanonikus briefingmodell → HTML → PDF → PNG — választott

A domainréteg egy rendereléstől független `NightBriefingDocument` modellt
állít elő. Egy szemantikus, minden assetet beágyazó HTML-renderelő ebből
elkészíti az előnézetet. A macOS WebKit ugyanebből hozza létre a PDF-et, a
PDFKit pedig ugyanazon PDF oldalait exportálja PNG-ként.

**Előnyök:** a PDF és PNG sosem tér el; kijelölhető szöveg; jó tipográfia és
oldaltörés; a renderelő nagyrészt tisztán tesztelhető; nincs hálózati
függőség.  
**Hátrány:** a WebKit aszinkron exportját külön, vékony platformadapterben
kell kezelni és valódi macOS integrációs teszttel ellenőrizni.

### B. Közvetlen Core Graphics/Core Text PDF

Minden elemet koordináták alapján rajzolnánk PDF-be, majd PDFKitből PNG-be.

**Előny:** nincs WebKit; teljes rajzolási kontroll.  
**Hátrány:** saját tördelő-, táblázat-, oldaltörés- és tipográfiai motorra
lenne szükség. A V4 értékéhez képest aránytalanul drága és hibaveszélyes.

### C. SwiftUI `ImageRenderer`-alapú oldalképek

Az előnézeti SwiftUI nézeteket képként mentenénk, és ezekből készülne PDF.

**Előny:** gyors első prototípus.  
**Hátrány:** raszteres PDF, gyenge nyomtatási és akadálymentesítési minőség,
megbízhatatlan többoldalas tördelés. Stabil kiadáshoz nem megfelelő.

## 4. Emberi folyamat

Az új **Briefing** felület a Tervezés része. A „Briefing készítése” gomb a
kiválasztott dátum, helyszín és setup kontextusát viszi tovább. A folyamat
öt, visszaléphető szakaszból áll.

### 4.1 Alapok

- dátum és helyszín;
- érkezési és legkésőbbi távozási idő;
- kiválasztott felszerelésprofil;
- áramforrás és várható hasznos üzemidő opcionális megadása;
- az időjárás-frissítés ideje és forrása;
- rövid „Mit használunk ebből?” magyarázat minden mezőnél.

Helyszín nélkül az app megmutatja, mi hiányzik, és a Helyszín beállításához
vezet. Időjárás nélkül is készülhet dokumentum, de a briefing nem állíthatja,
hogy az ég tiszta: jól látható „Nincs időjárási adat” jelölést kap.

### 4.2 Célpontok és idővonal

- az AstroTool ma esti ajánlásai szolgálnak kiindulásként;
- legalább egy elsődleges célpont választható;
- tetszőleges számú tartalék célpont adható hozzá;
- a célpontblokkok kezdete és vége szerkeszthető;
- az átfedés, nappali időszak, túl alacsony célpont, Hold-probléma és a
  távozási időn túlnyúló blokk azonnal látható;
- az automatikus javaslat sosem írja felül a felhasználó kézi döntését.

Az idővonal nem percre pontos ígéret. A UI és az export is „tervezett ablak”
néven mutatja, és külön jelzi a csillagászati láthatósági ablakot.

### 4.3 Capture-terv

Célpontblokkonként:

- setup és kamera;
- optika, fókusztáv és látómező;
- szenzormód és szűrő;
- expozíciós idő, tervezett képszám és becsült integráció;
- gain, offset, binning és hőmérséklet, ha ismert;
- meridiánátfordulásra vagy horizontkorlátra vonatkozó figyelmeztetés;
- szükséges dark, flat és bias összefoglaló;
- az ismert projektcélhoz viszonyított várható előrelépés.

Az app biztos metaadatot előtölthet. Ismeretlen értéket nem találhat ki:
`nincs megadva` állapotot és rövid következményt mutat.

### 4.4 Checklist és vészforgatókönyv

A checklist alapértelmezett, kezdőbarát sablonja öt szakaszos:

1. **Indulás előtt:** kamera, optika, állvány/mount, kábelek, tápellátás,
   adattároló, páramentesítés és időjárásnak megfelelő védelem.
2. **Felállítás:** stabilitás, pólusra állás, kábelút, energia, idő és hely
   ellenőrzése.
3. **Első capture előtt:** fókusz, hűtés, gain/offset/binning, szűrő,
   tesztkép, csillagforma és histogram.
4. **Éjszaka közben:** időjárás, pára, fókuszváltozás, guiding és szabad
   tárhely ellenőrzése.
5. **Befejezés:** flat-terv, adathordozók, eszközök számbavétele és biztonságos
   leállítás.

Minden elemnek van egy rövid címe, egy opcionálisan megnyitható „miért fontos?”
magyarázata és egy exportált, kipipálható négyzete. A felhasználó elemet
hozzáadhat és az adott briefingben elrejthet, de a beépített sablon fizikailag
nem törlődik.

Az automatikus vészforgatókönyvek:

- későbbi indulás;
- rövidebb rendelkezésre álló idő;
- erősödő felhőzet;
- Hold vagy horizont miatt kieső fő célpont;
- hiányzó kalibráció;
- gyengébb képminőség vagy fókuszprobléma.

Mindegyik csak olyan tartalék célpontot vagy műveletet javasolhat, amelyhez
valós számítás vagy felhasználói döntés tartozik. Ha nincs értelmes alternatíva,
ezt mondja ki.

### 4.5 Előnézet és export

- valódi, lapozható PDF-előnézet;
- figyelmeztetések listája export előtt;
- a hiányos mezők nem blokkolnak automatikusan, de az exportban is láthatók;
- alapértelmezett művelet: **PDF mentése**;
- másodlagos művelet: **PDF + PNG-oldalak mentése**;
- külön PNG-only export csak az exportmenüben;
- a célfájl létezésekor az app nem ír felül csendben: új nevet kér;
- export után Finderben megmutatható a létrehozott fájl vagy mappa.

## 5. A dokumentum felépítése

Az alapértelmezett lapméret A4 álló. A tipográfia legalább 11 pontos
törzsszöveggel és erős kontraszttal telefonos nagyításra és nyomtatásra is
alkalmas. A PNG-oldalak 144 DPI felbontásúak.

1. **Borító és este röviden** — dátum, helyszín, sötét időszak, időjárás,
   Hold, setup, készültségi állapot.
2. **Idővonal** — elsődleges és tartalék célpontblokkok, láthatósági ablakok,
   váltások és kockázati jelölések.
3. **Célpontlapok** — célpontonként keretezés, égboltpálya, capture-terv,
   projekt-előrelépés és figyelmeztetések.
4. **Felszerelés és kalibráció** — mit kell vinni, milyen kalibráció kell,
   mi hiányzik.
5. **Checklist** — a helyszínen kipipálható, szakaszokra bontott lista.
6. **B terv** — időjárási és időzítési alternatívák.
7. **Terepi jegyzetek** — üres, vonalazott rész tényleges jegyzeteléshez.

Rövid briefingnél a renderer kihagyja az üres szakaszt, és nem kényszerít hét
oldalt. A borító, idővonal, checklist és jegyzethely mindig megmarad.

## 6. Domainmodell és adatfolyam

### 6.1 `NightBriefingDraft`

A felhasználói döntések tartós, verziózható modellje:

- stabil briefing ID;
- revision szám és mentési idő;
- dátum, helyszínazonosító, setup ID;
- érkezés/távozás;
- sorrendezett célpontblokkok;
- capture-felülbírálások;
- checklist láthatóságok és egyedi elemek;
- szabad jegyzet;
- dokumentumnyelv.

Mentéskor az AstroTool új revision fájlt hoz létre a saját alkalmazásadat-
területén. Korábbi revisiont nem töröl és nem ír felül. A legfrissebb revision
a fájlnevekből határozható meg; külön, sérülékeny pointerfájl nem szükséges.

### 6.2 `NightBriefingComposer`

Tiszta, fájlrendszer- és UI-független use case. Bemenete:

- draft;
- `PlanningQuery` eredményei;
- `SkyPathQuery`/éjszakai égbolt adatok;
- setupok;
- kalibrációs lefedettség;
- projektcélok és meglévő integráció;
- időjárási pillanatkép és lekérési idő;
- opcionális személyes checklist-sablon.

Kimenete a változtathatatlan `NightBriefingDocument`, amely minden kiszámított
érték mellett megőrzi annak állapotát: ismert, hiányzik vagy elavult. A
renderer nem végez új csillagászati számítást.

### 6.3 Validálás

A `NightBriefingValidator` három szintet ad:

- **kész:** nincs lényeges hiány;
- **figyelmet kér:** exportálható, de valamit érdemes ellenőrizni;
- **hiányos:** exportálható tájékoztató dokumentumként, de a borítón egyértelmű
  hiányjelzés jelenik meg.

Csak a technikailag lehetetlen állapot blokkol: például nincs briefingdátum
vagy egy célpontblokk vége nem későbbi a kezdeténél.

### 6.4 Renderelés

- `NightBriefingHTMLRenderer`: tiszta `Document -> String` átalakítás,
  beágyazott CSS-sel és inline SVG chartokkal;
- `NightBriefingPDFExporter`: AstroUI/AppKit adapter, amely hálózat nélkül
  betölti a HTML-t WebKitbe és PDF-adatot készít;
- `NightBriefingPNGExporter`: PDFKitből, oldalanként generál 144 DPI PNG-t;
- `NightBriefingExportCommand`: fájlnevek, felülírásvédelem, ideiglenes fájl,
  ellenőrzés és végleges move;
- `NightBriefingPreviewStore`: generációs állapot, hiba és újrapróbálás.

Az SVG chartok a már kiszámított magasság-, Hold- és keretezési pontokat
rajzolják. Külső font, kép, script vagy webkérés nincs.

## 7. Tárolási és biztonsági modell

- Briefing revision: kizárólag új fájl létrehozása az app saját
  alkalmazásadat-területén.
- PDF/PNG: kizárólag a felhasználó által kiválasztott célba kerül.
- Meglévő exportfájlt az AstroTool nem ír felül.
- A forrás képkönyvtár fotóihoz a briefing egyáltalán nem ír.
- Nincs briefing-törlés a V4-ben; archiválás későbbi verzió kérdése lehet.
- Sikertelen exportnál csak az adott művelet saját, frissen létrehozott
  ideiglenes példánya takarítható el.
- PDF/PNG készítés közben nincs hálózati kérés.
- Az időjárás továbbra is opt-in; csak a már meglévő Open-Meteo szabályok
  szerint kérhető le.

## 8. Felületi architektúra

Új, önálló `.briefing` route kerül a Tervezés alá. Belépési pontok:

- Tervezés fő toolbar: „Briefing készítése”;
- egy ajánlott célpont context menüje: „Hozzáadás briefinghez”;
- Home esti ajánlás: „Este megtervezése”;
- korábbi briefingek listája a Briefing nyitóoldalán.

A szerkesztő bal oldalon az öt szakaszt és azok készültségét, jobb oldalon az
aktuális szakaszt mutatja. A lapozható dokumentum-előnézet csak az ötödik
szakaszban jelenik meg, hogy a szerkesztés és a kész dokumentum ne keveredjen.

Az első üres állapot nem dokumentummodellt magyaráz, hanem három emberi
lehetőséget ad:

- „A ma estét szeretném megtervezni”;
- „Másik dátumra készülök”;
- „Egy korábbi briefinget folytatok”.

## 9. Hibakezelés

- Időjárási hálózati hiba: a régi adat időbélyeggel vagy „nincs adat” állapot;
  a draft megmarad.
- Hiányzó site/setup: irányított javítási lehetőség, nem összeomlás.
- Ismeretlen célpontkoordináta: a célpont megtartható, de égboltpálya és
  láthatósági számítás nélkül, jól jelölve.
- WebKit/PDF hiba: az előnézet hibaállapotot és újrapróbálást mutat; a draft
  megmarad.
- PNG-oldal hibája: a PDF megmarad, a részleges PNG-csomag nem kerül végleges
  névre.
- Betelt lemez vagy megszűnt célmappa: nincs sikerüzenet; a forrás és a draft
  változatlan.
- Sérült régi revision: kihagyható és diagnosztikában jelezhető; a többi
  briefing továbbra is megnyílik.

## 10. Tesztstratégia

### Domain egységtesztek

- automatikus és kézi idővonal összeállítása;
- átfedés, sötét időn kívüli idő és távozási limit;
- elsődleges/tartalék célpontok;
- ismert/hiányzó/elavult adatállapot;
- expozíció, képszám és integráció konzisztenciája;
- kalibrációs hiányok;
- vészforgatókönyvek;
- checklist alapértelmezés, elrejtés és egyedi elem;
- magyar/angol dokumentummodell;
- revision round-trip és korábbi revision megőrzése.

### Renderer tesztek

- determinisztikus HTML snapshotok;
- HTML escaping és semmilyen külső URL/asset;
- minden kötelező szakasz és figyelmeztetés;
- oldaltörési jelölések;
- SVG chartok ismert fixture-rel;
- angol és magyar szövegfelületek;
- nincs technikai placeholder vagy fejlesztői szöveg.

### Export integrációs tesztek

- valós PDF fejléc, oldalszám és kijelölhető szöveg;
- PDFKit minden oldalát meg tudja nyitni;
- PNG-oldalak száma megegyezik a PDF oldalszámával;
- 144 DPI és nem üres képek;
- felülírás megtagadása;
- ideiglenes hiba nem hagy végleges részleges exportot;
- teljesen offline renderelés.

### UI és hozzáférhetőség

- mindhárom üresállapot-választás;
- teljes öt szakaszos journey;
- billentyűzetes navigáció és VoiceOver címkék;
- mentés, újranyitás és revision;
- hiányos adat egyértelmű, de nem indokolatlanul blokkoló;
- PDF, PNG és kombinált export;
- 1280-as és kompakt macOS ablakméret;
- tiszta telepítésen kezdő felhasználó fixture.

## 11. Kiadás

- stabil termékverzió: `4.0.0`, nem beta vagy prerelease;
- új V4 weboldalrész és külön „Éjszakai briefing” útmutató;
- magyar és angol dokumentáció;
- Universal Apple Silicon + Intel app és CLI;
- teljes Swift és macOS UI teszt;
- tiszta telepítési smoke;
- PDF/PNG fixture artifact CI-ből vizuális ellenőrzéshez;
- Developer ID aláírás és Apple-notarizáció a publikus kiadáshoz;
- helyi stabil build telepítése csak a teljes ellenőrzés után.

A publikus `v4.0.0` tag kizárólag akkor készülhet el, ha az Apple-aláírási és
notarizációs hitelesítők rendelkezésre állnak. Ad-hoc aláírt build nem jelenhet
meg stabil nyilvános kiadásként.

## 12. Elfogadási kritériumok

1. A felhasználó a meglévő tervekből 15 percen belül briefinget készít.
2. A briefing legalább egy elsődleges célpontot, setupot, idővonalat és
   checklistet tartalmaz.
3. Minden hiányzó vagy elavult adat látható; nincs kitalált érték.
4. A PDF szöveges, többoldalas, telefonon és A4 nyomtatásban olvasható.
5. A PNG-oldalak tartalmilag és oldalszámban egyeznek a PDF-fel.
6. Az export hálózat nélkül működik.
7. Meglévő felhasználói fájlt nem ír felül és nem töröl.
8. A képkönyvtár forrásképei változatlanok maradnak.
9. A draft bezárás és újraindítás után folytatható, előző revisionjei
   megmaradnak.
10. A teljes teszt, UI-smoke, Universal build és tiszta telepítés zöld.

## 13. Design önellenőrzés

- Nincs kitöltetlen vagy nyitva hagyott termékdöntés.
- A PDF az elsődleges kimenet; PNG ugyanabból a PDF-ből készül.
- A V4 nem igényel terepi Macet vagy internetet.
- A domain számítás, dokumentummodell és renderelés külön réteg.
- A terv nem bővíti a törlési jogosultságot.
- A V4 terjedelme egyetlen összefüggő journey, nem különálló funkcióhalmaz.
- A stabil publikus kiadás Apple-hitelesítő nélkül továbbra is külső blocker.
