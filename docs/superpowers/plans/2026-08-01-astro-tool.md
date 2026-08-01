# Astro-Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Natív macOS SwiftUI app + `astrotool` CLI, ami az asztrofotó-könyvtárat auditálja, pontozza és nyilvántartja — kizárólag jelöl/javasol, soha nem töröl.

**Architecture:** SwiftPM csomag zéró third-party függőséggel. `AstroCore` könyvtár (scan, FITS, SQLite, audit, rate, calib, suggest, new-session), `astrotool` CLI és `AstroToolApp` SwiftUI app egyaránt ezt linkeli. Minden fájlrendszer-írás egyetlen `WriteGuard` komponensen megy át, fehérlistával.

**Tech Stack:** Swift 6 (SwiftPM), rendszer-libsqlite3, Foundation + ImageIO, SwiftUI, Siril CLI (külső bináris, `/Applications/Siril.app/Contents/MacOS/siril-cli`).

**Referencia:** a spec a `docs/superpowers/specs/2026-08-01-astro-tool-design.md`. A vasszabályok (0. szakasz) minden taskra kötelezőek. A képkönyvtár (`/Volumes/images`) jelenleg TCC-blokkolt — MINDEN teszt fixture-fákon fut temp könyvtárban; a valós könyvtárhoz hozzá se nyúlunk.

**Konvenciók minden taskhoz:**
- TDD: előbb a teszt, futtatás (FAIL), implementáció, futtatás (PASS), commit.
- Teszt futtatás: `swift test 2>&1 | tail -20` (a repo gyökeréből).
- Commit után: `git push`.
- Public API-t csak a plan-ben megadott szignatúrákkal vegyél fel — a későbbi taskok ezekre építenek.
- Magyar UI-szövegek az appban; kód/kommentek/commit üzenetek angolul.

---

### Task 1: SPM skeleton + Model típusok

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Sources/AstroCore/Model/Types.swift`
- Create: `Sources/astrotool/main.swift` (minimál: kiírja a verziót)
- Test: `Tests/AstroCoreTests/TypesTests.swift`

- [ ] **Step 1:** `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Astro-Tool",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AstroCore", targets: ["AstroCore"]),
        .executable(name: "astrotool", targets: ["astrotool"]),
    ],
    targets: [
        .target(name: "AstroCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "astrotool", dependencies: ["AstroCore"]),
        .testTarget(name: "AstroCoreTests", dependencies: ["AstroCore"]),
    ]
)
```

`.gitignore`: `.build/`, `build/`, `.DS_Store`, `*.xcodeproj`, `.swiftpm/`.

- [ ] **Step 2:** `Types.swift` — pontosan ezek a public típusok:

```swift
public enum FrameRole: String, Codable, Sendable, CaseIterable {
    case light, flat, dark, bias, master, stack, processed, other
}
public enum LibraryArea: String, Codable, Sendable {
    case sessions, stacks, processed, calibration, other
}
public enum Severity: String, Codable, Sendable {
    case sureError = "sure_error"
    case suspicious
    case probablyIntentional = "probably_intentional"
}
public enum SuggestedAction: Codable, Equatable, Sendable {
    case rename(from: String, to: String)
    case move(from: String, to: String)
    case review(note: String)
}
public struct Finding: Codable, Equatable, Sendable {
    public var severity: Severity
    public var category: String      // pl. "placeholder-name", "orphan-calib-dir"
    public var path: String          // root-relatív
    public var message: String
    public var suggestion: SuggestedAction?
    public init(severity: Severity, category: String, path: String,
                message: String, suggestion: SuggestedAction? = nil)
}
public enum AstroError: Error, Equatable {
    case accessDenied(path: String)   // TCC / EPERM
    case volumeNotMounted(path: String)
    case corruptFITS(path: String, reason: String)
    case databaseError(String)
    case writeForbidden(path: String)
    case sirilNotFound(path: String)
}
```

- [ ] **Step 3:** Teszt: `Finding` JSON round-trip (encode → decode → egyenlő), `Severity.sureError.rawValue == "sure_error"`. Futtatás: FAIL → implementáció → PASS.
- [ ] **Step 4:** `swift build && swift test` zöld. Commit: `feat: SPM skeleton with core model types`, push.

---

### Task 2: Sanitizer + SessionDateParser

**Files:**
- Create: `Sources/AstroCore/NewSession/Sanitizer.swift`
- Create: `Sources/AstroCore/NewSession/SessionDateParser.swift`
- Test: `Tests/AstroCoreTests/SanitizerTests.swift`, `Tests/AstroCoreTests/SessionDateParserTests.swift`

- [ ] **Step 1:** Failing tesztek. Sanitize (az add_new_session.sh szabályai a PROMPT.md szerint — szóköz→`_`, csak `[A-Za-z0-9._-]` marad, több `_` összevonva, szélekről `_` levágva):

```swift
#expect(Sanitizer.sanitize("Heart and Soul Nebula") == "Heart_and_Soul_Nebula")
#expect(Sanitizer.sanitize("IC1805-1848") == "IC1805-1848")
#expect(Sanitizer.sanitize("  M45  Pleiades!! ") == "M45_Pleiades")
#expect(Sanitizer.sanitize("a///b   c") == "a_b_c")
#expect(Sanitizer.sanitize("") == "")
#expect(Sanitizer.makeTarget(catalog: "IC1805-1848", name: "Heart and Soul Nebula")
        == "IC1805-1848_Heart_and_Soul_Nebula")
```

Dátum-parser esetek (a `patterns` az alap `IntentionalPatterns()`):

```swift
// kanonikus
parse("2026-04-06")        // start==end==2026-04-06, isCanonical == true, label == nil
// szándékos minták (nem hiba!)
parse("2026-04-06-2")      // isCanonical false, kind == .runSuffix(2), start == 2026-04-06
parse("2026-02-25_2026-03-15") // kind == .range, start/end kitöltve
parse("2026-04-18-2026-04-19") // kind == .range (kötőjeles változat is)
parse("2026-03-15-OSC")    // kind == .labeled, label == "OSC"
parse("2026-03-15_hibas")  // kind == .labeled, label == "hibas"
// hibák
parse("2026-13-01") == nil // nem valós dátum
parse("Please_enter") == nil
parse("2026-04-31") == nil // nem létező nap
```

- [ ] **Step 2:** API pontosan:

```swift
public enum Sanitizer {
    public static func sanitize(_ s: String) -> String
    public static func makeTarget(catalog: String, name: String) -> String
}
public struct IntentionalPatterns: Codable, Equatable, Sendable {
    public var runSuffix: Bool        // "-N" (default true)
    public var dateRange: Bool        // (default true)
    public var labels: [String]       // default ["hibas", "OSC"] — de bármilyen
                                      // rövid alfanumerikus suffix labelként parsolódik
    public init()
}
public enum SessionDateKind: Equatable, Sendable {
    case canonical
    case runSuffix(Int)
    case range
    case labeled
}
public struct SessionDate: Equatable, Sendable {
    public var raw: String
    public var kind: SessionDateKind
    public var start: String   // "YYYY-MM-DD"
    public var end: String     // == start, ha nem range
    public var label: String?
    public var isCanonical: Bool { kind == .canonical }
}
public enum SessionDateParser {
    public static func parse(_ name: String,
                             patterns: IntentionalPatterns = .init()) -> SessionDate?
}
```

Dátum-validálás `DateComponents` + `Calendar(identifier: .gregorian)`-nel (valós nap ellenőrzése), NE regex-only.

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: sanitizer and session date parser`, push.

---

### Task 3: Config

**Files:**
- Create: `Sources/AstroCore/Config/AstroConfig.swift`
- Test: `Tests/AstroCoreTests/ConfigTests.swift`

- [ ] **Step 1:** Failing tesztek: default értékek; JSON round-trip; részleges JSON betöltése (hiányzó kulcsok defaultra esnek — `init(from:)` `decodeIfPresent`-tel); ismeretlen kulcs nem hiba.
- [ ] **Step 2:** API:

```swift
public struct WideFieldRule: Codable, Equatable, Sendable {
    public var extensions: [String]      // default ["cr3", "tif"]
    public var maxFocalLengthMM: Double  // default 135
    public var nameMarkers: [String]     // default ["wide"]
    public var overrides: [String: Bool] // target név → kézi besorolás
}
public struct CalibRule: Codable, Equatable, Sendable {
    public var tempToleranceC: Double    // default 0.5
    public var exposureToleranceS: Double// default 0.0 (pontos egyezés)
    public var darkMaxAgeMonths: Int     // default 6
}
public struct RatingRule: Codable, Equatable, Sendable {
    public var workers: Int              // default 4
    public var outlierZScore: Double     // default 2.0
    public var sirilPath: String         // default "/Applications/Siril.app/Contents/MacOS/siril-cli"
    public var weights: [String: Double] // default ["fwhm": 0.4, "roundness": 0.2, "starCount": 0.2, "background": 0.2]
}
public struct AstroConfig: Codable, Equatable, Sendable {
    public var rootPath: String            // default "/Volumes/images/Astro"
    public var excludedDirNames: [String]  // default ["tools"] (".astro_tool" MINDIG kizárt, nem config kérdése)
    public var excludedPaths: [String]     // root-relatív, default []
    public var residuePatterns: [String]   // default ["*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store"]
    public var residueDirNames: [String]   // default ["process"]
    public var intentional: IntentionalPatterns
    public var wideField: WideFieldRule
    public var calib: CalibRule
    public var rating: RatingRule
    public init()
    public static func load(from url: URL) throws -> AstroConfig
    public func save(to url: URL, using guard: WriteGuard) throws  // Task 4 után kötendő be; addig file-private write
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: JSON config with defaults`, push.

---

### Task 4: WriteGuard

**Files:**
- Create: `Sources/AstroCore/WriteGuard.swift`
- Test: `Tests/AstroCoreTests/WriteGuardTests.swift`

- [ ] **Step 1:** Failing tesztek temp root-tal:
  - `createSessionTree(target:dateDir:)` létrehozza a `sessions/T/D/{lights,flats,darks,biases}` fákat + README.txt-t, és visszaadja a létrejött URL-eket;
  - session-fa létrehozás **meglévő** dátum-mappára → `AstroError.writeForbidden` (soha nem ír felül);
  - `writeToolFile(relativePath: "reports/x.json", data:)` a `.astro_tool/` alá ír;
  - `writeToolFile(relativePath: "../evil.txt")` → `writeForbidden` (path-traversal tiltva; a feloldott útvonalnak a `.astro_tool` alatt KELL maradnia);
  - `writeToolFile` abszolút úttal → `writeForbidden`.
- [ ] **Step 2:** API:

```swift
public struct WriteGuard: Sendable {
    public let root: URL
    public init(root: URL)
    public var toolDir: URL { root.appendingPathComponent(".astro_tool") }
    @discardableResult
    public func createSessionTree(target: String, dateDir: String,
                                  readme: String) throws -> [URL]
    @discardableResult
    public func writeToolFile(relativePath: String, data: Data) throws -> URL
}
```

Ez a KIZÁRÓLAGOS író-API — a csomagban máshol tilos `FileManager.createDirectory/removeItem/write` a root alá (kivéve tesztek és a temp munkakönyvtár a Rate-ben, ami sosem a root alatt van). `removeItem` az egész `Sources/`-ban elő sem fordulhat.

- [ ] **Step 3:** FAIL → implement → PASS. Kösd be a `AstroConfig.save`-et a WriteGuard-ra (config a `.astro_tool/config.json`). Commit `feat: WriteGuard as the sole filesystem writer`, push.

---

### Task 5: SQLite réteg + séma

**Files:**
- Create: `Sources/AstroCore/DB/SQLite.swift` (vékony wrapper), `Sources/AstroCore/DB/Database.swift` (séma+migráció+DAO-k)
- Test: `Tests/AstroCoreTests/DatabaseTests.swift`

- [ ] **Step 1:** Failing tesztek: in-memory DB (`:memory:`) nyitás + `migrate()`; fájl-rekord upsert és visszaolvasás; `schema_version` = 1; ratings upsert `input_sig` kulccsal; findings insert + lekérdezés severity szerint.
- [ ] **Step 2:** Wrapper API (C API fölött, `import SQLite3`):

```swift
public final class SQLiteDB {
    public init(path: String) throws          // sqlite3_open_v2, WAL mód
    public func exec(_ sql: String) throws
    public func query(_ sql: String, bind: [SQLiteValue],
                      row: (SQLiteRow) throws -> Void) throws
    public func run(_ sql: String, bind: [SQLiteValue]) throws
    public var lastInsertRowID: Int64 { get }
}
public enum SQLiteValue { case text(String), int(Int64), real(Double), null, blob(Data) }
```

Séma (a spec 4. szakasza szerint, szó szerint ez a SQL kerül a `migrate()`-be):

```sql
CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS files(
  id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, size INTEGER NOT NULL,
  mtime REAL NOT NULL, ext TEXT NOT NULL, kind TEXT NOT NULL,
  area TEXT NOT NULL, target TEXT, session_date TEXT, role TEXT NOT NULL,
  content_hash TEXT, scanned_at REAL NOT NULL, missing INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_files_target ON files(target);
CREATE TABLE IF NOT EXISTS fits_meta(
  file_id INTEGER PRIMARY KEY REFERENCES files(id), exptime REAL, gain REAL,
  offset REAL, set_temp REAL, ccd_temp REAL, instrume TEXT, focallen REAL,
  filter TEXT, date_obs TEXT, imagetyp TEXT, naxis1 INTEGER, naxis2 INTEGER,
  header_json TEXT);
CREATE TABLE IF NOT EXISTS ratings(
  file_id INTEGER PRIMARY KEY REFERENCES files(id), fwhm REAL, roundness REAL,
  star_count INTEGER, background REAL, saturated_fraction REAL, score REAL,
  rated_at REAL, siril_version TEXT, input_sig TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS findings(
  id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, severity TEXT NOT NULL,
  category TEXT NOT NULL, path TEXT NOT NULL, message TEXT NOT NULL,
  suggestion_json TEXT);
CREATE TABLE IF NOT EXISTS runs(
  id INTEGER PRIMARY KEY, kind TEXT NOT NULL, started_at REAL NOT NULL,
  finished_at REAL, root TEXT NOT NULL, config_json TEXT);
```

(`targets`/`sessions`/`calib_masters` nézet-szerűen a `files`-ból származtatható — YAGNI: külön tábla csak akkor, ha egy későbbi task igényli.)

DAO-szint: `upsertFile(FileRecord) -> Int64`, `fileID(path:) -> Int64?`, `upsertFITSMeta(fileID:FITSMetaRecord)`, `insertFinding(runID:Finding)`, `findings(runID:) -> [Finding]`, `beginRun(kind:root:config:) -> Int64`, `finishRun(id:)`, `upsertRating(...)`, `rating(fileID:) -> RatingRecord?` — a rekord-structok `Codable` public típusok a `Database.swift`-ben.

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: sqlite layer and schema v1`, push.

---

### Task 6: PathClassifier + Scanner

**Files:**
- Create: `Sources/AstroCore/Scan/PathClassifier.swift`, `Sources/AstroCore/Scan/Scanner.swift`
- Create: `Tests/AstroCoreTests/Fixtures.swift` (közös fixture-fa építő!)
- Test: `Tests/AstroCoreTests/PathClassifierTests.swift`, `Tests/AstroCoreTests/ScannerTests.swift`

- [ ] **Step 1:** `Fixtures.swift`: `makeMessyLibrary(in tmpDir: URL)` — felépíti a PROMPT.md teljes rendetlenség-katalógusát (placeholder mappa, M42-négyes, `bias`+`biases`, `-2`/range/`-OSC`/`_hibas` dátumok, session-fa a stacks alatt, `collected_lights`, hiányzó párok, pár kamu `.fit`/`.seq`/`.DS_Store` fájl, `tools/` almappa csali fájlokkal). Ezt a Task 9+ tesztjei is használják.
- [ ] **Step 2:** Failing tesztek. Classifier (root-relatív út → besorolás):

```swift
classify("sessions/M45_Pleiades/2026-01-10/lights/a.fit")
  // area .sessions, target "M45_Pleiades", dateRaw "2026-01-10", role .light
classify("calibration_library/darks/60sec_-10deg/d.fit")
  // area .calibration, role .dark, target nil
classify("stacks/M42_Orion/2026-01-17/result.fit")   // area .stacks, role .stack
classify("processed/M45_Pleiades/2026-01-10/x.tif")  // area .processed, role .processed
classify("stacks/M42_Orion/2026-01-17/sessions/session1/lights/a.fit")
  // area .stacks — a beágyazott "sessions" NEM teszi .sessions-szé (ez lesz audit-finding)
```

Scanner tesztek: első scan felveszi a fájlokat (a `tools/` és `.astro_tool/` kihagyva); második scan változatlan fájlnál `unchanged`; mtime-touch után `updated`; fájl eltűnése után `missing=1` (a rekord NEM törlődik); `subpath:`-ra szűkített scan csak azt frissíti. EPERM-szimuláció: nem-olvasható mappa (chmod 000) → `AstroError.accessDenied` propagálódik, NEM üres eredmény. (Teszt végén chmod vissza!)
- [ ] **Step 3:** API:

```swift
public struct PathInfo: Equatable, Sendable {
    public var area: LibraryArea
    public var target: String?
    public var dateRaw: String?
    public var role: FrameRole
}
public enum PathClassifier {
    public static func classify(relativePath: String) -> PathInfo
}
public struct ScanSummary: Codable, Sendable {
    public var added: Int, updated: Int, unchanged: Int, missing: Int
}
public final class LibraryScanner {
    public init(config: AstroConfig, db: Database)
    public func scan(subpath: String? = nil,
                     progress: (@Sendable (Int) -> Void)? = nil) throws -> ScanSummary
}
```

Bejárás `FileManager.enumerator` helyett kézzel (rekurzív `contentsOfDirectory(at:includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey,.isDirectoryKey])`), hogy a kizárást belépés ELŐTT dönthessük el, és az EPERM elkapható legyen mappánként. Role finomítás: FITS meta nélkül a mappa-pozícióból (`lights/`→light stb.); kalibrációs könyvtárban a szülő (`darks`→dark).
- [ ] **Step 4:** FAIL → implement → PASS → commit `feat: path classifier and incremental scanner`, push.

---

### Task 7: FITS header parser

**Files:**
- Create: `Sources/AstroCore/FITS/FITSReader.swift`
- Test: `Tests/AstroCoreTests/FITSReaderTests.swift` (+ generált fixture-bájtok a tesztben, NEM bináris fájl a repóban)

- [ ] **Step 1:** Failing tesztek. A teszt kódból gyárt érvényes FITS-t: 80 bájtos kártyák, 2880-ra END+szóköz padding:

```
SIMPLE  =                    T / comment
BITPIX  =                   16
NAXIS   =                    2
NAXIS1  =                 6248
EXPTIME =                300.0
GAIN    =                 100.
SET-TEMP=                -10.0
INSTRUME= 'ZWO ASI2600MC Pro'
IMAGETYP= 'Light Frame'
END
```

Esetek: string kvótok és aposztróf-escape (`''`), `T`/`F` bool, egész/lebegő, kommentek levágása, `END` utáni szemét ignorálva; csonka fájl (nem teljes 2880 blokk) → `AstroError.corruptFITS`; **fz-szimuláció**: primary header `NAXIS=0` + `XTENSION= 'BINTABLE'` második header — a `readHeader` a primary-t és az első extension headert **összefésülve** adja vissza (extension kulcs nyer, `ZNAXIS1`→`NAXIS1` átemeléssel).
- [ ] **Step 2:** API:

```swift
public struct FITSHeader: Sendable {
    public var string(_ key: String) -> String?
    public var double(_ key: String) -> Double?
    public var int(_ key: String) -> Int?
    public var bool(_ key: String) -> Bool?
    public var allCards: [String: String]   // nyers érték-szövegek
}
public enum FITSReader {
    public static func readHeader(url: URL) throws -> FITSHeader
    public static func parse(data: Data) throws -> FITSHeader  // tesztelhető belépő
}
```

Max 64 KiB-ot olvas fájlonként (header-blokkok, amíg END; extension esetén seek a data-blokk átugrásával a NAXIS/BITPIX-ből számolt offsettel).
- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: native FITS header parser incl. .fz layout`, push.

---

### Task 8: CR3/TIF metaadat (ImageIO) + scan-integráció

**Files:**
- Create: `Sources/AstroCore/FITS/ImageMetaReader.swift`
- Modify: `Sources/AstroCore/Scan/Scanner.swift` (FITS/CR3 meta kitöltése scan közben)
- Test: `Tests/AstroCoreTests/ImageMetaReaderTests.swift`

- [ ] **Step 1:** API: `ImageMetaReader.read(url:) -> ImageMeta?` (`focalLengthMM`, `cameraModel`, `dateTaken` — `CGImageSourceCopyPropertiesAtIndex`-ből, EXIF/TIFF dictionary-k). Teszt: kódból generált minimál TIFF-fel (ImageIO tudja írni: `CGImageDestination` + EXIF fókusztáv property), CR3-ra nincs fixture → azt nem teszteljük, best-effort.
- [ ] **Step 2:** Scanner: `.fit/.fits/.fz` → `FITSReader`, eredmény `fits_meta`-ba; `.cr3/.tif` → `ImageMetaReader`, `focallen`/`instrume`/`date_obs` mezőkbe. Meta-olvasás CSAK új/változott fájlnál (inkrementalitás tesztje bővítve).
- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: image metadata via ImageIO, meta capture during scan`, push.

---

### Task 9: Audit szabálymotor + szabályok

**Files:**
- Create: `Sources/AstroCore/Audit/AuditEngine.swift`, `Sources/AstroCore/Audit/Rules.swift`
- Test: `Tests/AstroCoreTests/AuditTests.swift`

- [ ] **Step 1:** Failing tesztek a `makeMessyLibrary` fixture-n (scan után audit). Elvárt findings — kategória, severity, path szerint assertálva:
  - `placeholder-name` / sureError → `stacks/Please_enter_a_value.._Milkyway`
  - `orphan-calib-dir` / sureError → `calibration_library/bias`
  - `duplicated-catalog-prefix` / sureError → `C2025_R3_C2025_R3_Panstarrs*` (mindkettő)
  - `nested-session-tree` / sureError → `stacks/M42_Orion/2026-01-17/sessions`
  - `noncanonical-subdir` / suspicious → `collected_lights`, `paneled_mosaic_process`
  - `assets-without-date` / suspicious → `light_frame_rating_report_assets` célpont-szinten
  - `similar-target-names` / suspicious → az M42-négyes EGY findingben, suggestion `nil` (nincs összevonási javaslat — döntés!)
  - `missing-counterpart` / suspicious → stack session nélkül, processed session+stack nélkül, session stack nélkül (3 külön kategória-altag a detailben)
  - `intentional-date` / probablyIntentional → `-2`, range, `-OSC`, `_hibas` mappák
  - `residue` / suspicious → `.seq`, `.lst`, `.DS_Store`, `r_*` fájlok, `process/` mappa
  - `calib-in-wrong-dir` / sureError → fixture-be tett flat FITS (IMAGETYP='Flat Field') a `lights/` alatt → suggestion `.move`
- [ ] **Step 2:** API:

```swift
public protocol AuditRule: Sendable {
    var id: String { get }
    func evaluate(_ ctx: AuditContext) -> [Finding]
}
public struct AuditContext {  // a DB-ből előre lekérdezett nézetek
    public let config: AstroConfig
    public let db: Database
    public let files: [FileRecord]
    public let targetsByArea: [LibraryArea: Set<String>]
}
public final class AuditEngine {
    public init(config: AstroConfig, db: Database, rules: [AuditRule] = AuditEngine.defaultRules(...))
    public func run() throws -> (runID: Int64, findings: [Finding])
}
```

Hasonló célpontnevek: normalizálás = kisbetű + `_`-összevonás + `wide`/`field`/`nebula` és számjegy-only tokenek eltávolítása; közös katalógus-prefix (regex `^(m|ngc|ic|sh2|c)\d+` illetve `c\d{4}_[a-z]\d`) egyezés → egy csoport.
- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: audit engine with classification rules`, push.

---

### Task 10: Duplikátum-kereső

**Files:**
- Create: `Sources/AstroCore/Audit/DuplicateFinder.swift`
- Test: `Tests/AstroCoreTests/DuplicateFinderTests.swift`

- [ ] **Step 1:** Failing teszt: fixture-be azonos tartalmú fájlok több helyre → méret-előszűrés után SHA-256 (CryptoKit), csoportok; a hash a `files.content_hash`-be cache-elődik (második futás nem hash-el újra — teszt méri, hogy a mtime-változatlan fájl hash-e megmarad). Finding: `duplicate-content` / suspicious, detail: a csoport összes útja, suggestion `.review`.
- [ ] **Step 2:** `public enum DuplicateFinder { static func findDuplicates(db: Database, config: AstroConfig, minSizeBytes: Int64 = 1_048_576) throws -> [Finding] }` — bekötve az AuditEngine default rules közé (külön kapcsolható).
- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: hash-based duplicate detection with cache`, push.

---

### Task 11: Suggestion script generátor

**Files:**
- Create: `Sources/AstroCore/Suggest/SuggestionScript.swift`
- Test: `Tests/AstroCoreTests/SuggestionScriptTests.swift`

- [ ] **Step 1:** Failing tesztek (CSAK szöveg-assert, futtatás soha):
  - fejléc: `#!/bin/bash`, `set -euo pipefail`, figyelmeztető komment + interaktív `read -p "Type YES to continue: "` kapu;
  - minden findinghez komment-blokk (kategória+üzenet), majd `mv` idézőjelezve (`printf '%q'` szemantika — aposztrófos escape);
  - alapból csak sureError kerül bele; `includeSuspicious: true` esetén a suspicious tételek is, de kikommentezve (`# mv ...`);
  - `.review` suggestion → csak komment, parancs nélkül;
  - üres findings → nil (nem generálunk üres scriptet).
- [ ] **Step 2:** API:

```swift
public enum SuggestionScript {
    public static func generate(findings: [Finding], root: URL,
                                includeSuspicious: Bool = false) -> String?
    public static func write(findings: [Finding], root: URL,
                             includeSuspicious: Bool, using: WriteGuard) throws -> URL?
    // → .astro_tool/suggestions/suggestions-<run-timestamp>.sh
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: reviewable suggestion shell scripts`, push.

---

### Task 12: Stats + wide-field besorolás

**Files:**
- Create: `Sources/AstroCore/Stats/StatsQueries.swift`, `Sources/AstroCore/Stats/WideFieldHeuristic.swift`
- Test: `Tests/AstroCoreTests/StatsTests.swift`

- [ ] **Step 1:** Failing tesztek: fixture-be FITS-ek EXPTIME-mal → `perTarget()` integrációs összidő (csak `role == .light` és `area == .sessions` számít!), session-számok, utolsó dátum, expozíció-bontás (`60s × 120`); wide-field: cr3-többségű + `wide` nevű target → `isWideField == true`, override felülír.
- [ ] **Step 2:** API:

```swift
public struct TargetStats: Codable, Sendable {
    public var target: String
    public var isWideField: Bool
    public var totalIntegrationSeconds: Double
    public var sessionDates: [String]
    public var exposureBreakdown: [String: Int]  // "300.0" → darabszám
    public var lastSessionDate: String?
    public var cameras: [String]
    public var filters: [String]
}
public enum StatsQueries {
    public static func perTarget(db: Database, config: AstroConfig) throws -> [TargetStats]
    public static func target(_ name: String, db: Database, config: AstroConfig) throws -> TargetStats?
}
public enum WideFieldHeuristic {
    public static func isWideField(target: String, files: [FileRecord],
                                   meta: [Int64: FITSMetaRecord], rule: WideFieldRule) -> Bool
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: per-target statistics and wide-field heuristic`, push.

---

### Task 13: Kalibrációs lefedettség

**Files:**
- Create: `Sources/AstroCore/Calib/CalibAnalyzer.swift`
- Test: `Tests/AstroCoreTests/CalibTests.swift`

- [ ] **Step 1:** Failing tesztek: fixture `calibration_library/darks/{60sec_-10deg,300sec_-10deg}` + lightok (300 s/−10°, 120 s/−10°) → a 300-as fedett, a 120-as hiányzik (`CalibNeed.matchedMasterPath == nil`); mappanév-parser (`6.8sec_-10deg`, `5.5sec_-10deg` — tizedes!); tűrés-teszt (−9.8° light a −10° darkhoz jó ±0.5-tel); elévülés: master mtime > 6 hónap → `isStale == true`; teendő-szöveg: `"készíts 120 s / −10 °C darkot"`.
- [ ] **Step 2:** API:

```swift
public struct CalibNeed: Codable, Sendable {
    public var kind: FrameRole            // .dark / .flat / .bias
    public var exposureSeconds: Double
    public var tempC: Double?
    public var lightCount: Int
    public var targets: [String]
    public var matchedMasterPath: String?
    public var masterAgeDays: Int?
    public var isStale: Bool
    public var todo: String?              // nil, ha fedett és friss
}
public enum CalibAnalyzer {
    public static func parseMasterDirName(_ name: String) -> (exposureS: Double, tempC: Double)?
    public static func coverage(db: Database, config: AstroConfig,
                                now: Date = .init()) throws -> [CalibNeed]
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: calibration coverage and todo list`, push.

---

### Task 14: Session-párosítás

**Files:**
- Create: `Sources/AstroCore/Calib/SessionMatcher.swift`
- Test: `Tests/AstroCoreTests/SessionMatcherTests.swift`

- [ ] **Step 1:** Failing tesztek: adott target+dátum lightjaihoz megtalálja az ugyanazon session-mappa flat/dark/bias almappáit; ha a session-ben nincs dark, a calibration_library megfelelő (exp/temp) masterét ajánlja; IMAGETYP alapján rossz mappában lévő frame → Finding (`calib-in-wrong-dir`, ugyanaz a kategória mint Task 9-ben — a szabály ide kerül át/innen hívódik, NE legyen duplikálva).
- [ ] **Step 2:** API:

```swift
public struct SessionCalibration: Codable, Sendable {
    public var target: String, date: String
    public var lights: Int
    public var flats: [String], darks: [String], biases: [String]  // path-ok
    public var libraryDark: String?
    public var problems: [Finding]
}
public enum SessionMatcher {
    public static func match(target: String, date: String,
                             db: Database, config: AstroConfig) throws -> SessionCalibration
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: session calibration matching`, push.

---

### Task 15: Rate — natív statisztika + Siril illesztő + pontszám

**Files:**
- Create: `Sources/AstroCore/Rate/NativeStats.swift`, `Sources/AstroCore/Rate/SirilCLI.swift`, `Sources/AstroCore/Rate/Rater.swift`
- Test: `Tests/AstroCoreTests/RateTests.swift`

- [ ] **Step 1:** Failing tesztek:
  - `NativeStats.compute(data:header:)` — a teszt 16-bites FITS-t generál ismert pixelekkel → háttér-medián és szaturált arány pontos;
  - `StarMetricsProvider` protokoll + `MockProvider` a tesztben; `SirilCLI` a valódi (integrációs teszt `try #require(FileManager.default.isExecutableFile(...))`-dal skippel, ha nincs Siril);
  - `SirilCLI` a Siril `stat`/`findstar` kimenet-formátumát parsolja — a parser KÜLÖN függvény (`parseFindstarOutput(_: String) -> StarMetrics?`), fixture-szövegen tesztelve;
  - Siril munkakönyvtár: `FileManager.default.temporaryDirectory` alatt, SOHA nem a root alatt (teszt assertálja a kapott workDir-t);
  - score: session-en belüli z-score súlyozva (config.weights), `isOutlier` ha |z| > outlierZScore a rossz irányban; cache: változatlan `input_sig` → provider nem hívódik (mock számlálóval mérve).
- [ ] **Step 2:** API:

```swift
public struct StarMetrics: Codable, Sendable { public var fwhm: Double; public var roundness: Double; public var starCount: Int }
public protocol StarMetricsProvider: Sendable {
    func metrics(for url: URL, workDir: URL) throws -> StarMetrics
    var version: String { get }
}
public struct SirilCLI: StarMetricsProvider { public init(path: String) throws /* sirilNotFound */ }
public struct FrameScore: Codable, Sendable {
    public var path: String; public var score: Double; public var isOutlier: Bool
    public var metrics: StarMetrics?; public var background: Double?
}
public final class Rater {
    public init(db: Database, config: AstroConfig, provider: StarMetricsProvider?)
    public func rate(target: String, date: String?,
                     progress: (@Sendable (Int, Int) -> Void)?) throws -> [FrameScore]
}
```

- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: hybrid frame rating with siril adapter and cache`, push.

---

### Task 16: CLI

**Files:**
- Create: `Sources/astrotool/ArgParser.swift`, `Sources/astrotool/Commands.swift`; Modify: `Sources/astrotool/main.swift`
- Test: `Tests/AstroCoreTests/CLISmokeTests.swift` (Process-szel hívja a buildelt binárist fixture-root ellen)

- [ ] **Step 1:** Failing smoke tesztek: `astrotool scan --root <tmp> --json` → parsolható JSON `ScanSummary`; `audit --json` → findings tömb; `audit --suggest` → script létrejön a `.astro_tool/suggestions/` alatt; `stats --target M45_Pleiades --json`; `new-session --catalog M45 --name "Pleiades Test" --date 2026-08-01` → fa létrejön, második futásra exit 1 "already exists"; rossz root (nem létező) → exit 1; EPERM-root → exit 2 + magyarázó szöveg stderr-re; `config show --json`.
- [ ] **Step 2:** Alparancsok és opciók (kézzel írt parser, `--flag value` és `--flag=value` egyaránt):

```
astrotool scan   [--root R] [--path SUB] [--json] [--config C]
astrotool audit  [--root R] [--path SUB] [--json] [--suggest] [--include-suspicious] [--no-duplicates]
astrotool rate   [--root R] --target T [--date D] [--json] [--no-siril]
astrotool stats  [--root R] [--target T] [--json]
astrotool calib  [--root R] [--json]            # lefedettség + teendők
astrotool match  [--root R] --target T --date D [--json]
astrotool new-session --catalog CAT --name NAME --date D [--root R] [--json]
astrotool config (show|set KEY VALUE|path) [--json]
astrotool --version | --help
```

Exit kódok: 0 OK, 1 hiba, 2 hozzáférés-megtagadás (TCC üzenettel: melyik beállítást kapcsolja be és hogy újraindítás kell). Emberi kimenet tömör táblázatos; `--json` stabil, dokumentált kulcsokkal (a Codable típusok snake_case encoderrel).
- [ ] **Step 3:** FAIL → implement → PASS → commit `feat: astrotool CLI with all subcommands`, push.

---

### Task 17: SwiftUI app

**Files:**
- Create: `Sources/AstroToolApp/AstroToolApp.swift` (@main), `Sources/AstroToolApp/AppState.swift`,
  `Sources/AstroToolApp/Views/OverviewView.swift`, `AuditView.swift`, `QualityView.swift`,
  `CalibrationView.swift`, `StatsView.swift`, `SettingsView.swift`, `NewSessionSheet.swift`,
  `AccessDeniedView.swift`
- Modify: `Package.swift` (executableTarget `AstroToolApp`)

Nincs UI-unit-teszt (SwiftUI); az elfogadás: `swift build` zöld + az app kézzel indítható. A logika az AppState-ben minimális — minden számítás AstroCore-hívás.

- [ ] **Step 1:** `AppState: @Observable` — root kiválasztás (NSOpenPanel + security-scoped bookmark UserDefaults-ba), DB/Config megnyitás, `runScan()/runAudit()/runRate()` async Task-okban, progress + cancel (`Task.cancel` + a core progress-callbackben `Task.checkCancellation` híd), hibák `AstroError`-ra mintázva.
- [ ] **Step 2:** Fülek (TabView): Áttekintés (összefoglaló számok, utolsó futások, gyors gombok), Audit (findings tábla severity-szűrővel + kategória-szűrő + "Javaslat-script generálása" gomb → megnyitja Finderben), Minőség (target/date választó, score-tábla, outlier kiemelés), Kalibráció (lefedettség-mátrix + teendő-lista), Statisztika (target-tábla: összidő/sessionök/utolsó dátum, deep-sky/wide bontás), Beállítások (config szerkesztő). `NewSessionSheet`: célpont-autocomplete a DB targetjeiből, dátum-picker, validálás Sanitizerrel élőben.
- [ ] **Step 3:** `AccessDeniedView`: ha `accessDenied` → teendő-lista + gomb: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` megnyitása. Kötet-nincs-felcsatolva külön nézet.
- [ ] **Step 4:** Build zöld → commit `feat: SwiftUI app with six tabs`, push.

---

### Task 18: build.sh + ikon + DMG

**Files:**
- Create: `build.sh`, `icon/make_icon.swift`, `Resources/Info.plist` (sablon a build.sh-ban heredoc)

- [ ] **Step 1:** `icon/make_icon.swift`: CoreGraphics-szel 1024×1024 PNG-t rajzol (éjkék háttér, stilizált csillag-halmaz + távcső sziluett vagy spirál — egyszerű, vektoros), majd `iconutil`-lal `.icns` (a script `sips`+`iconutil` hívásokat ír ki, a build.sh futtatja). Minta: `hdrheic-src/icon/make_icon.swift`.
- [ ] **Step 2:** `build.sh` (HDRHeic-minta adaptálva): `swift build -c release --arch arm64` → `build/AstroTool.app` bundle (MacOS/AstroTool = AstroToolApp bináris, Resources/astrotool CLI is bekerül, Info.plist: bundle id `com.zoltanpalotai.astrotool`, `LSMinimumSystemVersion 14.0`, NEM LSUIElement — rendes ablakos app), ad-hoc codesign, `hdiutil create` DMG Applications-symlinkkel, `astrotool` symlink `~/.local/bin`-be.
- [ ] **Step 3:** Futtatás: `./build.sh` → DMG létrejön, `build/AstroTool.app` megnyílik. Commit `build: app bundle, dmg and cli install script`, push.

---

### Task 19: CI + LICENSE + CHANGELOG + README

**Files:**
- Create: `.github/workflows/release.yml`, `LICENSE` (MIT, © 2026 Zoltán Palotai), `CHANGELOG.md`, `README.md`

- [ ] **Step 1:** Workflow: `on: push: tags: ['v*']`, `runs-on: macos-15`, lépések: checkout → `swift test` → `./build.sh` → `gh release create "$GITHUB_REF_NAME" build/AstroTool.dmg build/astrotool.zip --generate-notes` (zip: `ditto -c -k` a CLI-ről). `permissions: contents: write`.
- [ ] **Step 2:** README (magyar): mi ez, vasszabályok ("semmit nem töröl"), telepítés DMG-ből + jobbklikk→Open (nincs notarizálás), TCC Teljes lemez-hozzáférés beállítása képernyőnként leírva, CLI példák minden alparancsra, config-referencia táblázat. CHANGELOG: `## [Unreleased]` + 0.1.0 szekció.
- [ ] **Step 3:** Commit `docs: readme, license, changelog; ci: release workflow`, push. Tag NEM készül még (a v0.1.0 tag a Task 20 után).

---

### Task 20: GitHub Pages letöltőoldal

**Files:**
- Create: `docs/index.html`, `docs/favicon-32.png`, `docs/apple-touch-icon.png`, `docs/og-image.jpg`, `docs/icon.png`

- [ ] **Step 1:** A `hdrheic-src/docs/index.html` mintájára önálló (inline CSS) oldal: app-név, egy mondat, képernyőkép-placeholder helyett feature-lista, nagy Download gomb → `https://github.com/themokx1/Astro-Tool/releases/latest`, OG meta + favicon (a Task 18 ikonjából `sips`-szel méretezve). Sötét téma illik a témához.
- [ ] **Step 2:** Commit `docs: github pages download site`, push. `gh api` PUT `repos/themokx1/Astro-Tool/pages` (branch main, path /docs) — ha jogosultság-hiba, jelezni a felhasználónak kézi bekapcsolásra.
- [ ] **Step 3:** `git tag v0.1.0 && git push origin v0.1.0` → CI Release ellenőrzése (`gh run watch`, `gh release view v0.1.0`).

---

## Self-review (elvégezve)

- **Spec-lefedettség:** funkciók 1–8 ↔ Task 9–11 (takarítás-jelölő+audit+duplikátum), Task 15 (rate), Task 5+12 (DB+stats), Task 13 (calib), Task 14 (párosítás), Task 2+16+17 (new-session CLI+GUI), Task 3 (config); szállítandók ↔ Task 18–20. TCC-hibakezelés: Task 6 (scanner EPERM), 16 (exit 2), 17 (AccessDeniedView).
- **Nyitott (nem placeholder, hanem külső függés):** az `add_new_session.sh` és `tools/rate/` verifikáció a kötet-hozzáférés megadása után külön lépés — a spec 2. szakasza rögzíti.
- **Típus-konzisztencia:** `Database`, `FileRecord`, `FITSMetaRecord` a Task 5-ben definiálva, a 6/9/12–15 ugyanezeket használja; `WriteGuard` (Task 4) a 11/16/17 íróműveleteié; `IntentionalPatterns` (Task 2) a Config (Task 3) mezője.
