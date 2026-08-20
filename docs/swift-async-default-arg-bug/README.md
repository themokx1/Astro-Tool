# Swift fordítóhiba: modulhatárt átlépő async alapértelmezett argumentum

**Talált verzió:** Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), macOS 26.5, arm64
**Dátum:** 2026-08-16
**Állapot:** az AstroToolban javítva; **upstream bejelentés még nem történt**

Ez a mappa egy önálló, 28 soros reprodukáló. Nem tartozik a build-hez, nem része egyetlen targetnek sem — azért él a repóban, mert enélkül a hiba magyarázata elveszne, és a javítás úgy nézne ki, mint egy indokolatlan stílusválasztás.

## A hiba

Egy **async** alapértelmezett argumentum egy `public init`-en implicit closure-t és hozzá async-function-pointer rekordot (`…fu_Tu`) emittál `weak private external`-ként — **minden** fordítási egységbe, amelyik használja az alapértelmezést. A fordító **eltérő async-context méretet ír** a definiáló és a kliens modulban.

Az AstroToolban mérve, ugyanarra a szimbólumra:

```
NightsStore.swift.o              context size = 80   ← definiáló modul (AstroUI)
GlobalSearchStoreTests.swift.o   context size = 64   ← kliens modul
NightsStoreTests.swift.o         context size = 64
```

A linker a függvénytörzset és a méret-rekordot **függetlenül** koaleszkálja. Ha a 64-es rekord marad a 80-as törzs mellé, a folytatás-funklet 16 bájttal túlír a `swift_task_alloc`-kal foglalt kereten, és szétveri a task-allokátor következő blokkjának fejlécét. A következő `swift_task_dealloc` `SIGABRT`-ol:

```
freed pointer was not the last allocation
```

## Két csapda, ami napokat vihet el

**1. Az AddressSanitizer tiszta marad.** Ez nem a malloc-heap sérülése, hanem a Swift **task-allokátoráé**. A backtrace `libswift_Concurrency.dylib` → `swift_task_dealloc`. Az ASan, a TSan és a `MallocScribble` nem műszerezi ezt a réteget, tehát mind a hármat le lehet futtatni eredménytelenül. A hibaüzenet szövege félrevezet: malloc-hibának hangzik.

**2. A változtatás visszavonása „javítani" látszik.** Bármely szerkesztés az érintett fájlban megváltoztatja az objektumfájl méretét, és ezzel átbillentheti, melyik weak definíciót tartja meg a linker. Ezért tűnik úgy, mintha egy ártatlan, nem kapcsolódó módosítás okozná — és ezért oldja meg a visszaállítás. Az nem javítás, csak az érme másik oldala. Aki ezt nem tudja, a következő módosításnál újra találkozik vele, és megint mást fog hibáztatni.

## A javítás

Ne legyen modulhatárt átlépő async alapértelmezett argumentum. Vedd `Optional`-ként, és oldd fel az inicializáló **törzsében** — az csak a definiáló modulban él:

```swift
public init(provider: Provider? = nil) {
    self.provider = provider ?? Self.production
}
```

Ekkor a rekord `non-external` lesz, egyszer emittálódik, és a kliens fordítási egységek nem gyártanak belőle másolatot. A javítás után az AstroTool mind a hét érintett rekordja megszűnt `weak` lenni.

## Amit a reprodukáló mutat

- `Store` — a hibás alak (`@MainActor`, `= Store.production`)
- `NonIsolatedDefault` — explicit closure-ként írva **sem** segít
- `NoActor` — `@MainActor` **nem** feltétele a hibának
- `OptionalDefault` — a javított alak
- `makeInLib()` — a definiáló modulon belüli használat, ami **nem** tér el

Futtatás: `swift build`, majd a `LibA` és az `AppB` objektumfájljaiban ugyanannak a `…fu_Tu` szimbólumnak a második 4 bájtos szava (a context-méret) összevetése.

## Miért nem robbant a szállított AstroToolban

Minden produkciós példányosítás az `AstroUI`-n **belül** volt, ahol a fordítási egységek egyetértenek. Ez véletlen, nem védelem: az első `NightsStore()` az `AstroToolApp`-ban ugyanezt az érmedobást hozza a szállított binárisba, egy olyan store-ban, ami a felhasználó pótolhatatlan képkönyvtárát olvassa. Ezért lett mind a hét hely javítva, nem csak az, amelyik elbukott.

## Gát

Forrás-vizsgálat ezt **nem** tudja elkapni — a hiba csak a lefordított objektumfájlokban látszik. A `Tests/AstroUITests/AsyncContextSizeGateTests.swift` a Mach-O szimbólumtáblákat olvassa, és bukik, ha ugyanaz a weak `…Tu` szimbólum két különböző context-mérettel szerepel.

**Korlátja:** a `.build` alatti objektumokat nézi, tehát a `swift test` útvonalat fedi. Egy Xcode-vezérelt build DerivedDatába rak, azt **nem** fedi.
