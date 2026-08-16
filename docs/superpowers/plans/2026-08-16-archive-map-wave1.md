# Archívum-térkép (1. hullám) — implementációs terv

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Library` oldal helyére egy olyan Archívum-képernyő kerül, amely egyetlen mondattal megmondja, mi vár a felhasználóra, egyetlen sávval megmutatja, hol van a könyvtára összes bájtja, és kategóriánként összevont teendő-kártyákkal — mindegyiken egy valóban működő gombbal — kínálja fel a helyreállítást.

**Architecture:** Két új, tisztán olvasó lekérdezés az `AstroApplication` rétegben (`ArchiveMapQuery`, `ArchiveTaskQuery`), amelyek a meglévő read-only index-adatbázisból dolgoznak egyetlen-egyetlen `GROUP BY` menetben. Új séma, új tábla, migráció **nincs**. A felület egy `@Observable` store (`ArchiveStore`) mögött ül, minden számítás `async load()`-ban fut generation-guarddal, semmi a `body`-ban. A karantén-végrehajtás a már meglévő, tesztelt `CleanupPreviewQuery` + `QuarantineApplyCommand` úton megy — ez a hullám egyetlen mutációs kódutat sem ír újra.

**Tech Stack:** Swift 6.3, SwiftUI, swift-testing (`@Test` / `#expect` / `#require`), SQLite (`AstroCore.SQLiteDB`), `@Observable` store-ok, `OperationHost`.

**Spec:** `docs/superpowers/specs/2026-08-16-archive-map-ux-redesign-design.md`

**Ág / worktree:** `codex/v2.0.0-ui-rework` a `.worktrees/v200-ui-rework` worktree-ben. Minden parancs onnan fut.

**Hatókör-határ:** ez a hullám **nem** nyúl a navigáció négy-szekciós átszabásához (3. hullám), **nem** cseréli le az `AstroTokens`-t (2. hullám), és **nem** emeli a deployment targetet macOS 26-ra (a 2. hullám első lépése). A színeket a mostani `AstroTokens.Color` tokenekből veszi, és egy új, szűk `ArchivePalette` bővítményt vezet be az öt adatkategória-színre — ezt a 2. hullám olvasztja bele a teljes rendszerbe.

---

## Fájlszerkezet

**Létrehozandó:**

| Fájl | Felelősség |
|---|---|
| `Sources/AstroApplication/Features/Archive/ArchiveClass.swift` | A `files.role` → megjelenítési kategória leképezés, egyetlen helyen |
| `Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift` | Az archívum bájt-bontása összesen és célpontonként, plusz a visszanyerhető mennyiség |
| `Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift` | Az audit-találatok kategóriánként összevont, végrehajtható teendőkké alakítása |
| `Sources/AstroUI/Features/Archive/ArchivePalette.swift` | Az öt adatkategória-szín (a 2. hullám olvasztja az `AstroTokens`-be) |
| `Sources/AstroUI/Features/Archive/ArchiveStore.swift` | Betöltés, hibaállapot, generation-guard, teendő-akciók továbbítása |
| `Sources/AstroUI/Features/Archive/ArchiveStripView.swift` | Az archívum-sáv, a visszanyerhető-sín és a jelmagyarázat |
| `Sources/AstroUI/Features/Archive/ArchiveTaskCard.swift` | Egyetlen teendő-kártya |
| `Sources/AstroUI/Features/Archive/ArchiveTargetRowView.swift` | Egyetlen célpont-sor a sávjaival |
| `Sources/AstroUI/Features/Archive/ArchiveView.swift` | Az oldal összeállítása: ítélet-mondat, fejléc, lista, állapotok, toolbar-akciók |
| `Tests/AstroApplicationTests/ArchiveClassTests.swift` | |
| `Tests/AstroApplicationTests/ArchiveMapQueryTests.swift` | |
| `Tests/AstroApplicationTests/ArchiveTaskQueryTests.swift` | |
| `Tests/AstroUITests/ArchiveStoreTests.swift` | |
| `Tests/AstroUITests/ArchiveSurfaceTests.swift` | Az ítélet-mondat ágai, a sáv-normalizálás, a kapu-szabályok |

**Módosítandó:**

| Fájl | Változás |
|---|---|
| `Sources/AstroApplication/Features/Library/AuditRunCommand.swift` | A verify-ág útvonalas `integrity` találatokat is kiír |
| `Sources/AstroUI/App/V2RootView.swift` | A `.library` route az `ArchiveView`-t rajzolja; a Health sidebar-gyereksor törlése; a `.health` route átirányítása |
| `Sources/AstroUI/Inspector/FrameInspector.swift:24` | A „Move to Archive…" gomb törlése |
| `Sources/AstroUI/Features/Review/ReviewWorkspace.swift:10,202-203,438-450,508-539` | Az `ArchivePreviewSheet` és állapota törlése |
| `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings` | Az új felületi kulcsok magyar fordítása |
| `Tests/AstroUITests/V2PolishSurfaceTests.swift` | Új kapu: teendő-kártya végrehajtható akció nélkül nem létezhet |

**Törlendő:**

| Fájl | Miért |
|---|---|
| `Sources/AstroUI/Features/Library/LibraryView.swift` | Teljes tartalma az `ArchiveView`-ba kerül (3 számláló-kártya → a sáv; a három gomb → toolbar-akciók) |

---

## Task 1: `ArchiveClass` — a szerep-leképezés egyetlen helyen

**Files:**
- Create: `Sources/AstroApplication/Features/Archive/ArchiveClass.swift`
- Test: `Tests/AstroApplicationTests/ArchiveClassTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@testable import AstroApplication
import Testing

struct ArchiveClassTests {
    @Test("Every scanner role maps to exactly one archive class")
    func rolesMapToClasses() {
        #expect(ArchiveClass(role: "light") == .light)
        #expect(ArchiveClass(role: "flat") == .calibration)
        #expect(ArchiveClass(role: "dark") == .calibration)
        #expect(ArchiveClass(role: "bias") == .calibration)
        #expect(ArchiveClass(role: "stack") == .stack)
        #expect(ArchiveClass(role: "processed") == .processed)
        #expect(ArchiveClass(role: "other") == .unclassified)
    }

    @Test("An unknown or empty role falls back to unclassified, never crashing")
    func unknownRoleFallsBack() {
        #expect(ArchiveClass(role: "somethingNew") == .unclassified)
        #expect(ArchiveClass(role: "") == .unclassified)
        #expect(ArchiveClass(role: "LIGHT") == .light, "role matching is case-insensitive")
    }

    @Test("The display order is stable and puts collected data first")
    func displayOrderIsStable() {
        #expect(ArchiveClass.displayOrder == [.light, .stack, .processed, .calibration, .unclassified])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveClassTests`
Expected: FAIL — `cannot find 'ArchiveClass' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The five buckets the Archive map renders a library's bytes into. This is
/// the ONLY place `files.role` (the scanner's own vocabulary, owned by
/// `AstroCore.Scanner`) is translated into a presentation category -- every
/// other Archive type takes an `ArchiveClass` and never sees a raw role
/// string. An unrecognized role lands in `.unclassified` rather than
/// throwing: the scanner may learn new roles, and a map that refuses to draw
/// is worse than one that honestly says "I don't know what this is".
public enum ArchiveClass: String, CaseIterable, Codable, Sendable {
    case light
    case calibration
    case stack
    case processed
    case unclassified

    public init(role: String) {
        switch role.lowercased() {
        case "light": self = .light
        case "flat", "dark", "bias": self = .calibration
        case "stack": self = .stack
        case "processed": self = .processed
        default: self = .unclassified
        }
    }

    /// Left-to-right order in the strip and the legend: what you collected
    /// first, what you made from it next, the supporting frames after that,
    /// and what the app could not identify last.
    public static let displayOrder: [ArchiveClass] = [
        .light, .stack, .processed, .calibration, .unclassified
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveClassTests`
Expected: PASS — 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroApplication/Features/Archive/ArchiveClass.swift Tests/AstroApplicationTests/ArchiveClassTests.swift
git commit -m "feat: map scanner roles to archive display classes"
```

---

## Task 2: `ArchiveMapQuery` — az archívum bájt-bontása

**Files:**
- Create: `Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift`
- Test: `Tests/AstroApplicationTests/ArchiveMapQueryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct ArchiveMapQueryTests {
    /// Builds a throwaway index database with the exact column set
    /// `ArchiveMapQuery` reads, plus the `runs`/`findings` tables the
    /// reclaim and freshness queries need.
    private static func makeIndexDatabase(includeAuditTables: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveMap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            """)
        // NGC 7000: 2 nights, 300 bytes of light, 100 of stack, 100 of flat.
        try db.exec("""
            INSERT INTO files VALUES
              ('a.fit', 200, 'NGC_7000', '2026-08-01', 'light',  'sessions', 0),
              ('b.fit', 100, 'NGC_7000', '2026-08-02', 'light',  'sessions', 0),
              ('c.tif', 100, 'NGC_7000', '2026-08-02', 'stack',  'stacks',   0),
              ('d.fit', 100, 'NGC_7000', '2026-08-01', 'flat',   'sessions', 0),
              ('e.fit', 400, 'M42',      '2026-01-05', 'stack',  'stacks',   0),
              ('gone.fit', 9999, 'M42',  '2026-01-05', 'light',  'sessions', 1);
            """)
        if includeAuditTables {
            try db.exec("""
                CREATE TABLE runs(id INTEGER PRIMARY KEY, kind TEXT, started_at REAL);
                CREATE TABLE findings(id INTEGER PRIMARY KEY, run_id INTEGER, severity TEXT,
                                      category TEXT, path TEXT, message TEXT);
                """)
            try db.exec("INSERT INTO runs VALUES(1,'scan',1000.0),(2,'audit',2000.0);")
            try db.exec("""
                INSERT INTO findings VALUES
                  (1, 2, 'suspicious', 'residue', 'c.tif', 'leftover'),
                  (2, 2, 'suspicious', 'duplicate-content', 'e.fit', 'copy');
                """)
        }
        return path
    }

    @Test("The snapshot totals only non-missing files and groups them by class")
    func totalsExcludeMissingFiles() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.totalBytes == 900)
        #expect(snapshot.fileCount == 5)
        #expect(snapshot.targetCount == 2)
        #expect(snapshot.nightCount == 3)

        let light = try #require(snapshot.slices.first { $0.archiveClass == .light })
        #expect(light.bytes == 300)
        #expect(light.fileCount == 2)
        let stack = try #require(snapshot.slices.first { $0.archiveClass == .stack })
        #expect(stack.bytes == 500)
        #expect(snapshot.slices.contains { $0.archiveClass == .calibration && $0.bytes == 100 })
        #expect(!snapshot.slices.contains { $0.archiveClass == .processed },
                "a class with no bytes produces no slice at all")
    }

    @Test("Target rows are sorted by size and carry their own night and class breakdown")
    func targetRowsAreSortedBySize() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.rows.map(\.id) == ["NGC_7000", "M42"])
        let ngc = try #require(snapshot.rows.first)
        #expect(ngc.totalBytes == 500)
        #expect(ngc.nightCount == 2)
        #expect(ngc.fileCount == 4)
        #expect(ngc.displayName == "NGC 7000")
        #expect(ngc.slices.map(\.archiveClass) == [.light, .stack, .calibration],
                "slices come back in ArchiveClass.displayOrder, dropping empty classes")
    }

    @Test("Reclaimable bytes come from the latest audit run's residue and duplicates")
    func reclaimableComesFromLatestAudit() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.reclaimableBytes == 500)
        #expect(snapshot.reclaimableFiles == 2)
        let m42 = try #require(snapshot.rows.first { $0.id == "M42" })
        #expect(m42.reclaimableBytes == 400)
        let ngc = try #require(snapshot.rows.first { $0.id == "NGC_7000" })
        #expect(ngc.reclaimableBytes == 100)
    }

    @Test("A library whose index has no audit tables still renders a map")
    func missingAuditTablesStillProducesAMap() async throws {
        let index = try Self.makeIndexDatabase(includeAuditTables: false)
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.totalBytes == 900)
        #expect(snapshot.reclaimableBytes == 0)
        #expect(snapshot.lastAuditAt == nil)
        #expect(!snapshot.isAuditStale, "no audit at all is not staleness -- it is its own state")
    }

    @Test("An audit older than the last scan is reported as stale")
    func auditOlderThanScanIsStale() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("INSERT INTO runs VALUES(3,'scan',3000.0);")

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()
        #expect(snapshot.isAuditStale)
    }

    @Test("An empty library produces an empty, non-throwing snapshot")
    func emptyLibrary() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveMapEmpty-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            """)

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: path).snapshot()
        #expect(snapshot.totalBytes == 0)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.slices.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveMapQueryTests`
Expected: FAIL — `cannot find 'ArchiveMapQuery' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import AstroCore
import Foundation

public struct ArchiveSlice: Equatable, Sendable, Identifiable {
    public var id: ArchiveClass { archiveClass }
    public let archiveClass: ArchiveClass
    public let fileCount: Int
    public let bytes: Int64

    public init(archiveClass: ArchiveClass, fileCount: Int, bytes: Int64) {
        self.archiveClass = archiveClass
        self.fileCount = fileCount
        self.bytes = bytes
    }
}

public struct ArchiveTargetRow: Equatable, Sendable, Identifiable {
    /// The target's own folder name -- the stable identity everything else
    /// (findings, routes, Finder reveal) keys off.
    public let id: String
    /// The catalog designation when the folder name yields one
    /// (`TargetNameResolver`), otherwise the folder name with underscores
    /// turned into spaces. Deliberately NOT `ResolvedTargetName.displayName`:
    /// that one appends `CatalogNames.hungarian`'s common name, which would
    /// put Hungarian text on an English UI (V2 UI/UX audit pattern P1). The
    /// localized common name is a wave-2 addition.
    public let displayName: String
    public let nightCount: Int
    public let fileCount: Int
    public let totalBytes: Int64
    public let slices: [ArchiveSlice]
    public let reclaimableBytes: Int64
    public let reclaimableFiles: Int

    public init(
        id: String, displayName: String, nightCount: Int, fileCount: Int,
        totalBytes: Int64, slices: [ArchiveSlice],
        reclaimableBytes: Int64, reclaimableFiles: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.nightCount = nightCount
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.slices = slices
        self.reclaimableBytes = reclaimableBytes
        self.reclaimableFiles = reclaimableFiles
    }
}

public struct ArchiveMapSnapshot: Equatable, Sendable {
    public let totalBytes: Int64
    public let fileCount: Int
    public let targetCount: Int
    public let nightCount: Int
    public let slices: [ArchiveSlice]
    public let rows: [ArchiveTargetRow]
    public let reclaimableBytes: Int64
    public let reclaimableFiles: Int
    public let lastScanAt: Date?
    public let lastAuditAt: Date?

    /// `true` only when BOTH runs exist and the scan is the newer one --
    /// then the reclaim figures describe a library state that has already
    /// moved on. "Never audited" is a separate state the UI words
    /// differently, so it deliberately does not report as stale here.
    public var isAuditStale: Bool {
        guard let lastScanAt, let lastAuditAt else { return false }
        return lastScanAt > lastAuditAt
    }

    public init(
        totalBytes: Int64, fileCount: Int, targetCount: Int, nightCount: Int,
        slices: [ArchiveSlice], rows: [ArchiveTargetRow],
        reclaimableBytes: Int64, reclaimableFiles: Int,
        lastScanAt: Date?, lastAuditAt: Date?
    ) {
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.targetCount = targetCount
        self.nightCount = nightCount
        self.slices = slices
        self.rows = rows
        self.reclaimableBytes = reclaimableBytes
        self.reclaimableFiles = reclaimableFiles
        self.lastScanAt = lastScanAt
        self.lastAuditAt = lastAuditAt
    }
}

/// Reads the whole archive's byte distribution out of the read-only index
/// database in three `GROUP BY` passes -- never row-by-row, and never
/// touching the image library itself. Same read path as
/// `LibraryHealthQuery.readSnapshot`.
public struct ArchiveMapQuery: Sendable {
    /// The audit categories whose findings count as reclaimable space.
    /// `residue` is Siril/DSS intermediate output; `duplicate-content` is a
    /// byte-identical extra copy. Nothing else is ever counted as
    /// reclaimable -- a structural error is a problem to fix, not space to
    /// win back.
    static let reclaimableCategories = ["residue", "duplicate-content"]

    private let indexDatabase: URL
    private let metadata: MetadataStore?

    init(indexDatabaseForTesting: URL, metadata: MetadataStore? = nil) {
        self.indexDatabase = indexDatabaseForTesting
        self.metadata = metadata
    }

    public static func production(rootURL: URL, metadata: MetadataStore? = nil) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(indexDatabaseForTesting: storage.indexDatabase, metadata: resolvedMetadata)
    }

    public func snapshot() async throws -> ArchiveMapSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        var bytesByTargetAndClass: [String: [ArchiveClass: (files: Int, bytes: Int64)]] = [:]
        var nightsByTarget: [String: Set<String>] = [:]
        try db.query(
            """
            SELECT COALESCE(target, ''), COALESCE(role, ''), COALESCE(session_date, ''),
                   COUNT(*), COALESCE(SUM(size), 0)
            FROM files WHERE missing = 0
            GROUP BY target, role, session_date;
            """
        ) { row in
            let target = row.string(0) ?? ""
            let archiveClass = ArchiveClass(role: row.string(1) ?? "")
            let night = row.string(2) ?? ""
            let files = Int(row.int64(3) ?? 0)
            let bytes = row.int64(4) ?? 0
            guard !target.isEmpty else { return }
            var classes = bytesByTargetAndClass[target] ?? [:]
            let existing = classes[archiveClass] ?? (files: 0, bytes: 0)
            classes[archiveClass] = (files: existing.files + files, bytes: existing.bytes + bytes)
            bytesByTargetAndClass[target] = classes
            if !night.isEmpty { nightsByTarget[target, default: []].insert(night) }
        }

        let reclaim = try Self.reclaimByTarget(db: db, metadata: metadata)
        let rows = Self.buildRows(
            bytesByTargetAndClass: bytesByTargetAndClass,
            nightsByTarget: nightsByTarget,
            reclaimByTarget: reclaim.byTarget
        )
        let slices = Self.aggregateSlices(rows.flatMap(\.slices))
        let (lastScanAt, lastAuditAt) = try Self.lastRuns(db: db)

        return ArchiveMapSnapshot(
            totalBytes: rows.reduce(0) { $0 + $1.totalBytes },
            fileCount: rows.reduce(0) { $0 + $1.fileCount },
            targetCount: rows.count,
            nightCount: nightsByTarget.values.reduce(0) { $0 + $1.count },
            slices: slices,
            rows: rows,
            reclaimableBytes: reclaim.totalBytes,
            reclaimableFiles: reclaim.totalFiles,
            lastScanAt: lastScanAt,
            lastAuditAt: lastAuditAt
        )
    }

    private static func buildRows(
        bytesByTargetAndClass: [String: [ArchiveClass: (files: Int, bytes: Int64)]],
        nightsByTarget: [String: Set<String>],
        reclaimByTarget: [String: (files: Int, bytes: Int64)]
    ) -> [ArchiveTargetRow] {
        bytesByTargetAndClass.map { target, classes in
            let slices = ArchiveClass.displayOrder.compactMap { archiveClass -> ArchiveSlice? in
                guard let value = classes[archiveClass], value.bytes > 0 || value.files > 0 else { return nil }
                return ArchiveSlice(archiveClass: archiveClass, fileCount: value.files, bytes: value.bytes)
            }
            let reclaim = reclaimByTarget[target] ?? (files: 0, bytes: 0)
            let resolved = TargetNameResolver.resolve(folderName: target)
            return ArchiveTargetRow(
                id: target,
                displayName: resolved.designation
                    ?? target.replacingOccurrences(of: "_", with: " "),
                nightCount: nightsByTarget[target]?.count ?? 0,
                fileCount: slices.reduce(0) { $0 + $1.fileCount },
                totalBytes: slices.reduce(0) { $0 + $1.bytes },
                slices: slices,
                reclaimableBytes: reclaim.bytes,
                reclaimableFiles: reclaim.files
            )
        }
        .sorted { lhs, rhs in
            // Biggest first; folder name breaks a tie so the order is stable
            // across runs rather than following dictionary iteration order.
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.id < rhs.id
        }
    }

    private static func aggregateSlices(_ slices: [ArchiveSlice]) -> [ArchiveSlice] {
        var totals: [ArchiveClass: (files: Int, bytes: Int64)] = [:]
        for slice in slices {
            let existing = totals[slice.archiveClass] ?? (files: 0, bytes: 0)
            totals[slice.archiveClass] = (
                files: existing.files + slice.fileCount,
                bytes: existing.bytes + slice.bytes
            )
        }
        return ArchiveClass.displayOrder.compactMap { archiveClass in
            guard let value = totals[archiveClass], value.bytes > 0 || value.files > 0 else { return nil }
            return ArchiveSlice(archiveClass: archiveClass, fileCount: value.files, bytes: value.bytes)
        }
    }

    private static func reclaimByTarget(
        db: SQLiteDB, metadata: MetadataStore?
    ) throws -> (byTarget: [String: (files: Int, bytes: Int64)], totalFiles: Int, totalBytes: Int64) {
        guard try tableExists(db, name: "findings"), try tableExists(db, name: "runs") else {
            return ([:], 0, 0)
        }
        let placeholders = reclaimableCategories.map { "'\($0)'" }.joined(separator: ",")
        var byTarget: [String: (files: Int, bytes: Int64)] = [:]
        var totalFiles = 0
        var totalBytes: Int64 = 0
        try db.query(
            """
            SELECT COALESCE(f.target, ''), COUNT(*), COALESCE(SUM(f.size), 0)
            FROM findings d JOIN files f ON f.path = d.path
            WHERE d.run_id = (SELECT MAX(id) FROM runs WHERE kind = 'audit')
              AND d.category IN (\(placeholders)) AND f.missing = 0
            GROUP BY f.target;
            """
        ) { row in
            let target = row.string(0) ?? ""
            let files = Int(row.int64(1) ?? 0)
            let bytes = row.int64(2) ?? 0
            totalFiles += files
            totalBytes += bytes
            guard !target.isEmpty else { return }
            byTarget[target] = (files: files, bytes: bytes)
        }
        return (byTarget, totalFiles, totalBytes)
    }

    private static func lastRuns(db: SQLiteDB) throws -> (scan: Date?, audit: Date?) {
        guard try tableExists(db, name: "runs") else { return (nil, nil) }
        var scan: Date?
        var audit: Date?
        try db.query(
            "SELECT kind, MAX(started_at) FROM runs WHERE kind IN ('scan','audit') GROUP BY kind;"
        ) { row in
            guard let seconds = row.double(1) else { return }
            let date = Date(timeIntervalSince1970: seconds)
            if row.string(0) == "scan" { scan = date } else { audit = date }
        }
        return (scan, audit)
    }

    private static func tableExists(_ db: SQLiteDB, name: String) throws -> Bool {
        var found = false
        try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
            bind: [.text(name)]
        ) { _ in found = true }
        return found
    }
}
```

> **Note on `metadata`:** acknowledged finding groups are filtered in Task 3, where the task grouping happens and the ack key is meaningful. `ArchiveMapQuery` keeps the parameter so the two queries construct identically from one call site; it is unused in the reclaim maths on purpose — an acknowledged residue group still occupies disk, and the map reports physical truth.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveMapQueryTests`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift Tests/AstroApplicationTests/ArchiveMapQueryTests.swift
git commit -m "feat: read the archive byte map from the index"
```

---

## Task 3: `ArchiveTaskQuery` — összevont, végrehajtható teendők

**Files:**
- Create: `Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift`
- Test: `Tests/AstroApplicationTests/ArchiveTaskQueryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct ArchiveTaskQueryTests {
    private static func makeIndexDatabase(withFindings: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveTasks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            CREATE TABLE runs(id INTEGER PRIMARY KEY, kind TEXT, started_at REAL);
            CREATE TABLE findings(id INTEGER PRIMARY KEY, run_id INTEGER, severity TEXT,
                                  category TEXT, path TEXT, message TEXT);
            """)
        try db.exec("""
            INSERT INTO files VALUES
              ('r_pp_a.fit', 1000, 'M42', '2026-01-05', 'other', 'sessions', 0),
              ('r_pp_b.fit', 2000, 'M42', '2026-01-05', 'other', 'sessions', 0),
              ('dupe.fit',    500, 'M42', '2026-01-05', 'dark',  'calibration', 0),
              ('flats/x.tif', 300, 'C2025', '2026-04-18', 'other', 'sessions', 0);
            """)
        try db.exec("INSERT INTO runs VALUES(1,'scan',1000.0),(2,'audit',2000.0);")
        if withFindings {
            try db.exec("""
                INSERT INTO findings VALUES
                  (1, 2, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover'),
                  (2, 2, 'suspicious', 'residue', 'r_pp_b.fit', 'leftover'),
                  (3, 2, 'suspicious', 'duplicate-content', 'dupe.fit', 'copy'),
                  (4, 2, 'sure_error', 'calib-in-wrong-dir', 'flats/x.tif', 'not a flat');
                """)
        }
        return path
    }

    @Test("Findings collapse into one card per kind, never one row per finding")
    func findingsCollapseIntoCards() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

        #expect(tasks.count == 3)
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 2)
        #expect(intermediates.bytes == 3000)
        #expect(intermediates.severity == .reclaim)
        #expect(intermediates.evidencePaths == ["r_pp_a.fit", "r_pp_b.fit"])

        let duplicates = try #require(tasks.first { $0.kind == .duplicateContent })
        #expect(duplicates.bytes == 500)

        let misplaced = try #require(tasks.first { $0.kind == .misplacedCalibration })
        #expect(misplaced.severity == .error)
        #expect(misplaced.action == .revealInFinder(path: "flats/x.tif"))
    }

    @Test("Cards are ordered errors first, then by reclaimable size")
    func cardsAreOrderedBySeverityThenSize() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

        #expect(tasks.map(\.kind) == [.misplacedCalibration, .intermediateFiles, .duplicateContent])
    }

    @Test("At most three evidence paths are carried, however many findings there are")
    func evidenceIsCappedAtThree() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
            INSERT INTO files VALUES('r_pp_c.fit', 10, 'M42', '2026-01-05', 'other', 'sessions', 0),
                                    ('r_pp_d.fit', 10, 'M42', '2026-01-05', 'other', 'sessions', 0);
            INSERT INTO findings VALUES(5, 2, 'suspicious', 'residue', 'r_pp_c.fit', 'leftover'),
                                       (6, 2, 'suspicious', 'residue', 'r_pp_d.fit', 'leftover');
            """)

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 4)
        #expect(intermediates.evidencePaths.count == 3)
    }

    @Test("A library that was never audited gets exactly one honest card")
    func neverAuditedProducesTheAuditCard() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let db = try SQLiteDB(path: index.path)
        try db.exec("DELETE FROM runs WHERE kind = 'audit';")

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(tasks.map(\.kind) == [.auditNeverRun])
        #expect(tasks[0].severity == .info)
        #expect(tasks[0].action == .runAudit)
    }

    @Test("An audited, clean library produces no cards at all")
    func cleanLibraryProducesNoCards() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(tasks.isEmpty)
    }

    @Test("Acknowledged groups are dropped from the cards")
    func acknowledgedGroupsAreDropped() async throws {
        let index = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        try await metadata.acknowledgeFindingGroup(
            category: "archive-task", groupKey: ArchiveTaskKind.duplicateContent.rawValue, note: nil
        )

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index, metadata: metadata).tasks()
        #expect(!tasks.contains { $0.kind == .duplicateContent })
        #expect(tasks.contains { $0.kind == .intermediateFiles })
    }

    @Test("Every produced card carries an executable action")
    func everyCardIsActionable() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(!tasks.isEmpty)
        for task in tasks {
            #expect(task.action != .unavailable, "\(task.kind) produced a card with no action")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveTaskQueryTests`
Expected: FAIL — `cannot find 'ArchiveTaskQuery' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import AstroCore
import Foundation

public enum ArchiveTaskKind: String, CaseIterable, Sendable {
    case intermediateFiles
    case duplicateContent
    case misplacedCalibration
    case brokenNames
    case integrity
    /// Not a problem -- the honest "I have not looked yet" state, which
    /// still deserves a card because it has a real button.
    case auditNeverRun

    /// The raw `findings.category` values that roll up into this card.
    var findingCategories: [String] {
        switch self {
        case .intermediateFiles: ["residue"]
        case .duplicateContent: ["duplicate-content"]
        case .misplacedCalibration: ["calib-in-wrong-dir", "orphan-calib-dir"]
        case .brokenNames: ["placeholder-name", "duplicated-catalog-prefix",
                            "nested-session-tree", "noncanonical-subdir"]
        case .integrity: ["integrity"]
        case .auditNeverRun: []
        }
    }
}

public enum ArchiveTaskSeverity: String, Sendable {
    case error
    case reclaim
    case attention
    case info

    var rank: Int {
        switch self {
        case .error: 0
        case .reclaim: 1
        case .attention: 2
        case .info: 3
        }
    }
}

public enum ArchiveTaskAction: Equatable, Sendable {
    /// Pushes the existing quarantine preview, pre-selected to these
    /// `CleanupPreviewGroup.category` values.
    case previewQuarantine(categories: [String])
    case compareDuplicates
    case revealInFinder(path: String)
    case runAudit
    /// Only ever produced internally, and filtered out before `tasks()`
    /// returns -- a card with no action must not reach the UI. Deliberately
    /// NOT named `none`: `ArchiveTaskAction.none` collides with
    /// `Optional.none` at every `??` and comparison site.
    case unavailable
}

public struct ArchiveTask: Equatable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ArchiveTaskKind
    public let severity: ArchiveTaskSeverity
    public let affectedFileCount: Int
    public let bytes: Int64
    /// Up to three real paths from the underlying findings, so the card can
    /// show what it is talking about instead of only a count.
    public let evidencePaths: [String]
    public let action: ArchiveTaskAction

    /// The acknowledgement key this card is silenced by -- one key per
    /// KIND, so acknowledging survives a re-audit that renumbers every
    /// individual finding.
    public static let ackCategory = "archive-task"
    public var ackGroupKey: String { kind.rawValue }

    public init(
        kind: ArchiveTaskKind, severity: ArchiveTaskSeverity,
        affectedFileCount: Int, bytes: Int64,
        evidencePaths: [String], action: ArchiveTaskAction
    ) {
        self.kind = kind
        self.severity = severity
        self.affectedFileCount = affectedFileCount
        self.bytes = bytes
        self.evidencePaths = evidencePaths
        self.action = action
    }
}

/// Turns the latest audit run's findings into at most six cards -- one per
/// `ArchiveTaskKind` -- instead of one row per finding. The 3 228 residue
/// findings on the reference library are one card, not 3 228 rows.
///
/// Hard rule, gated by `ArchiveTaskQueryTests.everyCardIsActionable`: a card
/// only exists if its `action` can actually run. Titles and explanatory
/// sentences are NOT built here -- they are localized UI strings keyed off
/// `kind`, so this type stays free of presentation text.
public struct ArchiveTaskQuery: Sendable {
    public static let evidenceLimit = 3

    private let indexDatabase: URL
    private let metadata: MetadataStore?

    init(indexDatabaseForTesting: URL, metadata: MetadataStore? = nil) {
        self.indexDatabase = indexDatabaseForTesting
        self.metadata = metadata
    }

    public static func production(rootURL: URL, metadata: MetadataStore? = nil) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(indexDatabaseForTesting: storage.indexDatabase, metadata: resolvedMetadata)
    }

    public func tasks() async throws -> [ArchiveTask] {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        guard try Self.hasAuditRun(db: db) else {
            return [ArchiveTask(
                kind: .auditNeverRun, severity: .info,
                affectedFileCount: 0, bytes: 0, evidencePaths: [], action: .runAudit
            )]
        }

        var grouped: [ArchiveTaskKind: (files: Int, bytes: Int64, paths: [String])] = [:]
        try db.query(
            """
            SELECT d.category, d.path, COALESCE(f.size, 0)
            FROM findings d LEFT JOIN files f ON f.path = d.path
            WHERE d.run_id = (SELECT MAX(id) FROM runs WHERE kind = 'audit')
            ORDER BY d.id;
            """
        ) { row in
            let category = row.string(0) ?? ""
            let path = row.string(1) ?? ""
            let size = row.int64(2) ?? 0
            guard let kind = ArchiveTaskKind.allCases.first(where: {
                $0.findingCategories.contains(category)
            }) else { return }
            var entry = grouped[kind] ?? (files: 0, bytes: 0, paths: [])
            entry.files += 1
            entry.bytes += size
            if entry.paths.count < Self.evidenceLimit, !path.isEmpty { entry.paths.append(path) }
            grouped[kind] = entry
        }

        let ackedKeys: Set<String>
        if let metadata {
            ackedKeys = Set(try await metadata.acknowledgements().map(\.ackKey))
        } else {
            ackedKeys = []
        }

        return grouped.compactMap { kind, entry -> ArchiveTask? in
            let ackKey = MetadataStore.ackKey(category: ArchiveTask.ackCategory, groupKey: kind.rawValue)
            guard !ackedKeys.contains(ackKey) else { return nil }
            let action = Self.action(for: kind, entry: entry)
            guard action != .unavailable else { return nil }
            return ArchiveTask(
                kind: kind, severity: Self.severity(for: kind),
                affectedFileCount: entry.files, bytes: entry.bytes,
                evidencePaths: entry.paths, action: action
            )
        }
        .sorted {
            ($0.severity.rank, -$0.bytes, $0.kind.rawValue)
                < ($1.severity.rank, -$1.bytes, $1.kind.rawValue)
        }
    }

    private static func severity(for kind: ArchiveTaskKind) -> ArchiveTaskSeverity {
        switch kind {
        case .misplacedCalibration, .brokenNames, .integrity: .error
        case .intermediateFiles, .duplicateContent: .reclaim
        case .auditNeverRun: .info
        }
    }

    private static func action(
        for kind: ArchiveTaskKind, entry: (files: Int, bytes: Int64, paths: [String])
    ) -> ArchiveTaskAction {
        switch kind {
        case .intermediateFiles:
            .previewQuarantine(categories: kind.findingCategories)
        case .duplicateContent:
            .compareDuplicates
        case .misplacedCalibration, .brokenNames, .integrity:
            // Honest gate: with no concrete path there is nothing to open,
            // so no card is produced at all (see this type's doc comment).
            entry.paths.first.map { ArchiveTaskAction.revealInFinder(path: $0) } ?? .unavailable
        case .auditNeverRun:
            .runAudit
        }
    }

    private static func hasAuditRun(db: SQLiteDB) throws -> Bool {
        var found = false
        try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'runs';"
        ) { _ in found = true }
        guard found else { return false }
        var hasRun = false
        try db.query("SELECT COUNT(*) FROM runs WHERE kind = 'audit';") { row in
            hasRun = (row.int64(0) ?? 0) > 0
        }
        return hasRun
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveTaskQueryTests`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift Tests/AstroApplicationTests/ArchiveTaskQueryTests.swift
git commit -m "feat: collapse audit findings into actionable archive tasks"
```

---

## Task 4: Az integritás-találatok jussanak el a térképig

**Ennek a tasknak a premisszája megváltozott.** Az eredeti szöveg abból indult ki, hogy a verify-futás nem ír fájlszintű találatot, és az `AstroCore`-t kell bővíteni. A kód elolvasása után ez **nem igaz**:

- `FixityVerifier.run` (`Sources/AstroCore/Audit/FixityVerifier.swift:425`) **már ma is** beszúrja a találatokat `db.insertFinding`-gel, teljes fájlútvonallal.
- A `FixityVerifier.findings(from:)` (`:366`) négy kategóriát gyárt: `content-changed` (sureError, néma korrupció), `modified-in-place` (suspicious), `modified` (probablyIntentional, szándékos szerkesztés) és `verify-read-error` (suspicious).
- Ezek viszont **saját, `"verify"` típusú futásba** kerülnek, nem az `"audit"`-ba.

**A valódi hézag tehát nem az `AstroCore`-ban van, hanem az `ArchiveTaskQuery`-ben:** az csak a `(SELECT MAX(id) FROM runs WHERE kind = 'audit')` futást olvassa, így a verify találatai **láthatatlanok** a térkép számára. `AstroCore`-t ez a task **nem** módosít.

Egy második, kisebb döntés is benne van: a `modified` kategória kimarad. Az azt jelenti, hogy a fájl mérete és ideje is változott — szándékos szerkesztés, nem adatvesztés. Riasztani érte azt tanítaná a felhasználónak, hogy hagyja figyelmen kívül a kártyákat.

És egy harmadik: a „állítsd vissza biztonsági mentésből" tanács **csak** a `content-changed`-re igaz. Egy olvasási hiba nem korrupció, hanem meg nem erősített állapot. Ezért egyetlen `integrity` kártya helyett **kettő** lesz, hogy mindkettő a saját, igaz tanácsát adhassa.

**Files:**
- Modify: `Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift`
- Modify: `Tests/AstroApplicationTests/ArchiveTaskQueryTests.swift`

- [ ] **Step 1: Write the failing tests**

Bővítsd a fixture-t egy verify-futással és annak találataival:

```swift
try db.exec("INSERT INTO runs VALUES(3,'verify',3000.0);")
try db.exec("""
    INSERT INTO files VALUES
      ('rot.fit', 700, 'M42', '2026-01-05', 'light', 'sessions', 0),
      ('unread.fit', 50, 'M42', '2026-01-05', 'light', 'sessions', 0),
      ('edited.fit', 60, 'M42', '2026-01-05', 'light', 'sessions', 0);
    """)
try db.exec("""
    INSERT INTO findings VALUES
      (10, 3, 'sure_error', 'content-changed',   'rot.fit',    'bitrot'),
      (11, 3, 'suspicious', 'verify-read-error', 'unread.fit', 'unreadable'),
      (12, 3, 'probably_intentional', 'modified', 'edited.fit', 'edited on purpose');
    """)
```

```swift
@Test("Corruption from the latest verify run becomes its own card")
func corruptionFromVerifyRunBecomesACard() async throws {
    let index = try Self.makeIndexDatabase()
    let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

    let corruption = try #require(tasks.first { $0.kind == .corruption })
    #expect(corruption.severity == .error)
    #expect(corruption.affectedFileCount == 1)
    #expect(corruption.bytes == 700)
    #expect(corruption.evidencePaths == ["rot.fit"])
    #expect(corruption.action == .revealInFinder(path: "rot.fit"))
}

@Test("A file that could not be read is reported as unconfirmed, not as corruption")
func unreadableFileIsNotReportedAsCorruption() async throws {
    let index = try Self.makeIndexDatabase()
    let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

    let unconfirmed = try #require(tasks.first { $0.kind == .unverified })
    #expect(unconfirmed.severity == .attention)
    #expect(unconfirmed.evidencePaths == ["unread.fit"])
    #expect(!(try #require(tasks.first { $0.kind == .corruption }).evidencePaths.contains("unread.fit")))
}

@Test("A deliberately edited file raises nothing at all")
func deliberatelyModifiedFileRaisesNothing() async throws {
    let index = try Self.makeIndexDatabase()
    let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

    #expect(!tasks.contains { $0.evidencePaths.contains("edited.fit") },
            "'modified' means the user changed the file on purpose -- alarming about it teaches the user to ignore cards")
}

@Test("Audit and verify findings are read from their own latest runs, independently")
func auditAndVerifyRunsAreReadIndependently() async throws {
    let index = try Self.makeIndexDatabase()
    let db = try SQLiteDB(path: index.path)
    // A newer audit run must not hide the older verify run's findings.
    try db.exec("INSERT INTO runs VALUES(4,'audit',4000.0);")
    try db.exec("INSERT INTO findings VALUES(13, 4, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover');")

    let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
    #expect(tasks.contains { $0.kind == .corruption }, "the verify run's findings survive a newer audit run")
    let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
    #expect(intermediates.affectedFileCount == 1, "only the LATEST audit run's residue counts")
}
```

A meglévő hét teszt várt értékeit igazítsd az új fixture-höz. **Ne** lazíts egyetlen meglévő asszerción sem: ha egy nem elégíthető ki helyes kóddal, állj meg és jelentsd.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter ArchiveTaskQueryTests`
Expected: FAIL — `type 'ArchiveTaskKind' has no member 'corruption'`

- [ ] **Step 3: Implement**

Az `ArchiveTaskKind`-ból **töröld** az `integrity` esetet, és tedd a helyére ezt a kettőt:

```swift
    /// Silent corruption: the bytes changed while size and timestamp did
    /// not. The only finding here that means data may already be lost, and
    /// the only one for which "restore from a backup copy" is true advice.
    case corruption
    /// The verify pass could not confirm these files -- it read an error, or
    /// found an in-place rewrite. Not proof of loss, so it must not borrow
    /// corruption's language.
    case unverified
```

és a `findingCategories`-ben:

```swift
        case .corruption: ["content-changed"]
        case .unverified: ["modified-in-place", "verify-read-error"]
```

A `"modified"` kategória **egyik** listában sem szerepel — ez szándékos, és a `deliberatelyModifiedFileRaisesNothing` teszt pinneli.

A `severity(for:)`-ben: `.corruption` → `.error`, `.unverified` → `.attention`.

Az `action(for:entry:)`-ben mindkettő a `revealInFinder` ágra megy, ugyanazzal az „útvonal nélkül nincs kártya" szabállyal.

A `tasks()` lekérdezésében a `WHERE` feltétel **két** futást fogadjon el, nem egyet:

```sql
WHERE d.run_id IN (
        (SELECT MAX(id) FROM runs WHERE kind = 'audit'),
        (SELECT MAX(id) FROM runs WHERE kind = 'verify')
      )
```

A `hasAuditRun` **változatlan marad**: az „még nem néztem át a könyvtáradat" állapot továbbra is az audit hiányát jelenti, nem a verify-ét. Egy sosem futtatott verify nem ugyanaz, mint egy sosem futtatott audit, és nem szabad ugyanazt a mondatot kapnia.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter ArchiveTaskQueryTests`
Expected: PASS — 11 tests

- [ ] **Step 5: Run the whole suite**

Run: `swift test --no-parallel 2>&1 | tail -20`
Expected: minden zöld (2320+ teszt). Az `AuditRunCommandTests` és a `FixityVerifier` tesztjei **nem** változhatnak — ez a task nem nyúlt hozzájuk.

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift Tests/AstroApplicationTests/ArchiveTaskQueryTests.swift
git commit -m "fix: surface verify findings on the archive page"
```


## Task 5: `ArchivePalette` — az öt adatkategória-szín

**Files:**
- Create: `Sources/AstroUI/Features/Archive/ArchivePalette.swift`
- Modify: `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import AstroApplication
import SwiftUI

/// The Archive map's five data-category colors, derived from narrowband
/// false-color mapping: what you collected reads as OIII teal, what you made
/// from it reads as SII gold, calibration reads violet, and what the app
/// could not identify reads as a muted slate -- grey because the app knows
/// nothing about it.
///
/// These encode a DATA CATEGORY and never a status. Status stays on
/// `AstroTokens.Color.success` / `.warning` / `.danger`, which
/// `V2PolishSurfaceTests.noBareStatusColorLiterals` already gates. Wave 2
/// folds this enum into a rebuilt `AstroTokens`; it lives beside its only
/// consumer until then.
enum ArchivePalette {
    static func color(for archiveClass: ArchiveClass) -> Color {
        switch archiveClass {
        case .light: dataLight
        case .stack: dataStack
        case .processed: dataProcessed
        case .calibration: dataCalibration
        case .unclassified: dataUnclassified
        }
    }

    static let dataLight = dynamic(dark: 0x46CDD6, light: 0x0E9AA4)
    static let dataStack = dynamic(dark: 0xF0B429, light: 0xB87B0C)
    static let dataProcessed = dynamic(dark: 0xC78F1D, light: 0x8E5E08)
    static let dataCalibration = dynamic(dark: 0x9B87E8, light: 0x6A54C4)
    static let dataUnclassified = dynamic(dark: 0x48536B, light: 0x98A3B8)

    private static func dynamic(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
```

- [ ] **Step 2: Extend the color gate so the new palette is not mistaken for a leak**

A `V2PolishSurfaceTests.noHardcodedColorLiterals` ma minden `Features/` alatti színliterált tilt. Vedd fel az `ArchivePalette.swift`-et a kivételek közé — **név szerint, nem mintával** —, és írj mellé kommentet, hogy ez az egyetlen fájl, ami hexát definiálhat, mert ez a paletta forrása.

```swift
// A single allowed exception: ArchivePalette.swift IS the palette
// definition, so it is the one file under Features/ that may contain hex
// literals. Everything else must read from it or from AstroTokens.
private static let colorLiteralExemptFiles: Set<String> = ["ArchivePalette.swift"]
```

- [ ] **Step 3: Write the failing gate test**

```swift
@Test("Archive views read their category colors from ArchivePalette, never inline")
func archiveViewsUseThePalette() throws {
    let archiveDirectory = "Sources/AstroUI/Features/Archive"
    for file in try filenames(under: archiveDirectory) where file != "ArchivePalette.swift" {
        let source = try contents("\(archiveDirectory)/\(file)")
        #expect(!source.contains("NSColor(hex:"), "\(file) defines its own color")
        #expect(!source.contains("Color(red:"), "\(file) defines its own color")
    }
}
```

- [ ] **Step 4: Run the gates**

Run: `swift test --no-parallel --filter V2PolishSurfaceTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchivePalette.swift Tests/AstroUITests/V2PolishSurfaceTests.swift
git commit -m "feat: add the archive category palette"
```

---

## Task 6: `ArchiveStore` — betöltés generation-guarddal

**Files:**
- Create: `Sources/AstroUI/Features/Archive/ArchiveStore.swift`
- Test: `Tests/AstroUITests/ArchiveStoreTests.swift`

> **Kötelező olvasmány a task előtt:** `Sources/AstroUI/Features/Planning/PlanningStore.swift` fejléc-kommentje. Az ott felsorolt hét fagyás-antipattern mindegyike érvényes ide is. Külön kiemelve: az `init` **mellékhatás-mentes**, semmilyen lekérdezés nem futhat computed getterben, és minden setter azonosérték-őrrel kezdődik.

- [ ] **Step 1: Write the failing test**

```swift
@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
struct ArchiveStoreTests {
    @Test("A fresh store holds nothing and has run nothing")
    func initIsSideEffectFree() {
        let store = ArchiveStore(
            mapFactory: { _ in Issue.record("init must not query"); throw CancellationError() },
            taskFactory: { _ in Issue.record("init must not query"); throw CancellationError() }
        )
        #expect(store.snapshot == nil)
        #expect(store.tasks.isEmpty)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("Loading publishes the snapshot and the tasks together")
    func loadPublishesBoth() async throws {
        let store = ArchiveStore(
            mapFactory: { _ in .stub(totalBytes: 1000) },
            taskFactory: { _ in [.stub(kind: .intermediateFiles, bytes: 400)] }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"))

        #expect(store.snapshot?.totalBytes == 1000)
        #expect(store.tasks.count == 1)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test("A failing query surfaces its message instead of leaving a silent blank page")
    func loadFailureIsVisible() async throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "index unreadable" } }
        let store = ArchiveStore(
            mapFactory: { _ in throw Boom() },
            taskFactory: { _ in [] }
        )
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/lib"))

        #expect(store.snapshot == nil)
        #expect(store.errorMessage == "index unreadable")
        #expect(!store.isLoading)
    }

    @Test("A superseded load never overwrites a newer result")
    func staleLoadIsDiscarded() async throws {
        let gate = AsyncGate()
        let store = ArchiveStore(
            mapFactory: { url in
                if url.lastPathComponent == "slow" { await gate.wait() }
                return .stub(totalBytes: url.lastPathComponent == "slow" ? 1 : 2)
            },
            taskFactory: { _ in [] }
        )

        let slow = Task { await store.load(rootURL: URL(fileURLWithPath: "/tmp/slow")) }
        // Let the slow load reach its suspension point inside the factory
        // before the second one starts and bumps the generation.
        while await !gate.isWaiting { await Task.yield() }
        await store.load(rootURL: URL(fileURLWithPath: "/tmp/fast"))
        await gate.open()
        await slow.value

        #expect(store.snapshot?.totalBytes == 2, "the superseded slow load must not overwrite")
        #expect(!store.isLoading, "the superseded load must not clear the newer load's flag either")
    }

    @Test("Setting the same class filter twice does not republish")
    func filterSetterGuardsEqualValues() {
        let store = ArchiveStore(mapFactory: { _ in .stub(totalBytes: 0) }, taskFactory: { _ in [] })
        store.selectedClass = .light
        let first = store.filterChangeCount
        store.selectedClass = .light
        #expect(store.filterChangeCount == first)
    }
}

/// A one-shot suspension point the test opens by hand, so "a slow load is
/// overtaken by a fast one" is deterministic rather than a race the test
/// hopes to win.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
```

A `.stub(...)` segédfüggvények az `ArchiveMapSnapshot`-ra és az `ArchiveTask`-ra a tesztfájl alján, `private extension`-ként éljenek — ne a produkciós kódban.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveStoreTests`
Expected: FAIL — `cannot find 'ArchiveStore' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import AstroApplication
import Foundation
import Observation

@MainActor
@Observable
public final class ArchiveStore {
    public typealias MapFactory = @Sendable (URL) async throws -> ArchiveMapSnapshot
    public typealias TaskFactory = @Sendable (URL) async throws -> [ArchiveTask]

    public private(set) var snapshot: ArchiveMapSnapshot?
    public private(set) var tasks: [ArchiveTask] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// Which class the user clicked in the strip, filtering the target rows
    /// below it. `nil` = no filter.
    public var selectedClass: ArchiveClass? {
        didSet {
            guard oldValue != selectedClass else { return }
            filterChangeCount += 1
        }
    }
    /// Test-visible proof the equal-value guard above actually fires.
    public private(set) var filterChangeCount = 0

    /// Rows after the strip filter -- a stored property recomputed on load
    /// and on filter change, never a computed getter (see this file's
    /// required reading: a query in a computed getter is what froze
    /// Planning).
    public private(set) var visibleRows: [ArchiveTargetRow] = []

    private let mapFactory: MapFactory
    private let taskFactory: TaskFactory
    private var generation = 0

    public init(
        mapFactory: @escaping MapFactory = { rootURL in
            try await ArchiveMapQuery.production(rootURL: rootURL).snapshot()
        },
        taskFactory: @escaping TaskFactory = { rootURL in
            try await ArchiveTaskQuery.production(rootURL: rootURL).tasks()
        }
    ) {
        self.mapFactory = mapFactory
        self.taskFactory = taskFactory
    }

    public func load(rootURL: URL) async {
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        do {
            let map = try await mapFactory(rootURL)
            let loaded = try await taskFactory(rootURL)
            guard token == generation else { return }
            snapshot = map
            tasks = loaded
            recomputeVisibleRows()
        } catch {
            guard token == generation else { return }
            snapshot = nil
            tasks = []
            visibleRows = []
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }

    public func recomputeVisibleRows() {
        guard let snapshot else { visibleRows = []; return }
        guard let selectedClass else { visibleRows = snapshot.rows; return }
        visibleRows = snapshot.rows.filter { row in
            row.slices.contains { $0.archiveClass == selectedClass }
        }
    }
}
```

Egészítsd ki a `selectedClass` `didSet`-jét `recomputeVisibleRows()` hívással a számláló növelése után.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveStoreTests`
Expected: PASS — 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchiveStore.swift Tests/AstroUITests/ArchiveStoreTests.swift
git commit -m "feat: add the archive store with a generation guard"
```

---

## Task 7: `ArchiveStripView` — a sáv, a sín és a jelmagyarázat

**Files:**
- Create: `Sources/AstroUI/Features/Archive/ArchiveStripView.swift`
- Test: `Tests/AstroUITests/ArchiveSurfaceTests.swift`

- [ ] **Step 1: Write the failing test for the normalization rule**

A szélesség-számítás tiszta függvény, ezért közvetlenül tesztelhető — nem kell hozzá nézetet renderelni.

```swift
@testable import AstroUI
import AstroApplication
import Testing

struct ArchiveStripLayoutTests {
    @Test("Slice fractions sum to one")
    func fractionsSumToOne() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 300),
            .init(archiveClass: .stack, fileCount: 1, bytes: 600),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
        #expect(layout.segments.map(\.archiveClass) == [.light, .stack, .calibration])
    }

    @Test("Slices under half a percent merge into one residual segment")
    func tinySlicesMerge() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 99_800),
            .init(archiveClass: .stack, fileCount: 1, bytes: 100),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(layout.segments.count == 2, "the two 0.1% slices collapse into one residual")
        #expect(layout.segments.last?.isResidual == true)
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
    }

    @Test("An empty archive produces no segments and never divides by zero")
    func emptyArchiveHasNoSegments() {
        #expect(ArchiveStripLayout(slices: []).segments.isEmpty)
        #expect(ArchiveStripLayout(slices: [.init(archiveClass: .light, fileCount: 0, bytes: 0)]).segments.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveStripLayoutTests`
Expected: FAIL — `cannot find 'ArchiveStripLayout' in scope`

- [ ] **Step 3: Write the layout type and the view**

```swift
import AstroApplication
import SwiftUI

/// Pure layout maths for the archive strip, kept separate from the view so
/// it can be tested without rendering: a 1px-wide segment is unclickable and
/// unreadable, so anything under `residualThreshold` of the archive merges
/// into a single residual segment rather than being drawn as a sliver.
struct ArchiveStripLayout {
    static let residualThreshold = 0.005

    struct Segment: Equatable {
        let archiveClass: ArchiveClass?
        let fraction: Double
        var isResidual: Bool { archiveClass == nil }
    }

    let segments: [Segment]

    init(slices: [ArchiveSlice]) {
        let total = slices.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { segments = []; return }
        var kept: [Segment] = []
        var residual = 0.0
        for slice in slices {
            let fraction = Double(slice.bytes) / Double(total)
            if fraction >= Self.residualThreshold {
                kept.append(Segment(archiveClass: slice.archiveClass, fraction: fraction))
            } else {
                residual += fraction
            }
        }
        if residual > 0 { kept.append(Segment(archiveClass: nil, fraction: residual)) }
        segments = kept
    }
}
```

A nézet ugyanabban a fájlban. Egyetlen `GeometryReader` a sáv köré (nem szegmensenként — az `N` darab `GeometryReader` `N` layout-menetet jelentene), és a szélességek abból a **egy** mért szélességből származnak:

```swift
struct ArchiveStripView: View {
    let slices: [ArchiveSlice]
    let reclaimableBytes: Int64
    let totalBytes: Int64
    let selectedClass: ArchiveClass?
    let onSelect: (ArchiveClass?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stored, computed once in `init` -- not a computed getter. `body` may
    /// run many times per layout pass, and this codebase's freeze history is
    /// entirely "work that ran in a getter on the body path".
    private let layout: ArchiveStripLayout

    init(
        slices: [ArchiveSlice], reclaimableBytes: Int64, totalBytes: Int64,
        selectedClass: ArchiveClass?, onSelect: @escaping (ArchiveClass?) -> Void
    ) {
        self.slices = slices
        self.reclaimableBytes = reclaimableBytes
        self.totalBytes = totalBytes
        self.selectedClass = selectedClass
        self.onSelect = onSelect
        self.layout = ArchiveStripLayout(slices: slices)
    }

    private var reclaimFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(reclaimableBytes) / Double(totalBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment, width: proxy.size.width)
                    }
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Capsule()
                .fill(AstroTokens.Color.hairline)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(AstroTokens.Color.danger)
                            .frame(width: proxy.size.width * reclaimFraction)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: reclaimFraction)
                .accessibilityIdentifier("v2.archive.reclaim-rail")
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ArchiveStripLayout.Segment, width: CGFloat) -> some View {
        let isDimmed = selectedClass != nil && selectedClass != segment.archiveClass
        Rectangle()
            .fill(segment.archiveClass.map(ArchivePalette.color(for:)) ?? AstroTokens.Color.hairline)
            .opacity(isDimmed ? 0.35 : 1)
            .frame(width: max(0, width * segment.fraction))
            .onTapGesture { onSelect(segment.archiveClass) }
    }
}
```

> A `HStack` `spacing: 1.5` és a `max(0, …)` együtt garantálja, hogy egy nagyon keskeny ablakban se essen negatívba egyetlen szélesség sem. A szegmensek összege a rés-szélességek miatt néhány ponttal kisebb a teljes szélességnél — ez szándékos, a `clipShape` így is teljes sávot rajzol.

Minden szegmens kapjon:
- `.help(...)` — „Stack · 233,4 GB · 5 626 fájl"
- `.accessibilityLabel(...)` és `.accessibilityValue(...)`
- `.accessibilityIdentifier("v2.archive.strip.<rawValue>")` (a reziduális szegmens: `v2.archive.strip.residual`)
- `.onTapGesture { onSelect(segment.archiveClass) }`

A sín alatta: 5pt magas `Capsule`, `AstroTokens.Color.hairline` alapon, benne `AstroTokens.Color.danger` kitöltés a `reclaimableBytes / totalBytes` arányban, `.animation(.snappy(duration: 0.45), value: fraction)` — a `@Environment(\.accessibilityReduceMotion)` igaz értékénél `nil` animációval.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveStripLayoutTests`
Expected: PASS — 3 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchiveStripView.swift Tests/AstroUITests/ArchiveSurfaceTests.swift
git commit -m "feat: draw the archive strip with a reclaim rail"
```

---

## Task 8: `ArchiveTaskCard` és `ArchiveTargetRowView`

**Files:**
- Create: `Sources/AstroUI/Features/Archive/ArchiveTaskCard.swift`
- Create: `Sources/AstroUI/Features/Archive/ArchiveTargetRowView.swift`

- [ ] **Step 1: Write `ArchiveTaskCard`**

A kártya bemenete egyetlen `ArchiveTask` és egy `onAction: (ArchiveTaskAction) -> Void`. A megjelenítési szövegek **itt** élnek, `kind` szerint kapcsolva, `LocalizedStringKey`-ként (nem `String`-ként — lásd a lokalizációs jegyzetet a `MetricCard`-on):

| `kind` | Cím | Magyarázat | Gombfelirat |
|---|---|---|---|
| `.intermediateFiles` | „Stacking leftovers" | „Intermediate output from stacking — regenerable from your raw frames. Your light frames are not touched." | „Preview Quarantine…" |
| `.duplicateContent` | „Byte-identical copies" | „Files whose exact contents already exist elsewhere. You choose which copy stays." | „Compare Copies…" |
| `.misplacedCalibration` | „Calibration in the wrong folder" | „These files sit in a calibration folder but are not calibration frames, so this night's matching is silently wrong." | „Reveal in Finder" |
| `.brokenNames` | „Folder names that break scanning" | „A nested session tree, an unfilled template name, or a duplicated catalog prefix." | „Reveal in Finder" |
| `.integrity` | „Checksum mismatch" | „A file's contents changed since it was indexed. Restore it from a backup copy." | „Reveal in Finder" |
| `.auditNeverRun` | „Not checked yet" | „I have not looked through this library yet. The check reads only — it never moves or deletes anything." | „Run Check" |

A fő érték (`headlineValue`) a kártyában számolódik: `.reclaim` súlyosságnál `AstroFormat.bytes(task.bytes)`, egyébként `task.affectedFileCount.formatted()`. Ha még nincs `AstroFormat` (2. hullám vezeti be), írj egy `private func` formázót ebbe a fájlba, és hagyj `// wave 2: move to AstroFormat` kommentet.

Az `evidencePaths` legfeljebb három sorban, `.font(.caption.monospaced())`, `.textSelection(.enabled)`, `.lineLimit(1)`, `.truncationMode(.head)` — az útvonal vége a beszédes rész.

Egyetlen gomb, `.buttonStyle(.borderedProminent)` csak `.reclaim` és `.info` esetén, `.bordered` az `.error` esetén (a hiba-kártyáé nem „csináld meg", hanem „nézd meg"). Kontextusmenü: `Mark as Acknowledged…`, ami a `MetadataStore.acknowledgeFindingGroup(category: ArchiveTask.ackCategory, groupKey: task.ackGroupKey, note:)`-t hívja.

Accessibility ID: `v2.archive.task.<kind.rawValue>`, a gombé `v2.archive.task.<kind.rawValue>.action`.

A váz:

```swift
struct ArchiveTaskCard: View {
    let task: ArchiveTask
    let onAction: (ArchiveTaskAction) -> Void
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AstroTokens.Spacing.section) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(headlineValue)
                        .font(.system(size: 23, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(task.severity == .error
                            ? AstroTokens.Color.danger : AstroTokens.Color.spectralBlue)
                    Text(title).font(.system(.title3, weight: .semibold))
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(task.evidencePaths, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button(actionTitle) { onAction(task.action) }
                .buttonStyle(.borderedProminent)
                .tint(task.severity == .error
                    ? AstroTokens.Color.danger : AstroTokens.Color.spectralBlue)
                .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue).action")
        }
        .padding(AstroTokens.Spacing.standard)
        .background(AstroTokens.Color.elevatedGraphite, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(task.severity == .error
                    ? AstroTokens.Color.danger.opacity(0.34) : AstroTokens.Color.hairline, lineWidth: 1)
        }
        .contextMenu { Button("Mark as Acknowledged…", action: onAcknowledge) }
        .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue)")
    }
}
```

> A `buttonStyle` **nem** kapcsolható ternáriussal — a `.bordered` és a `.borderedProminent` különböző típus, és nincs `AnyButtonStyle`. Ezért egyetlen stílus, és a súlyosságot a `tint` hordozza.

**Lokalizációs csapda:** a `title`, `explanation` és `actionTitle` `LocalizedStringKey`-t adjon vissza, **ne** `String`-et. Egy `switch`, ami minden ágon sztringliterált ad vissza, `String`-re következtet, és **soha nem fordul le magyarra** — pontosan ez a hiba történt a `MetricCard.title`-lel. Írd ki a típust explicit módon: `private var title: LocalizedStringKey { switch task.kind { … } }`.

- [ ] **Step 2a: Előbb vidd ki a felületi mondatot a motorrétegből**

A 2b. task `ArchiveTargetRow.displayName`-je a célpont nélküli vödörre a `"Not tied to a target"` **angol `String` literált** kapta, az `AstroApplication` rétegben. Ez ugyanaz a hibaosztály, amit a 7b. task most zárt be, csak eggyel rosszabb helyen: felületi mondat a motorrétegben, ami így soha nem fordul le, és megsérti a projekt saját határát („a store nem tartalmaz felületi szöveget; a lokalizáció a nézetrétegben történik").

A valódi célpontoknál a `displayName` **katalógus-jelölés** (`NGC 7000`) vagy mappanév — az helyesen nem fordítandó, és marad. Csak az untargeted ág a hibás.

Ezért:

- `ArchiveTargetRow.displayName` legyen `String?`, és az untargeted sorra `nil`. A doc-komment mondja ki, hogy a `nil` **nem** hiányzó adat, hanem „ennek a sornak a nevét a nézet adja, mert az fordítandó szöveg".
- `ArchiveMapQuery.buildRows` ennek megfelelően ne gyártson felületi mondatot.
- A meglévő `untargetedFilesGetTheirOwnRow` teszt asszertálja, hogy `displayName == nil`.
- A nézet dönt:

```swift
if let name = row.displayName {
    Text(name)                      // verbatim: catalog designation, not translatable
} else {
    Text("Not tied to a target")    // LocalizedStringKey, translatable
}
```

- `hu.lproj`: `"Not tied to a target" = "Nem tartozik célponthoz";`

Ez a lépés az `AstroApplication`-t is módosítja (`ArchiveMapQuery.swift` és a hozzá tartozó teszt), ezért **előbb** fut, mint a nézet megírása.

- [ ] **Step 2b: Write `ArchiveTargetRowView`**

Három zóna: `210pt` név-blokk (a fenti név + `„<n> nights · <m> files"` caption), rugalmas sáv-blokk, `92pt` érték-blokk (összméret + `−<reclaim>` piros második sor, ha van).

A sávok a **legnagyobb célpont** méretéhez normalizálódnak, ezért a nézet paraméterként kap egy `maxTargetBytes: Int64`-et — nem számolja ki magának, mert a sorok egymáshoz mérten értelmesek. Ha `maxTargetBytes <= 0`, a sáv üresen marad (nulla osztás nélkül).

Kontextusmenü: `Reveal in Finder` és `Preview Quarantine for This Target…`. Dupla kattintás → `Reveal in Finder`.

> **Szándékosan nincs „Open in Targets" ebben a hullámban.** A sor identitása a célpont **mappaneve**, a `.project(_)` route viszont projekt-`UUID`-t vár, és a térkép-lekérdezésnek nincs mappanév → projekt feloldása. Egy hamis vagy üres navigáció rosszabb, mint a hiányzó menüpont. A `.archiveTarget(String)` route és a feloldás a 3. hullám része.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -20`
Expected: no errors, no warnings

- [ ] **Step 4: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchiveTaskCard.swift Sources/AstroUI/Features/Archive/ArchiveTargetRowView.swift
git commit -m "feat: add the archive task card and target row"
```

---

## Task 9: `ArchiveView` — az oldal összeállítása

**Files:**
- Create: `Sources/AstroUI/Features/Archive/ArchiveView.swift`
- Modify: `Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift` (lásd a „soha nem ellenőrzött épség" alfejezetet lentebb)
- Test: `Tests/AstroUITests/ArchiveSurfaceTests.swift` (bővítés)
- Test: `Tests/AstroApplicationTests/ArchiveMapQueryTests.swift` (bővítés)

### Előfeltétel: a „semmi nem sérült" nem mondható el ellenőrzés nélkül

A valódi könyvtárban **egyetlen `verify` típusú futás sincs** — a felhasználó soha nem futtatott integritás-ellenőrzést. Ez a normális eset, nem kivétel.

Az `ArchiveVerdictDetail` `hasIntegrityFinding`-je viszont `tasks.contains { $0.kind == .corruption }`, ami ilyenkor `false`, és a nézet ebből azt a mondatot építené, hogy **„Semmi nem sérült."** Ez pontosan az a fajta megalapozatlan állítás, amit ez az egész átépítés meg akar szüntetni: az app olyat állítana, amit meg sem nézett. Ugyanaz a hiba, mint a régi Health oldal „0 calibration issues"-a.

Ezért:

1. Az `ArchiveMapSnapshot` kapjon egy `lastVerifyAt: Date?` mezőt. A `lastRuns(db:)` már a `runs` táblát olvassa — bővítsd a `WHERE kind IN ('scan','audit')`-ot `'verify'`-jal, és add vissza harmadik értékként. Teszt pinnelje, hogy verify-futás nélkül `nil`.
2. Az `ArchiveVerdictDetail` `hasIntegrityFinding: Bool`-ja helyett **három** állapotú legyen:

```swift
enum IntegrityState: Equatable {
    /// A verify pass has run and found corruption.
    case corruptionFound
    /// A verify pass has run and found none.
    case verifiedClean
    /// No verify pass has ever run -- the app knows nothing about this
    /// library's integrity and must not imply otherwise.
    case neverVerified
}
```

3. A második sor szövege ágakként:
   - `.corruptionFound` → „N fájl tartalma megváltozott." (elöl, minden más előtt)
   - `.verifiedClean` → „Az utolsó ellenőrzés óta semmi nem sérült."
   - `.neverVerified` → „Az adatépséget még nem ellenőriztem." — és **semmilyen** formában nem állítja, hogy rendben van

Teszt mindhárom ágra. Ez a legfontosabb egyetlen mondat az oldalon; nem elég, ha „általában" igaz.

- [ ] **Step 1: Write the failing test for the verdict sentence**

Az ítélet-mondat tiszta függvény, tehát renderelés nélkül tesztelhető.

```swift
@Test("The verdict sentence has one deterministic branch per library state")
func verdictSentenceBranches() {
    #expect(ArchiveVerdict(tasks: [], snapshot: .stub(lastAuditAt: .distantPast)).headline == .allClear)
    #expect(ArchiveVerdict(tasks: [.stub(kind: .intermediateFiles)], snapshot: .stub()).headline == .oneTask)
    #expect(ArchiveVerdict(
        tasks: [.stub(kind: .intermediateFiles), .stub(kind: .duplicateContent)],
        snapshot: .stub()
    ).headline == .manyTasks(2))
    #expect(ArchiveVerdict(tasks: [.stub(kind: .auditNeverRun)], snapshot: .stub(lastAuditAt: nil)).headline == .neverChecked)
    #expect(ArchiveVerdict(
        tasks: [],
        snapshot: .stub(lastScanAt: Date(timeIntervalSince1970: 2000), lastAuditAt: Date(timeIntervalSince1970: 1000))
    ).headline == .stale)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter ArchiveSurfaceTests/verdictSentenceBranches`
Expected: FAIL — `cannot find 'ArchiveVerdict' in scope`

- [ ] **Step 3: Implement `ArchiveVerdict` and the view**

```swift
/// The second line under the verdict: what is at stake, in facts the view
/// turns into a sentence. Separate from `Headline` because these two answer
/// different questions -- "do I have to do something?" and "how much is it
/// worth?" -- and only the first one is ever allowed to be alarming.
struct ArchiveVerdictDetail: Equatable {
    /// `true` when a checksum mismatch is among the tasks -- the only
    /// finding that means data may already be lost, so it is stated before
    /// anything about disk space.
    let hasIntegrityFinding: Bool
    let reclaimableBytes: Int64
    /// The target holding the most reclaimable bytes, when any target does.
    /// `nil` when nothing is reclaimable -- the view then omits the clause
    /// entirely rather than printing "0 bytes in (none)".
    let worstTargetName: String?
    let worstTargetBytes: Int64
}

/// The one sentence at the top of the Archive page. Pure, exhaustive, and
/// tested branch-by-branch: this is the sentence a user can read and then
/// close the app on, so it must never be assembled ad hoc in `body`.
struct ArchiveVerdict: Equatable {
    enum Headline: Equatable {
        case neverChecked
        case stale
        case allClear
        case oneTask
        case manyTasks(Int)
    }

    let headline: Headline
    let detail: ArchiveVerdictDetail

    init(tasks: [ArchiveTask], snapshot: ArchiveMapSnapshot) {
        // Order matters: "never checked" outranks everything, because every
        // other sentence would be claiming knowledge the app does not have.
        if snapshot.lastAuditAt == nil {
            headline = .neverChecked
        } else if snapshot.isAuditStale {
            headline = .stale
        } else if tasks.isEmpty {
            headline = .allClear
        } else if tasks.count == 1 {
            headline = .oneTask
        } else {
            headline = .manyTasks(tasks.count)
        }
        detail = ArchiveVerdictDetail(
            hasIntegrityFinding: tasks.contains { $0.kind == .integrity },
            reclaimableBytes: snapshot.reclaimableBytes,
            worstTargetName: snapshot.rows.max { $0.reclaimableBytes < $1.reclaimableBytes }
                .flatMap { $0.reclaimableBytes > 0 ? $0.displayName : nil },
            worstTargetBytes: snapshot.rows.map(\.reclaimableBytes).max() ?? 0
        )
    }
}
```

A nézet váza — **nem-görgető gyökér, egyetlen görgető lista** (a `WorkspaceTablePage` mintája, lásd az antipattern-jegyzet 5. pontját):

```swift
VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
    verdictHeader                 // rögzített
    ArchiveStripView(...)         // rögzített
    List {                        // az EGYETLEN görgető
        if !store.tasks.isEmpty {
            Section("Needs you") {
                ForEach(store.tasks) { ArchiveTaskCard(task: $0, onAction: perform) }
            }
        }
        Section("Targets") {
            ForEach(store.visibleRows) { ArchiveTargetRowView(row: $0, maxTargetBytes: maxBytes, ...) }
        }
    }
    .listStyle(.inset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
.padding(AstroTokens.Spacing.spacious)
```

**Kötelező állapotágak** (mind `ContentUnavailableView`, hogy a meglévő `everyFeatureViewHasAContentUnavailableEmptyState` kapu zöld maradjon):
- `rootURL == nil` → „No library open" + `Choose Image Library…`
- `store.isLoading && store.snapshot == nil` → `ProgressView("Reading the archive…")`
- `store.errorMessage != nil` → `ContentUnavailableView` a hibaszöveggel + `Try Again` gomb, ami újra `load`-ol
- `snapshot.totalBytes == 0` → „Nothing indexed yet" + `Rescan`

**Kötelező lábjegyzet: ami nem kapott kártyát.** Az `ArchiveTaskQuery` szándékosan csak azokat a találat-kategóriákat képezi kártyára, amelyekhez tartozik végrehajtható művelet. A valódi könyvtáron visszajátszva ez **138 találatot, 8,69 GB-ot hagy kártya nélkül** — `capture-unassigned-artifact` (34), `capture-legacy-folder` (32), `tool-output` (23), `missing-counterpart` (18) és további nyolc kategória. Ezeket **nem szabad némán elhagyni**: a lista alján, halkan (`.caption`, `inkFaint`), egyetlen sor:

> „További 138 találat olyan kategóriákban, amikre ez az oldal nem kínál műveletet · 8,69 GB"

A sor `.help()`-je sorolja fel a kategóriákat darabszámmal. Ehhez az `ArchiveTaskQuery` adjon vissza egy `uncoveredFindings: (count: Int, bytes: Int64, categories: [String: Int])` mezőt a `tasks()` mellett — új típus **nem** kell, elég egy `ArchiveTaskSummary` struct, ami a `tasks`-t és ezt együtt hordozza. Teszt pinnelje, hogy egy nem képezett kategóriájú találat pontosan itt jelenik meg, és **nem** kártyaként.

Ez a „no silent caps" szabály: ha a felület szűkíti a lefedettséget, mondja ki, mennyit hagyott el — különben úgy olvasódik, hogy mindent lefedett.

**Toolbar-akciók** (`WorkspaceActionCenter`-en át, `.onAppear` / `.onChange` / `.onDisappear`, **soha nem `body`-ból** — lásd az antipattern-jegyzet 2. pontját, és másold a `HealthView.publishWorkspaceActions()` mintáját pontosan):

```swift
WorkspaceActions([
    .menu(WorkspaceActionMenu(
        id: "v2.archive.check", title: "Check Library",
        help: "Read through the library for leftovers, duplicates, and structural problems",
        isDisabled: rootURL == nil || runningAuditOperation != nil,
        items: [WorkspaceMenuItem(id: "v2.archive.check.fast", title: "Fast (Skip Duplicate Scan)") { runAudit(.fast) }],
        primaryAction: { runAudit(.full) }
    )),
    .button(WorkspaceAction(id: "v2.archive.rescan", title: "Rescan", systemImage: "arrow.clockwise",
                            help: "Re-read the library folder for new or changed files (⌘R)", action: rescan)),
    .button(WorkspaceAction(id: "v2.archive.organize", title: "Organize One Session…", systemImage: "folder.badge.gearshape",
                            action: convertSession)),
    .button(WorkspaceAction(id: "v2.archive.change", title: "Change Library…", systemImage: "externaldrive",
                            action: chooseLibrary)),
])
```

Ez a négy akció örökli a törlendő `LibraryView` három gombját plusz a `HealthView` audit-menüjét.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter ArchiveSurfaceTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchiveView.swift Tests/AstroUITests/ArchiveSurfaceTests.swift
git commit -m "feat: assemble the archive page around its verdict sentence"
```

---

## Task 10: Bekötés a shellbe, a `LibraryView` törlése

**Files:**
- Modify: `Sources/AstroUI/App/V2RootView.swift:1213-1220` (a `.library` ág), `:822-838` (a Library `DisclosureGroup`), `:1009-1010` (route-címek)
- Delete: `Sources/AstroUI/Features/Library/LibraryView.swift`
- Test: `Tests/AstroUITests/V2NavigationSurfaceTests.swift` (bővítés)

- [ ] **Step 1: Write the failing navigation test**

```swift
@Test("The Library section renders the archive page, and Health is no longer its own sidebar row")
func librarySectionRendersTheArchive() throws {
    let source = try contents("Sources/AstroUI/App/V2RootView.swift")
    #expect(source.contains("ArchiveView("))
    #expect(!source.contains("LibraryView("), "LibraryView is replaced, not merely bypassed")
    #expect(!source.contains("v2.sidebar.library.health"),
            "Health's findings now live on the archive page, so it has no sidebar row")
    #expect(source.contains("v2.sidebar.library.calibration"), "Calibration keeps its row")
}

@Test("The library/health deep link still resolves, redirected to the archive page")
func healthDeepLinkRedirects() throws {
    let route = try #require(AppRoute(deepLink: URL(string: "astrotool://library/health")!))
    #expect(route == .content(.library))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter V2NavigationSurfaceTests`
Expected: FAIL

- [ ] **Step 3: Implement**

1. A `.library` ág az `ArchiveView`-t építi, átadva: `store: archiveStore`, `rootURL: onboardingStore.selectedRoot`, `chooseLibrary`, `rescan`, `convertSession: { router.push(.conversion) }`, `openQuarantinePreview: { router.push(.cleanup) }`, `accessMode`. **`openTarget` nincs** — lásd a 8. task jegyzetét arról, hogy a mappanév nem oldható fel projekt-`UUID`-vé ebben a hullámban.
2. A `V2Shell` kapjon egy `@State private var archiveStore = ArchiveStore()`-t, a `libraryHealthStore` mintájára, és adja tovább.
3. A sidebar `DisclosureGroup`-jából töröld a `Health` gyereksort; a `Calibration` marad.
4. Az `AppRoute.init(deepLink:)`-ben a `case ("library", ["health"])` ága `.content(.library)`-t adjon vissza (átirányítás), és kapjon kommentet, hogy a kiadott dokumentációban élő linkek ne törjenek.
5. A `.health` `ContentRoute` **maradjon meg** ebben a hullámban (a 3. hullám törli), de a `destination(for:)`-ban irányítson át: `case .health: ArchiveView(...)` — így egy régi, visszaállított ablakállapot sem landol üres nézeten.
6. Töröld a `LibraryView.swift`-et.

- [ ] **Step 4: Run the full test suite**

Run: `swift test --no-parallel 2>&1 | tail -20`
Expected: minden teszt zöld (a korábbi 2300 + az újak). Ha a `LibraryHealthStoreTests` vagy a `V2WorkspaceParitySurfaceTests` a törölt `LibraryView`-ra hivatkozik, igazítsd őket — **ne** töröld a lefedettséget, hanem irányítsd az `ArchiveView`-ra.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/AstroUI Tests/AstroUITests
git commit -m "feat: replace the Library page with the archive map"
```

---

## Task 11: A „Move to Archive…" zsákutca törlése

A `2026-08-15`-i termékaudit 3(5) pontja: a sheet egyetlen gombja a `Close`, és semmilyen kódút nem alkalmaz archív tervet. Ez hamis ígéret, nem félkész funkció.

**Files:**
- Modify: `Sources/AstroUI/Inspector/FrameInspector.swift:24`
- Modify: `Sources/AstroUI/Features/Review/ReviewWorkspace.swift:10, 202-203, 438-450, 508-539`
- Test: `Tests/AstroUITests/V2HonestSurfacesTests.swift` (bővítés)

- [ ] **Step 1: Write the failing test**

```swift
@Test("No surface offers an archive move the app cannot perform")
func noFalseArchivePromise() throws {
    for file in ["Sources/AstroUI/Inspector/FrameInspector.swift",
                 "Sources/AstroUI/Features/Review/ReviewWorkspace.swift"] {
        let source = try contents(file)
        #expect(!source.contains("Move to Archive"), "\(file) still offers a move nothing implements")
        #expect(!source.contains("ArchivePreviewSheet"), "\(file) still presents the dead-end sheet")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter V2HonestSurfacesTests/noFalseArchivePromise`
Expected: FAIL

- [ ] **Step 3: Implement**

1. `FrameInspector.swift:24` — töröld a `Button("Move to Archive…", …)` sort és a `requestArchive` paramétert az inicializálóból; igazítsd a hívási helyet (`ReviewWorkspace.inspector(for:)`).
2. `ReviewWorkspace.swift` — töröld az `@State private var archivePreview`-t, a `.sheet(item: $archivePreview)`-t és a `private struct ArchivePreviewSheet` egészét.
3. `ReviewStore.archivePlan(for:)` és `ReviewCommands.archivePlan(relativePath:)` **maradjon** — tesztelt magréteg, amire a jövőbeli, valódi archív-folyamat épül. Írj a `ReviewStore.archivePlan` fölé egy doc-kommentet, hogy ma szándékosan nincs UI-fogyasztója, és miért.

- [ ] **Step 4: Run the full test suite**

Run: `swift test --no-parallel 2>&1 | tail -20`
Expected: minden zöld

- [ ] **Step 5: Commit**

```bash
git add Sources/AstroUI Tests/AstroUITests
git commit -m "fix: remove the archive move the app never performs"
```

---

## Task 12: Lokalizáció és a kapu-tesztek zárása

**Files:**
- Modify: `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings`
- Modify: `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1: Extract the new keys**

Run: `swift scripts/extract-localizable-strings.swift`
Expected: a kulcsszám a mostani 651-ről az új felületi szövegek számával nő

- [ ] **Step 2: Write the failing coverage test run**

Run: `swift test --no-parallel --filter LocalizationCoverageTests`
Expected: FAIL — hiányzó magyar fordítások az új `Sources/AstroUI/Features/Archive/**` kulcsokra

- [ ] **Step 3: Add the Hungarian translations**

Vedd fel mind az új kulcsot a `hu.lproj/Localizable.strings`-be. Ellenőrizd, hogy egyetlen új felületi szöveg sincs `String`-ként tipizálva (`ternary ? "A" : "B"` és `opt ?? "x"` is `String`-re következtet, és **soha nem fordul**) — mind `LocalizedStringKey`.

- [ ] **Step 4: Add the actionability gate**

```swift
@Test("The archive never renders a task card without an executable action")
func archiveTaskCardsAreAlwaysActionable() throws {
    let source = try contents("Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift")
    #expect(source.contains("guard action != .unavailable else { return nil }"),
            "the actionability gate was removed from ArchiveTaskQuery")
    let card = try contents("Sources/AstroUI/Features/Archive/ArchiveTaskCard.swift")
    #expect(!card.contains("Text(nextStep"), "a card must render a Button, never a next-step label")
}

@Test("No archive surface uses the engine's internal vocabulary")
func archiveSurfacesUseHumanWords() throws {
    let banned = ["Triage", "Frame fill", "Photographable", "Residue", "Finding("]
    for file in try filenames(under: "Sources/AstroUI/Features/Archive") {
        let source = try contents("Sources/AstroUI/Features/Archive/\(file)")
        for word in banned {
            #expect(!source.contains("\"\(word)"), "\(file) shows the user the word \(word)")
        }
    }
}
```

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel 2>&1 | tail -20`
Expected: minden zöld

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroToolApp/Resources Tests/AstroUITests
git commit -m "test: gate archive actionability, vocabulary, and translation"
```

---

## Task 13: Futásidejű ellenőrzés a valódi könyvtáron

Ez nem opcionális. A fagyás-sorozat minden egyes köre azzal ért véget, hogy „a tesztek zöldek" — a valódi könyvtárral mérve viszont nem volt az.

- [ ] **Step 1: Build and install the dev build**

```bash
./build.sh && ./scripts/install-local.sh
```

- [ ] **Step 2: Launch straight into the Archive section against the real library**

```bash
open -a AstroTool --args -UITestInitialSection library
```

- [ ] **Step 3: Measure CPU at 25 s and at 115 s**

```bash
ps -o %cpu,rss,comm -p "$(pgrep -x AstroTool)"
```

Expected: **<15%** mindkét mérésnél. 98–100% = invalidálási vihar; ilyenkor `sample "$(pgrep -x AstroTool)" 3 -file /tmp/archive-sample.txt`, és a `PlanningStore` fejléc-kommentjének hét pontja szerint keresd a forrást.

- [ ] **Step 4: Verify the numbers against the database**

A képernyőn látszó összméretnek, fájlszámnak, célpontszámnak és visszanyerhető mennyiségnek egyeznie kell ezzel:

```bash
sqlite3 "$HOME/Library/Caches/AstroTool/Libraries/"*/index.sqlite "
  SELECT COUNT(*), SUM(size) FROM files WHERE missing=0;
  SELECT COUNT(DISTINCT target) FROM files WHERE missing=0 AND target IS NOT NULL;"
```

- [ ] **Step 5: Check both appearances**

Váltsd a rendszert világos és sötét megjelenés között. A sáv minden szegmense és a jelmagyarázat maradjon olvasható; a visszanyerhető-sín maradjon megkülönböztethető a sáv többi részétől.

- [ ] **Step 6: Commit the measurement**

```bash
git commit --allow-empty -m "chore: verify the archive page against the real 612 GB library"
```

---

## Elfogadási kritériumok

Az 1. hullám akkor kész, ha mind igaz:

- ⓐ A valódi könyvtárral megnyitva az Archívum oldal az **első képernyőn** kimondja, hány dolog vár a felhasználóra és mennyi hely nyerhető vissza — görgetés nélkül.
- ⓑ A sáv szegmenseinek összege a teljes archívum, és minden szegmens hover-szövege osztályt, méretet és fájlszámot mond.
- ⓒ Az `M42_Orion` sora látható vörös sínt kap, ami a sor hosszának nagyjából kétharmada.
- ⓓ Minden teendő-kártyán van gomb, és minden gomb valódi folyamatot indít.
- ⓔ Egy audit nélküli könyvtár térképet rajzol és **egyetlen** őszinte kártyát mutat, nem hibaüzenetet.
- ⓕ A `Library` sidebar-szekció alatt nincs `Health` sor, és az `astrotool://library/health` mélylink az Archívum oldalra visz.
- ⓖ Sehol nem szerepel a „Move to Archive…" felirat.
- ⓗ `swift test --no-parallel` teljesen zöld, és a tesztszám nem csökkent.
- ⓘ Az app CPU-ja az Archívum szekcióban 25 s és 115 s után is <15%.

---

## Task 2b: A célponthoz nem köthető fájlok sem tűnhetnek el a térképről

**Miért van ez a task:** a 2. task leszállított kódját a **valódi** könyvtáron visszajátszva kiderült, hogy a `buildRows` `guard !target.isEmpty else { return }` sora **129 fájlt, 6,28 GB-ot némán kihagy** a térképből. Nem szemét: ennek a 6,28 GB-nak a túlnyomó része a `calibration_library/darks/…` — a **megosztott kalibrációs törzs**, ami tervezetten nem tartozik egyetlen célponthoz sem. És **3,13 GB duplikátum van benne**, vagyis valódi visszanyerhető hely.

Két konkrét következmény, amit ez okoz:

1. A sáv fejléce „605,7 GB"-ot ír, miközben a könyvtár 611,9 GB. Egy térkép, ami a bájtok holléte a tárgya, nem hagyhat el 6 GB-ot szó nélkül.
2. A `reclaimableBytes` a `reclaimByTarget` **teljes** összegéből jön (a `guard` csak a célpontonkénti bontásra hat), a `totalBytes` viszont a sorokból. Így a visszanyerhető-sín aránya olyan nevezőre számol, amiben a számlálója egy része nincs is benne, és a sorok visszanyerhető értékei nem adják ki a fejlécben írt összeget.

Ez a terv hibája volt, nem a megvalósításé. A javítás: a célponthoz nem köthető fájlok kapjanak **saját sort**, ne tűnjenek el.

**Files:**
- Modify: `Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift`
- Modify: `Tests/AstroApplicationTests/ArchiveMapQueryTests.swift`

- [ ] **Step 1: Write the failing tests**

Vedd fel a meglévő `makeIndexDatabase` fixture-be két célpont nélküli fájlt — egy nagyot és egy duplikátum-találattal jelöltet:

```swift
try db.exec("""
    INSERT INTO files VALUES
      ('calibration_library/darks/d1.fit', 250, NULL, NULL, 'dark', 'calibration', 0),
      ('calibration_library/darks/d2.fit', 250, NULL, NULL, 'dark', 'calibration', 0);
    """)
try db.exec("INSERT INTO findings VALUES(3, 2, 'suspicious', 'duplicate-content', 'calibration_library/darks/d2.fit', 'copy');")
```

Ezzel a fixture összesen 1400 bájt, és a célpont nélküli vödör 500 bájt, ebből 250 visszanyerhető.

```swift
@Test("Files that belong to no target get their own row instead of vanishing")
func untargetedFilesGetTheirOwnRow() async throws {
    let index = try Self.makeIndexDatabase()
    let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

    let untargeted = try #require(snapshot.rows.first { $0.isUntargeted })
    #expect(untargeted.target == nil)
    #expect(untargeted.totalBytes == 500)
    #expect(untargeted.fileCount == 2)
    #expect(untargeted.nightCount == 0)
    #expect(untargeted.reclaimableBytes == 250)
    #expect(untargeted.slices.map(\.archiveClass) == [.calibration])
}

@Test("The header total is the whole library, and the rows add up to it")
func rowsAddUpToTheHeaderTotal() async throws {
    let index = try Self.makeIndexDatabase()
    let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

    #expect(snapshot.totalBytes == 1400)
    #expect(snapshot.rows.reduce(0) { $0 + $1.totalBytes } == snapshot.totalBytes,
            "a byte in the library must appear in exactly one row")
    #expect(snapshot.fileCount == 7)
    #expect(snapshot.slices.reduce(0) { $0 + $1.bytes } == snapshot.totalBytes,
            "the strip must cover the same bytes the header claims")
}

@Test("Reclaimable totals reconcile between the header and the rows")
func reclaimReconcilesBetweenHeaderAndRows() async throws {
    let index = try Self.makeIndexDatabase()
    let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

    #expect(snapshot.rows.reduce(0) { $0 + $1.reclaimableBytes } == snapshot.reclaimableBytes,
            "the rail's numerator must be the sum of what the rows show")
}

@Test("targetCount counts real targets, not the untargeted bucket")
func targetCountExcludesTheUntargetedRow() async throws {
    let index = try Self.makeIndexDatabase()
    let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()
    #expect(snapshot.targetCount == 2)
    #expect(snapshot.rows.count == 3)
}
```

A meglévő négy teszt várt értékeit is igazítsd az új fixture-höz (`totalsExcludeMissingFiles`, `targetRowsAreSortedBySize`, `reclaimableComesFromLatestAudit`, `missingAuditTablesStillProducesAMap`). **Ne** lazíts rajtuk — az `emptyLibrary` teszt változatlan marad.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter ArchiveMapQueryTests`
Expected: FAIL — `value of type 'ArchiveTargetRow' has no member 'isUntargeted'`

- [ ] **Step 3: Implement**

`ArchiveTargetRow` kapjon egy `target: String?`-ot az `id` mellé, és az `id` abból származzon — így nincs üres-string mágia, és a nézet egyértelműen tudja, melyik sorra nem alkalmazhatók a célpont-specifikus műveletek:

```swift
public struct ArchiveTargetRow: Equatable, Sendable, Identifiable {
    /// The target's own folder name, or `nil` for files the scanner could
    /// not attribute to any target -- on a real library that bucket is
    /// dominated by `calibration_library/`, a shared store that belongs to
    /// no single target by design. It gets a row rather than being dropped:
    /// this map's entire claim is "here is where your bytes are", and a
    /// silently missing 6 GB (3 GB of it reclaimable duplicates) breaks that
    /// claim.
    public let target: String?
    /// Stable identity for `ForEach`/selection. Derived from `target`, with
    /// a sentinel for the untargeted bucket so no real folder name can
    /// collide with it (`/` cannot appear in a scanned target name).
    public var id: String { target ?? "/untargeted" }
    public var isUntargeted: Bool { target == nil }
    public let displayName: String
    …
}
```

A `buildRows`-ból **töröld** a `guard !target.isEmpty else { return }` sort, és helyette az üres célpontot `nil`-re képezd le. Az untargeted sor `displayName`-je `"Not tied to a target"`, `nightCount`-ja `0`.

A `snapshot()`-ban:
- `targetCount` = `rows.count(where: { !$0.isUntargeted })` — a felhasználó célpontjai, nem a vödör
- `nightCount` változatlan (az untargeted vödörnek nincs éjszakája)
- `reclaimByTarget` kulcsa legyen `String?`, hogy az üres célpontú találatok az untargeted sorra kerüljenek, ne csak az összegbe

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter ArchiveMapQueryTests`
Expected: PASS — 10 tests

- [ ] **Step 5: Verify against the real library**

```bash
sqlite3 "/Volumes/images/Astro/.astro_tool/astrotool.sqlite" \
  "SELECT COUNT(*), SUM(size) FROM files WHERE missing=0;"
```

A `snapshot.totalBytes` és `fileCount` ennek **pontosan** meg kell egyeznie. Ha a kötet nincs csatolva, hagyd ki ezt a lépést, és jelezd a riportban.

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroApplication/Features/Archive/ArchiveMapQuery.swift Tests/AstroApplicationTests/ArchiveMapQueryTests.swift
git commit -m "fix: keep untargeted files on the archive map"
```

---

## Task 7b: A sáv feliratai forduljanak le

**Miért van ez a task:** a 7. task leszállított `ArchiveStripView.swift`-je bevezetett egy `ArchiveClass.displayName` bővítményt `String` visszatérési típussal, öt beégetett angol névvel („Light frames", „Stacks", „Processed", „Calibration", „Unclassified"), plusz egy `"Other"`-t a maradék-szegmensre és egy `"\(count) files"`-t a részletsorban.

Két baj van vele:

1. **A `String`-ként tipizált felületi szöveg soha nem fordul le.** A `LocalizedStringKey` felbontása csak literálon működik; egy `String`-et visszaadó `switch`-et a kinyerő script sem lát, tehát kulcs sem keletkezik belőle. Ez a projekt **már elkövetett** hibája — pontosan ezért lett a `MetricCard.title` `String`-ből `LocalizedStringKey`, és pontosan ezért van rá kapu-teszt. A `LocalizationCoverageTests` most sem szólt, mert nincs mit észrevennie.
2. **Az indoklás téves.** A doc-komment az `ArchiveTargetRow.displayName`-re hivatkozik precedensként. Az viszont **katalógus-jelölés** („NGC 7000") — az tényleg nem fordítandó. A „Processed", „Unclassified" és „Calibration" ellenben hétköznapi szavak, amiknek van természetes magyar alakjuk.

A tulajdonos saját nyelvhasználata a mérce (README, kiadási jegyzetek): a `light frame`, `stack`, `dark`, `flat`, `bias` **angolul marad** magyar szövegben is, mert a magyar asztrofotósok így mondják; a `Feldolgozott`, `Kalibráció`, `Besorolatlan` viszont magyarul van. A fordításnak ezt kell követnie, nem egy mechanikus szótárazásnak.

**Files:**
- Modify: `Sources/AstroUI/Features/Archive/ArchiveStripView.swift`
- Modify: `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings`
- Modify: `Tests/AstroUITests/V2PolishSurfaceTests.swift`

- [ ] **Step 1: Write the failing gate**

A meglévő kapuk nem tudják elkapni ezt a hibaosztályt, ezért előbb a kaput írjuk meg:

```swift
@Test("No Archive view returns user-facing text as a plain String")
func archiveViewsDoNotReturnUserFacingStringsFromSwitches() throws {
    // A `var x: String { switch … }` over UI words never localizes: the
    // extraction script only sees LocalizedStringKey literals, so no key is
    // ever produced and the Hungarian build silently shows English. This is
    // the exact defect that forced MetricCard.title from String to
    // LocalizedStringKey -- gate it at the layer where it recurs.
    for file in try filenames(under: "Sources/AstroUI/Features/Archive") {
        let source = try contents("Sources/AstroUI/Features/Archive/\(file)")
        #expect(!source.contains("var displayName: String"),
                "\(file) returns display text as String -- use LocalizedStringKey")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --no-parallel --filter archiveViewsDoNotReturnUserFacingStringsFromSwitches`
Expected: FAIL — `ArchiveStripView.swift returns display text as String`

- [ ] **Step 3: Implement**

`ArchiveClass.displayName` legyen `LocalizedStringKey`, öt literál kulccsal, és a `"Other"` is literál kulcs. A `.help(...)` és az `.accessibilityLabel(...)` `Text`-et is elfogad, ezért a szegmens szövege két lefordítható darabból álljon össze, nem egy összefűzött `String`-ből:

```swift
private func segmentText(_ segment: ArchiveStripLayout.Segment) -> Text {
    Text(segment.archiveClass?.displayName ?? "Other")
        + Text(verbatim: " · ")
        + Text("\(byteString(segment.bytes)) · \(segment.fileCount.formatted()) files")
}
```

Ez pontosan két kulcsot termel: az osztálynevet és a `"%@ · %@ files"` formátumot — mindkettő ugyanúgy kinyerhető és fordítható, mint a meglévő `"%@ checked"`.

- [ ] **Step 4: Add the Hungarian translations**

```
"Light frames" = "Light frame-ek";
"Stacks" = "Stackek";
"Processed" = "Feldolgozott";
"Calibration" = "Kalibráció";
"Unclassified" = "Besorolatlan";
"Other" = "Egyéb";
"%@ · %@ files" = "%@ · %@ fájl";
```

- [ ] **Step 5: Run the gates and the suite**

Run: `swift test --no-parallel --filter LocalizationCoverageTests`
Run: `swift test --no-parallel 2>&1 | tail -20`
Expected: minden zöld

- [ ] **Step 6: Commit**

```bash
git add Sources/AstroUI/Features/Archive/ArchiveStripView.swift Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings Tests/AstroUITests/V2PolishSurfaceTests.swift
git commit -m "fix: localize the archive strip's own labels"
```
