# Astro-Tool — asztrofotós szakértői review (4. kör)

**Dátum:** 2026-08-03
**Jelleg:** szakértői termék-review, valós DB-n ellenőrzött adatokkal

---

Elolvastam a repót és — mivel a kötet csatolva van — **read-only lekérdezésekkel a valós DB-t is** (`/Volumes/images/Astro/.astro_tool/astrotool.sqlite`, 14 675 fájl / 11 720 fits_meta), hogy a javaslatok ne elméletiek legyenek. Semmit nem írtam és nem módosítottam.

---

# A) Először: ami MOST hibás vagy félrevezető (domain szempontból)

Ezek nem stílus-kérdések — mérhetően rossz számokat mutat az app.

## A1. Az integrációs idő ~30%-kal inflált (VERIFIKÁLT)

A `sessions/<T>/<D>/lights/` alatt a LightFrameRater triázs-mappái (`Reject/<indok>/`, `Review/`, `Stack/`) **hardlinkek ugyanarra a keretre** (ellenőriztem: `ls -li` link count = 2, ugyanaz a fájlnév és DATE-OBS 5-9 példányban), és a Canon-oldalon a CR3 mellé ott van ugyanannak a keretnek a TIF konverziója is. A `StatsQueries` mindegyiket önálló lightként számolja:

| | érték |
|---|---|
| jelenlegi (bruttó) integráció, session lightok | **42,55 h** |
| dedup (target, session_date, DATE-OBS) szerint | **29,77 h** |
| eltérés | **−12,8 h (−30%)** |

Konkrét példa: `sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/…_0048.fit` ugyanaz a keret 6×, mert 5 `Reject/<indok>/` almappában is ott van hardlinkként. A `NGC2237` 11,67 h-ja emiatt fantázia.

Ráadásul a **`Reject/` alatti keretek** (a felhasználó által SAJÁT kézzel eldobott 74 keret) is beleszámítanak a "megvan" integrációba — pedig épp az a lényeg, hogy nem használhatók.

## A2. A `lightCount` több mint 1000 nem-keret fájlt tartalmaz

A `PathClassifier` a `lights/` alatt MINDENT `role = .light`-ra állít. A valóság:

```
cr3 1297 | fit 967 | tif 710 || png 396 | txt 351 | xmp 295 | (ext nélkül) 24 | html 2 | csv 2 | dssfilelist 2 | ssf 1 | json 1
```

Tehát a 4048 "light" közül **~1073 egyáltalán nem keret** (Siril `.ssf`, Lightroom `.xmp`, riport `.png`/`.html`, jegyzet `.txt`). A Statisztika fül "Keretek" oszlopa ennyivel hazudik.

Plusz: a `lights/`-ban ülő **feldolgozott származékok** is lightnak számítanak (`VeraLux_StarComposer_result.fit`, `starless_…_process_strechy_overstreched.fit`, `starmask_…`) — ezeknél a `FILTER` értéke szó szerint `Starless`/`StarMask`, ami be is szivárog a Statisztika "szűrő" listájába.

## A3. A `_hibas` session beszámít a totálba

`sessions/M42_Orion_wide_field/2026-03-15_hibas` — a `SessionDateParser` szépen felismeri `.labeled`-ként, az audit „valószínűleg szándékos"-ra teszi, **de a `StatsQueries` ugyanúgy hozzáadja az integrációhoz**. Egy „hibás"-nak jelölt éjszakát nem szabad a „mennyi van meg" számba tenni; külön sorban, áthúzva vagy `excludeLabelsFromStats` config-listával kell kezelni.

## A4. Az expozíció-bucketek szétesnek a Canon-nál

`exposureBreakdown` kulcsa `exptime.description`, így a valós adatban egymás mellett áll `30.0` (822 db) és `29.899999618523` (91 db), illetve `120.0` / `119.900001525995`, `360.0` / `359.700012207031`. Ugyanez a `Rater` 0,1 s-re kerekítő `ExposureGroupKey`-ét is szétvágja: a 29,9 s-os keretek **külön, pár elemű z-score csoportba** kerülnek, ahol az `std ≈ 0` → minden z = 0 → a pontszám értelmetlen. Kell egy „nominális expozíció" fogalom (relatív 1-2% tolerancia, vagy 0,5 s-re kerekítés DSLR-nél).

## A5. A z-score összehasonlítási egysége túl széles

Az „azonos expozíciós idő" a LightFrameRater-ből átvett helyes *minimum*, de az `astrotool rate --target M42_Orion` (dátum nélkül) **több éjszakát egy poolba dob**. Asztrofotósként ez rossz: a háttér és az FWHM éjszakák között a Holdtól, tranzparenciától, seeingtől 2-3×-ot is változik, tehát egy remek éjszaka keretei „outlier"-nek tűnhetnek egy rossz éjszaka mellett — és viszont, egy pocsék éjszaka minden kerete „átlagos" lesz, mert egymáshoz mérjük. **Helyes egység: (session_date, nominális exptime, filter, focallen/setup)** — a setup azért, mert a 302 mm-es ASI2600 és a 70 mm-es Canon FWHM-je pixelben nem összemérhető.

Két további rate-részlet:
- `SirilCLI.parseFindstarOutput` **`roundness` default 0.5**-öt ír a DB-be, ha a log nem tartalmazza. Ez kitalált adat, ami bekerül a z-score átlagba/szórásba, és mindenki felé húzza a „kerekség" statisztikát. Helyes: `nil` (a `Rater` már renormalizálja a súlyokat a hiányzó metrikákra).
- `roundness` egyébként gyengébb guiding-proxy, mint az **eccentricitás/elongáció**; a Siril `findstar` ki tudja adni, érdemes arra váltani/kiegészíteni.

## A6. Dark-öregedés: 6 hónap default + `mtime` alapú kor — mindkettő gyenge

- **6 hónap túl agresszív** egy hűtött, IMX571-es ASI2600MC Pro-hoz. Set-point hűtött CMOS masterdarkja tipikusan **1+ évig** használható, ha a gain/offset/hőfok és a firmware nem változott; a valódi érvénytelenítő ok nem az idő, hanem a **gain/offset/hőmérséklet/firmware váltás**. Javaslat: default `darkMaxAgeMonths: 12`, és a kor csak *figyelmeztetés* legyen, ne az elsődleges „elavult" kritérium.
- A kor **`mtime`-ból** jön (`CalibAnalyzer.dayCount(from: newestMtime)`). Egy `rsync`/másolás/kötetváltás után az összes régi dark „mai" lesz. A DB-ben ott van a `DATE-OBS` (ellenőriztem: minden calib dark fájlnál kitöltött) — **`DATE-OBS` elsődleges, `mtime` csak fallback**.

## A7. A kalibráció-illesztés nem nézi a gain/offset/binning/kamerát

`CalibAnalyzer` kulcsa `(exposure, temp)`, a mesterek jellemzése pedig a **mappanévből** (`<exp>sec_<temp>deg`) jön. A valós dark fájlnév maga is mondja, amit a mappanév elhallgat: `Dark_4deg_120.0s_Bin1_2600MC_gain100_…_-20.1C_0001.fit`. Az ASI2600 gain 0 és gain 100 dark-szintje/amp-glow-ja teljesen más — egy gain-eltérésű dark **rontja** a képet, nem javítja. Ma ez csendben átmegy. Ugyanez az offsetre (bias-szint!) és a binningre. A `link-calib` ugyanezt a matchert használja, tehát **hibás mastert linkelhet be** a session `darks/`-jába.

Mellékesen: a `tempToleranceC: 0.5` a CMOS set-point stabilitása mellett indokolatlanul szigorú (a valós fájlokban −20,1 / −19,9 °C CCD-TEMP ugyanabban a `-20deg` mappában); a dark current ~5-6 °C-onként duplázódik, tehát **±1 °C teljesen biztonságos**. Az `exposureToleranceS: 0` a hűtött oldalon helyes, de a DSLR 29,9 s miatt ott mindig hibázik → relatív tolerancia kell.

## A8. Flat/bias lefedettség egyáltalán nincs — és a flat a legfontosabb

`calibration_library/flats/` a valóságban **üres**, és ott van a régóta jelzett `bias` ↔ `biases` páros is. A `CalibAnalyzer` dokumentáltan „v1: csak darks", azzal az érveléssel, hogy a flatoknak nincs exp/temp mátrixa. Ez igaz, de **a flatnak van értelmes kulcsa**: (optika/gyújtótáv, **rotátorállás**, kamera, szűrő, dátum-közelség). A flat nem cserélhető session között, ha közben a rotátor elfordult vagy por került a szenzorra — ez OSC deep-sky-nál a #1 minőségi tétel. A `SessionMatcher` `missing-flats` findingje jó kezdet, de nem nézi, hogy a *létező* flat egyáltalán illik-e a lightokhoz.

## A9. Wide-field besorolás célpont-szinten dől el

`WideFieldHeuristic` a célpontra aggregál, holott a valós könyvtárban ugyanahhoz a témához van 302 mm-es deep-sky ÉS 70 mm-es wide session is (az `M42_*` négyes család pont ezért négy mappa). **A besorolás session-szinten (sőt setup-szinten) értelmes**, a célpont-szintű flag pedig ebből származtatott „mixed" állapotot is felvehet.

---

# B) Javasolt funkciók, prioritás szerint

Fontos, amit a kód-olvasás során találtam: **a `fits_meta.header_json` a TELJES FITS headert eltárolja** minden beolvasott fájlra. Egy valós ASI2600 light headere tartalmazza: `DATE-OBS` (ms pontossággal), `RA`/`DEC` + teljes WCS (`CRVAL1/2`, `CD1_1..CD2_2`, SIP), `SITELAT`/`SITELONG`, `XPIXSZ`, `FOCALLEN`, `EGAIN`, `OFFSET`, `GAIN`, `SET-TEMP`, `CCD-TEMP`, `XBINNING`, `BAYERPAT`, `TELESCOP`, `GUIDECAM`, `ROTATOR`. **Az alábbi javaslatok 80%-ához nem kell új adatgyűjtés, csak a már meglévő `header_json` kiolvasása** — legfeljebb egy `scan --refresh-meta` backfill.

---

## P1 — nagy érték, most is megvalósítható

### 1. Valós integráció és keretszám (dedup + szerep-szűrés) — `Stats`
- **Mi**: Minden statisztika két számot ad: **valós** (fizikai keretek, egyszer számolva) és opcionálisan bruttó. A session-sorban külön látszik: `használható 118 · triázsban elvetett 12 · duplikált link 47 · nem keret 33`.
- **Miért**: Ez a tool legfontosabb kimondott száma („mennyi integráció van a célponton"), és ma 30%-kal téved (A1–A2). Amatőr szinten ez dönti el, hogy „elég-e már"; haladó szinten ebből számol SNR-becslést és tervez.
- **Hogyan**:
  - `Scan`: DB séma **v3**, `files.inode INTEGER` + `files.nlink INTEGER` (`URL.resourceValues(forKeys: [.fileResourceIdentifierKey])` vagy `stat`) — a hardlink-dedup így egzakt és ingyenes; a séma-migráció már verzió-lépcsős, illeszkedik.
  - Új `Sources/AstroCore/Stats/FrameSet.swift`: egy `FrameSet.lights(for:)` helper, ami (a) csak keret-kiterjesztéseket enged (`fit/fits/fz/cr3/tif`), (b) `inode` szerint deduplikál, fallback `(target, session_date, normalizált DATE-OBS, exptime)` — a normalizálás azért kell, mert az EXIF `2026:04:18 04:36:24` és a FITS `2026-04-18T…` formátum eltér, (c) `Reject/`/`Review/` alatti keretet külön bucketbe tesz, (d) `SessionDateParser` `.labeled` + `config.stats.excludeLabels` (default `["hibas"]`) alapján kizár.
  - `StatsQueries` és `SessionStatsQueries` ezen a helperen keresztül dolgozzon (egy helyen, ne duplikálva); `TargetStats`/`SessionDetail` **additív** új mezők: `usableIntegrationSeconds`, `grossIntegrationSeconds`, `frameCount`, `duplicateLinkCount`, `rejectedFrameCount`, `nonFrameFileCount`, `excludedLabeledSessions`.
  - CLI: meglévő `stats` kimenet a valós számot mutatja, `--gross` a régit; `--json` mindkettőt.
  - App: Statisztika fül oszlopai + tooltip a bontással.
- **Méret**: **M**

### 2. Éjszaka-idővonal: felvételi ablak, kiesések, overhead — `Stats` (új `SessionTimeline`)
- **Mi**: Sessiononként: első–utolsó `DATE-OBS`, teljes ablak (pl. 3 h 42 m), ebből valós integráció (2 h 11 m), **hatékonyság 59%**, és a >N perces szünetek listája időbélyeggel („22:41–23:18, 37 min kiesés").
- **Miért**: Erre nincs ma semmi válasz, pedig ez a legkonkrétabb tanulság minden éjszaka után: hol veszett el az idő (felhő, meridián-flip, újrafókusz, guiding-újrakalibrálás)? Amatőr szinten: „miért csak 2 óra jött össze 4 óra kintlétből"; haladó szinten: a dither/download overhead és a flip-időzítés optimalizálása.
- **Hogyan**: A `DATE-OBS` mind a 2974 meta-val rendelkező session lightnál kitöltött — tiszta lekérdezés. Új `Sources/AstroCore/Stats/SessionTimeline.swift` (`windowStart/End`, `gaps: [(from,to,seconds)]`, `dutyCycle`), a gap-küszöb configból (`stats.gapThresholdSeconds`, default 3× exptime). CLI `astrotool stats --target T --timeline`; app: a session-sor lenyitva egy vízszintes sáv-diagram (Swift Charts, Apple SDK).
- **Méret**: **S/M**

### 3. Absolút, sessionök között összemérhető minőség-összegzés — `Rate`/`Stats`
- **Mi**: Session-szintű összegző táblázat: median FWHM **px ÉS arcsec**, median háttér **e⁻/s/arcsec²**, csillagszám-median, eccentricitás, elvetett keretek aránya — és egy „ez az éjszaka a célpont eddigi 6 sessionje közül a 2. legjobb" rangsor.
- **Miért**: A z-score önmagában *relatív* — megmondja, melyik keret rosszabb a szomszédjánál, de nem azt, hogy **jobb volt-e a mai éjszaka, mint a múlt hónapi**. Ez a hobbi egyik legtöbbet feltett kérdése. Arcsec-be konvertálva a 302 mm-es és a 70 mm-es setup is összemérhető, e⁻/s/arcsec²-ben pedig a háttér a Hold/Bortle-hatást mutatja pixelméret-függetlenül.
- **Hogyan**: Minden bemenet megvan: pixel scale = `206.265 × XPIXSZ / FOCALLEN` (a valós adatban 3,76 µm / 302 mm → 2,57 "/px), háttér e⁻/s-ben = `background(ADU) × EGAIN / EXPTIME`, majd `/ (arcsec/px)²`. Új `Sources/AstroCore/Stats/SessionQuality.swift` a `ratings ⋈ fits_meta` joinból, a `header_json`-ból kiolvasott `XPIXSZ`/`EGAIN`-nel (érdemes ezt a kettőt önálló `fits_meta` kolumnává is emelni v3-ban, hogy ne kelljen JSON-t parse-olni lekérdezésenként). CLI `astrotool quality --target T [--date D]`; app: a Minőség fül fölé egy session-összegző szekció, a mostani keret-táblázat alá kerül.
- **Méret**: **M**

### 4. Kalibráció-illesztés a teljes elektronikai kulccsal (gain/offset/binning/kamera) — `Calib`
- **Mi**: A lefedettségi mátrix és a `link-calib` kulcsa `(exp, temp, gain, offset, binning, kamera)`; a mesterek jellemzése a bennük lévő fájlok **FITS headeréből**, nem a mappanévből. Nem illeszkedő master esetén a `link-calib` terv indoklása kimondja, mi nem stimmel („gain 0 ≠ 100").
- **Miért**: Lásd A7. Ez az egyetlen javaslat, ami **aktív kárt** előz meg: a `link-calib` ma hard-linkel egy potenciálisan hibás dark mastert a session `darks/` mappájába, amit a Siril utána jóhiszeműen levon.
- **Hogyan**: `CalibAnalyzer.masterDirs` ma `parseMasterDirName`-re épül; kiegészítés: minden master-dirhez a hozzá tartozó `area == .calibration` fájlok `fits_meta` aggregátuma (domináns gain/offset/xbinning/instrume, medián CCD-TEMP + szórás). `CalibCombo` bővül ezekkel a mezőkkel; a matching bekapcsolható/hangolható: `calib.matchGain/matchOffset/matchBinning/matchCamera` (default `true`), `gainTolerance`, `tempToleranceC` default **1.0**, relatív `exposureToleranceFraction` (0.02) az `exposureToleranceS` mellé. A `SessionMatcher`/`CalibLinker` már a `CalibAnalyzer` matcherét hívja, tehát mindkettő ingyen javul. `CalibNeed` új mezők: `requiredGain`, `requiredOffset`, `mismatchReasons: [String]`.
- **Méret**: **M**

### 5. „Mit vegyek fel ma?" — planner: alulintegrált célpont + kulmináció + Hold — új `Sky` modul
- **Mi**: Egy lista: célpont, valós integráció, „hiányzik a célig", **ma este mikor kulminál és milyen magasan** a saját észlelőhelyről, mikor van 30° fölött, **Hold fázisa és szeparációja a célponttól**, és egy egyszerű „ma jó / ma a Hold tolja" verdikt. Szezonalitás: „ez a célpont már csak 3 hétig érhető el napnyugta után".
- **Miért**: Ez a hobbi *tényleges* döntése minden derült estén, és ma kézzel, Stellariummal + fejben tartott integrációs számokkal történik. Egy könyvtár-menedzser tool pont ehhez tud a legjobb választ adni, mert **csak neki van meg, hogy miből mennyi van már**. Amatőr szinten: nem kezd olyan célpontot, ami 2 óra múlva lemegy. Haladó szinten: a szűk szezonablakos célpontokat priorizálja, és nem pazarol Hold közeli éjszakát széles sávra.
- **Hogyan**: Teljesen számítás, **nulla dependency, nulla hálózat**:
  - Célpont RA/DEC: a `header_json`-ból (`CRVAL1`/`CRVAL2` a plate-solved WCS-ből, fallback `RA`/`DEC`), célpontonként medián — a valós adatban minden ASIAIR light plate-solved.
  - Helyszín: `SITELAT`/`SITELONG` a headerből (REDACTED / REDACTED a valós adatban), `config.site` override-dal.
  - Új `Sources/AstroCore/Sky/` — `SiderealTime.swift` (GMST/LST), `AltAz.swift` (RA/DEC + LST + lat → alt/az, airmass), `MoonSun.swift` (Meeus low-precision nap/hold pozíció + fázis, ±1' pontosság, ~250 sor, tesztelhető ismert dátumokra).
  - CLI `astrotool plan [--date D] [--min-alt 30] [--json]`; app: új „Terv" fül vagy egy Áttekintés-doboz („Ma este ezekre érdemes: …").
  - Cél-integráció: `goal:6h` konvenciós tag a meglévő `tags` táblában (nem kell új séma), vagy `config.targets.goals`.
- **Méret**: **L** (de a magja — alt/az + holdfázis + kulminációs idő — **M**, és önmagában is használható)

---

## P2 — értékes, több munka

### 6. Kalibrációs higiénia-riport (flat-fegyelem, bias-készlet, dark-kor DATE-OBS szerint) — `Calib`
- **Mi**: Egy „Kalibráció egészség" nézet három blokkal: (a) **flat-fegyelem** — mely sessionöknek nincs flatje, és mely sessionök flatje nem illik a lightokhoz (más gyújtótáv/rotátorállás/szűrő, vagy >30 nap eltérés); (b) **bias/offset-készlet** gain+offset szerint (és a `bias` ↔ `biases` árva mappa); (c) **dark-készlet** kora `DATE-OBS` szerint, gain/offset/binning bontásban, hőmérséklet-stabilitással (CCD-TEMP szórás a masterben).
- **Miért**: OSC deep-sky-nál a flat a legnagyobb minőségi tétel (vignettálás + szenzorpor + rotátorállás), és pont ez az, amit sietve kihagy az ember. A valóságban a `calibration_library/flats/` üres, tehát ma minden flat session-lokális — épp ezért kell a per-session fegyelem-ellenőrzés.
- **Hogyan**: A `CalibAnalyzer` „v1: csak darks" korlátjának feloldása: a flatokat/bias-okat **ne mappanévből**, hanem `fits_meta`-ból csoportosítsuk (`instrume`, `gain`, `offset`, `focallen`, `ROTATOR` a `header_json`-ból, `filter`, `DATE-OBS`). A `SessionMatcher` `missing-flats` findingje mellé új `flat-mismatch` finding. Új config: `calib.flatMaxAgeDays`, `calib.matchRotator`. CLI `astrotool calib --health`; app: a Kalibráció fül új szekciója.
- **Méret**: **M**

### 7. Export/riport: Astrobin-kompatibilis acquisition CSV + session-napló — új `Export`
- **Mi**: `astrotool export --target T --format astrobin|csv|md` → soronként (dátum, szűrő, expozíció, keretszám, gain, offset, hőfok, darks/flats/bias darabszám), plusz egy emberi Markdown/HTML session-napló a `.astro_tool/exports/` alá.
- **Miért**: Minden publikálás előtt (Astrobin, fórum, saját blog) kézzel kell összeszedni ezeket — 10-15 perc célpontonként, és épp itt csúszik el a keretszám/integráció. A tool az egyetlen hely, ahol ez az adat pontosan megvan (P1-1 után **valósan** megvan).
- **Hogyan**: Színtiszta olvasás: `SessionStatsQueries` + `FrameSet` + `SessionMatcher` calib-darabszámok. Új `Sources/AstroCore/Export/AcquisitionExport.swift`, írás a meglévő `WriteGuard.writeToolFile`-on át (`exports/<target>-<timestamp>.csv`) — a vasszabály érintetlen. App: „Exportálás…" gomb a célpont-soron.
- **Méret**: **S/M**

### 8. Mozaik-panel és FOV-követés a WCS-ből — `Sky`/`Stats`
- **Mi**: Célpontonként a plate-solved keretek középpontjai klaszterezve → „ez 3 panelből álló mozaik: A 2 h 10 m, B 1 h 50 m, **C csak 35 m**", plusz panelenként a rotátorállás és a FOV/pixel scale.
- **Miért**: Mozaikoknál a panel-egyenlőtlenség kézzel nem követhető, és pont ez az, ami tönkreteszi a végeredményt (látszó SNR-lépcső a panelhatáron). A Canon R8-as wide-field mozaikoknál ez közvetlenül a felhasználó munkamódszere. Emellett ez adja meg a „két session valóban ugyanaz a képmező?" választ, ami az M42-négyes családnál nyitott kérdés.
- **Hogyan**: `header_json`-ból `CRVAL1/2` (mezőközép) és a CD-mátrix → pixel scale + rotációs szög + FOV (`NAXIS1/2` × scale). Klaszterezés: szögtávolság a középpontok között, ha > FOV × 0,5 → új panel (egyszerű single-linkage, nincs szükség könyvtárra). Új `Sources/AstroCore/Sky/FieldGeometry.swift`; app: Statisztika fül alatti „Panelek" szekció, CLI `astrotool panels --target T`.
- **Méret**: **M/L**

### 9. Setup-ujjlenyomat és felszerelés-változás követés — `Stats`
- **Mi**: Sessiononként egy „setup fingerprint" chip (teleszkóp + kamera + gyújtótáv + pixelméret + binning + guide-kamera + Bayer-minta), célpont-szinten pedig figyelmeztetés: „ehhez a célponthoz 2 különböző setup tartozik — ezek nem stackelhetők egybe", illetve egy időrendi „mikor mit használtam" napló.
- **Miért**: A több szezont átfogó projekteknél (és a négy `M42_*` mappánál) a setup-keverés a leggyakoribb rejtett hiba: az ember összestackel két olyan éjszakát, amiknek más a képskálája vagy a rotációja. A wide-field besorolás session-szintűvé tétele (A9) ennek a melléktermékeként megoldódik.
- **Hogyan**: `fits_meta` + `header_json` (`TELESCOP`, `INSTRUME`, `FOCALLEN`, `XPIXSZ`, `XBINNING`, `GUIDECAM`, `BAYERPAT`) aggregáció; új `Sources/AstroCore/Stats/EquipmentProfile.swift` egy stabil hash/leíró stringgel. Új audit finding (`mixed-setup-in-session` = `suspicious`, `mixed-setup-in-target` = `probablyIntentional`, hisz lehet szándékos). App: chip a session-sorban.
- **Méret**: **M**

---

## P3 — jó, ha van

### 10. Hűtő- és fókusz-egészség egy éjszakán belül — `Stats`/`Rate`
- **Mi**: Sessiononként: `CCD-TEMP` eltérése `SET-TEMP`-től (max/median/szórás) — „a hűtő nem érte el a −20 °C-ot 01:10 után" —, és az FWHM lineáris trendje az éjszaka során: „+0,4" 3 óra alatt → fókuszcsúszás vagy harmatosodás".
- **Miért**: Nyáron az ASI2600 hűtője nem mindig tartja a −20 °C-ot; ha nem tartja, a dark-illesztés csendben érvénytelen (kapcsolódik A7-hez). A fókuszcsúszás pedig azt magyarázza meg, miért lett gyenge a második éjszakafél — és ez a tanulság a KÖVETKEZŐ éjszakán hasznosul (autofókusz-intervallum).
- **Hogyan**: `ccd_temp` már önálló kolumna, `set_temp` is; a trendhez `ratings.fwhm ⋈ fits_meta.date_obs` és egy egyszerű lineáris regresszió. App: Minőség fül grafikon (Swift Charts). Új audit/finding: `cooler-not-reaching-setpoint`, ha |ΔT| > 1 °C a keretek >10%-ánál.
- **Méret**: **S/M**

### 11. Projekt-státusz: célpont-lezárás és pipeline-hiánylista — `Stats`/`Audit`
- **Mi**: Célpontonként egy állapot: `gyűjtés alatt` / `elég van, stackelhető` / `stackelve, feldolgozásra vár` / `kész`, és a konkrét hiányok: nincs README, van light de nincs stack, van stack de nincs `processed/`, cél-integráció alatt van.
- **Miért**: A félbehagyott célpont a hobbi legnagyobb rejtett vesztesége: 2 óra van rajta, nem elég publikálni, de az ember elfelejti, hogy vissza kell menni rá. Ez a fél lépés a P1-5 plannertől: az ad választ, mit vegyek fel; ez ad választ, mit dolgozzak fel egy felhős estén.
- **Hogyan**: A session↔stack↔processed párosítás már audit szabály — csak össze kell fogni egy `ProjectStatus` táblába, plusz a `goal:` tag parse (meglévő `tags` tábla, nincs új séma). CLI `astrotool projects [--json]`; app: Áttekintés doboz „Feldolgozásra vár (4)".
- **Méret**: **S/M**

### 12. README.txt indexelés → kereshető éjszaka-napló (SQM/Bortle/seeing/megjegyzés) — `Scan`/`Stats`
- **Mi**: A `SessionCreator` által generált README.txt „Fill in metadata" szekciójának beolvasása kulcs-érték párokká (Bortle, SQM, seeing, szél, hold, szabad megjegyzés), majd kereshetőség: `astrotool search "harmat"`, és a session-sorban a beírt körülmények megjelenítése.
- **Miért**: Az égi körülmény (Bortle-osztály, SQM, seeing, harmat, szél) az EGYETLEN dolog, amit nem lehet FITS headerből kinyerni — viszont a felhasználó munkamódszerében már benne van, hogy README-be írja. Ha indexelt, akkor a P1-3-as absolút háttér-metrika mellé odatehető a szubjektív körülmény, és kiderül, mi korrelál mivel („Bortle 4-es helyszínen 3× jobb a háttér" → érdemes utazni).
- **Hogyan**: A design-spec `sessions.readme_json` mezője **tervben volt, de nem implementálódott** — ez az. `Scanner`: README.txt (kis fájl) beolvasása és `key: value` sorok kinyerése; DB v3 `session_notes(target, session_date, key, value, raw)` vagy egyszerűen a meglévő `sessions.readme_json` mező. A `SessionDetail.hasReadme` bool helyére/mellé `readmeFields: [String: String]`. Fontos: **csak olvasás**, a README-t nem írjuk át.
- **Méret**: **M**

---

# Top 3, amit azonnal implementálnék

**1. Valós integráció és keretszám (P1-1, M).** Mielőtt bármi új épül, a tool központi számának igaznak kell lennie. Ma 42,55 h helyett 29,77 h a valóság, és a „4048 light" közül ~1073 nem is keret — minden más funkció (planner, export, minőség-összehasonlítás) ERRE épül, tehát ha ez hibás, mindent megfertőz. Az `inode`-alapú dedup egzakt, és a séma-migráció mintája már készen áll. Ide csomagolnám a `_hibas` kizárást és a `Reject/` szeparálást is.

**2. Session-szintű, absolút minőség + éjszaka-idővonal (P1-3 + P1-2, együtt M).** Ez a legnagyobb „aha" élmény a legkisebb új adatért: minden bemenet már a `header_json`-ban ül, és először tud válaszolni a hobbi két örök kérdésére — *„jobb volt-e a mai éjszaka, mint a múlt hónapi?"* (FWHM arcsec-ben, háttér e⁻/s/arcsec²-ben, setupok között összemérhetően) és *„hova ment el a 4 órából 2?"*. Mellékhatásként javítja a rate összehasonlítási egységét (A5) és kidobja a hamis `roundness = 0.5` bejegyzéseket.

**3. Kalibráció-illesztés a teljes kulccsal (P1-4, M).** Ez a legkisebb munka a legnagyobb *elkerült kárért*: a `link-calib` ma hard-linkelhet gain/offset szempontból hibás mastert a session mappájába, és onnantól a Siril azt vonja le. Menne vele együtt a két default-hangolás (`tempToleranceC` 0,5 → 1,0; `darkMaxAgeMonths` 6 → 12) és a dark-kor `DATE-OBS`-ra átállítása.

Ezután a planner (P1-5) az, ami a toolt „könyvtár-rendszerezőből" **a hobbi tervező eszközévé** emeli — de csak akkor van értelme, ha az 1. pont miatt igazat mond arról, miből mennyi van már meg.
