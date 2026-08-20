# AstroTool 1.0 — kiadás-előkészítési és termék-review

## Cél

Az AstroTool 0.x fejlesztői állapotából olyan 1.0 terméket készíteni, amely
egy tiszta Macen személyes placeholder nélkül indul, más felhasználó számára
is érthető, adatvédelmileg őszinte, visszaállítható munkafolyamatokat használ,
és ellenőrizhető telepítőből adható ki.

## Kockázatok, amelyeket a review feltárt

1. A korábbi alapkonfiguráció fejlesztői külső lemezes root pathot feltételezett.
2. Az első indítás automatikusan részletes varázslót nyitott és konkrét
   felszerelés-/szűrőpéldákat kínált.
3. A beállítások sok, egymással versengő tabon oszlottak meg.
4. Nem volt felhasználó által exportálható, adatvédelmileg korlátozott
   diagnosztika.
5. A build egyben telepített és CLI-szimlinket is átírt.
6. A csomag csak a buildgép architektúrájára készült, notarizáció nélkül.
7. A weboldal fejlesztői projektoldal benyomását keltette, személyes
   könyvtárstatisztikákat és elavult telepítési lépést mutatott.
8. A repository gyökérdokumentációja tartalmazta az eredeti személyes
   fejlesztési promptot és konkrét könyvtár-/felszereléspéldákat.

## Elkészült termékdöntések

- Üres root path, kifejezett könyvtárválasztás és adatmentes welcome.
- A részletes onboarding csak felhasználói kérésre indul; minden oldala
  kihagyható, és nem gyárt automatikus setupot vagy filtert.
- Általános, Könyvtár, Megfigyelés és Segítség csoportosítású natív
  beállítás-oldalsáv.
- Biztonságos diagnosztikai adatmodell, amely nem tud privát könyvtáradatot
  fogadni.
- Külön build, külön visszaállítható install és külön fail-closed public
  release.
- Universal app/CLI, verziózott DMG/ZIP és SHA-256 fájl.
- Új, közös webes designrendszer szintetikus app-előnézettel.
- Publikus README és 1.0 release note konkrét telepítési/upgrade információval.

## Asztrofotós szakmai álláspont

Az 1.0 legnagyobb értéke nem egyetlen mérőszám, hanem az, hogy a sessiont
nem tekinti homogén fájlhalmaznak. Az OSC, dual-band, keskenysáv, eltérő
expozíció vagy setup külön gyűjtésként él, de a session és a célpont teljes
összesítése megmarad. Ez teszi helyessé a capture-szintű FWHM-et,
kalibrációt, stacklistát és riportot.

Az alapbiztonsági irány helyes: előbb felismerés és előnézet, utána döntés,
majd bizonylat és rollback. Az audit nem lehet „takarítóprogram”; a
fájlmozgatás ritka, szűk és explicit kivétel marad.

## Kiadási kapuk

- teljes Swift tesztcsomag;
- tiszta első indítás elkülönített UserDefaults suite-tal;
- production/public placeholder scan;
- Universal architektúra-ellenőrzés;
- plist, kódaláírás, DMG, CLI ZIP és checksum ellenőrzés;
- telepített app indulási smoke;
- nyilvános csomagnál Developer ID és Apple notarizáció.

## Független kiadás-review utáni keményítés

A külön release-review tíz fontos rést talált az első jelöltben; egyik sem
maradt elfogadott adósságként:

- a sikeres első scan eredményoldala a Tovább döntésig a képernyőn marad;
- a régi bundle preferenciái csak üres új domain és külön felhasználói
  jóváhagyás után vehetők át;
- a setup menük kizárólag APS-C/full-frame szenzorméretet ajánlanak, kamera-,
  optika- és f-szám feltételezés nélkül;
- a támogatási export csak a felhasználó által ténylegesen átnézett, rögzített
  pillanatképet másolja vagy menti;
- root nélküli CLI-hívás konkrét `--root /path/to/library` útmutatást ad;
- a CI izolált preferenciával valódi, ideiglenes üres könyvtárat nyit meg,
  megvárja az első-scan felület tényleges megjelenését, és ellenőrzi, hogy
  nem indul automatikus scan vagy személyes mintaállapot;
- a publikus DMG külön Developer ID aláírást, notarizációt, staplinget,
  lemezkép-ellenőrzést és Gatekeeper `open` vizsgálatot kap;
- a tag, a ProductInfo-verzió, a CHANGELOG és a kötelező release note közös
  hard gate;
- a webes app-minta láthatóan fiktív adatot használ;
- minden publikus oldal billentyűzetes skip linket és fókuszolható fő tartalmi
  landmarkot kapott.

## Külső feltétel

A helyi gépen nincs érvényes Developer ID Application identity. Emiatt itt
csak ad-hoc aláírású, helyi telepítés validálható. A publikus release workflow
elő van készítve, de nyilvános/notarizált kiadást csak a repositoryhoz tartozó
Apple és GitHub hitelesítő adatokkal szabad létrehozni.
