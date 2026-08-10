# AstroTool 1.0 — nyilvános, tiszta és kiadásra kész macOS-termék

**Dátum:** 2026-08-10  
**Ág:** `codex/v1.0.0-public-release`  
**Kiindulási alap:** v0.16.0 (`3aa3704`)  
**Állapot:** megvalósításra jóváhagyott irány

## 1. Cél

Az AstroTool 1.0 ne egyetlen ember gépére szabott fejlesztői build, hanem mások
által is érthetően telepíthető, biztonságosan kipróbálható és stabilan használható
macOS-alkalmazás legyen. A termék induljon tiszta állapotból, ne tartalmazzon
személyes útvonalat, felszerelést vagy mintafolyamatot, és minden adatkezelési
művelet előtt világosan mondja el, mit fog tenni.

A felület nem Apple-felületet másol, hanem a macOS Human Interface Guidelines
alapelveit követi: natív vezérlők, világos hierarchia, kevés modális megszakítás,
reszponzív ablak, közvetlen manipuláció, jó billentyűzetes használat és visszafogott
vizuális nyelv.

## 2. A kiadás előtti audit tényei

Az audit az alábbi 1.0-blokkolókat találta:

1. A friss telepítés alapértelmezett gyökere `/Volumes/images/Astro`, ezért egy
   idegen gépen nem létező személyes kötetet próbál megnyitni.
2. A v0.16 onboarding üres konfigurációnál automatikusan betölti a Canon R8,
   APS-C 100–400 mm és SV220 jellegű személyes mintákat. Ezek explicit presetként
   sem lehetnek gyári alapállapotok.
3. A bundle azonosító `com.zoltanpalotai.astrotool`, ami személyhez kötött és
   nem kiadói/termékazonosító.
4. A build vékony `arm64` bináris, ad-hoc aláírással. A GitHub Actions jelenleg
   aláírás és notarizálás nélkül publikálna.
5. A weboldal szűk fejlesztői dokumentációs oldal; személyes könyvtárból származó
   számokat és nem notarizált telepítési kerülőutat emel ki termékígéretként.
6. A verzió több helyen kézzel beégetett, ezért könnyen eltérhet az app, CLI,
   riport és release note verziója.
7. Nincs tiszta telepítést ellenőrző automata kapu, amely új felhasználói profillal
   bizonyítja a személyes placeholder-mentes első indítást.
8. Nincs felhasználóbarát támogatási diagnosztika és egyértelmű adatvédelmi
   összefoglaló.

## 3. Megvizsgált megközelítések

### A — csak release-hardening

Verzió, bundle ID, universal build, weboldal és release workflow javítása. Gyors,
de a személyes onboarding és az első indítás szerkezeti hibája megmaradna.

### B — teljes, fókuszált 1.0 termékesítés — választott

A release-hardening mellett új tiszta indulási modell, örökölt állapot migráció,
egységes felületi alapok, támogatási diagnosztika, weboldal-újratervezés és tiszta
telepítési smoke teszt készül. Ez ad valós kiadási minőséget anélkül, hogy fiókot,
felhőt vagy telemetriát vezetne be.

### C — teljes kereskedelmi infrastruktúra

Automatikus frissítő, crash backend, fiók, felhőszinkron és többnyelvű lokalizáció.
Ezek hasznos későbbi irányok, de indokolatlan kockázatot és külső függést vinnének
az első stabil kiadásba.

## 4. Termékhatár

### Benne van az 1.0-ban

- tiszta első indítás és könyvtárválasztás;
- v0.x felhasználói állapot biztonságos, egyszeri migrációja;
- opcionális, rövidebb onboarding és később is elérhető részletes beállítás;
- személyes gyári presetek eltávolítása;
- egységes, natív macOS vizuális rendszer az app fő vázán, üres állapotain,
  beállításain és onboardingján;
- központi verzióforrás az app, CLI, riport és csomagolás számára;
- univerzális Apple Silicon + Intel kiadási build;
- Developer ID aláírásra, hardened runtime-ra és notarizálásra kész build/release
  folyamat, egyértelmű hibával hiányzó kiadási hitelesítő adatok esetén;
- ad-hoc helyi fejlesztői build külön, félreérthetetlen csatornaként;
- Névjegy és támogatási diagnosztika, személyes képadatok nélkül;
- új, reszponzív termékweboldal, dokumentáció és adatvédelmi oldal;
- tiszta telepítés, migráció, üres könyvtár és hibás/missing kötet regressziós
  tesztjei;
- 1.0 release note, ellenőrzött DMG és CLI ZIP, helyi telepítés.

### Nem része az 1.0-nak

- felhasználói fiók vagy felhőszinkron;
- kötelező telemetria vagy háttérben futó crash feltöltés;
- automatikus, felhasználói döntés nélküli fájlmozgatás/törlés;
- teljes angol lokalizáció;
- Mac App Store kiadás;
- harmadik fél frissítőkeretrendszere.

## 5. Tiszta első indítás

### 5.1 Gyári állapot

Az `AstroConfig.rootPath` gyári alapértéke üres. Bookmark nélkül az app `.noRoot`
állapotba kerül, és semmilyen útvonalat nem próbál automatikusan megnyitni vagy
létrehozni.

Az első képernyő három világos dolgot mond:

1. az AstroTool helyben dolgozik;
2. a felhasználó választja ki a könyvtárat;
3. a kezdeti beolvasás nem töröl és nem mozgat.

Elsődleges gomb: **Képkönyvtár kiválasztása…**. Másodlagos: **Hogyan rendezzem a
könyvtáram?**. A felhasználó könyvtár nélkül is bezárhatja az appot; nincs hamis
„folytatás” és nincs blokkoló hibaállapot.

### 5.2 Onboarding

Az Apple onboarding elvét követve a kötelező út rövid:

- könyvtár kiválasztása;
- biztonsági/hozzáférési összefoglaló;
- első, explicit beolvasás.

A helyszín, felszerelés, szűrő, minőségi küszöb és célidő részletes kérdései egy
**Személyre szabás most** választással nyithatók meg, minden oldaluk kihagyható,
és később a Beállításokból újraindíthatók. Az onboarding nem tölt be automatikusan
felszerelést vagy szűrőt.

Az explicit preset menü kizárólag semleges szenzorméreteket ajánlhat
(`APS-C 23,5 × 15,6 mm`, `Full frame 36 × 24 mm`) és minden további adatot a
felhasználó nevez el. Márka/modell nincs gyárilag kiválasztva.

### 5.3 Korábbi telepítés migrációja

Az új bundle ID: `io.github.themokx1.AstroTool`.

Első induláskor, ha az új preferenciatartomány még üres, az app egyszer olvassa a
régi `com.zoltanpalotai.astrotool` tartományt. Csak az ismert, biztonságos kulcsokat
másolja: könyvtár-bookmark, legutóbbi könyvtárak, UI-preferenciák és onboarding
verzió. A könyvtárban lévő `.astro_tool` adatbázis/config változatlanul a könyvtár
része marad. A migráció idempotens, nyugtázott és tesztelt.

Friss telepítésnél a régi tartomány hiánya normális, és semmilyen mintaadat nem
keletkezik.

## 6. Felületi irány

### 6.1 Vizuális rendszer

- SF rendszerbetűk, rendszeres Dynamic Type méretek;
- natív material/sidebar háttér, rendszeres selection és accent szín;
- egységes 8/12/16/24 pontos ritmus;
- dashboardon legfeljebb egy erős hangsúly szekciónként;
- szín nem lehet az állapot egyetlen hordozója: ikon + szöveg is kell;
- kártyák csak valódi csoportosításhoz, nem minden szöveg köré;
- táblázatok sűrűek, de olvashatók, a másodlagos mezők halkabbak;
- animáció csak állapotváltást magyaráz, és tiszteletben tartja a Reduce Motiont.

### 6.2 Navigáció és ablak

A meglévő oldalsávos információs architektúra jó és megmarad. A fő ablak:

- kisebb minimális méreten is értelmesen törik;
- a toolbar csak globális műveleteket tartalmaz;
- az aktuális oldal műveletei az oldal fejlécében maradnak;
- visszaállítja a legutóbbi oldalt és ablakállapotot;
- minden fontos művelethez menüparancs és ésszerű billentyűzetes út tartozik.

### 6.3 Üres, hiba- és folyamatállapotok

Minden fő oldal külön kezeli:

- nincs könyvtár;
- még nincs scan;
- nincs releváns adat;
- folyamatban;
- részleges eredmény;
- helyrehozható hiba.

Az üres állapot rövid magyarázatot és pontos következő lépést ad. A hibaüzenet nem
nyers technikai szöveg; tartalmazza a következményt, a felhasználói teendőt és egy
**Részletek másolása** lehetőséget.

### 6.4 Beállítások

A Beállítások külön macOS-ablak marad, áttekinthető kategóriákkal:

- Általános;
- Könyvtár;
- Helyszínek;
- Felszerelések;
- Szűrők;
- Minőség és kalibráció;
- Adatvédelem és támogatás.

Az azonnal alkalmazható beállítások automatikusan mentődnek. A több mezős,
validációt igénylő szerkesztők egyértelmű Mégse/Mentés határt kapnak.

## 7. Adatvédelem és támogatás

Az AstroTool alapból offline és helyi. Egyedüli hálózati funkció az opt-in időjárás,
amelynek bekapcsolásakor a felület megmondja, milyen koordináta hagyja el a gépet.

A támogatási diagnosztika tartalmazhatja:

- app/CLI verzió és build;
- macOS és architektúra;
- konfigurációs kulcsok redaktált összefoglalója;
- legutóbbi műveletek állapota és hibakategóriája;
- adatbázisséma és számlálók.

Nem tartalmazhat FITS/RAW képet, teljes könyvtárlistát, pontos koordinátát, jegyzetet,
API-kulcsot vagy security-scoped bookmark adatot. Export előtt pontos előnézet és
felhasználói mentés szükséges.

## 8. Build, aláírás és kiadás

### 8.1 Egyetlen verzióforrás

A repository egy géppel olvasható verziófájlt használ. Ebből épül:

- `CFBundleShortVersionString`;
- `CFBundleVersion`;
- `astrotool --version`;
- riport footer;
- weboldal aktuális verziója;
- release ellenőrzés.

A release kapu hibázik, ha a tag, release note és verzió eltér.

### 8.2 Kiadási csatornák

`./build.sh` fejlesztői csomagot készít, ad-hoc aláírással, és ezt a kimenetben
egyértelműen jelöli. A publikus release mód külön parancs/flag, amely:

1. universal binárist készít;
2. Developer ID-val, hardened runtime + timestamp opcióval aláír;
3. szigorúan ellenőrzi az app és a beágyazott CLI aláírását;
4. DMG-t készít;
5. `notarytool`-lal beküldi és staplerrel rögzíti a ticketet;
6. Gatekeeperrel ellenőrzi a végterméket;
7. SHA-256 checksumokat és kiadási manifesztet készít.

Kiadási módban a hiányzó tanúsítvány vagy notary credential hard failure. Nem
publikálható „sikeres” 1.0 úgy, hogy valójában csak ad-hoc aláírású.

### 8.3 CI

Pull request/push kapu:

- teljes Swift tesztcsomag;
- release build;
- placeholder- és személyesadat-scan;
- universal architektúra-ellenőrzés;
- tiszta telepítés smoke teszt.

Tag kapu ezek után, csak konfigurált secrets mellett végzi az aláírást,
notarizálást és publikálást.

## 9. Weboldal

Az új oldal terméket mutat be, nem fejlesztési naplót. Szerkezete:

1. kompakt, ragadós navigáció;
2. erős hero: egy mondatos értékígéret, letöltés, rendszerkövetelmény;
3. generikus, szintetikus adatokkal készült app-makett;
4. három fő munkafolyamat: Tervezés → Gyűjtés → Minőség/feldolgozás;
5. biztonsági és helyi adatkezelési blokk;
6. valódi funkciórészletek, kerülve az ismeretlen eredetű marketing-számokat;
7. telepítési út és aktuális kiadási státusz;
8. dokumentáció, adatvédelem, licenc, forrás és támogatás.

A design világos és sötét módot, mobil elrendezést, billentyűzetes navigációt,
látható fókuszt, megfelelő kontrasztot és csökkentett mozgást támogat. Nincs
emoji-ikonrendszer és nincs csillagmező-dekoráció a tartalom rovására; a termékikon,
tipográfia és egyetlen visszafogott égi színátmenet ad identitást.

## 10. Hibakezelés

- fájlrendszeri és adatbázis-hiba nem omolhat össze;
- háttérművelet csak main actoron módosíthat UI-állapotot;
- részleges scan jelölt részleges eredményt ad;
- kötet leválasztása visszatérő, helyreállítható állapot;
- minden destruktívnak tűnő művelet előnézetet, hatókört és visszaállítási
  információt mutat;
- nem ismert fájl- vagy config-verzió biztonságosan elutasítható diagnosztikával.

## 11. Ellenőrzési kritériumok

Az 1.0 csak akkor kész, ha:

1. a teljes tesztcsomag zöld;
2. egy új, üres felhasználói preferenciatartományban nincs személyes útvonal,
   setup, szűrő vagy adat;
3. a régi v0.16 bookmarkkal és könyvtárral a migráció adatvesztés nélkül működik;
4. a fő oldalak üres és normál állapotban is megnyílnak;
5. az app és CLI verziója egyezik;
6. a build arm64 és x86_64 architektúrát tartalmaz;
7. a helyi fejlesztői DMG telepíthető és indul;
8. a publikus release pipeline megfelelő hitelesítő adatok nélkül megáll, velük
   pedig aláírt/notarizált/stapled csomagot állít elő;
9. a weboldal desktopon és keskeny nézetben vizuálisan ellenőrzött;
10. a release note pontosan leírja a migrációt, adatvédelmet, rendszerkövetelményt
    és a telepítést.

## 12. Kockázatok és védőkorlátok

- **Bundle ID csere:** explicit, idempotens preferenciamigráció és régi azonosító
  konstans; nincs régi domain törlés.
- **Universal build:** architektúránkénti build/teszt és `lipo` ellenőrzés; Intel
  futtatás hiányában a korlát release note-ban dokumentált.
- **Notarizálási credential hiány:** a kód és CI elkészülhet, de a nyilvános
  notarizált asset nem állítható elő hitelesítő adat nélkül; ezt a végső kiadás
  nem rejti el.
- **Nagy UI-scope:** nem írjuk újra a bizonyított AstroCore logikát. A változás a
  shellre, első indításra, beállításokra, közös komponensekre és állapotkezelésre
  koncentrál; az oldalspecifikus szakmai funkciók megmaradnak.
- **Saját adatok a weben:** csak generikus/szintetikus tartalom kerülhet committed
  assetbe és HTML-be.

