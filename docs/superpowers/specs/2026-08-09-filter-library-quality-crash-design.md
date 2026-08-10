# v0.15.3 — Szűrőtörzs, feloldott riportadat és Minőség-stabilitás

## Kiinduló probléma

Az IC 1396 / 2026-08-08 sessionben a capture-gyűjtések helyesen tartalmazzák az SV220 adatot, a célpont áttekintője és a HTML-riport mégis „nincs szűrő-adat” állapotot mutat. A valós adatbázisban a 120 s-os és 300 s-os gyűjtések `filter_model = SV220` értéket tárolnak, a FITS-fejlécek viszont nem tartalmaznak `FILTER` kártyát.

A Minőség fül megnyitásakor a v0.15.2 összeomlik. A crash report a `QLThumbnailGenerator.response` queue-ról meghívott, Swift 6 által main-actor izoláltnak tekintett callbackre mutat (`swift_task_checkIsolatedSwift`, `ThumbnailCell.generateQuickLookThumbnail`).

Emellett nincs központi hely, ahol a felhasználó a saját szűrőit kezelhetné. A capture-felületek szabad szöveges gyártó/modell/név mezői nem alkotnak újrahasználható készletet, és nem támogatják a gyors helyszíni felvételt.

## Célok

1. A kézzel vagy capture-gyűjtésben megadott szűrőadat ugyanúgy jelenjen meg a célpont-összesítésben, éjszaka-listában, statisztikában és riportban, mint a FITS-fejlécből érkező adat.
2. Legyen első osztályú, könyvtárhoz kötött „Saját szűrők” törzs.
3. A gyűjtés-, fájlszintű besorolás- és session-konvertáló felületek közös listából válasszanak, és helyben is lehessen új szűrőt felvenni.
4. A Minőség fül QuickLook-bélyegképei ne sértsék a Swift 6 actor-izolációt, és ne omoljon össze az alkalmazás.
5. A meglévő könyvtár, sessionök és capture-besorolások veszteség nélkül migrálódjanak.

## Nem cél

- Nem módosítjuk a nyers FITS/CR3 fájlok fejlécét.
- Nem kötjük a régi sessionöket élő idegen kulccsal egy később szerkeszthető szűrőprofilhoz.
- Nem találjuk ki automatikusan a szűrőt, ha sem FITS-, sem kézi, sem capture-adat nincs.
- Nem mozgatunk fájlokat a szűrőtörzs kezelésekor.

## Adatmodell

Új, v12-es séma: `filter_profiles`.

| Mező | Jelentés |
|---|---|
| `id` | Stabil lokális azonosító |
| `manufacturer` | Gyártó, opcionális |
| `model` | Modell, opcionális |
| `name` | Saját vagy sávnév, opcionális |
| `signal_mode` | Szélessáv / dual-band / keskenysáv / LRGB / stb. |
| `notes` | Opcionális megjegyzés |
| `created_at`, `updated_at` | Auditálható időbélyegek |

Legalább a gyártó, modell és név egyikének nem üresnek kell lennie. A normalizált, kis- és nagybetűtől, szóköztől és írásjeltől független azonosság megakadályozza ugyanazon profil véletlen duplikálását.

A capture-gyűjtés továbbra is saját gyártó/modell/név pillanatképet tárol. Egy profil kiválasztása ezeket az értékeket másolja a draftba. Ez garantálja, hogy a profil későbbi átnevezése vagy törlése nem írja át a történeti sessiont.

## Feloldási szabály

Minden nyers light frame szűrőcímkéjének egyetlen közös forrása a `CaptureResolver`:

1. fájlszintű kézi felülírás;
2. capture-gyűjtés pillanatképe;
3. FITS `FILTER` fejléc;
4. ha egyik sincs, a dokumentált `(nincs szűrő-adat)` sentinel.

A `ResolvedCaptureMetadata` publikus `filterLabel` tulajdonságot kap. A `FilterBreakdownQueries`, `StatsQueries`, `NightsQueries` és a riportok ezt használják, így nem marad párhuzamos, egymástól eltérő összesítési útvonal.

Az IC 1396 példánál az elvárt eredmény:

- 32 × 30 s: `(nincs szűrő-adat)` vagy „szűrő nélkül”, a rögzített gyűjtés szerint;
- 3 × 120 s: `SV220`;
- 46 × 300 s: `SV220`;
- a célpont felső Szűrők kártyája és HTML-riport ugyanazt a két bucketet mutatja.

## Saját szűrők felület

Az oldalsáv ESZKÖZÖK szakaszában új `Szűrők` oldal jelenik meg.

- Üres állapot: rövid magyarázat és `Első szűrő hozzáadása` gomb.
- Lista: beszédes címke, gyártó/modell/név, fénysáv és megjegyzés.
- `+ Szűrő` gomb: új profil.
- Szerkesztés: ugyanaz az űrlap előtöltve.
- Törlés: megerősítés; egyértelműen jelzi, hogy a korábbi session-pillanatképek megmaradnak.
- „Felfedezett” rész: a capture-gyűjtésekben vagy FITS-fejlécekben már használt, de még a törzsben nem szereplő szűrők egy kattintással importálhatók. A jelenlegi SV220 így azonnal felajánlható.

## Közös szűrőválasztó

Új, újrahasznosítható `FilterProfilePicker` kerül a következő helyekre:

1. `CaptureGroupSheet`;
2. `CaptureAssignmentSheet` pontos fájlszintű felülírása;
3. `SessionConversionSheet` gyűjtés-döntési sora.

A menü elemei:

- `Szűrő nélkül`;
- mentett saját szűrők;
- `Új szűrő…`.

Az `Új szűrő…` egy kis, fókuszált szerkesztő sheetet nyit. Sikeres mentés után az új elem automatikusan kiválasztódik az aktuális szerkesztésben. A kiválasztás átveszi a profil fénysávját is, de a felhasználó utána felülírhatja.

## Hiányzó szűrőadat kezelése

Ha egy célpontnak csak sentinel bucketje van, az Áttekintés nem pusztán hibaüzenetet mutat, hanem `Szűrő hozzárendelése…` műveletet kínál. Ez a legutóbbi session capture-gyűjtés szerkesztésére vezet. Az app továbbra sem állítja, hogy biztosan nincs fizikai szűrő; azt mondja, hogy nincs rögzített adat.

## Minőség fül crash-javítása

A QuickLook completion handler tetszőleges queue-n fut. A `ThumbnailCell` SwiftUI `View` statikus metódusa Swift 6 alatt main-actor izolációt örökölt, így a callback futásidejű queue-ellenőrzésen elbukott.

A javítás:

- a QuickLook callback-híd külön, explicit `nonisolated` segédbe kerül;
- a callback csak `CGImage?` értéket ad át a continuationön;
- `NSImage` továbbra is a main actoron készül;
- a SwiftUI `@State` és az `NSCache` csak main-actor kódból érhető el;
- forrásszintű konkurenciabiztonsági regressziós teszt és tényleges async bridge-teszt védi a határt.

## Hibakezelés

- Üres vagy duplikált profil nem menthető; a felület helyben magyarázza az okot.
- Adatbázishiba esetén a sheet nyitva marad, az `AppState.lastError` látható.
- A profil törlése nem töröl capture-adatot vagy fájlt.
- A „felfedezett” szűrő importja idempotens.
- A feloldási logika megőrzi a meglévő FITS-only működést.

## Validáció

- v11 → v12 migrációs teszt, meglévő capture-adatok megőrzésével;
- filter profile CRUD és duplikációs tesztek;
- FilterBreakdown teszt capture groupból és fájlszintű override-ból érkező szűrőre;
- Stats/Nights/report konzisztenciateszt;
- IC 1396 mintára 30/120/300 s bucketteszt;
- QuickLook actor-híd regressziós teszt;
- teljes `swift test`;
- release build;
- read-only valós könyvtári riportellenőrzés;
- telepített app indítás- és Minőség-fül smoke teszt.

