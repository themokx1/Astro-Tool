# AstroTool — robusztussági és „folyjon, mint a víz” review (2026-09-02)

**Vizsgált állapot:** `codex/v5-iphone-companion` ág, `1705808` (a `main` + a V5 iPhone-kísérő
folyamatban lévő munkája).
**Cél:** az alapfunkciók bárki Macjén, bárki adatával működjenek (ne csak a szerző gépén, a
szerző eszközeivel), a felület maradjon egyszerű és letisztult, és minden képernyő vezesse
tovább a felhasználót: se zsákutca, se néma hiba, se hamis üzenet.
**Módszer:** hat párhuzamos, csak olvasó review (első indítás és vezetett folyamat; AstroCore
scan/index hordozhatóság; UI állapot és konkurrencia; build/telepítés/dokumentáció; CLI;
V5 mobil), a találatok forráskódban ellenőrizve, majd 12 javító agent két párhuzamos
munkafán, végül egy független regresszió-review az egész hullámra, és annak találatai is
javítva.

## Eredmény egy mondatban

82 commit, a teljes tesztkészlet 3607 → 3844 tesztre bővült (239 suite), végig zöld
(`swift test --no-parallel`); a hullám az alábbi hibaosztályokat zárta le.

## Mit találtunk és mit javítottunk

### 1. AstroCore — más felhasználó adata (kritikus)
- **Csak Canon CR3 + TIF számított keretnek.** Nikon/Sony/Fuji/DNG/CR2 és PixInsight XISF
  „nem-keret fájl”-ként 0 használható integrációt adott. → Kiterjesztéskészletek bővítve
  (`fts`, 10 RAW-formátum, `xisf`), a FrameSet a scanner készletéből származik, a
  CorruptFITS-szabály nem jelöl RAW/XISF-et. RAW+DNG párok egy expozíciónak számítanak,
  a JPEG-előnézet nem növeli a bruttó időt.
- **Egy nem-ASCII bájt a FITS-fejlécben az egész fejlécet eldobta** (N.I.N.A./SGP UTF-8
  OBJECT). → Az őr eltávolítva; a bájt↔karakter 1:1 megfeleltetés bizonyítottan megmarad.
- **EXPTIME/DATE-OBS csak pontos kulccsal.** → `EXPOSURE`, `DATE-LOC`, `DATE` fallback.
- **Exif idő UTC-ként értelmezve** (DSLR-keretek 1–12 órával eltolva). →
  `OffsetTimeOriginal`, különben a Mac időzónája; kártya-importban is.
- **NFC/NFD útvonalak dupla sort adtak** (HFS+ → APFS/SMB). → NFC-kulcs, bájt-szintű
  „hiányzik” összevetés, és a régi, másképp normalizált sorokat a scan **átveszi** (id és
  értékelések megmaradnak); `capture_sources` is; notes/tags migráció (lásd 6.).
- **Symlink-hurok az audit könyvtárjárásban = crash; eltűnő fájl = az egész scan
  elszáll.** → Symlink kihagyás, toleráns `resourceValues`.
- **Nem kanonikus mappaszerkezet némán üres appot adott.** → Audit-szabály, ha van keret,
  de egy sem sorolódik ismert területre; kósza területek; `.fits.gz`/`.ser` nem indexelt
  fájlok jelzése könyvtáranként.
- **Adatbázis:** sémaverzió-visszalépés őr (nem „újra” hanem „frissíts”); WAL kérés
  visszaellenőrzése, TRUNCATE-fallback hálózati megosztáson; `busy_timeout` 30 s;
  a scan írásai tranzakciókban (2000 fájl vagy 2 s), COMMIT-hiba után is konzisztens
  állapot; a session-konverzió metaadatai SAVEPOINT-tal atomiak scan közben is.
- **Nyelvsemleges alapértékek:** `excludeLabels` bő készlet csak új konfigra (régi konfig
  megtartja a `hibas`-t); `tools` kizárás csak a gyökérben, felhasználói nevek bárhol.
- **Gyökér-hiba osztályozás:** iCloud Drive és `/Volumes`-on kívüli kötethatár is
  „csatlakoztasd újra”, létező gyökér + hiányzó almappa viszont „nincs ilyen útvonal”.

### 2. Első indítás és vezetett folyamat (V2)
- Lecsatolt külső meghajtó = „ez egy fájl, nem mappa” + a könyvtár örökre elfelejtve. →
  Valódi diagnózis (`volumeNotMounted`, Újra), a bookmark csak végleges hibánál törlődik.
- Home örökké „Könyvtár megnyitása…” sikertelen előkészítés + Mégse után. → Külön állapot
  Újra / Másik könyvtár gombbal.
- A „Már van AstroTool-könyvtáram” ág kikerülte a vezetett folyamatot és sosem engedélyezte
  az írást (később „engedélyezd a Beállításokban” zsákutca). → A journey a shell tulajdona,
  túléli a mappaválasztót, ugyanoda vezet.
- Saját mappa (`~`) választása értelmetlen általános hibát adott. → Nevesített ok, akció.
- Rossz mappa: „A könyvtár készen áll” 0/0/0-val. → „Nem találtunk asztrofotót”, Másik mappa.
- Könyvtár nélkül az eszköztár „Import kártyáról / Új éjszaka” hamis „hamarosan” lapot
  mutatott. → „Nincs megnyitott könyvtár” lap, Könyvtár választása akció.
- Bookmark-létrehozás néma hibája → sima útvonal + nem-scoped bookmark fallback.
- Súgó ▸ Első lépések mappaválasztója sheet fölött nem nyílt. → Ugyanaz az útvonal, mint
  első indításnál.
- Wizard: megszakított másolás részleges bizonylattal (és a művelet „megszakítva”, nem
  „sikeres”); „Struktúra létrehozása” hibája inline; félkész projekt őszinte jelzése +
  Undo; valódi mappa-előnézet és írás-engedély a létrehozás gombján; magyar szövegek az
  angol UI-ban és angol hibák a magyarban javítva; valódi scan-progress összesítő.

### 3. UI állapot és konkurrencia
- Fordítóhibás minta (Swift 6.3.3): `ClearSkyTriggerCheckRunner.check` closure-alapértéke
  modulhatáron át → Optional paraméterek, a testben feloldva.
- LiveNight-figyelő: soha le nem zárt security-scope minden UserDefaults-változásnál,
  observer-szivárgás → egyensúly + `deinit`; scope a feloldott URL-példányon.
- Könyvtárváltás: ProjectsStore/NightsStore/HomeStore/SidebarBadge generációs őrök, hibás
  megnyitás üríti a régi sorokat; router és Review/Health/Archive állapot reset; „Ez a
  projekt nem ebben a könyvtárban van” állapot a hamis „nincs könyvtár” helyett; egyetlen
  könyvtár-előkészítés egyszerre (duplikált kérés örökbe fogadja a futót).
- Egy MetadataStore-kapcsolat könyvtáranként (Health, Rating, Archive, SavedTargets,
  Results, NightActionMenu, Home).
- Néma írási hibák: review-verdict, karantén Undo, konverzió újratervezés → látható;
  konverzió dupla-apply tiltva; értékelés-futások kölcsönösen kizáróak.
- Kereső debounce + generáció; fókuszált parancsok `Equatable` (invalidációs vihar);
  review-táblázat rendezése kikerült a `body`-ból.

### 4. CLI
- Emberi kimenet ~150 helyen kétnyelvű (`ASTROTOOL_LANG`, `LC_*`/`LANG`, alapból angol),
  a TCC-útmutató, `config show`, a session-convert biztonsági hibája is; `--json` és
  kilépési kódok változatlanok; a CLI-tesztek locale-függetlenek.
- `docs/cli.html` mind a 34 parancsot lefedi; a gyökér-ellenőrzés a közös osztályozót
  használja.

### 5. V5 iPhone-kísérő
- Megváltozott eszközidentitás = örök zsákutca → „Felejtsd el ezt az eszközt” mindkét
  oldalon, a hiba látszik, a párosítás megismétlése külön, tudatos lépés.
- Háttérbe kerülés megszakítja a szinkront; elakadt kapcsolat külön hibaüzenet + AirDrop
  tartalék; a párosító képernyő mutatja a másik eszköz (nem ellenőrzött, levágott) nevét;
  Application Support fallback figyelmeztetéssel.
- Az iOS-only fájlok itt csak forrás-szinten ellenőrzöttek (SwiftPM nem fordítja) —
  **Xcode `AstroToolMobile` build és szimulátor-gate szükséges.**

### 6. Build, dokumentáció, hygiene
- Az Xcode által beírt személyes `DEVELOPMENT_TEAM` a követett projektfájlban visszaállítva
  (ne kerüljön commitba).
- README és magyar adatvédelmi oldal: a bővített célpont-katalógus alapból **be** van
  kapcsolva (a kód így működik, az angol oldal ezt írta); first-steps lapnév „iPhone
  szinkron”.
- Séma v13: a `session_notes`, `tags` és `capture_groups` NFD célpont-sztringjei NFC-re
  írva (ütközésnél jegyzet-összefűzés, címke-unió, capture-csoportnál a függő sorokkal
  rendelkező sor marad), az elérők kanonizálják a `target` argumentumot.

## Tudatos döntések
- A katalógus alapértelmezett bekapcsolása marad; a dokumentáció követi a kódot.
- A követett `.xcodeproj` marad (a tulajdonos szándékosan commitolta), a driftet
  visszaállítjuk.
- A V1 felület (`-UseV1UI`) nem volt a review tárgya.

## Hátralévő, csak engedéllyel futtatható kapuk
- Xcode `AstroToolMobile` build + iOS szimulátor-gate (fókuszrabló).
- macOS `xcodebuild test -scheme AstroTool` (fókuszrabló).
- Saját készülékes oda-vissza próba.

## Ismert nyitott pontok
- Több ablak (`WindowGroup`) második onboardinget indíthat.
- `summary.reclassified` a normalizációs heal-eket is számolja az első újrascanen.
- `TimeZone.current` fallback Exif-nél: gépfüggő, dokumentált.
