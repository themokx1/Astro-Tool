# AstroTool V5 — iPhone companion és közeli szinkron

**Dátum:** 2026-08-23  
**Célverzió:** AstroTool V5 prototípus  
**Állapot:** elfogadott termékirány alapján elkészített, felülvizsgálatra kész specifikáció

## 1. Termékcél

A V5 az AstroTool könyvtárának tudását viszi ki a terepre anélkül, hogy az
eredeti asztrofotós képarchívumot telefonra vagy felhőbe másolná. A Mac marad a
könyvtár elsődleges gazdája. Az iPhone egy gyors, offline használható terepi
társalkalmazás: megmutatja a projekteket és az esti tervet, kezeli a briefing
checklistáját és jegyzeteit, majd ezeket a szűk körű változásokat visszaadja a
Macnek.

Az egyetlen termékígéret:

> Az estéd terve és a szükséges tudás veled jön az iPhone-ra; a teljes
> képarchívumod biztonságban a Macen vagy a külső lemezen marad.

A prototípusnak fizetős Apple Developer Program és CloudKit nélkül, a
felhasználó saját iPhone-ján is kipróbálhatónak kell lennie.

## 2. Sikerkritérium

Egy nem műszaki felhasználó legfeljebb három perc alatt képes:

1. megnyitni az AstroToolt a Macen és az iPhone-on;
2. a Macen megnyomni az **iPhone szinkronizálása** gombot;
3. első alkalommal egy rövid párosító kóddal összekapcsolni a két eszközt;
4. emberi nyelvű előnézetben ellenőrizni, mi kerül át és mi biztosan nem;
5. az iPhone-on internet nélkül megnyitni az esti briefinget;
6. checklistát pipálni és jegyzetet írni;
7. a következő szinkronnál ezeket előnézet után visszavezetni a Macre.

Ha a közvetlen kapcsolat nem használható, ugyanaz az adat egy AirDroppal
elküldhető AstroTool mobilcsomagban átadható.

## 3. Nem alku tárgya: adat- és fájlbiztonság

1. Eredeti FITS, RAW, TIFF, JPEG, PNG vagy más felhasználói képfájl nem része a
   mobil snapshotnak.
2. A telefon nem kap könyvtárútvonalat, biztonsági könyvjelzőt, tetszőleges
   FITS-fejlécet vagy közvetlen fájlazonosítót.
3. Az iPhone nem indíthat másolást, mozgatást, átnevezést vagy törlést a Mac
   könyvtárában.
4. Az iPhone-ról csak checklist-állapot és felhasználói jegyzet térhet vissza.
5. A Mac minden visszatérő változást tételesen megmutat, mielőtt alkalmazná.
6. Szinkronizálás soha nem kapcsolja be vagy kerüli meg a Mac írási módját.
7. Automatikus felülírás nincs. Párhuzamos szerkesztéskor konfliktusnézet
   jelenik meg, és mindkét változat megmarad a döntésig.
8. Minden átadás verziózott manifestet, elemszámokat, bájtméretet és SHA-256
   ellenőrzőösszegeket tartalmaz.
9. Ismeretlen vagy újabb csomagséma nem importálható részlegesen.
10. A sikertelen vagy megszakított átvitel nem módosíthatja az utolsó érvényes
    mobil snapshotot.

## 4. A felhasználói folyamat

### 4.1 Első párosítás

Macen a Beállítások új **iPhone** része és a Briefing exportfelülete egyaránt
elérhetővé teszi az **iPhone szinkronizálása** műveletet. A Mac rövid időre
láthatóvá válik a közelben.

Az iPhone nyitóképernyője három emberi állapotot kezel:

- **Kapcsolódás a Macemhez** — első használat;
- **Legutóbbi estém megnyitása** — már van helyi snapshot;
- **Csomag fogadása AirDroppal** — közvetlen kapcsolat nélküli tartalék.

A két eszköz ugyanazt a hatjegyű, egyszer használatos párosító kódot mutatja.
Mindkét oldalon jóvá kell hagyni. A képernyő előre elmondja, hogy a helyi
hálózati engedély kizárólag a két AstroTool alkalmazás közötti közeli
adatátadásra szolgál.

### 4.2 Szinkron-előnézet

A Mac a küldés előtt összefoglalja:

- projektek, éjszakák, capture-ök és briefingek száma;
- felszerelések és helyszínek száma;
- checklisták és jegyzetek száma;
- opcionális előnézeti képek száma és teljes mérete;
- iPhone-ról visszaérkező módosítások száma;
- utolsó sikeres szinkron ideje;
- állandó biztonsági mondat: **„Eredeti fotó nem kerül át. Az iPhone nem tud
  fájlt módosítani a képkönyvtárban.”**

A felhasználó az előnézeti képeket külön kapcsolóval engedélyezi. A strukturált
adatok és a briefing akkor is átadhatók, ha az előnézetek ki vannak kapcsolva.

### 4.3 Átvitel és eredmény

A folyamat állapotai hétköznapiak: **Mac keresése**, **Biztonságos kapcsolat**,
**Adatok előkészítése**, **Átvitel**, **Ellenőrzés**, **Kész**. Megszakításkor
nem állít sikert, és egyetlen **Újrapróbálás** műveletet ajánl.

Az eredmény pontosan megmutatja, mi frissült. A telefon helyi tartalma csak a
teljes csomag ellenőrzése után, atomikusan vált az új snapshotra.

### 4.4 Következő szinkron és visszirány

Az iPhone minden szerkesztést új, append-only változásként tárol. A következő
kapcsolódáskor a Mac előbb lekéri ezeket, összeveti azzal a revisionnel,
amelyből készültek, majd tételes előnézetet ad:

- „7 checklist-elem állapota megváltozott”;
- „2 terepi jegyzet érkezett”;
- „1 jegyzetet időközben a Macen is szerkesztettek — döntés szükséges”.

A jóváhagyott változások a Mac meglévő, engedélyezett alkalmazási parancsain
keresztül kerülnek be. A mobil szinkronréteg közvetlenül nem ír adatbázist és
nem használ `FileManager`-írást.

## 5. iPhone-alkalmazás

Az első prototípus négy fő lapot tartalmaz:

1. **Ma este** — a következő vagy legutóbbi briefing, készenléti állapot,
   idővonal és nagy, kesztyűben is használható checklist.
2. **Projektek** — célpontok, összegyűjtött és tervezett integráció,
   capture-összefoglalók és opcionális reprezentatív előnézet.
3. **Briefingek** — a Macen elkészített dokumentumok mobil, natív nézete;
   nem PDF-képernyőként, hanem jól olvasható szakaszokként.
4. **Szinkron** — párosított Mac, utolsó frissítés, csomag tartalma,
   tárhelyhasználat, közvetlen kapcsolat és AirDrop-import.

Az alkalmazás nem tartalmaz Finder-szerű fájlböngészőt, minőségértékelő
munkaállomást, képmozgatást, könyvtárjavítást vagy törlést. Ha a mobil adat
régi, minden releváns képernyő láthatóan, de nem riasztóan jelzi az utolsó
szinkron idejét.

## 6. Hordozható adatmodell

### 6.1 Stabil könyvtárazonosító

A meglévő `LibraryIdentity` a Mac lokális gyökérútvonalához kötődik, ezért nem
kerülhet mobilcsomagba. A V5 új `PortableLibraryID` UUID-t vezet be, amelyet a
könyvtár manifestje tartósan őriz. Meglévő könyvtár első mobil
szinkronizálásakor a Mac előnézet után kizárólag ezt az új azonosítót hozza
létre. A művelet új, szűk `WriteGuard.createPortableLibraryIdentity()`
belépési ponton fut, nem mozgat fájlt és nem ír felül korábbi tartalmat.

### 6.2 `MobileLibrarySnapshot`

Változtathatatlan, `Codable` gyökérmodell:

- schema version és készítő alkalmazásverzió;
- `PortableLibraryID`, snapshot ID, revision és létrehozási idő;
- projektek, éjszakák és capture-összefoglalók stabil domainazonosítókkal;
- felszerelésprofilok és a briefinghez szükséges helyszínadatok;
- integrációs és minőségi összesítések;
- briefing draftok és kiszámított mobil dokumentumok;
- checklist-elemek stabil azonosítóval és alaprevisionnel;
- jegyzetek stabil azonosítóval és alaprevisionnel;
- opcionális `MobilePreviewDescriptor` elemek;
- kizárási nyilatkozat és a snapshot részletes manifestje.

A modell kifejezett mezőlistából épül. Nem serializálhat közvetlenül meglévő
adatbázissort, teljes `LibrarySnapshot` objektumot vagy tetszőleges
szótárpayloadot. Ez teszi tesztelhetővé, hogy tiltott adat nem kerülhet bele.

### 6.3 Mobil változások

Kizárólag két parancstípus létezik:

- `ChecklistCompletionChange`
- `NoteRevisionChange`

Mindkettő tartalmaz change ID-t, eszköz ID-t, alaprevisiont, létrehozási időt
és az új értéket. Nincs általános CRUD-parancs, fájlművelet vagy törlési
jelző. A Mac idempotensen alkalmazza őket: ugyanaz a change ID másodszor nem
okoz új műveletet.

### 6.4 Előnézeti képek

Az opcionális előnézet kizárólag a Mac által külön létrehozott, legfeljebb
1600 képpont hosszabb oldalú, kijelzőre szánt JPEG lehet. Nem tartalmazhat
eredeti fájlnevet, elérési utat vagy FITS-fejlécet. A snapshot teljes
előnézeti méretét a felhasználó még a küldés előtt látja.

Az első prototípus csak már létező reprezentatív kép biztonságos renderéből
készít előnézetet. Ismeretlen vagy nem renderelhető formátumot kihagy, nem
próbálja az eredeti fájlt becsomagolni.

## 7. Architektúra

### 7.1 Célpontok és modulhatárok

Új, iOS-en és macOS-en is forduló Swift package targetek:

- `AstroMobileDomain` — snapshot-, change-, manifest- és protokollmodellek;
- `AstroMobileTransport` — titkosítás, keretezés, Network/Bonjour és csomag I/O;
- `AstroMobileUI` — megosztható, platformsemleges mobil komponensek, ahol ez
  valóban egyszerűsíti a kódot.

Az új `AstroToolMobile` iOS alkalmazás ezekre épül. Nem függ a macOS-only
`AstroUI` targettől, WebKittől, PDFKittől vagy a teljes könyvtárszkennertől.
Az iOS targetet az XcodeGen `project.yml` írja le, saját app- és UI-teszt
targettel.

A Mac oldalon új, szűk adapterek készülnek:

- `MobileSnapshotComposer` — meglévő queryk eredményéből hordozható modellt
  készít;
- `MobileChangeImporter` — validálja, előnézi, majd a meglévő parancsokon át
  alkalmazza az engedélyezett változásokat;
- `NearbySyncCoordinator` — a felhasználói folyamatot és transportot köti össze;
- `MobilePackageService` — ugyanazt a protokollpayloadot írja és olvassa
  AirDrop-dokumentumként.

### 7.2 Közvetlen kapcsolat

Új kód nem használja a 2026-ban elavulttá tett Multipeer Connectivity
keretrendszert. A kapcsolat a Network frameworkre épül:

- `NWListener` publikál egy rögzített AstroTool Bonjour szolgáltatást;
- `NWBrowser` csak ezt az egy szolgáltatást keresi;
- a paraméterek engedélyezik az Apple peer-to-peer Wi-Fi kapcsolatot;
- az iPhone és a Mac `Info.plist` fájlja pontos helyi hálózati magyarázatot és
  a konkrét Bonjour szolgáltatást deklarálja;
- nincs általános hálózatszkennelés, multicast vagy saját háttérdaemon.

A prototípus alatt mindkét alkalmazásnak elöl és nyitva kell lennie. Nincs
háttérszinkronra utaló ígéret.

### 7.3 Párosítás, titkosítás és hitelesítés

Az első kapcsolat tartós eszközazonosító kulcsot és ephemeral Curve25519
kulcscserét használ. A két eszköz a teljes párosítási transcriptből
származtatott, hatjegyű rövid hitelesítő kódot mutat. Csak a két oldali
jóváhagyás után mentik egymás nyilvános eszközkulcsát a helyi Keychainbe. A
későbbi sessionök ephemeral kulcsait a tartós eszközkulcs hitelesíti, így egy
korábban ismeretlen gép nem adhatja ki magát a párosított Macnek vagy iPhone-nak.

Minden további üzenet CryptoKit által hitelesített titkosítást kap, egyedi
nonce-szal és sessionazonosítóval. A fogadó a manifest hashét és minden asset
SHA-256 értékét ellenőrzi. Ismeretlen páros, rossz kód, ismételt üzenet,
lejárt session vagy hash-eltérés esetén nincs részleges import.

A protokoll verziózott, hosszmezős üzenetkereteket használ. A vezérlőüzenetek
és a snapshot byte-folyama ugyanazon, hitelesített session részei; tetszőleges
bejövő fájlútvonal nem értelmezhető.

### 7.4 AirDrop mobilcsomag

Az `io.github.themokx1.astrotool.mobile-snapshot` egyedi dokumentumtípus
`com.apple.package` és `public.content` konformitással rendelkezik, így Finder,
Files és AirDrop kezelni tudja. Javasolt kiterjesztése `.astromobile`.

A package nyilvános része csak a formátumverziót, a titkosított payload méretét,
egy véletlen csomagazonosítót és a ciphertext hashét tartalmazza. A snapshot,
változások és előnézetek egyetlen hitelesítetten titkosított payloadban vannak.
Párosított iPhone esetén a Mac a csomagkulcsot a telefon mentett nyilvános
kulcsára csomagolja. Első, még párosítatlan AirDrop-importnál a Mac egy nagy
entrópiájú, egyszer használatos kulcsot QR-kódként mutat, amelyet az iPhone a
csomag fogadása után beolvas. Rövid, offline törhető PIN nem szolgál
csomagtitkosításra.

A package logikai tartalma:

```text
Mobile Library.astromobile/
  manifest.json
  encrypted-payload.bin
```

Az iPhone saját dokumentumtípusként megnyitja, hitelesíti, ideiglenes staging
területre fejti, majd importelőnézetet mutat. A Mac ugyanilyen csomagból vissza
tudja fogadni a mobil változásokat. Az AirDrop nem csendes automatikus szinkron,
hanem érthető, kézi tartalékút. Az import után a fogadott dokumentum esetleges
Files-példányának kezeléséről a rendszer és a felhasználó dönt; az AstroTool
nem töröl önállóan külső dokumentumot.

### 7.5 Későbbi CloudKit

A domainréteg nem ismeri a Network frameworköt, AirDropot vagy CloudKitet. A
`MobileSyncTransport` interfész snapshot- és change-envelope-okat küld és
fogad. A V5 prototípus két adaptere a Nearby és Package transport. Később egy
CloudKit adapter ugyanazokat a stabil rekordokat használhatja adatmodell- és
UI-újraírás nélkül.

## 8. Konfliktuskezelés

Checklist-változás automatikusan csak akkor alkalmazható, ha a Mac aktuális
elemrevisionje megegyezik a mobil változás alaprevisionjével. Eltéréskor a Mac
mindkét állapotot megmutatja.

Jegyzet automatikusan csak azonos alaprevision esetén frissíthető. Ha közben a
Macen is változott, három lehetőség van:

- Mac változat megtartása;
- iPhone változat használata;
- mindkettő megtartása új, időbélyegzett terepi jegyzetként.

Az alapértelmezett és ajánlott választás a **mindkettő megtartása**. A mobil
import soha nem töröl jegyzetet és nem értelmezi az üres szöveget törlésként.

## 9. Offline és hibakezelés

- Az iPhone az utolsó érvényes snapshotból teljesen offline működik.
- Félbeszakadt fogadás staging területre kerül, és nem váltja le az aktív adatot.
- Ismételt sync ugyanazzal a snapshot- vagy change ID-val idempotens.
- Nincs szabad hely esetén az app előre jelzi a szükséges és elérhető méretet.
- Hálózati engedély elutasításakor közvetlenül a Beállítások megfelelő részéhez
  vezet, és felajánlja az AirDrop-csomagot.
- A Mac leválasztott könyvtárnál nem készít régi állapotot frissként feltüntető
  snapshotot; megmutatja az utolsó ismert állapot idejét.
- Sérült vagy manipulált csomag nem nyitható meg részlegesen.
- Újabb séma esetén az alkalmazás frissítést kér, de a meglévő mobil adatot nem
  veszti el.

## 10. Vizuális és szövegezési irány

- Natív SwiftUI, iPhone-on tab bar és nagy, egyértelmű terepi műveletek.
- Képernyőnként egy elsődleges döntés; technikai hálózati kifejezés csak
  lenyitható segítségben.
- A párosítás, előnézet és eredmény nem használ fejlesztői terminológiát.
- A biztonsági állítások konkrétak: mit viszünk át, mit nem, és mi változhat.
- VoiceOver, Dynamic Type, teljes billentyűzet-hozzáférés Macen, megfelelő
  kontraszt és Reduce Motion támogatás kötelező.
- Magyar és angol lokalizáció együtt készül; felhasználói szöveg nem maradhat
  kódba rejtett lokalizációs kulcs nélkül.

## 11. Ingyenes prototípus határa

A saját iPhone-ra az app ingyenes Apple Accounttal, Xcode Personal Teamként
telepíthető. A provisioning hét nap után lejárhat, ezért a prototípust újra
kell telepíteni. Ez a fejlesztési próbát nem akadályozza, de nem tekinthető
felhasználói terjesztésnek.

A prototípus nem tartalmaz:

- CloudKit- vagy iCloud-szinkront;
- TestFlightot vagy App Store-terjesztést;
- háttérben, nyitott alkalmazások nélkül futó szinkront;
- Apple Watch alkalmazást;
- eredeti vagy teljes felbontású fotók átvitelét;
- iPhone-ról indítható könyvtári fájlműveletet.

## 12. Ellenőrzési stratégia

### 12.1 Automatizált

- Snapshot whitelist tesztek: tiltott típus, útvonal, fájlnév, FITS-header és
  eredeti képbyte nem serializálható.
- Stabil schema- és round-trip tesztek régi fixture-ökkel.
- Manifest és asset SHA-256 egyezés, manipuláció és hiányzó asset.
- CryptoKit kulcscsere, rövid kód, titkosítás, nonce-újrahasználat és
  tamper-detection tesztek.
- Sync állapotgép: párosítás, visszautasítás, megszakítás, újrapróbálás,
  duplikált snapshot és idempotens change import.
- Checklist- és jegyzetkonfliktus minden ága.
- AirDrop package export/import és ismeretlen séma.
- Preview méret-, formátum- és metadata-korlát.
- Mac oldali negatív teszt: mobil import nem érheti el a fájlmutációs API-kat.
- iPhone store: atomikus snapshotcsere, offline újranyitás és change queue.
- Magyar/angol lokalizáció, accessibility identifier és Dynamic Type felület.
- macOS és iOS build, Mac unit/UI tesztek, iOS unit/UI tesztek.

### 12.2 Integrációs és fizikai készülékes próba

- localhost/in-memory transporttal determinisztikus protokollteszt;
- két alkalmazás közötti Bonjour-felderítés közös Wi-Fi-n;
- Apple peer-to-peer Wi-Fi próba hálózat nélkül;
- első helyi hálózati engedélykérés és tiltás utáni helyreállítás;
- 100 MB feletti, sok előnézetes megszakított és újraindított átvitel;
- AirDrop oda-vissza dokumentumimport;
- saját iPhone-on offline briefing, checklist és jegyzet;
- visszaszinkron után a forráskönyvtár teljes fájlmanifestje bitazonos marad.

## 13. Kiadási kapuk

A V5 prototípus akkor kész saját készülékes kipróbálásra, ha:

1. a teljes meglévő macOS tesztcsomag zöld;
2. mindkét alkalmazás buildel és elindul;
3. a közvetlen sync és az AirDrop fallback működik;
4. a korlátozott kétirányú checklist/jegyzet körút bizonyított;
5. a tiltott adatokat és fájlműveleteket negatív tesztek zárják ki;
6. a tiszta iPhone-telepítési út dokumentált;
7. a Mac könyvtár teljes fájlmanifestje a fizikai készülékes próba előtt és
   után azonos;
8. az alkalmazás mindenütt egyértelműen jelzi, hogy ez helyi prototípus, nem
   háttérben működő felhőszinkron.

Nyilvános TestFlight- vagy App Store-kiadás csak későbbi Apple Developer
Program-tagsággal és külön kiadási ellenőrzéssel történhet.

## 14. Megvalósítási sorrend

1. Hordozható domainmodell, csomagmanifest és biztonsági negatív tesztek.
2. Mac snapshot composer és AirDrop package export/import.
3. iOS target, helyi store és a négy alapképernyő fixture-adatokkal.
4. Korlátozott mobil change queue és Mac importelőnézet.
5. Network framework transport, párosítás és titkosítás.
6. Közvetlen sync UI és hibakezelés.
7. Opcionális, korlátozott előnézet-generálás.
8. Teljes automatizált és fizikai készülékes validáció.

Ez a sorrend korán ad valódi, AirDroppal kipróbálható iPhone-alkalmazást, és
csak ezután teszi hozzá a bonyolultabb közeli automatikus kapcsolatot.
