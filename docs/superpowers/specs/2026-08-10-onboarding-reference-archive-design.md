# AstroTool v0.16.0 — onboarding, relatív integrációs referencia és frame-archívum

## Cél

Az első indítás ne egyetlen mappaválasztó legyen, hanem egy nyugodt, többoldalas beállítóvarázsló. A felhasználó minden oldalt kihagyhat, a már meglévő értékei megmaradnak, és a varázsló később újra megnyitható. A tervező minden explicit cél nélküli célponthoz egy érthető, felszerelésfüggő alapcélt ad. Az elvetett frame-eket külön, visszaállítható művelettel lehet a saját gyűjtésük archív mappájába tenni úgy, hogy az app továbbra is mutassa őket és minden mérésük megmaradjon.

## 1. Onboarding életciklus

- A varázsló verziózott alkalmazás-preferencia. A v0.16.0 egy alkalommal felajánlja az új onboardingot új és meglévő telepítésen is.
- Könyvtár nélkül a meglévő üdvözlőképernyő marad az első biztonságos kapu. A gyökér kiválasztása után, még az első scan előtt jelenik meg a varázsló.
- Már használt könyvtárnál a főablak betöltése után jelenik meg modális lapként.
- A „Most kihagyom” és a befejezés is lezárja az aktuális onboarding-verzió automatikus megjelenését. A Beállítások „Onboarding újraindítása…” gombja bármikor megnyitja.
- A lapok: Üdvözlés; Helyszín és időjárás; Felszerelések; Szűrők; Minőség és Siril; Integrációs referencia; Ellenőrzés.
- Minden tartalmi oldalon van „Ezt kihagyom”. A kihagyott oldal nem ír üres értéket a meglévő konfigurációra.
- A draft csak a végső „Beállítások alkalmazása” műveletnél kerül mentésre. A konfiguráció egyetlen `config.json` írással frissül. A szűrőprofilok csak ezután, az adatbázis saját tranzakcióbiztos upsertjeivel kerülnek be.
- A varázsló az alapértelmezéseket előre kitölti, de nem kér kötelező választ egyetlen szakmai mezőnél sem.

## 2. Oldalak és alapértékek

### Üdvözlés

Elmagyarázza az olvasási és írási határt: az AstroTool alapból csak olvas; könyvtári fájlt kizárólag külön előnézett, felhasználó által megerősített létrehozás, konverzió vagy archíválás mozgat/hoz létre. Nincs automatikus törlés vagy archíválás.

### Helyszín és időjárás

Az automatikus FITS-helyszín az alap. Opcionálisan megadható név, szélesség, hosszúság és az Open-Meteo engedély. A hálózati adatküldés ténye a kapcsoló mellett látható.

### Felszerelések

Több setup vehető fel. Minden setup neve, kamera típusa, fizikai szenzormérete, fix/zoom fókusztávja, alap fókusztávja és f-száma megadható. Gyors sablonok: APS-C astro 100–400 mm f/5; Canon R8 16 mm; Canon R8 28–70 mm.

### Szűrők

Tetszőleges számú saját szűrő vehető fel gyártó, modell/saját név és fénysáv szerint. A sor helyben hozzáadható és eltávolítható. A mentett lista ugyanaz, mint amit a capture-felületek használnak.

### Minőség és Siril

Megadható a kiugró z-küszöb, worker-szám és Siril útvonal. A gyári értékek előre kitöltve maradnak.

### Integrációs referencia

Alapérték: 10 óra, 23,5 × 15,6 mm-es APS-C szenzor, f/5 és 100% relatív rendszerhatékonyság. A setup-ajánlás az azonos normalizált képkivágásra vonatkozó tervezési becslés:

`ajánlott idő = 10 h × (setup f-szám / 5)² × (APS-C terület / setup szenzorterület) ÷ setup hatékonyság`

Az érzékelőterület azért szerepel, mert az összehasonlítás azonos normalizált látómezőre vonatkozik; ez nem garantált SNR, csak konzisztens tervezési alap. Az explicit `goal:` címke mindig felülírja az automatikus ajánlást. Ha nincs használható setup, az eredmény pontosan 10 óra.

### Ellenőrzés

Összefoglalja, mely részek módosulnak és melyek maradnak érintetlenek. A mentés után a felhasználó dönthet az első scan elindításáról a meglévő képernyőn.

## 3. Célidő adatmodell és megjelenítés

- Új, visszafelé kompatibilis `IntegrationReferenceRule` kerül az `AstroConfig` alá.
- Az `ImagingSetupProfile` új opcionálisan dekódolt mezői: `fNumber` és `relativeEfficiency`. Régi config esetén f/5 és 1,0 az alap.
- `IntegrationGoalCalculator` egyetlen domain-szintű számoló. Érvénytelen kézi konfigurációra nem gyárt veszélyes szélsőértéket: a referencia 10 órára esik vissza.
- `ProjectState.goalSeconds` az effektív célt tartalmazza. Új `goalSource` jelzi, hogy explicit címke vagy automatikus setup-referencia adta-e. A UI „automatikus referencia” címkével megkülönbözteti az explicit céltól.
- A projektfázis, hiányzó órák, Ma este tervező, riport és cél-szerkesztő ugyanazt a számolót használja. A cél-szerkesztő az automatikus értéket kiindulásként mutatja; mentéskor explicit cél lesz belőle.
- A per-filter célok változatlanok és nem kapnak automatikusan fejenként 10 órát.

## 4. Elvetett frame archíválása

### Láthatóság és kizárás

- Az „Áthelyezés archívumba…” csak `accepted == false` frame-nél látszik.
- Megerősítő lap mutatja a forrás- és célútvonalat, valamint hogy a frame kizárva marad.
- A cél mindig az adott role-mappa alatti `archive/`: például `captures/nb-300s/lights/a.fit` → `captures/nb-300s/lights/archive/a.fit`.
- Ha a forrás role-mappán belül további alkönyvtárban volt, az relatívan megmarad az archive alatt. Így a visszaállítás pontos.
- Nincs felülírás. Létező cél blokkolja a műveletet, és érthető hiba jelenik meg.
- Az archív frame ugyanazzal a database `file_id`-val él tovább; így FITS-meta, rating, verdict és capture-hozzárendelés változatlan marad.
- Az `archive` útvonalkomponens a `Reject` mellett hard kizárás a használható integrációból és a stacklistből. A Minőség táblában „ARCHÍV · kizárva” jelzés jelenik meg.

### Visszaállítás és hibatűrés

- Archív frame-nél „Visszaállítás az eredeti helyre…” érhető el.
- A fájlművelet kizárólag a könyvtár gyökerén belüli, azonos session/role hatókörben engedélyezett.
- Előbb teljes preflight történik. A fájl mozgatása után egy DB-tranzakció frissíti ugyanannak a sornak az útvonalát. DB-hibánál a fájl visszamozog; rollback-hibát külön, súlyos hibaként jelez az app.
- Az automatikus scan soha nem mozgat archívumba és nem állít vissza semmit.

## 5. Nem cél ebben a kiadásban

- Tömeges fizikai archíválás, automatikus outlier-archíválás vagy fájltörlés.
- Tudományos SNR-garancia, égbolt-fényesség/QE/pixelméret automatikus modellezése.
- Per-filter automatikus 10 órás cél.
- Az onboarding kötelezővé tétele vagy a kihagyott oldal értékeinek törlése.

## 6. Ellenőrzés

- Config round-trip régi és új setupokkal.
- Referenciaszámítás: APS-C f/5 = 10 h; APS-C f/4 gyorsabb; full-frame f/5 rövidebb; invalid input = biztonságos alap.
- Project/Planner explicit cél elsőbbsége és implicit cél konzisztenciája.
- Archive plan, apply, restore, collision, scope escape és DB-failure rollback temp könyvtárban.
- FrameSet: archive kizárt, de `rejected` listában látható.
- Onboarding állapotgép: oldalankénti kihagyás, teljes kihagyás, újranyitás, atomikus config-alkalmazás.
- Teljes Swift tesztcsomag, release build, CLI smoke, natív app indítási smoke, verzió/release note/telepítés.
