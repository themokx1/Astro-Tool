# Capture groups és egy-sessionös konvertáló – jóváhagyott terv

**Dátum:** 2026-08-09  
**Állapot:** jóváhagyott  
**Célverzió:** v0.15.0  
**Referencia:** `/Volumes/images/Astro/sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08`

## 1. Probléma és valós bizonyíték

A jelenlegi modellben egy célpont egy dátumkönyvtára egyetlen homogén sessionként jelenik meg. A valós munkafolyamatban ugyanazon az éjszakán, ugyanarra a célpontra több, egymástól külön kezelendő felvételi csomag készülhet. Ezeknek közös éjszakai összegzésre, de külön forrás-, kalibrációs, minőségi, stackelési, feldolgozási és riport-életciklusra van szükségük.

Az IC 1396 mintasession tényleges tartalma:

- `lights_osc`: 32 darab 30 s-os light, 960 s összintegráció;
- `lights`: 3 darab 120 s-os nyers light és 48 darab 300 s-os FITS; utóbbiak közül 46 `Light_…`, kettő pedig `Stacked2_…`/`Stacked12_…` eredmény, amelyet a jelenlegi frame-szűrés tévesen lightként számolhat;
- a vizsgált FITS-ek kamerája `ZWO ASI2600MC Pro`, Bayer-mintája `RGGB`, ezért a szenzormód OSC-ként felismerhető;
- a light FITS-ekben nincs kitöltött `FILTER`, ezért az SVBONY SV220 használata nem következtethető ki megbízhatóan;
- a mintakönyvtárban a vizsgálat idején nem volt 5 s-os nyers FITS, miközben a felhasználói munkafolyamat ilyen sorozatot is tartalmazott – ezt eltérésként kell láthatóvá tenni, nem szabad adatot kitalálni;
- a stackek és feldolgozott eredmények már kézzel különülnek el `_osc`, `OSC` és `NO FLAT` jelölésekkel;
- a vegyes 120/300 s-os stackfájlnevek egyetlen subhosszt sugallhatnak, miközben a teljes integráció vegyes expozíciókból áll;
- a jelenlegi FWHM- és report-összesítés dátumszinten összemossa a különböző felvételi kontextusokat, és a két sessionbe mentett `Stacked*` eredmény az integrációt is felfelé torzíthatja.

## 2. Célok

1. A hierarchia legyen `célpont → session/éjszaka → felvételi gyűjtés → expozíciós kohorsz → fájl`.
2. Egy sessionnek lehessen több, külön névvel és metaadattal rendelkező gyűjtése.
3. A nyers képek, kalibrációk, stackek, feldolgozások és riportok legyenek gyűjtésenként külön kezelhetők.
4. A teljes session továbbra is legyen egyben összesíthető és riportálható.
5. Az OSC/mono szenzormód és a használt fénysáv/filter legyen két külön fogalom.
6. Egy vagy több fájl gyűjtéshez rendelése és metaadatolása legyen elérhető egyedi és tömeges műveletként.
7. Régi sessionök egyenként, teljes előnézettel, kontrolláltan legyenek az új modellre konvertálhatók.
8. A meglévő könyvtárak konvertálás nélkül is változatlanul használhatók maradjanak.

## 3. Nem célok

- Az alkalmazás nem írja át a nyers FITS-ek fejlécét.
- Nem mozgat fájlokat háttérben vagy automatikus scan közben.
- Nem konvertál egyszerre több sessiont vagy teljes könyvtárat.
- Nem próbál filtert pusztán expozíciós időből biztos tényként kitalálni.
- Nem válik acquisition-vezérlővé vagy teljes preprocessing motorrá.

## 4. Domainmodell

### 4.1. Session

A session továbbra is egy célpont egy dátumkönyvtára. Megőrzi az egész éjszakára vonatkozó idővonalat, összintegrációt, jegyzeteket, időjárási és egészségügyi kontextust.

### 4.2. Felvételi gyűjtés (`CaptureGroup`)

Egy felhasználó által értelmezhető, külön stackelhető és feldolgozható felvételi csomag. Példák:

- `OSC 5 s`;
- `OSC 30 s`;
- `SV220 dual-band`;
- `Hα 300 s`;
- `RGB csillagok`.

Mezői:

- célpont és sessiondátum;
- stabil, útvonalbiztos slug;
- megjelenített név;
- szenzormód: `osc`, `mono`, `unknown`;
- jelmód/fénysáv: `broadband`, `dualBand`, `narrowband`, `lrgb`, `luminance`, `unfiltered`, `other`, `unknown`;
- filter gyártója, modellje és megjelenített neve;
- opcionális jegyzet;
- forrásmappák és azok szerepe;
- létrehozási és módosítási idő.

### 4.3. Expozíciós kohorsz

Nem külön felhasználói mappa, hanem automatikusan képzett minőségi referenciahalmaz. Kulcsa:

`session + capture group + setup + resolved filter + nominal exposure + binning`.

Egy SV220 gyűjtés így tartalmazhat 120 és 300 s-os képeket ugyanazon feldolgozási cél alatt, miközben a két sorozat FWHM- és háttérpontozása nem keveredik.

### 4.4. A szenzor és a filter szétválasztása

Az `OSC` nem a `narrowband` ellentéte. Egy ASI2600MC + SV220 kép:

- szenzormód szerint `OSC`;
- jelmód szerint `dual-band narrowband`;
- konkrét filter szerint például `SVBONY SV220`.

A felület gyors címkéje ezért több tengelyt egyesít: `OSC · dual-band · SV220 · 300 s`.

## 5. Adattárolás és feloldási sorrend

A SQLite séma új, additív táblákat kap:

### `capture_groups`

- `id` elsődleges kulcs;
- `target`, `session_date`, `slug`, `display_name`;
- `sensor_mode`, `signal_mode`;
- `filter_manufacturer`, `filter_model`, `filter_name`;
- `notes`, `created_at`, `updated_at`;
- egyedi kulcs: `(target, session_date, slug)`.

### `capture_sources`

- `capture_group_id`;
- root-relatív mappaprefix;
- szerep: light/flat/dark/bias/stack/processed;
- egy forrásútvonal csak egy gyűjtéshez tartozhat.

Ez teszi lehetővé, hogy a régi `lights_osc` és `lights` mappák fájlmozgatás nélkül is külön gyűjtések legyenek.

### `file_capture_assignments`

- `file_id`;
- `capture_group_id`;
- opcionális szenzor-, jelmód- és filter-felülírás;
- hozzárendelési forrás és időpont.

Ez támogatja az egyedi fájlbesorolást, illetve azt az esetet, amikor egyetlen régi mappában több felvételi csomag keveredik.

### Feloldási precedencia

1. fájlszintű kézi felülírás;
2. gyűjtésszintű metaadat;
3. FITS/EXIF fejléc;
4. mappa- vagy fájlnév-alapú következtetés;
5. `ismeretlen`.

Ha két erős forrás ellentmond – például a FITS `FILTER` és a kézi gyűjtésfilter eltér –, az audit konfliktust jelez. A felület minden értéknél meg tudja mutatni az eredetet: `fejlécből`, `gyűjtésből`, `kézi`, `következtetett`.

## 6. Kanonikus mappastruktúra

Új vagy fizikailag konvertált session esetén:

```text
sessions/<target>/<date>/
  captures/
    <capture-slug>/
      lights/
      flats/
      darks/
      biases/

stacks/<target>/<date>/<capture-slug>/
processed/<target>/<date>/<capture-slug>/
```

A `captures/<slug>` egy külső stackelő eszköz számára is értelmezhető, önálló csomag. Kalibrációs fájlokat nem kötelező duplikálni: a meglévő calibration library és a hardlinkes illesztés gyűjtésszintű célmappát is támogat.

### Visszafelé kompatibilitás

- A régi `sessions/<target>/<date>/{lights,flats,darks,biases}` szerkezet implicit alapértelmezett gyűjtésként működik.
- A `lights_<label>`, `flats_<label>` alakokat a scanner örökölt gyűjtésforrásként felismeri.
- A korábbi sessionstatisztika, CLI és riport működése megmarad, ha nincs explicit gyűjtés.
- Konvertálás nélkül nincs kötelező migráció vagy fájlmozgatás.

## 7. Egy-sessionös konvertáló

### 7.1. Belépési pont és hatókör

A Sessionök nézet egy konkrét sorának menüjében jelenik meg: `Session átalakítása gyűjtésekre…`.

A konvertáló mindig pontosan egy `(target, date)` kulcsra van rögzítve. Nincs „összes konvertálása” gomb, wildcard vagy teljes könyvtárra vonatkozó apply.

### 7.2. Négy lépés

1. **Felmérés:** csak olvas; összegyűjti a mappákat, fájlokat, fejlécadatokat, expozíciós csoportokat, stackeket és processed eredményeket.
2. **Terv:** szerkeszthető gyűjtésjavaslatokat és fájl-hozzárendeléseket készít.
3. **Előnézet:** pontosan megmutatja, mi marad, mi kerül adatbázisba, milyen mappa jön létre és fizikai módban mely fájl honnan hová kerülne.
4. **Alkalmazás:** csak konfliktusmentes terv és külön megerősítés után fut; végül receiptet és visszaállítási tervet készít.

### 7.3. Átlátható előnézeti felület

A képernyő három fő része:

- bal oldalt a jelenlegi sessionfa és fájlszámok;
- középen a felismert mappák, expozíciós klaszterek és bizonytalanságok;
- jobb oldalt a tervezett capture-group fa.

Minden tervsor mutatja:

- a forrásmappát vagy kiválasztási szabályt;
- a fájlok számát és méretét;
- az expozíciókat, kamerát, Bayer/mono állapotot és filterinformációt;
- a célgyűjtést és célmappát;
- a műveletet: `változatlan`, `csak besorolás`, `mappa létrehozása`, `mozgatás`, `kézi döntés kell`;
- az adat eredetét és bizonyosságát.

A felső összegző mondat emberi nyelven is leírja a tervet, például:

> 83 expozíciós FITS-ből 32 az „OSC 30 s”, 49 az „SV220 dual-band” gyűjtésbe kerül. 2 `Stacked*` fájl nem nyers lightként lett felismerve. 41 flat besorolása még nem egyértelmű. Fizikai mozgatás nélkül 2 forrásmappa lesz logikailag hozzárendelve.

Az apply gomb blokkolt, amíg megoldatlan célütközés vagy olyan kétértelmű fájl van, amelyet a terv mozgatna.

### 7.4. Két konvertálási mód

#### Csak besorolás – alapértelmezett

- capture-group rekordokat, mappaforrásokat és fájl-hozzárendeléseket hoz létre;
- a meglévő nyers fájlokat és mappákat nem mozgatja;
- azonnal használhatóvá teszi a külön auditot, minőséget, riportot és stacklistát;
- ez az ajánlott első lépés pótolhatatlan, már feldolgozott sessionnél.

#### Fizikai rendezés

- létrehozza a kanonikus `captures/<slug>/...`, `stacks/.../<slug>` és `processed/.../<slug>` fákat;
- kizárólag az előnézetben felsorolt fájlokat mozgatja;
- minden célütközést még az első mozgatás előtt ellenőriz;
- soha nem ír felül létező fájlt;
- külön, erős megerősítést kér az apply előtt.

### 7.5. Biztonság és visszaállítás

Minden apply előtt a program a saját területére írja:

```text
.astro_tool/conversions/<conversion-id>/plan.json
.astro_tool/conversions/<conversion-id>/rollback.json
```

A fizikai műveletek szabályai:

- kizárólag a kiválasztott target/date session-, stack- és processed-ágain belül dolgozhatnak;
- a célútvonalak validált, feloldott abszolút útvonalai nem hagyhatják el ezeket az ágakat;
- nincs felülírás és nincs törlés;
- hiba esetén az addig végrehajtott lépések fordított sorrendű automatikus rollbackje indul;
- siker után részletes receipt készül;
- kézi `Visszaállítás…` csak akkor engedélyezett, ha a visszaútvonalak még szabadok és a mozgatott fájlok azonosíthatók;
- a rollback sem írhat felül fájlt.

A konvertálás után célzott újrascan frissíti az indexet. A session README-jét a konvertáló nem írja felül.

### 7.6. IC 1396 javasolt előnézete

A mintasessionnél a detektor kezdeti, szerkeszthető javaslata:

- `lights_osc` + 30 s → `OSC 30 s`;
- `lights` + 3×120 s és 46×300 s valódi `Light_*` → egy külön, még `filter ismeretlen` gyűjtés;
- a két `Stacked*` sessionfájlt artifactként mutatja, és külön stack-hozzárendelést kér;
- a felhasználó ezt `SV220 dual-band` névre és SVBONY SV220 filterre állíthatja;
- a 1,7 és 3,8 s-os flatcsoportok külön látszanak, de filter hiányában nem kapnak automatikusan biztos gyűjtést;
- az `OSC` processed mappa és `_osc` stack név csak javaslatot ad, nem bizonyítékot;
- a `NO FLAT` eredmény állapotjelölésként marad látható.

## 8. Egyedi és tömeges besorolás

A Minőség/frame-lista többes kijelölést kap. A `Besorolás…` sheet hatókörei:

- aktuális fájl;
- kijelölt fájlok;
- teljes forrásmappa;
- egy expozíciós kohorsz;
- a session minden, adott feltételnek megfelelő fájlja.

Műveletek:

- gyűjtéshez rendelés;
- szenzormód felülírása;
- jelmód felülírása;
- filter gyártó/modell/név megadása;
- felülírás törlése és visszatérés az örökölt értékhez.

A sheet apply előtt megmutatja az érintett fájlszámot és azt, hogy mely értékek változnak.

## 9. UI-változások

### Sessionök

A session sor lenyitható gyűjtésszintre:

```text
2026-08-08 · 81 light · 4:12
  OSC 30 s        · 32 light · 0:16 · OSC · broadband
  SV220 dual-band · 49 light · 3:56 · OSC · dual-band
```

Sessionműveletek:

- `Gyűjtés hozzáadása…`;
- `Session átalakítása gyűjtésekre…`;
- teljes session riport;
- gyűjtésriport.

### Új session

Az új-session sheet opcionálisan első gyűjtést is létrehoz. Presetek:

- OSC szélessáv;
- OSC dual-band;
- mono narrowband;
- mono LRGB;
- egyedi.

Később további gyűjtés adható ugyanahhoz a dátumhoz anélkül, hogy új sessiondátumot kellene kitalálni.

### Minőség

- session- és gyűjtésszűrő;
- gyűjtés, filter és expozíciós kohorsz oszlop;
- a pontszám referencia-kohorszának mérete és mediánja;
- többes kijelölés és besorolás;
- több gyűjtésnél nincs félrevezető közös FWHM-medián.

### Stackek és feldolgozás

- gyűjtés szerinti csoportosítás és szűrés;
- régi stack/processed fájl kézi vagy tömeges hozzárendelése;
- új stacklista exportja egy gyűjtésre vagy a teljes sessionre;
- gyűjtésspecifikus outputútvonal.

## 10. Minőség, kalibráció és összesítés

### Pontozás

A z-score csoportkulcs kibővül capture group, feloldott filter, setup és binning dimenzióval. Az OutlierBreakdown ugyanazt a kulcsot használja, ezért a pontszám és annak magyarázata nem térhet el.

### Kalibráció

A flat-illesztés a feloldott filtert és capture group kontextust használja. A session-szintű vagy calibration-library master továbbra is megosztható, ha minden kompatibilitási feltétel teljesül.

### Sessionösszesítés

- frame- és integrációs összegek gyűjtésenként és sessionösszesen;
- expozíciós bontás minden gyűjtés alatt;
- filterbontás a feloldott, kézzel megadható filter alapján;
- minőségi összegzés gyűjtésenként;
- több heterogén csoportból nem képződik hamis, egyetlen session-FWHM.

## 11. Audit

Új finding-kategóriák:

- besorolatlan session-light;
- örökölt `lights_<label>` vagy hasonló mappa;
- NB/dual-band gyűjtés konkrét filter nélkül;
- ellentmondó FITS- és kézi filteradat;
- heterogén setup egy gyűjtésben;
- gyűjtésen kívüli stack vagy processed eredmény;
- félrevezető vegyes-expozíciós stacknév;
- leírt és tényleges expozíciók eltérése, ha van strukturált terv/jegyzet;
- bizonytalan flat-hozzárendelés.

A findingek magyarázóak és javítási útvonalat adnak. Automatikus fájlmozgatást audit nem indít.

## 12. Riportok

Az éjszakai HTML-riport felépítése:

1. teljes sessionösszegzés;
2. gyűjtésenkénti integráció és expozíció;
3. gyűjtésenkénti minőség és outlierarány;
4. gyűjtésenkénti kalibrációs lefedettség;
5. kapcsolódó stackek és processed eredmények;
6. besorolási hiányok és auditfigyelmeztetések.

Külön gyűjtésriport is generálható. A teljes és részriportok egymásra hivatkoznak.

## 13. CLI és automatizálhatóság

Az alkalmazásfelület mellett a core funkciók CLI-n és JSON-ban is elérhetők:

- `astrotool captures list --target ... --date ...`;
- `astrotool captures create ...`;
- `astrotool captures assign ...`;
- `astrotool convert-session plan --target ... --date ...`;
- `astrotool convert-session apply --plan ...`;
- `astrotool convert-session rollback --conversion ...`.

Az apply csak korábban létrehozott, változatlan forrásállapotra érvényes tervet fogadhat el. A CLI sem kínál teljes könyvtáras konvertálást.

## 14. Tesztelési és elfogadási kritériumok

1. A régi, capture group nélküli fixture-k minden meglévő tesztje változatlanul átmegy.
2. A PathClassifier felismeri a kanonikus és örökölt gyűjtésútvonalakat.
3. Az adatbázis v10-ről veszteség nélkül migrál az új sémára.
4. Egy fájl és több fájl hozzárendelése, felülírása és törlése körbejárható tesztekkel.
5. A minőségi pontozás nem kever két capture groupot azonos session/expozíció esetén sem.
6. A report sessionösszege megegyezik a gyűjtésösszegek összegével.
7. A konverter planner tiszta, fájlrendszert nem író függvényként tesztelhető.
8. Az előnézet minden move-hoz pontos forrás- és célútvonalat ad.
9. Egyetlen célütközés blokkolja a fizikai apply-t még az első move előtt.
10. Középen szimulált hiba esetén az automatikus rollback visszaállítja a kiinduló fákat.
11. A konverter nem érhet más targethez vagy dátumhoz.
12. A logikai konvertálás egyetlen nyers fájlt sem módosít vagy mozgat.
13. Az IC 1396 fixture 30 s-os OSC és 120/300 s-os második gyűjtése külön jelenik meg; az SV220 csak kézi megadás után lesz tényként riportálva, a két `Stacked*` eredmény pedig nem számít nyers lightnak.
14. A teljes `swift test` és a release build sikeres.

## 15. Kiadás

A funkció külön `codex/capture-groups` ágon készül. A verifikált eredmény `v0.15.0` kiadásként kap release note-ot, GitHub release asseteket, majd a gépre telepített AstroTool.app is erre a verzióra frissül.
