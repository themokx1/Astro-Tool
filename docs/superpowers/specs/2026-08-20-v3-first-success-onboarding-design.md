# AstroTool V3 First-Success Onboarding Design

**Dátum:** 2026-08-20  
**Állapot:** jóváhagyott irány, önellenőrzött végleges specifikáció  
**Célkiadás:** AstroTool 3.0.0 (stabil, nem béta)

## 1. Cél és célközönség

Az onboarding olyan asztrofotósnak készül, aki nem fejlesztő, nem ismeri az
AstroTool mappaszabványát, és a fotói jelenleg tetszőleges mappákban vagy külső
lemezen lehetnek. A folyamat célja nem a teljes termék megtanítása, hanem az első
biztonságos siker: a felhasználó értse meg az alapmodellt, tudjon létrehozni vagy
megnyitni egy könyvtárat, és opcionálisan egyetlen összefüggő folyamatban
létrehozza az első projektjét, éjszakáját és capture-jét a képei bemásolásával.

A felület elsődleges nyelve hétköznapi. A „session”, „capture”, útvonal és
fájlrendszer-szintű részletek csak ott jelennek meg, ahol az asztrofotós
jelentésük szükséges; minden technikai részlet külön, lenyitható magyarázatba
kerül.

## 2. Kötelező termékígéretek

1. A forrásképek az import teljes ideje alatt változatlanok maradnak.
2. Az onboarding importja kizárólag másol; nem mozgat, nem nevez át és nem töröl
   forrásfájlt.
3. Meglévő célfájl soha nem íródik felül. Ütközés esetén kihagyás és érthető
   jelentés készül.
4. Minden elkészült másolat forrás- és céloldali SHA-256 ellenőrzést kap.
5. Nincs önálló törlési funkció. Az alkalmazás kizárólag a saját, ugyanabban az
   atomikus műveletben létrehozott félkész ideiglenes állományát takaríthatja el
   hiba esetén; korábban létező felhasználói fájlt vagy mappát nem töröl.
6. Fájlrendszeri írás csak a `WriteGuard` dedikált, fehérlistás műveletein át
   történhet. A SwiftUI nézetek nem írhatnak közvetlenül `FileManager`rel.
7. A projekt + éjszaka + capture + képmásolás egyetlen opcionális blokk: együtt
   végrehajtható vagy együtt kihagyható.
8. Az onboarding bezárható, majd a **Súgó → Első lépések** menüből bármikor újra
   előhozható.

## 3. Nyitóképernyő

A főképernyő három nagy, egymással egyenrangú, emberi választást ad:

1. **Új képkönyvtár létrehozása**
2. **Már van AstroTool-könyvtáram**
3. **Előbb szeretném megérteni**

Mindhárom kártya egy mondatban leírja az eredményt, nem a technikai műveletet.
Az első az ajánlott út, de nem kap megtévesztő vagy nyomást gyakorló jelölést.
Billentyűzettel, VoiceOverrel és teljes billentyűzet-hozzáféréssel is végigjárható.

## 4. Egységes folyamat

### 4.1 Új könyvtár

1. A felhasználó helyet és nevet választ.
2. Előnézet jelenik meg: „Egy új, rendezett képkönyvtár jön létre itt”, valamint
   egy lenyitható **Mi jön létre a gépemen?** rész.
3. A létrehozás idempotens, kizárólag hiányzó mappákat készít:
   `sessions/`, `stacks/`, `processed/`,
   `calibration_library/{darks,flats,biases}` és a szükséges `.astro_tool`
   alkalmazásterület.
4. Siker után a könyvtár mentett macOS biztonsági könyvjelzőt kap, megnyílik, és
   a mutációs mód engedélyeződik. A felület világosan jelzi, hogy az AstroTool
   ettől kezdve létrehozhat és bemásolhat elemeket ebbe a könyvtárba, de önálló
   törlést nem végez.

### 4.2 Meglévő könyvtár

1. Mappa választása vagy ráhúzása.
2. Gyors, írásmentes szerkezetellenőrzés.
3. Emberi összegzés: mi használható, mi hiányzik, és mit tud az AstroTool
   biztonságosan létrehozni.
4. A könyvtár csak kifejezett megerősítés után nyílik meg írásra engedélyezett
   módban. A hiányzó alapmappák létrehozása külön, előnézetes létrehozási
   művelet; meglévő tartalom nem változik.

### 4.3 Előbb szeretném megérteni

Ez az ág teljesen írásmentes. Rövid, lapozható magyarázatot ad:

- **Könyvtár:** minden AstroTool által követett kép közös otthona.
- **Projekt:** egy égboltobjektum hosszabb távú gyűjtése.
- **Éjszaka:** egy adott dátum megfigyelése.
- **Capture:** azonos felszereléssel, szűrővel és expozícióval készült sorozat.
- **Képtípusok:** light, flat, dark és bias egyszerű, egy-egy mondatos leírással.

A végén visszatér a három választáshoz; nem viszi át automatikusan másik ágba.

### 4.4 Opcionális első import

Az új vagy meglévő könyvtár sikeres megnyitása után egyetlen kártya kérdez:
**Szeretnéd most bemásolni az első fotóidat?**

- **Most bemásolom:** forrásmappa → felismerés → bizonytalan képek emberi
  besorolása → projekt/éjszaka/capture adatok → teljes másolási előnézet →
  megerősítés → másolás és ellenőrzés → eredmény.
- **Most kihagyom:** az onboarding késznek jelölhető, és megnyílik az alkalmazás.

A forrásválasztástól az eredményig minden oldalon látható egy állandó biztonsági
sáv: **„A forrásaid változatlanok maradnak. Az AstroTool csak ellenőrzött
másolatokat készít az új könyvtárban.”**

Csak nagy bizonyosságú metaadat tölthető elő. A célpont, dátum vagy capture
adata soha nem válik véglegessé felhasználói áttekintés nélkül. Az ismeretlen
képek kizáródnak, nem kapnak találgatott típust.

### 4.5 Befejezés

Az eredményoldal hétköznapi összegzést ad:

- létrehozott könyvtár;
- létrehozott projekt, éjszaka és capture;
- bemásolt és ellenőrzött képek száma és mérete;
- ütközés miatt kihagyott vagy hibás képek;
- ismételt állítás arról, hogy a forrás változatlan maradt.

Elsődleges művelet: **Projekt megnyitása**. Import kihagyásakor:
**Belépés az AstroToolba**.

## 5. Vizuális irány

A felület natív macOS és a meglévő `AstroTokens` rendszer része. Nem általános
telepítővarázsló: a megkülönböztető vizuális elem egy fokozatosan felépülő
„képkönyvtár-térkép”. A szétszórt forrásképekből vizuálisan egy rendezett út
alakul ki: Könyvtár → Projekt → Éjszaka → Capture → képtípusok.

- Nyugodt felület, egy elsődleges döntés képernyőnként.
- Technikai mappafa csak lenyitható részben.
- Nincs szükségtelen animáció; a reduce-motion beállítás tiszteletben tartandó.
- A veszélyt nem piros riasztásokkal dramatizáljuk, hanem állandó, következetes
  és konkrét biztonsági mondatokkal tesszük érthetővé.
- Magyar és angol lokalizáció teljes; nincs kódba rejtett, lefordíthatatlan
  felhasználói szöveg.

## 6. Alkalmazás-architektúra

### 6.1 Koordináció

Új `FirstSuccessOnboardingStore` tartja a képernyőállapotot és az útvonalat.
Nem másolja le a meglévő üzleti logikát:

- meglévő könyvtár megnyitásához a jelenlegi `OnboardingStore` képességeit;
- projekt/éjszaka/capture létrehozásához a `NewSessionStore` és
  `SessionCreationCommand` útját;
- felismeréshez és másoláshoz a `CaptureImportStore` és
  `CaptureImportCommand` útját használja.

A beágyazott nézeti szakaszok közös store-okat kapnak; nem indul egymásra több
független importfolyamat.

### 6.2 Új könyvtár létrehozása

Új `LibraryCreationCommand` biztosít:

- tisztán számolt `preview(root:) -> LibraryCreationPreview` eredményt;
- `create(root:accessMode:) -> LibraryCreationReceipt` műveletet;
- pontos létrehozott/korábban létező útvonallistát;
- kizárólag létrehozást, felülírás és általános törlés nélkül.

A tényleges mappaműveletek új, szűk `WriteGuard.createLibraryScaffold()`
belépési ponton mennek át. A parancs félbemaradása biztonságos: újbóli futtatása
csak a még hiányzó mappákat hozza létre.

### 6.3 Életciklus és visszahívás

`OnboardingLifecycle.currentVersion` 2-re emelkedik, így a lényegesen új
onboarding egyszer a korábbi felhasználóknak is megjelenik. A Súgó menü ugyanazt
a `FirstSuccessOnboardingView` felületet nyitja meg `help` módban. Bezáráskor az
eddigi sikeres könyvtár- vagy importművelet nem fordul vissza; a még el nem
indított lépések egyszerűen elmaradnak.

## 7. Webes „Első lépések” oldal

Új `docs/first-steps.html` készül a főoldal közös designrendszerével. A jelenlegi
`tutorial.html` megmarad rövid kompatibilitási/átirányítási oldalként, hogy régi
hivatkozás ne törjön el. A főoldal, a navigáció, a támogatási oldal, a README és
az alkalmazás termékinformációja az új oldalra mutat.

Az oldal ugyanazt a történetet meséli el, mint az alkalmazás:

1. a három kezdő választás;
2. a könyvtár egyszerű fogalmi térképe;
3. új könyvtár létrehozása;
4. opcionális, másolásos első projekt/capture;
5. az előnézet és SHA-256 ellenőrzés;
6. forrás érintetlensége és a „nincs önálló törlés” szabály;
7. későbbi újranyitás a Súgó menüből.

Az oldal reszponzív, billentyűzet- és képernyőolvasó-barát, és tiszteletben
tartja a reduced-motion, világos és sötét megjelenítést.

## 8. Hibák és megszakítás

- Mappalétrehozási hiba esetén pontosan megjelenik, mi készült el és mi nem;
  újrapróbálható.
- Másolási hiba fájlonként jelenik meg; a többi fájl feldolgozása folytatódik.
- Ellenőrzési eltérésnél csak az adott művelet által frissen létrehozott hibás
  célpéldány távolítható el tranzakciós takarításként.
- Külső lemez leválasztásakor az állapot nem állít sikert, és újrapróbálást kér.
- Megszakítás nem indít forrásoldali takarítást és nem kínál „kártya ürítése”
  műveletet.

## 9. Ellenőrzési stratégia

### Automatizált

- `LibraryCreationCommand`: pontos fa, idempotencia, read-only kapu,
  felülírás- és törlésmentesség.
- Onboarding store: mindhárom belépési ág, import kihagyása, visszalépés,
  súgóból megnyitás és lifecycle v2.
- Integráció: forrásmappa bitazonos manifestje a folyamat előtt és után;
  projekt/éjszaka/capture célfa és SHA-256 egyezés.
- Ütközés, bizonytalan típus, megszakítás és részleges hiba.
- Lokalizációs lefedettség, accessibility identifier és felületi szövegek
  őszintesége.
- Web: új oldal, navigációs hivatkozások, közös CSS, biztonsági állítások,
  reszponzív és reduced-motion felszín.
- Teljes Swift tesztcsomag, publikus tartalomellenőrzés, clean-install smoke,
  univerzális build és csomagolási tesztek.

### Kézi

- Első indítás üres alkalmazásállapottal.
- Új könyvtár belső és külső lemezen.
- Meglévő szabályos és hiányos könyvtár.
- Kis valódi mintamappa teljes első importja.
- VoiceOver, billentyűzet, nagyobb szöveg, világos/sötét mód.
- Weboldal asztali és keskeny mobilnézetben.

## 10. Stabil kiadás

- Verzió: `3.0.0`, build: `30002`, csatorna: Stable.
- Release notes külön kiemeli az onboardingot, a másolásos importot, az
  adatbiztonsági korlátokat és a rendszerkövetelményt.
- A build Universal (`arm64` + `x86_64`).
- A helyi telepítő előbb ellenőrzi a csomagot, menti a korábbi alkalmazást,
  telepít, majd verziót és architektúrát igazol.
- A GitHub stabil kiadás csak sikeres teszt, aláírás és notarizáció után
  tekinthető teljesnek. A repó jelenlegi külső blokkolója a hiányzó Developer ID
  tanúsítvány/notarizációs titok; ezt a publikáláskor újra ellenőrizni kell, és
  hiteles aláírás nélkül nem állítható, hogy a publikus macOS kiadás notarizált.

## 11. Önellenőrzés a felhasználói igény ellen

- **Nem műszaki embernek készül:** a három belépési pont és minden elsődleges
  címke eredményt mond, nem implementációt; a mappafa másodlagos.
- **Nem ismeri a szabványt:** az írásmentes „Előbb szeretném megérteni” ág és a
  progresszív könyvtártérkép ezt előfeltétel nélkül tanítja meg.
- **A képei bárhol lehetnek:** tetszőleges forrásmappa választható; a forrás nem
  kell AstroTool-szerkezetű legyen.
- **Első projekt és capture egy folyamatban:** az opcionális importblokk együtt
  hozza létre a projektet, éjszakát és capture-t, majd másol.
- **Egyben kihagyható:** nincs félig létrehozott üres projekt csak azért, mert a
  felhasználó kihagyta az importot.
- **Írás engedélyezett, törlés nem:** létrehozás és másolás explicit; önálló
  törlési művelet nincs, csak saját félkész temp tranzakciós eltakarítása.
- **Nagyon világos biztonság:** a forrás érintetlensége három döntési ponton és
  az eredménynél is megjelenik, nem csupán egyszer egy súgóban.
- **Bármikor visszahívható:** az első indítás és a Súgó ugyanazt a felületet
  használja.
- **Weben is tanulható:** az új, belinkelt oldal ugyanazt a mentális modellt és
  ugyanazokat a biztonsági ígéreteket adja.
- **Tényleges stabil kiadás:** a verzió és kiadási csatorna nem béta; publikus
  kiadási állítás csak bizonyított aláírás/notarizáció mellett történik.

Az önellenőrzés nem talált olyan felhasználói követelményt, amelyhez ne tartozna
konkrét folyamat, biztonsági invariáns és ellenőrzési pont.
