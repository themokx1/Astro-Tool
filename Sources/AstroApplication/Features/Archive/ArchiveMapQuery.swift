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
    /// The catalog designation when the folder name yields one
    /// (`TargetNameResolver`), otherwise the folder name with underscores
    /// turned into spaces. Deliberately NOT `ResolvedTargetName.displayName`:
    /// that one appends `CatalogNames.hungarian`'s common name, which would
    /// put Hungarian text on an English UI (V2 UI/UX audit pattern P1). The
    /// localized common name is a wave-2 addition.
    ///
    /// `nil` for the untargeted row -- that is NOT missing data. A catalog
    /// designation or folder name is verbatim, non-translatable text, so it
    /// belongs here. But the untargeted bucket has no folder name of its
    /// own; the view renders it as "Not tied to a target", which IS
    /// translatable UI prose. This type stays free of presentation text (the
    /// same boundary `ArchiveTaskQuery`'s doc comment states), so it hands
    /// the view `nil` and lets the view supply that sentence as a
    /// `LocalizedStringKey`.
    public let displayName: String?
    public let nightCount: Int
    public let fileCount: Int
    public let totalBytes: Int64
    public let slices: [ArchiveSlice]
    public let reclaimableBytes: Int64
    public let reclaimableFiles: Int

    public init(
        target: String?, displayName: String?, nightCount: Int, fileCount: Int,
        totalBytes: Int64, slices: [ArchiveSlice],
        reclaimableBytes: Int64, reclaimableFiles: Int
    ) {
        self.target = target
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
    /// The latest `verify` run's start time, or `nil` when the library has
    /// never had one -- the ordinary case on a real library. The view needs
    /// this as a distinct fact, not merely "no corruption card": with no
    /// verify run there is nothing to derive "nothing is corrupted" from,
    /// and asserting it anyway would be exactly the unearned "0 issues"
    /// claim this redesign exists to remove.
    public let lastVerifyAt: Date?

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
        lastScanAt: Date?, lastAuditAt: Date?, lastVerifyAt: Date? = nil
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
        self.lastVerifyAt = lastVerifyAt
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

        var bytesByTargetAndClass: [String?: [ArchiveClass: (files: Int, bytes: Int64)]] = [:]
        var nightsByTarget: [String?: Set<String>] = [:]
        try db.query(
            """
            SELECT COALESCE(target, ''), COALESCE(role, ''), COALESCE(session_date, ''),
                   COUNT(*), COALESCE(SUM(size), 0)
            FROM files WHERE missing = 0
            GROUP BY target, role, session_date;
            """
        ) { row in
            let rawTarget = row.string(0) ?? ""
            let target: String? = rawTarget.isEmpty ? nil : rawTarget
            let archiveClass = ArchiveClass(role: row.string(1) ?? "")
            let night = row.string(2) ?? ""
            let files = Int(row.int64(3) ?? 0)
            let bytes = row.int64(4) ?? 0
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
        let (lastScanAt, lastAuditAt, lastVerifyAt) = try Self.lastRuns(db: db)

        return ArchiveMapSnapshot(
            totalBytes: rows.reduce(0) { $0 + $1.totalBytes },
            fileCount: rows.reduce(0) { $0 + $1.fileCount },
            targetCount: rows.count(where: { !$0.isUntargeted }),
            nightCount: nightsByTarget.values.reduce(0) { $0 + $1.count },
            slices: slices,
            rows: rows,
            reclaimableBytes: reclaim.totalBytes,
            reclaimableFiles: reclaim.totalFiles,
            lastScanAt: lastScanAt,
            lastAuditAt: lastAuditAt,
            lastVerifyAt: lastVerifyAt
        )
    }

    private static func buildRows(
        bytesByTargetAndClass: [String?: [ArchiveClass: (files: Int, bytes: Int64)]],
        nightsByTarget: [String?: Set<String>],
        reclaimByTarget: [String?: (files: Int, bytes: Int64)]
    ) -> [ArchiveTargetRow] {
        bytesByTargetAndClass.map { target, classes in
            let slices = ArchiveClass.displayOrder.compactMap { archiveClass -> ArchiveSlice? in
                guard let value = classes[archiveClass], value.bytes > 0 || value.files > 0 else { return nil }
                return ArchiveSlice(archiveClass: archiveClass, fileCount: value.files, bytes: value.bytes)
            }
            let reclaim = reclaimByTarget[target] ?? (files: 0, bytes: 0)
            // `nil` for the untargeted bucket -- see `ArchiveTargetRow.displayName`'s
            // doc comment: that sentence is translatable UI prose, and this
            // layer never produces presentation text.
            let displayName: String?
            if let target {
                let resolved = TargetNameResolver.resolve(folderName: target)
                displayName = resolved.designation ?? target.replacingOccurrences(of: "_", with: " ")
            } else {
                displayName = nil
            }
            return ArchiveTargetRow(
                target: target,
                displayName: displayName,
                nightCount: nightsByTarget[target]?.count ?? 0,
                fileCount: slices.reduce(0) { $0 + $1.fileCount },
                totalBytes: slices.reduce(0) { $0 + $1.bytes },
                slices: slices,
                reclaimableBytes: reclaim.bytes,
                reclaimableFiles: reclaim.files
            )
        }
        .sorted { lhs, rhs in
            // Biggest first; id breaks a tie so the order is stable across
            // runs rather than following dictionary iteration order.
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
    ) throws -> (byTarget: [String?: (files: Int, bytes: Int64)], totalFiles: Int, totalBytes: Int64) {
        guard try tableExists(db, name: "findings"), try tableExists(db, name: "runs") else {
            return ([:], 0, 0)
        }
        let placeholders = reclaimableCategories.map { "'\($0)'" }.joined(separator: ",")
        var byTarget: [String?: (files: Int, bytes: Int64)] = [:]
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
            let rawTarget = row.string(0) ?? ""
            let target: String? = rawTarget.isEmpty ? nil : rawTarget
            let files = Int(row.int64(1) ?? 0)
            let bytes = row.int64(2) ?? 0
            totalFiles += files
            totalBytes += bytes
            byTarget[target] = (files: files, bytes: bytes)
        }
        return (byTarget, totalFiles, totalBytes)
    }

    private static func lastRuns(db: SQLiteDB) throws -> (scan: Date?, audit: Date?, verify: Date?) {
        guard try tableExists(db, name: "runs") else { return (nil, nil, nil) }
        var scan: Date?
        var audit: Date?
        var verify: Date?
        try db.query(
            "SELECT kind, MAX(started_at) FROM runs WHERE kind IN ('scan','audit','verify') GROUP BY kind;"
        ) { row in
            guard let seconds = row.double(1) else { return }
            let date = Date(timeIntervalSince1970: seconds)
            switch row.string(0) {
            case "scan": scan = date
            case "audit": audit = date
            case "verify": verify = date
            default: break
            }
        }
        return (scan, audit, verify)
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
