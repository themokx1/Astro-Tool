# AstroTool V2.0.0 — natív, objektumközpontú macOS-termék

**Dátum:** 2026-08-10
**Ág:** `codex/v2.0.0-ui-rework`
**Kiindulási alap:** AstroTool V1.0.0 (`dffdac8`)
**Állapot:** felhasználó által 2026-08-10-én jóváhagyott termékirány; implementáció előtti végleges designspecifikáció

## 1. Cél

Az AstroTool V2 ne a V1 vizuális átfestése legyen, hanem egy új, koherens,
natív macOS-alkalmazás ugyanarra a bizonyított asztrofotós domainmotorra építve.
A terméknek úgy kell működnie, ahogy egy asztrofotós gondolkodik: projektben,
éjszakában, homogén felvételi sorozatban, képkockában és eredményben — nem audit-,
kalibráció-, riport- és adatbázismodulok között ugrálva.

A V2 elsődleges sikerkritériuma nem az, hogy hány metrikát mutat egyszerre, hanem
az, hogy minden állapotban egyértelmű legyen:

1. mi történt;
2. mi kér figyelmet;
3. mi a következő értelmes lépés;
4. milyen adatból és milyen bizonyossággal következtetett az app;
5. mely művelet érinti kizárólag az app adatait, és melyik érintené a képfájlokat.

## 2. Nem alku tárgya

- A felhasználó képeihez fejlesztés, tesztelés és migráció során nem nyúlunk.
- Scan, audit, pontozás, tervezés, böngészés, keresés és index-reset után a
  képkönyvtárnak bitazonosnak kell maradnia.
- A képkönyvtár gyári hozzáférési módja `readOnly`.
- Fizikai fájlmozgatás csak külön engedélyezett, tételesen előnézett,
  felülírást tiltó, naplózott és visszavonható művelet lehet.
- A V1 `.astro_tool` könyvtárát a V2 nem törli és nem módosítja automatikusan.
- A meglévő AstroCore képességek nem veszhetnek el a felület újraírásakor.
- A V1 UI csak akkor törölhető, amikor a feature-parity mátrix minden sora és a
  teljes biztonsági tesztcsomag zöld.
- Az app nem válik acquisition-controllerré és nem próbálja helyettesíteni a
  PixInsight, Siril, DSS, N.I.N.A. vagy ASIAIR szoftvert.
- Nincs kötelező fiók, telemetria vagy felhő.

## 3. Kutatási alap és diagnózis

A design három független auditból épül:

1. natív macOS és Apple Human Interface Guidelines audit;
2. valós asztrofotós end-to-end workflow audit;
3. SwiftUI-, állapotkezelési, adatbázis- és fájlbiztonsági architektúra-audit.

A három audit közös megállapítása: a V1 szakmailag erős, de az adatmodell és a
fejlesztési történet közvetlenül kirajzolódik a felületen. A jelenlegi sidebar
feladatot, tartalomtípust, elemző eszközt, állapotellenőrzést, törzsadatot és
minden egyes célpontot egyszerre mutat. A célpontoldalak belső fülei, a sok
dashboard-kártya, a hosszú táblázatok, a kontextusmenük és a 67 sheet miatt a
felhasználónak a program szerkezetét kell megtanulnia a saját munkája helyett.

Technikai tünetek a V1-ben:

- `AppState.swift`: 5887 sor, 232 tárolt/megfigyelhető állapot, 124 művelet;
- 163 SwiftUI view;
- 67 `.sheet` prezentáció;
- egy processzglobális `AppState.shared`;
- NotificationCenter-alapú navigáció és prezentáció;
- globális `isBusy`, `progressText`, `lastError` és részben globális task slot;
- több 900–1500 soros képernyő;
- sok fix ablak- és sheetméret;
- valódi application- és XCUITest target hiánya.

Az Apple irányelveivel összhangban a V2 nagy kijelzőn több tartalmat mutat
kevesebb modalitással, támogatja az ablakméretet, billentyűzetet, menüsort,
fókuszt, Inspectort és állapot-visszaállítást:

- https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/onboarding
- https://developer.apple.com/design/human-interface-guidelines/accessibility
- https://developer.apple.com/documentation/swiftui/view/inspector%28ispresented%3Acontent%3A%29/

## 4. Megvizsgált megközelítések

### A. Vizuális reskin

Új színek, spacing, kártyák és toolbar a jelenlegi oldalakon.

**Előny:** gyors.
**Hátrány:** a túlterhelt navigáció, globális állapot, táblázat- és sheet-sűrűség
megmaradna. Elutasítva.

### B. Új shell, régi oldalak

Rövidebb sidebar és jobb toolbar, de a jelenlegi oldalak változatlanul költöznek.

**Előny:** közepes kockázat, gyorsabb feature-parity.
**Hátrány:** tovább örökíti a moduláris, admin-dashboard mentális modellt és a
monolitikus app-state-et. Elutasítva.

### C. Objektum- és workflow-központú újraírás — választott

Az AstroCore megmarad. Fölé új application/safety réteg, új explicit V2
adatmodell és teljesen új SwiftUI shell készül. A funkciók vertikális szeletekben
kerülnek át, feature-parity és biztonsági kapu mellett.

**Előny:** valódi ergonomikus V2, tesztelhető állapotmodell, natív Mac-viselkedés,
tartós workflow-memória.
**Költség:** nagyobb implementációs scope, ezért szigorú szeletelés és kapuzás
szükséges.

## 5. Domain- és mentális modell

```text
Library
  ├─ Project
  │    ├─ Project plan / target / composition
  │    ├─ Night participation
  │    │    └─ Series
  │    │         └─ Frame
  │    └─ Result
  │         ├─ Stack run/result
  │         └─ Processing variant
  ├─ Calibration asset/master
  ├─ Health issue
  └─ Mutation journal
```

### 5.1 Library

Egy felhasználó által megnyitott képkönyvtár. Stabil `LibraryID`-vel, security-
scoped bookmarkkal, külön metadata- és indexstore-ral rendelkezik. Egy library
egy önálló ablak lehet; több library több független ablakban nyitható meg.

### 5.2 Project

Egy elkészítendő végső asztrofotó. Stabil UUID-je van, nem pusztán egy mappanév.

Tartalma:

- kanonikus célpontazonosság és katalógusrekord;
- magyar/angol megjelenítési név és aliasok;
- kívánt setup, kompozíció és FOV;
- teljes és szűrőnkénti integrációs cél;
- projektállapot és következő lépés;
- részt vevő éjszakák és sorozatok;
- stackek, feldolgozási változatok és végleges kép;
- publikálási, archív- és backup-readiness.

### 5.3 Night

Egy valódi megfigyelési éjszaka, amely több projektet is tartalmazhat.

Tartalma:

- helyi dátum, helyszín és időzóna;
- sötét időablak, Hold, opcionális időjárás;
- acquisition timeline és kiesések;
- aznap fotózott projektek/sorozatok;
- használható integráció és hatékonyság;
- hűtés-, fókusz- és gap-figyelmeztetések;
- jegyzetek és eseményjelölések;
- tartós review-állapot.

A V1 célpont+dátum sessionje belső kompatibilitási egységként megmaradhat, de a
V2 UI egy dátum alatt összefogja az összes célpontot.

### 5.4 Series

A V1 capture group emberi neve. Egy technikailag homogén felvételi csomag:

- project és night;
- kamera- és setup-pillanatkép;
- OSC/mono/DSLR szenzormód;
- passband és konkrét szűrő;
- nominális expozíció;
- gain, offset, binning;
- célhőmérséklet és mérési tartomány;
- saját minőségi eloszlás;
- calibration státusz;
- saját stack-input és eredmények.

Az automatikus split kulcsai: kamera, setup, szűrő/passband, nominális expozíció,
gain/offset és binning. Kis hőmérséklet- vagy időbélyegeltérés nem hoz létre új
sorozatot; figyelmeztetésként jelenik meg.

### 5.5 Frame

Egy FITS/RAW/CR3 vagy más támogatott asset. Állapotai egymástól külön élnek:

- emberi verdict: elfogadott, elvetett, nincs döntés;
- automatikus minőségi ajánlás;
- logikai kizárás;
- fizikai archív állapot;
- sorozat-hozzárendelés és metadata-forrás;
- calibration/stack/provenance kapcsolat.

Semmilyen frame nem kerül automatikusan emberi reject állapotba.

### 5.6 Result és Lineage

Két explicit eredményszint:

1. stack run/result;
2. processing variant.

Minden eredmény rögzítheti:

- input sorozatokat és frame-eket;
- kizárt frame-eket;
- calibration mastereket;
- szoftvert és verziót;
- recipe/manifest fájlt;
- szülő eredményt;
- szerepet: intermediate, starless, mask, final;
- kedvenc, publikált és archivált jelölést.

## 6. Információs architektúra

A fő sidebar hat stabil, emberi célt mutat:

1. **Kezdőlap**
2. **Projektek**
3. **Éjszakák**
4. **Tervezés**
5. **Könyvtár**
6. **Elemzések**

Nem kerül a sidebarba:

- minden egyes célpont;
- keresési eredmény;
- Szenzorprofilok;
- Szűrők;
- Takarítás mint külön oldal;
- Naptár mint ál-aloldal;
- Haladó fájlműveletek.

### 6.1 Régi → új funkciótérkép

| V1 funkció | V2 hely |
|---|---|
| Ma este | Kezdőlap összefoglaló + Tervezés |
| Naptár | Tervezés tartalomnézet |
| Felfedezés | Tervezés katalógus és kompozíció |
| Előző éjszaka | Kezdőlap Inbox + Éjszakák review-jelzés |
| Minden célpont | Projektek |
| Célpont Áttekintés/Sessionök | Projekt-detail |
| Célpont Minőség | Project/Series Review workspace |
| Stackek | Projekt Eredmények + lineage |
| Jegyzetek | Night/Project Inspector és timeline |
| Kalibráció | Series állapot + Könyvtár Health |
| Audit | Könyvtár Health |
| Takarítás | Könyvtár Health ▸ Tárhely és duplikátumok |
| Trendek | Elemzések |
| Szenzorprofilok | Beállítások ▸ Felszerelés |
| Szűrők | Beállítások ▸ Felszerelés + Series Inspector |
| Globális keresés | Toolbar keresés/palette, külön route nélkül |
| Session-konverter | Könyvtár ▸ Rendszerezés, series kontextusból is |
| Capture-besorolás | Series Inspector és többkijelölés |
| Riport/export | Share/Export menü az aktuális objektumon |
| CLI | Megmarad, ugyanazt az application/domainréteget használja |

## 7. Ablak és navigáció

### 7.1 Főablak

Nagy képernyőn:

```text
┌────────────┬──────────────────┬────────────────────────────┬──────────────┐
│ Sidebar    │ Content          │ Detail                     │ Inspector    │
│ 180–260 pt │ 260–420 pt       │ rugalmas                   │ 280–380 pt   │
└────────────┴──────────────────┴────────────────────────────┴──────────────┘
```

- SwiftUI `NavigationSplitView(sidebar:content:detail:)`;
- a jobb oldali Inspector `.inspector`;
- keskenyítéskor először az Inspector, majd a sidebar csukódik össze;
- nincs merev 1100×700 minimum;
- cél minimum: 820×600 mellett működő, nem széteső felület;
- full screen és több monitor támogatott;
- ablakonként önálló library, selection, sort és navigáció.

### 7.2 Állapot-visszaállítás

Ablakonként visszaáll:

- library;
- elsődleges section;
- content route;
- selection;
- sort és szűrő;
- sidebar/inspector láthatóság és szélesség;
- táblázatoszlopok;
- legutóbbi görgetési pozíció, ahol stabilan megoldható.

Nem áll vissza:

- confirm sheet;
- fájlmutációs engedély;
- ideiglenes hiba/toast;
- futó export- vagy konverziós dialogus.

### 7.3 Toolbar

Alap toolbar:

- rendszeres sidebar toggle;
- aktuális library/document cím;
- nézetspecifikus filter/scope;
- globális keresés;
- Scan/Import státusz;
- Új projekt/session;
- Inspector toggle.

Nincs kézzel hozzáadott overflow gomb: a rendszer kezeli a szűk toolbar
overflow-t. Minden toolbar-művelet elérhető a menüsávból is.

### 7.4 Billentyűzet

- `⌘O`: library megnyitása;
- `⌘N`: kontextus szerint új projekt vagy új éjszaka/session;
- `⌘F`: keresés;
- `Space`: Quick Look;
- `Return`: kijelölt objektum megnyitása;
- `Escape`: ideiglenes állapot vagy sheet bezárása;
- `⌘,`: Beállítások;
- rendszeres sidebar/inspector commandok;
- review módban dokumentált előző/következő, elfogadás/elvetés shortcutok.

## 8. Fő képernyők

### 8.1 Kezdőlap

Nem KPI-dashboard. Legfeljebb három történetet mutat:

1. **Folytatás** — félbehagyott review, legutóbbi projekt, stackre kész munka;
2. **Ma este** — 3–5 setuphoz illő javaslat, sötét idő és időjárás;
3. **Figyelmet kér** — bizonytalan series, hiányzó calibration, integritás,
   feldolgozatlan Inbox.

A lap napszak és könyvtárállapot alapján adaptív. A statisztika csak akkor jelenik
meg, ha egy döntést támaszt alá.

### 8.2 Projektek

Lista vagy vizuális grid, user-választható megjelenítéssel.

Alapmezők:

- final/stack preview vagy katalógus-placeholder;
- név;
- fázis;
- valós integráció / effektív cél;
- következő lépés;
- utolsó aktivitás.

Gyári smart filterek: Folytatandó, Stackre kész, Feldolgozásra vár, Kész,
Archivált.

A project detail három természetes történetre redukálódik:

- Áttekintés és progress;
- Képek/sorozatok/review;
- Eredmények és lineage.

Ezek nem egyenrangú, sűrű tabfalak: a detail navigáció a kiválasztott objektum
hierarchiájából és a toolbarból érhető el. A ritka metadata az Inspectorban van.

### 8.3 Éjszakák

Egy sor egy valódi éjszaka. A detail tartalmazza:

- Night Ribbont;
- célpont- és series-blokkokat;
- kint töltött időt, valós integrációt és hatékonyságot;
- hűtés/fókusz/gap eseményeket;
- helyszínt, Holdat, opcionális időjárást;
- jegyzeteket;
- calibration readiness-t;
- elsődleges **Éjszaka átnézése** műveletet.

### 8.4 Tervezés

Egyesíti a Ma este, Naptár és Felfedezés funkciót, de nem egyetlen óriástáblában.

Folyamat:

1. dátum, helyszín és setup;
2. Night Ribbon és körülmények;
3. ajánlott projektfolytatás;
4. katalóguskeresés katalógusszám, angol vagy magyar név alapján;
5. FOV/kompozíció;
6. integrációs és filterjavaslat;
7. projekt vagy első session létrehozása.

A 10 óra / APS-C / f/5 baseline egy **22,0 mag/arcsec² átlagos célpont-felületi
fényességhez**, 21,0 mag/arcsec² égboltháttérhez, broadband áteresztéshez és
1,0 normalizált rendszerhatékonysághoz kötött referencia. Kiterjedt objektumnál
az integrált magnitúdó önmagában félrevezető, ezért a katalógusban közölt vagy az
integrált magnitúdóból és szögméretből becsült átlagos felületi fényesség a
vezérlő érték. Pontszerű vagy nagyon kompakt célpont külön point-source modellt
használ.

A háttérlimitált relatív modell első változata:

```text
t = 10 h
    × 10^(0,8 × (μtarget − 22,0))
    × 10^(−0,4 × (μsky − 21,0))
    × (f / 5)^2
    × (1 / ηsystem)
    × Kpassband
    × Ksampling
```

- `μtarget`: a célpont átlagos felületi fényessége mag/arcsec²-ben;
- `μsky`: a helyi égboltháttér mag/arcsec²-ben;
- `ηsystem`: a kamera-QE, optikai áteresztés és valós sessionhatékonyság
  normalizált szorzója;
- `Kpassband`: broadband, dual-band és mono keskenysáv külön, empirikusan
  kalibrálható korrekciója;
- `Ksampling`: pixelméret, binning és célfelbontás korrekciója.

Az APS-C a referencia setup és kompozíció része, de a szenzorformátum önmagában
nem kap hamis expozíciós szorzót. A katalógusérték mellett mindig látszik a
forrás, passband, bizonyosság és az, hogy mért, származtatott vagy osztály-alapú
becslésről van-e szó. Ismeretlen fényességnél az objektumosztály konzervatív
priorja indul, amit a felhasználó egy mozdulattal felülírhat. Saját korábbi
session alapján az app később személyes korrekciót tanulhat, helyben tárolva.

A felület ezt tervezési referenciaként, nem garantált képminőségként vagy
laborpontosságú SNR-kalkulátorként mutatja. Az explicit kézi cél mindig
elsőbbséget élvez. A modell a forrás- és égboltfényességet külön kezeli, mert a
háttérlimitált tartományban az elérhető jel-zaj viszony a teljes integráció
négyzetgyökével változik.

A modell fizikai iránya az ESO CCD jel–zaj összefoglalójára és exposure-time
modelljeire támaszkodik; a 10 órás amatőr baseline és a korrekciós konstansok
AstroTool-termékdefaultok, később fixture-rel és valós saját sessionökkel
validálandók:

- https://www.eso.org/~ohainaut/ccd/sn.html
- https://etc.eso.org/
- https://www.eso.org/sci/facilities/lasilla/instruments/efosc/doc/manual/EFOSC2manual_v4.1.pdf

### 8.5 Könyvtár

Az adatállomány állapota és szervezése:

- Beérkezett / még nem besorolt;
- Health issue-k;
- calibration library;
- audit és integritás;
- duplikátumok és tárhely;
- archívum;
- legacy struktúra és session-konverter;
- haladó Rendszerezés.

Az alapértelmezett konverter logikai. Fizikai mód külön engedélyt és teljes
source→destination előnézetet kér.

### 8.6 Elemzések

Az Elemzések nem egyszerre mutat minden grafikont. Kérdésalapú dashboard:

- mikor és mennyit fotóztam;
- mely projektekbe mennyi idő került;
- milyen a hatékonyság trendje;
- hogyan változott a FWHM, háttér és fókusz;
- setup/filter megoszlás;
- calibration és reject okok;
- év/hónap/site/project összehasonlítás.

Minden grafikonhoz szöveges összefoglaló és táblázatos alternatíva tartozik.

### 8.7 Review workspace

A review nem sheet, hanem dedikált fókuszált munkaterület:

- nagy frame preview;
- alsó filmszalag;
- series minőségi eloszlás és a jelenlegi frame helye;
- Inspector: metadata, quality, calibration, provenance;
- elfogadás/elvetés;
- előző/következő;
- többkijelölés és batch szerkesztés;
- elvetett frame-nél külön **Archívumba helyezés**.

OSC, broadband, dual-band, mono és eltérő expozíció csak a saját homogén
series-eloszlásán belül hasonlítható össze.

## 9. Inspector

A kiválasztás vezérli. Egyetlen vagy több objektumhoz alkalmazkodik.

### Project Inspector

- célpont és aliasok;
- státusz és célidő;
- setup/kompozíció;
- címkék;
- publishing readiness.

### Night Inspector

- dátum, site, időzóna;
- körülmények;
- jegyzet és események;
- review státusz.

### Series Inspector

- kamera, szenzor, optika, fókusztáv, f-szám;
- OSC/mono/DSLR;
- passband és konkrét szűrő;
- expozíció, gain, offset, binning, hőmérséklet;
- calibration;
- metadata-forrás és bizonyosság.

### Frame Inspector

- thumbnail/preview;
- verdict és archive állapot;
- minőségi metrikák;
- source metadata;
- series-hozzárendelés;
- calibration és stack lineage.

Több kijelölt frame esetén csak a közös és módosítható mezők jelennek meg,
egyértelmű „vegyes érték” állapottal.

## 10. Night Ribbon — a termék karakteres eleme

Az egyetlen erősen megkülönböztető, domain-specifikus vizuál:

- polgári/nautikai/csillagászati szürkület;
- teljes sötétség;
- Hold horizont feletti és releváns fényes időszaka;
- célpont magasságíve;
- tervezett capture-ablak;
- tényleges series-szakaszok;
- gap, meridián flip, refocus, felhő és egyéb események.

Megjelenik:

- Kezdőlap Ma este blokkjában;
- Tervezésben;
- Night detailben;
- Project detail releváns éjszakáján;
- V2 weboldal hero-előnézetében.

Mindig kap szöveges összefoglalót és hozzáférhető leírást.

## 11. Vizuális rendszer

### 11.1 Alapelv

Az app nem imitál Apple-marketinggrafikát. Rendszerkomponenseket, rendszer-
tipográfiát és rendszer-viselkedést használ. A szakmai tartalom adja az egyedi
karaktert.

### 11.2 Színek

Natív dinamikus színek az elsődlegesek:

- háttér: `windowBackgroundColor`, content background, sidebar material;
- elsődleges szöveg: `labelColor`;
- másodlagos: `secondaryLabelColor`;
- elválasztó: `separatorColor`;
- accent: system indigo (`#5856D6` világos referenciaként);
- adatkiemelés: system cyan (`#32ADE6`);
- siker: system green;
- figyelem: system orange;
- hiba: system red.

Szín soha nem az állapot egyetlen hordozója.

### 11.3 Tipográfia

- SF Pro / rendszerfont;
- `largeTitle` csak Welcome és ritka Home hero;
- `title2` oldal-/objektumcím;
- `headline` szekció;
- `body` elsődleges tartalom;
- `callout` magyarázat;
- `caption` másodlagos metadata;
- `caption2` nem hordoz kritikus információt;
- `monospacedDigit` idő, integráció és mérőszám esetén.

### 11.4 Térköz és formák

8 pontos alaprács, 8/12/16/24/32 értékekkel. Lekerekített kártya csak valódi,
önálló tartalmi egységhez. A legtöbb struktúrát spacing, Section, Divider,
selection és material adja, nem egymásba rakott szürke dobozok.

### 11.5 Táblázatok

- alapból 4–6 oszlop;
- rendezhető, átméretezhető, választható oszlopok;
- oszlopsorrend és szélesség per window visszaáll;
- nincs állandó ellipsis-akcióoszlop;
- művelet a context menüben, toolbarban, menüsávban vagy Inspectorban;
- expert Columns menüvel minden haladó adat visszakapcsolható.

## 12. Onboarding és első indítás

### 12.1 Kötelező út

Legfeljebb három rövid állapot:

1. **Library kiválasztása vagy mappa ráhúzása**
   - helyi feldolgozás;
   - a felhasználó választja a hatókört;
   - első scan nem töröl és nem mozgat.
2. **Read-only előnézet és első scan**
   - mit talált és mit ismer fel;
   - struktúrakorlátok;
   - valós progress;
   - részleges adatok már megjelenhetnek.
3. **Eredmény**
   - projektek, éjszakák, frame-ek száma;
   - elsődleges: Könyvtár áttekintése;
   - opcionális: Személyre szabás.

### 12.2 Kontextuális személyre szabás

A hétoldalas kötelező wizard megszűnik. A részletes oldalak megmaradnak, de
kihagyhatók és akkor jelennek meg, amikor szükségesek:

- site/időjárás az első tervezéskor;
- kamera/optika az első FOV vagy setup-hiánykor;
- szűrő az első bizonytalan filteradatnál;
- Siril/minőségi küszöb az első pontozáskor;
- baseline célidő az első projekttervezéskor.

Minden prompt: **Beállítás** és **Most nem**. TipKit vagy inline segítség tanít,
nem hosszú upfront oktatás.

### 12.3 Defaultok

- nincs személyes útvonal, kamera, optika vagy szűrő;
- semleges APS-C és full-frame szenzorméret preset megengedett;
- integrációs referencia: 10 óra, APS-C, f/5, 1,0 hatékonyság,
  22,0 mag/arcsec² célpont-felületi fényesség, 21,0 mag/arcsec² égboltháttér,
  broadband;
- időjárás kikapcsolva;
- Siril opcionális;
- könyvtárszervezés/fájlmozgatás kikapcsolva.

## 13. Beállítások

Külön macOS Settings scene, körülbelül öt stabil toolbar-pane-nel:

1. **Általános**
2. **Libraries és biztonság**
3. **Tervezés** — site, időjárás, célidőmodell
4. **Felszerelés és értékelés** — kamera, optika, setup, szűrő, szenzorprofil,
   Siril, minőségi modell
5. **Integrációk és támogatás** — export, AstroBin, diagnosztika, privacy

Az aktív pane visszaáll. A settings ablak nem kap külön főablak-szerű oldalsáv-
hierarchiát. A gyors, egymezős beállítás automatikusan ment; összetett editor
egyértelmű Mégse/Mentés határt használ.

## 14. Application architektúra

```text
AstroCore
  scan / FITS / audit / rating / planning / calibration / capture / export
        ↓
AstroApplication
  actor-alapú library session, use case, snapshot, operation, mutation safety
        ↓
AstroUI
  router, feature store, selection, inspector, SwiftUI view, design system
        ↓
AstroToolApp
  composition root, scenes, commands, app lifecycle
```

### 14.1 Célmodulok

```text
Sources/AstroApplication/
  Library/
  Operations/
  Mutations/
  Persistence/
  Features/

Sources/AstroUI/
  App/
  DesignSystem/
  Features/Home/
  Features/Projects/
  Features/Nights/
  Features/Planning/
  Features/Library/
  Features/Insights/
  Features/Review/
  Inspector/
  Commands/
  PreviewSupport/
```

### 14.2 AppModel

Az új globális appmodell csak ezt birtokolja:

- app lifecycle;
- megnyitott LibrarySessionök;
- ablakonkénti router;
- OperationCenter;
- globális, felhasználói figyelmet igénylő issue-k;
- típusos presentation route.

Nem birtokol feature-táblákat, minden oldal betöltött adatait vagy általános DB-
referenciát.

### 14.3 Feature store

Minden nagy feature külön `@MainActor @Observable` store. A view immutable
snapshotot rajzol és nem aggregál közvetlenül DB-adatot. Minden snapshot hordoz
`LibraryID` és `revision` értéket, ezért stale háttéreremény nem írható másik
library vagy frissebb query állapotára.

### 14.4 OperationCenter

Nincs globális `isBusy`. Műveleti scope példák:

- scan(libraryID);
- loadHome(libraryID, date);
- rate(seriesID);
- audit(libraryID);
- export(projectID);
- convert(sessionID).

Minden műveletnek saját progressze, cancellation policy-je, eredménye és logja
van. A UI csak az érintett kontextust tiltja. Nem kooperatívan megszakítható Core-
munka esetén a felirat őszintén az eredmény elengedését jelzi, nem hamis
„Mégse” ígéretet tesz.

### 14.5 Routing és presentation

- típusos PrimarySection, ContentRoute és LibrarySelection;
- selection vezérli a detailt és Inspectort;
- `FocusedValues`/`focusedSceneValue` köti a menüparancsot az aktív ablakhoz;
- nincs `AppState.shared`;
- nincs navigációs NotificationCenter;
- egy típusos `PresentationRoute` kezeli az aktív modált;
- nem marad képernyőnként 8–10 független sheet boolean.

## 15. Adattárolás és V1 átmenet

### 15.1 Új helyek

```text
~/Library/Application Support/AstroTool/
  app.sqlite
  Libraries/<library-id>/
    metadata.sqlite
    migration/

~/Library/Caches/AstroTool/
  Libraries/<library-id>/
    index.sqlite
    thumbnails/
    reports-preview/
```

`metadata.sqlite` tartalmazza az emberi és tartós adatot:

- project/night/series identitás;
- felszerelések, setupok, filterek, site-ok;
- célok, címkék, jegyzetek, verdict-ek;
- capture-besorolás és metadata override;
- review-állapot;
- lineage és mutation journal.

`index.sqlite` újraépíthető:

- fájlok és FITS/RAW metadata;
- számított rating;
- audit/fixity cache;
- keresési index;
- aggregált query cache.

### 15.2 V1 import

1. A V2 megkeresi, de nem módosítja a V1 `.astro_tool` store-t.
2. Teljes másolatot készít az Application Support migration területére.
3. A másolatból importálja a user-authored adatokat.
4. A derived indexet read-only rescanből újraépíti.
5. Importösszegzést és eltérést mutat.
6. A V1 store automatikusan soha nem törlődik.

A felhasználó engedélyezte a V2 app-adatbázis resetjét, de a design ennél
konzervatívabb: az új store tisztán épül, a régi forrás pedig megmarad
visszaállítási alapnak.

### 15.3 Hordozható manifest

A tartós emberi döntések exportálhatók/importálhatók verziózott manifestbe.
Egy sérült vagy resetelt SQLite nem semmisítheti meg a projectidentitást,
jegyzetet, verdictet, series-hozzárendelést vagy lineage-et.

## 16. Fájlmódosítási biztonság

Gyári állapot: `LibraryAccessMode.readOnly`.

Bármilyen képet érintő művelet csak a következő pipeline-on futhat:

1. explicit könyvtárszervezési engedély;
2. immutable `LibraryMutationPlan`;
3. library revision és source fingerprint;
4. fájlszám, byte és minden source/destination előnézete;
5. no-overwrite és symlink-escape ellenőrzés;
6. külön felhasználói megerősítés;
7. apply előtti friss fingerprint;
8. append-only journal/receipt;
9. rollback;
10. collision vagy stale terv esetén fail-closed leállás.

A view és feature store nem kap általános `FileManager.moveItem` hozzáférést.
Kizárólag validált plan ID-t adhat át a mutation authorizernek.

Explicit mutációk:

- új session/projekt mappaszerkezet létrehozása;
- session fizikai konverziója;
- elvetett frame archívumba mozgatása/visszaállítása;
- calibration hardlink;
- user által választott exportcél.

Minden más read-only vagy app-owned store-ba ír.

## 17. Hibák, progress és tevékenység

Feature load state:

```text
idle
loading(previous?)
loaded(snapshot)
failed(userFacingIssue, previous?)
```

- Frissítés közben a korábbi tartalom megmaradhat.
- Részleges hiba nem üríti ki az egész oldalt.
- Helyrehozható hiba inline jelenik meg konkrét művelettel.
- Tartós biztonsági vagy adatminőségi issue a Health/Inspector felületen marad.
- Toast csak rövid, nem kritikus visszajelzés.
- Technikai részlet külön **Részletek másolása** alatt található.
- Activity Center csak valóban hosszú műveleteket mutat.

## 18. Akadálymentesség

- Full Keyboard Access támogatás;
- VoiceOver-label minden ikongombon és interaktív vizuálon;
- Night Ribbon és grafikon szöveges/táblázatos alternatívával;
- állapot ikon + szöveg, nem csak szín;
- minimum kényelmes macOS kontrollméret;
- nagyított szöveg és ablakméret mellett nincs levágás;
- Dark Mode, Increase Contrast, Differentiate Without Color;
- Reduce Motion mellett nincs pulzáló/repetitív empty-state animáció;
- Accessibility Inspector és automatizált audit a release gate része.

## 19. Lokalizáció

A V1 magyar és angol lokalizációt deklarál teljes valódi lokalizáció nélkül. A
V2 release csak az alábbi két őszinte állapot egyikével készülhet:

1. teljes String Catalog magyar és angol UI-val; vagy
2. csak magyar lokalizáció deklarálásával.

A domainadatok stabil, nyelvfüggetlen kódot kapnak; a megjelenített szöveg a UI-
rétegben lokalizálódik. DB-be és JSON-ba nem kerül új, lokalizált enum-érték.

## 20. Weboldal

A jelenlegi oldal technikailag reszponzív és hozzáférhető alapokat tartalmaz, de
a V1 dashboard-makettet és általános fekete/lila termékesztétikát viszi tovább.

A V2 weboldal története:

```text
Projekt → Éjszaka → Sorozat → Képkocka → Eredmény
```

Szerkezete:

1. rövid hero valódi, szintetikus V2 app-előnézettel;
2. Night Ribbon;
3. esti tervezés és reggeli review;
4. project/series/provenance történet;
5. read-only és helyi adatbiztonság;
6. feldolgozási lineage és stack handoff;
7. telepítés, rendszerkövetelmény, privacy, támogatás;
8. pontos release státusz.

Nincs dekoratív csillagmező, irreális marketingmetrika vagy a V1-ről készült
félrevezető screenshot. Minden app-minta szintetikus és láthatóan mintaadat.

## 21. Tesztstratégia

### 21.1 Célok

- `AstroCoreTests` megmarad;
- új `AstroApplicationTests`;
- új UI-store/router tesztek;
- valódi `AstroToolUITests` XCUITest scheme;
- source-string teszt csak másodlagos release guard lehet.

### 21.2 UI fixture

Minden UI teszt determinisztikus, ideiglenes fixture libraryt kap launch
argumentból. A valódi `/Volumes/images` vagy más felhasználói könyvtár útvonalát
a tesztfolyamat explicit tiltólistával elutasítja.

Kötelező fixture-ek:

- tiszta telepítés, üres library;
- IC 1396: 5/30/120/300 s, OSC + SV220 dual-band;
- több célpontos egyetlen Night;
- DSLR/OSC/mono vegyes library;
- hiányzó és bizonytalan calibration;
- audit/duplikátum/fixity issue;
- stack és processing lineage;
- lecsatolt volume és hozzáférési hiba;
- nagy, szintetikus index teljesítményteszthez.

### 21.3 Képkönyvtár-manifest guard

Read-only tesztek előtt és után:

- relatív path;
- size;
- mtime;
- inode;
- SHA-256.

Bitazonosság szükséges scan, audit, rating, planning, search, browsing, preview,
report-preview és index-reset után. Mutation preview/cancel után ugyanez szükséges.
Apply csak ideiglenes fixture-másolaton futhat.

### 21.4 Vizuális és accessibility mátrix

- 820×600;
- 1100×700;
- 1440×900;
- teljes képernyő;
- light/dark;
- Increase Contrast;
- Reduce Motion;
- nagyított szöveg;
- sidebar és Inspector nyitva/csukva;
- VoiceOver/Full Keyboard Access smoke.

### 21.5 Feature-parity mátrix

Minden V1 funkcióhoz rögzíteni kell:

- V2 route;
- UI acceptance test;
- AstroCore/application use case;
- permission és mutation mód;
- export/CLI parity;
- accessibility és empty/error állapot.

A V1 UI-fájl csak akkor távolítható el, ha a hozzá tartozó sor teljes.

## 22. Implementációs szeletek

1. **Biztonsági és application-alap** — manifest guard, App Support store,
   LibrarySession, OperationCenter, V1 import.
2. **Új shell és design system** — router, split view, Inspector, toolbar,
   focused commands, window state.
3. **Onboarding és Home** — clean install, scan, Inbox, next actions.
4. **Projects és Nights** — explicit modell, listák, detail, Night Ribbon.
5. **Series és Review** — felismerés, Inspector, quality, archive split.
6. **Planning** — katalógus, FOV, setup, célidő, új project/session.
7. **Library Health** — calibration, audit, cleanup, fixity, converter.
8. **Results és Insights** — stack, processing lineage, riportok, trendek.
9. **Haladó mutációk és CLI parity**.
10. **Website, lokalizáció, accessibility és release hardening**.

Minden szelet sorrendje:

1. failing application/UI test;
2. minimal implementation;
3. feature parity review;
4. safety manifest run;
5. visual/accessibility review;
6. commit;
7. következő szelet.

## 23. Elfogadási próba

Egy új felhasználó külső segítség nélkül legyen képes:

1. kiválasztani a libraryt és megérteni a read-only ígéretet;
2. beolvasni anélkül, hogy a képfájlok változnának;
3. Elephant's Trunkot katalógusszám, angol vagy magyar név alapján megtalálni;
4. meglévő vagy új projektet megnyitni/létrehozni;
5. ugyanazon éjszakán külön 5, 30, 120 és 300 s sorozatot látni;
6. az SV220 szűrőt az Inspectorban beállítani;
7. külön minőségi eloszlást látni minden sorozathoz;
8. frame-et elvetni anélkül, hogy az mozogna;
9. külön döntéssel, előnézettel archívumba helyezni és visszaállítani;
10. megérteni, mely calibration hiányzik és miért;
11. csak a kiválasztott sorozat stacket előkészíteni;
12. megtalálni a stack és processing származási láncát;
13. látni, mennyit és mikor fotózott;
14. mindig látni a következő értelmes lépést;
15. mindezt úgy, hogy nem kell tudnia, mely technikai riport mely régi oldalon
    vagy menüben lakott.

## 24. V2.0.0 release gate

A V2.0.0 csak akkor tekinthető késznek, ha:

1. a teljes régi AstroCore-tesztcsomag zöld;
2. az új application/store/router tesztek zöldek;
3. az XCUITest fő workflow-k zöldek;
4. a read-only manifest suite bitazonosságot bizonyít;
5. clean install és V1-import smoke sikeres;
6. minden V1 funkció feature-parity sora teljes;
7. nincs személyes placeholder vagy útvonal;
8. accessibility és ablakméret mátrix ellenőrzött;
9. app, CLI, riport, weboldal és release note verziója `2.0.0`;
10. Universal arm64+x86_64 build kész;
11. DMG, CLI ZIP és SHA-256 manifest ellenőrzött;
12. a helyi build telepítve és a futó bináris útja/verziója ellenőrzött;
13. publikus release csak megfelelő Developer ID, notarizációs hitelesítés és
    konkrét GitHub publikálási jogosultság mellett készül.

## 25. Önellenőrzési checklist

- [x] Nincs TBD, placeholder vagy nyitott termékdöntés.
- [x] A V1 funkciók új helye meghatározott.
- [x] A képkönyvtár-biztonsági modell explicit.
- [x] A DB-reset és V1 import viselkedése explicit.
- [x] Az onboarding, főképernyők, Inspector és Settings meghatározott.
- [x] A vizuális rendszer és Night Ribbon meghatározott.
- [x] Az application/UI architektúra és state ownership meghatározott.
- [x] A teszt-, accessibility-, web- és release kapuk meghatározottak.
- [x] A specifikáció nem tesz hamis publikus aláírás/notarizáció ígéretet.
