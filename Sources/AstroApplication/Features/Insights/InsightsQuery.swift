import AstroCore
import Foundation

public struct MonthlyCapture: Equatable, Sendable, Identifiable {
    public var id: String { month }
    public let month: String
    public let integrationSeconds: Double
    public let frameCount: Int
}

public struct TargetCapture: Equatable, Sendable, Identifiable {
    public var id: String { target }
    public let target: String
    public let integrationSeconds: Double
    public let nightCount: Int
}

public struct FilterUsage: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let frameCount: Int
    public let integrationSeconds: Double
}

public struct SetupUsage: Equatable, Sendable, Identifiable {
    public var id: String { "\(camera)|\(focalLength ?? -1)" }
    public let camera: String
    public let focalLength: Double?
    public let frameCount: Int
    public let integrationSeconds: Double
}

public struct InsightsSnapshot: Equatable, Sendable {
    public let nightCount: Int
    public let targetCount: Int
    public let frameCount: Int
    /// The TRUE integration -- deduped (hardlinked triage copies, cross-
    /// extension CR3/TIF pairs, and metadata-identical fallback matches
    /// collapsed to one canonical frame each via `FrameSet.lightBuckets`,
    /// the exact engine `StatsQueries`/`astrotool stats` use), non-frame
    /// noise (sidecars, derivative files) excluded, and `_hibas`-style
    /// excluded sessions dropped. This is what `TargetStats.totalIntegrationSeconds`
    /// and the README's "valós integráció" both mean; Insights used to
    /// report a naive `SUM(exptime)` instead, which double-counted every
    /// duplicated frame in the index.
    public let integrationSeconds: Double
    /// The naive, undeduped sum this screen used to show as `integrationSeconds`
    /// -- kept so the UI can explain, rather than silently hide, why the
    /// headline number is smaller after this fix. Measured on the owner's
    /// real library (2026-08-17), against the exact V2 index this code
    /// reads: the screen reported 51.52 h where the deduplicated truth is
    /// 35.58 h, so it was inflated by ~31%. The gap is not only
    /// same-filename copies: `FrameSet.lightBuckets` also collapses
    /// hardlinked triage copies and cross-extension CR3/TIF pairs, and drops
    /// non-frame files and excluded sessions.
    ///
    /// Note which database a figure comes from: `astrotool stats` reads the
    /// V1 database inside the library root, while the app reads its own V2
    /// index under Application Support/Caches. Measured a day apart they
    /// disagree -- 33.95 h from the former, 35.58 h from the latter -- and
    /// the number a user sees is the latter. A measurement is only evidence
    /// about the database it was taken from.
    public let grossIntegrationSeconds: Double
    public let months: [MonthlyCapture]
    public let topTargets: [TargetCapture]
    public let filterUsage: [FilterUsage]
    public let setupUsage: [SetupUsage]
    public let rejectedFrameCount: Int
    public let trendPoints: [TrendPoint]
    public let isReadOnly: Bool
    public var bestMonth: MonthlyCapture? { months.max { $0.integrationSeconds < $1.integrationSeconds } }
    public var averageIntegrationPerNight: Double {
        nightCount == 0 ? 0 : integrationSeconds / Double(nightCount)
    }
    public var usableFrameCount: Int { max(0, frameCount - rejectedFrameCount) }
    public var captureEfficiency: Double {
        frameCount == 0 ? 0 : Double(usableFrameCount) / Double(frameCount)
    }
    /// Whether the gross (undeduped) total materially differs from the true
    /// one -- the UI only bothers explaining the difference when there is
    /// one. 1 second of floating-point noise doesn't count.
    public var hasDuplicateExposure: Bool { grossIntegrationSeconds > integrationSeconds + 1 }
    public var setupChoices: [String] { TrendQueries.distinctSetupDescriptors(trendPoints) }
}

public struct InsightsQuery: Sendable {
    typealias TrendProvider = @Sendable () throws -> [TrendPoint]
    /// The whole library's session-light `FileRecord`s (any target/date, not
    /// yet filtered to `.sessions`/`.light` -- `snapshot` does that), their
    /// FITS metadata, and the `AstroConfig` needed to run
    /// `FrameSet.lightBuckets` -- the exact dedup engine `StatsQueries`/
    /// `FilterBreakdownQueries`/`astrotool stats` use. Going through this
    /// (rather than a second, hand-rolled SQL dedup) is what keeps Insights
    /// from ever again disagreeing with the target detail page or the CLI
    /// about what "real integration" means.
    typealias LibraryProvider = @Sendable () throws -> (files: [FileRecord], meta: [Int64: FITSMetaRecord], config: AstroConfig)

    private let indexDatabase: URL
    private let trendProvider: TrendProvider?
    private let libraryProvider: LibraryProvider

    init(
        indexDatabaseForTesting: URL,
        trendPointsForTesting: TrendProvider? = nil,
        libraryForTesting: LibraryProvider? = nil
    ) {
        self.indexDatabase = indexDatabaseForTesting
        self.trendProvider = trendPointsForTesting
        // Tests that don't care about deduped totals at all (e.g. ones that
        // only exercise trend points against an intentionally tiny ad hoc
        // schema) get an empty library rather than being forced to build a
        // full scanned fixture just to satisfy this parameter.
        self.libraryProvider = libraryForTesting ?? { ([], [:], AstroConfig()) }
    }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let index = storage.indexDatabase
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        let config: AstroConfig = {
            var loaded = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            loaded.rootPath = rootURL.path
            return loaded
        }()
        return Self(
            indexDatabaseForTesting: index,
            trendPointsForTesting: {
                let database = try Database(path: index.path)
                return try TrendQueries.points(db: database, config: config)
            },
            libraryForTesting: {
                let database = try Database(path: index.path)
                let files = try database.allFiles(includeMissing: false)
                let meta = try database.fitsMetaBatch(fileIDs: files.compactMap(\.id))
                return (files, meta, config)
            }
        )
    }

    public func snapshot(year: Int? = nil) async throws -> InsightsSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        let yearClause = year.map { " AND f.session_date LIKE '\($0)-%'" } ?? ""
        var nightCount = 0
        var targetCount = 0
        var grossIntegrationSeconds = 0.0
        var rejectedFrameCount = 0
        try db.query(
            """
            SELECT COUNT(DISTINCT target || '|' || session_date), COUNT(DISTINCT target),
                   COALESCE(SUM(COALESCE(m.exptime, 0)), 0)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light'\(yearClause);
            """
        ) { row in
            nightCount = Int(row.int64(0) ?? 0)
            targetCount = Int(row.int64(1) ?? 0)
            grossIntegrationSeconds = row.double(2) ?? 0
        }
        if try Self.tableExists(db: db, table: "user_verdicts") {
            try db.query(
                """
                SELECT COUNT(*) FROM user_verdicts uv JOIN files f ON f.id = uv.file_id
                WHERE uv.accepted = 0 AND f.missing = 0 AND f.area = 'sessions'
                  AND f.role = 'light'\(yearClause);
                """
            ) { row in rejectedFrameCount = Int(row.int64(0) ?? 0) }
        }

        let (dedupedLights, meta) = try Self.dedupedUsableLights(year: year, library: libraryProvider)
        func exptime(_ file: FileRecord) -> Double { file.id.flatMap { meta[$0] }?.exptime ?? 0 }

        var monthSeconds: [String: Double] = [:]
        var monthFrames: [String: Int] = [:]
        var targetSeconds: [String: Double] = [:]
        var targetDates: [String: Set<String>] = [:]
        var filterSeconds: [String: Double] = [:]
        var filterFrames: [String: Int] = [:]
        var setupSeconds: [SetupKey: Double] = [:]
        var setupFrames: [SetupKey: Int] = [:]

        for file in dedupedLights {
            let seconds = exptime(file)
            if let date = file.sessionDate {
                let month = String(date.prefix(7))
                monthSeconds[month, default: 0] += seconds
                monthFrames[month, default: 0] += 1
            }
            if let target = file.target {
                targetSeconds[target, default: 0] += seconds
                if let date = file.sessionDate { targetDates[target, default: []].insert(date) }
            }
            if let record = file.id.flatMap({ meta[$0] }) {
                if let rawFilter = record.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFilter.isEmpty {
                    filterSeconds[rawFilter, default: 0] += seconds
                    filterFrames[rawFilter, default: 0] += 1
                }
                let rawCamera = record.instrume?.trimmingCharacters(in: .whitespacesAndNewlines)
                let camera = (rawCamera?.isEmpty == false) ? rawCamera! : "Unknown camera"
                let key = SetupKey(camera: camera, focalLength: record.focallen)
                setupSeconds[key, default: 0] += seconds
                setupFrames[key, default: 0] += 1
            }
        }

        let months = monthSeconds.keys.sorted().map {
            MonthlyCapture(month: $0, integrationSeconds: monthSeconds[$0] ?? 0, frameCount: monthFrames[$0] ?? 0)
        }
        let targets = targetSeconds.keys
            .sorted { lhs, rhs in
                let (ls, rs) = (targetSeconds[lhs] ?? 0, targetSeconds[rhs] ?? 0)
                return ls != rs ? ls > rs : lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .prefix(8)
            .map { TargetCapture(target: $0, integrationSeconds: targetSeconds[$0] ?? 0, nightCount: targetDates[$0]?.count ?? 0) }
        let filterUsage = filterSeconds.keys
            .sorted { lhs, rhs in
                let (ls, rs) = (filterSeconds[lhs] ?? 0, filterSeconds[rhs] ?? 0)
                return ls != rs ? ls > rs : lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .map { FilterUsage(name: $0, frameCount: filterFrames[$0] ?? 0, integrationSeconds: filterSeconds[$0] ?? 0) }
        let setupUsage = setupSeconds.keys
            .sorted { lhs, rhs in
                let (ls, rs) = (setupSeconds[lhs] ?? 0, setupSeconds[rhs] ?? 0)
                return ls != rs ? ls > rs : lhs.camera.localizedCaseInsensitiveCompare(rhs.camera) == .orderedAscending
            }
            .map { SetupUsage(camera: $0.camera, focalLength: $0.focalLength, frameCount: setupFrames[$0] ?? 0, integrationSeconds: setupSeconds[$0] ?? 0) }

        let trendPoints = try trendProvider?() ?? []
        return InsightsSnapshot(
            nightCount: nightCount, targetCount: targetCount, frameCount: dedupedLights.count,
            integrationSeconds: dedupedLights.reduce(0) { $0 + exptime($1) },
            grossIntegrationSeconds: grossIntegrationSeconds,
            months: months, topTargets: targets,
            filterUsage: filterUsage, setupUsage: setupUsage,
            rejectedFrameCount: rejectedFrameCount, trendPoints: trendPoints, isReadOnly: true
        )
    }

    private struct SetupKey: Hashable {
        let camera: String
        let focalLength: Double?
    }

    /// The deduped, non-frame-noise-filtered, non-excluded-session session
    /// lights across the WHOLE library (optionally scoped to one calendar
    /// year), grouped per target before dedup exactly like
    /// `StatsQueries.computeStats`/`FilterBreakdownQueries.breakdown` do --
    /// `FrameSet.lightBuckets` itself is never reimplemented here, only
    /// invoked once per target.
    ///
    /// Filtering to `year` BEFORE dedup (rather than deduping the whole
    /// library and filtering after) is safe: `FrameSet`'s fallback dedup key
    /// already includes `sessionDate`, and its inode-based primary key only
    /// ever matches files a triage tool hardlinked within the same session,
    /// so a single physical exposure never spans two different years' worth
    /// of input frames.
    private static func dedupedUsableLights(
        year: Int?,
        library: LibraryProvider
    ) throws -> (files: [FileRecord], meta: [Int64: FITSMetaRecord]) {
        let (allFiles, meta, config) = try library()
        var sessionLights = allFiles.filter { $0.area == .sessions && $0.role == .light }
        if let year {
            let prefix = "\(year)-"
            sessionLights = sessionLights.filter { ($0.sessionDate ?? "").hasPrefix(prefix) }
        }

        let excludedLabels = Set(config.stats.excludeLabels.map { $0.lowercased() })
        var usable: [FileRecord] = []
        for (_, groupFiles) in Dictionary(grouping: sessionLights, by: { $0.target ?? "" }) {
            let buckets = FrameSet.lightBuckets(files: groupFiles, meta: meta, config: config)
            // Same `_hibas`-style excluded-session-date convention as
            // `StatsQueries.computeStats`/`FilterBreakdownQueries.breakdown`
            // -- copied, not shared, matching this codebase's existing
            // "copied verbatim so the two can never quietly disagree"
            // pattern for this exact snippet (see `FilterBreakdown.swift`).
            let excludedDates = Set(groupFiles.compactMap(\.sessionDate).filter { date in
                guard let parsed = SessionDateParser.parse(date, patterns: config.intentional),
                      parsed.kind == .labeled, let label = parsed.label
                else { return false }
                return excludedLabels.contains(label.lowercased())
            })
            usable.append(contentsOf: buckets.usable.filter { file in
                guard let date = file.sessionDate else { return true }
                return !excludedDates.contains(date)
            })
        }
        return (usable, meta)
    }

    private static func tableExists(db: SQLiteDB, table: String) throws -> Bool {
        var exists = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", bind: [.text(table)]) { _ in
            exists = true
        }
        return exists
    }
}
