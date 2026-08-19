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
    public let captureTrendPoints: [CaptureTrendPoint]
    /// Every measured session (any capture group, whole-night background)
    /// bucketed by the Moon's illumination fraction on its own date -- "how
    /// much brighter does this owner's own sky actually read near full
    /// Moon than under a dark one." Built from `TrendPoint`s (whole
    /// sessions, `SessionQuality`'s original unit), NOT `captureTrendPoints`
    /// (per-capture-group) -- the Moon doesn't care which rig was mounted,
    /// only what night it was, so this reuses every rated session's
    /// background rather than only ones already resolved to a capture
    /// group.
    public let moonSkyCorrelation: MoonSkyCorrelationSummary
    /// Expert ideation reserve #9 ("Év-összegző Wrapped"): the year-card's
    /// data, built from the exact same `trendPointsProvider` the Moon-sky
    /// card above reads (never a second, year-scoped query) -- `AstroCore`'s
    /// `YearWrapped.summarize` itself does the year-filtering, since it also
    /// needs every OTHER year's points to tell "first light this year" apart
    /// from "merely continued this year" (see that function's own doc
    /// comment). `nil` whenever `year` (this snapshot's own scope) is `nil`
    /// -- "Minden év" has no single year to summarize -- or when the
    /// selected year holds no session at all.
    public let yearWrapped: YearWrapped?
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
    /// W6-B: every distinct, non-nil `setupDescriptor` among `captureTrendPoints`
    /// -- the "Összeállítás" filter's choices, now scoped to CAPTURES rather
    /// than whole sessions (`CaptureTrendPoint`'s own doc comment explains
    /// why a session-wide choice list let a mixed-rig night's setups blend
    /// together).
    public var setupChoices: [String] { Array(Set(captureTrendPoints.compactMap(\.setupDescriptor))).sorted() }
}

/// One capture group's measured quality/operational numbers for one session
/// date -- the "Capture quality trends" card's unit of data (W6-B, owner
/// screenshot review: "itt nem 'session' minőség trend kell, hanem capture
/// trend kell"). A session (night) can hold more than one capture group,
/// each its own optics/filter/exposure combination
/// (`CaptureGroupSummary`'s own doc comment); FWHM/background/efficiency are
/// properties of ONE capture, and blending them across capture groups within
/// a session -- which the former per-SESSION `TrendPoint` did, since
/// `TrendPoint.efficiencyPercent` came from the whole night's dark-window
/// duty cycle -- made the trend physically meaningless whenever a night
/// mixed setups. The owner's own example: a Canon EOS R8·16mm widefield rig
/// and a ZWO ASI2600MC narrowband rig running the same night, folded into
/// one "Efficiency" line.
///
/// Built by joining `SessionStatsQueries.sessions(...)`'s own
/// `SessionDetail.captureGroups: [CaptureGroupSummary]` (operational: frame
/// counts, integration, filters) with `SessionQuality.summaries(...)`'s own
/// `SessionQualitySummary.captureGroups: [CaptureQualitySummary]` (quality:
/// FWHM, background) by `id` -- the EXACT SAME join `NightReportQuery.
/// captureGroupRows` performs for the night workspace's own "Capture Groups"
/// table, so a capture's numbers here and there can never drift apart
/// (`InsightsQueryTests`'s reconciliation test pins this against a shared
/// fixture, replaying a real capture group both ways). Neither half's own
/// math is re-derived here -- this type only zips two already-computed rows
/// together.
public struct CaptureTrendPoint: Equatable, Sendable, Identifiable {
    public var target: String
    /// Raw session date-dir name, verbatim -- same convention as
    /// `TrendPoint.date`.
    public var date: String
    /// The session's canonical `YYYY-MM-DD` start date, or `nil` when the
    /// date-dir name doesn't parse as one -- same convention as
    /// `TrendPoint.sessionStartDate`.
    public var sessionStartDate: String?
    /// The capture group's own display name (`CaptureGroupSummary.
    /// displayName`, e.g. `"OSC 30 s"`, or `"Nincs gyűjtéshez rendelve"` for
    /// an ungrouped/implicit capture).
    public var displayName: String
    /// `CaptureGroupSummary.filters`, joined -- `"—"` when the group carries
    /// none on record.
    public var filterLabel: String
    /// This capture group's own dominant equipment fingerprint
    /// (`EquipmentProfile.fingerprint`'s descriptor, majority vote over the
    /// group's own usable lights) -- narrower than a whole session's
    /// `SessionDetail.setupDescriptor`, since a session can (the whole point
    /// of this type existing) mix more than one. `nil` when no usable light
    /// in the group carries derivable equipment metadata.
    public var setupDescriptor: String?
    public var medianFWHMArcsec: Double?
    public var medianFWHMPixels: Double?
    public var backgroundEPerSecPerArcsec2: Double?
    /// This capture's own accept rate -- `usableLightCount / (usableLightCount
    /// + rejectedCount) * 100` -- NOT the whole night's dark-window duty
    /// cycle (`TrendPoint.efficiencyPercent`'s old meaning), which has no
    /// per-capture breakdown at all and is exactly what let one night's
    /// Efficiency line blend two different rigs together. `nil` when the
    /// group has no usable-or-rejected light on record at all (e.g. only
    /// calibration frames ever landed in it).
    public var efficiencyPercent: Double?
    public var usableFrameCount: Int
    public var integrationSeconds: Double
    /// `CaptureGroupSummary.id` (the `groupID` as text, or `"implicit"`) --
    /// kept so `id` below stays stable even if two capture groups in
    /// different sessions ever shared the same `displayName`.
    public var groupKey: String

    public var id: String { "\(target)|\(date)|\(groupKey)" }

    public init(
        target: String,
        date: String,
        sessionStartDate: String? = nil,
        displayName: String,
        filterLabel: String,
        setupDescriptor: String? = nil,
        medianFWHMArcsec: Double? = nil,
        medianFWHMPixels: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil,
        efficiencyPercent: Double? = nil,
        usableFrameCount: Int = 0,
        integrationSeconds: Double = 0,
        groupKey: String
    ) {
        self.target = target
        self.date = date
        self.sessionStartDate = sessionStartDate
        self.displayName = displayName
        self.filterLabel = filterLabel
        self.setupDescriptor = setupDescriptor
        self.medianFWHMArcsec = medianFWHMArcsec
        self.medianFWHMPixels = medianFWHMPixels
        self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        self.efficiencyPercent = efficiencyPercent
        self.usableFrameCount = usableFrameCount
        self.integrationSeconds = integrationSeconds
        self.groupKey = groupKey
    }

    /// Same "arcsec when derivable, else raw pixels" convention `TrendPoint.
    /// fwhmValue` already establishes -- kept as an identical tuple shape so
    /// `InsightsView` didn't need a second formatting branch when this type
    /// replaced `TrendPoint` as the trend charts' data source.
    public var fwhmValue: (value: Double, isPixelFallback: Bool)? {
        if let arcsec = medianFWHMArcsec { return (arcsec, false) }
        if let pixels = medianFWHMPixels { return (pixels, true) }
        return nil
    }
}

/// One `MoonSkyCorrelation.IlluminationBand`'s display-ready aggregate --
/// `AstroCore`'s pure `MoonSkyCorrelation.Bucket` plus the mag/arcsec2
/// reading `MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2:)`
/// converts its median flux into (never recomputed here -- that
/// conversion's zero-point assumption lives in exactly one place).
public struct MoonSkyBucket: Equatable, Sendable, Identifiable {
    public let band: MoonSkyCorrelation.IlluminationBand
    public let sampleCount: Int
    public let isLowConfidence: Bool
    public let medianBackgroundEPerSecPerArcsec2: Double?
    public let medianMagnitudePerArcsec2: Double?
    public var id: Int { band.rawValue }

    public init(
        band: MoonSkyCorrelation.IlluminationBand,
        sampleCount: Int,
        isLowConfidence: Bool,
        medianBackgroundEPerSecPerArcsec2: Double?,
        medianMagnitudePerArcsec2: Double?
    ) {
        self.band = band
        self.sampleCount = sampleCount
        self.isLowConfidence = isLowConfidence
        self.medianBackgroundEPerSecPerArcsec2 = medianBackgroundEPerSecPerArcsec2
        self.medianMagnitudePerArcsec2 = medianMagnitudePerArcsec2
    }
}

/// Display-ready wrapper around `MoonSkyCorrelation.Result` -- the
/// "Moon x sky brightness" card's data.
public struct MoonSkyCorrelationSummary: Equatable, Sendable {
    public let buckets: [MoonSkyBucket]
    public let headlineRatio: Double?
    public let usableBucketCount: Int

    public init(buckets: [MoonSkyBucket], headlineRatio: Double?, usableBucketCount: Int) {
        self.buckets = buckets
        self.headlineRatio = headlineRatio
        self.usableBucketCount = usableBucketCount
    }

    /// Fewer than two bands ever reached a trustworthy sample count -- the
    /// card collapses to the honest "not enough measured sessions yet"
    /// hint instead of a two-bar chart that can't say anything real.
    public var hasEnoughDataToDisplay: Bool { usableBucketCount >= 2 }

    /// The empty summary every `moonSkyCorrelation` field starts from when
    /// no `TrendPoint` provider is wired (e.g. a test fixture that doesn't
    /// care about this card) -- four empty, low-confidence buckets and no
    /// headline, matching `MoonSkyCorrelation.buckets(points: [])`.
    public static let empty = MoonSkyCorrelationSummary(
        buckets: MoonSkyCorrelation.IlluminationBand.allCases.map {
            MoonSkyBucket(
                band: $0, sampleCount: 0, isLowConfidence: true,
                medianBackgroundEPerSecPerArcsec2: nil, medianMagnitudePerArcsec2: nil
            )
        },
        headlineRatio: nil,
        usableBucketCount: 0
    )
}

public struct InsightsQuery: Sendable {
    typealias CaptureTrendProvider = @Sendable () throws -> [CaptureTrendPoint]
    /// The whole library's session-light `FileRecord`s (any target/date, not
    /// yet filtered to `.sessions`/`.light` -- `snapshot` does that), their
    /// FITS metadata, and the `AstroConfig` needed to run
    /// `FrameSet.lightBuckets` -- the exact dedup engine `StatsQueries`/
    /// `FilterBreakdownQueries`/`astrotool stats` use. Going through this
    /// (rather than a second, hand-rolled SQL dedup) is what keeps Insights
    /// from ever again disagreeing with the target detail page or the CLI
    /// about what "real integration" means.
    typealias LibraryProvider = @Sendable () throws -> (files: [FileRecord], meta: [Int64: FITSMetaRecord], config: AstroConfig)
    /// Every session on record, `TrendQueries.points`'s own unit -- the
    /// Moon-correlation card's raw material. A separate provider from
    /// `CaptureTrendProvider` above: that one is per-capture-group, this
    /// one is per-WHOLE-SESSION (`SessionQuality`'s original scope, before
    /// `CaptureTrendPoint` split it), which is what a session-dated Moon
    /// phase actually keys against.
    typealias TrendPointsProvider = @Sendable () throws -> [TrendPoint]

    private let indexDatabase: URL
    private let captureTrendProvider: CaptureTrendProvider?
    private let libraryProvider: LibraryProvider
    private let trendPointsProvider: TrendPointsProvider?

    init(
        indexDatabaseForTesting: URL,
        captureTrendPointsForTesting: CaptureTrendProvider? = nil,
        libraryForTesting: LibraryProvider? = nil,
        trendPointsForTesting: TrendPointsProvider? = nil
    ) {
        self.indexDatabase = indexDatabaseForTesting
        self.captureTrendProvider = captureTrendPointsForTesting
        // Tests that don't care about deduped totals at all (e.g. ones that
        // only exercise trend points against an intentionally tiny ad hoc
        // schema) get an empty library rather than being forced to build a
        // full scanned fixture just to satisfy this parameter.
        self.libraryProvider = libraryForTesting ?? { ([], [:], AstroConfig()) }
        self.trendPointsProvider = trendPointsForTesting
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
            captureTrendPointsForTesting: {
                let database = try Database(path: index.path)
                return try Self.captureTrendPoints(db: database, config: config)
            },
            libraryForTesting: {
                let database = try Database(path: index.path)
                let files = try database.allFiles(includeMissing: false)
                let meta = try database.fitsMetaBatch(fileIDs: files.compactMap(\.id))
                return (files, meta, config)
            },
            trendPointsForTesting: {
                let database = try Database(path: index.path)
                return try TrendQueries.points(db: database, config: config)
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

        let capturePoints = try captureTrendProvider?() ?? []
        let trendPoints = try trendPointsProvider?() ?? []
        return InsightsSnapshot(
            nightCount: nightCount, targetCount: targetCount, frameCount: dedupedLights.count,
            integrationSeconds: dedupedLights.reduce(0) { $0 + exptime($1) },
            grossIntegrationSeconds: grossIntegrationSeconds,
            months: months, topTargets: targets,
            filterUsage: filterUsage, setupUsage: setupUsage,
            rejectedFrameCount: rejectedFrameCount, captureTrendPoints: capturePoints,
            moonSkyCorrelation: Self.moonSkyCorrelationSummary(points: trendPoints),
            yearWrapped: year.flatMap { YearWrapped.summarize(points: trendPoints, year: $0) },
            isReadOnly: true
        )
    }

    /// Wraps `MoonSkyCorrelation.buckets(points:)` (`AstroCore`, pure) with
    /// the one conversion it deliberately doesn't do itself: each bucket's
    /// median flux into a mag/arcsec2 reading, via `MeasuredSkyQuery.
    /// magnitudePerArcsec2(fromEPerSecPerArcsec2:)` -- called, never
    /// copied, so this card and Planning's own "own sky: mu~=X" caption can
    /// never quietly disagree about what a measured flux means in
    /// magnitudes.
    static func moonSkyCorrelationSummary(points: [TrendPoint]) -> MoonSkyCorrelationSummary {
        let result = MoonSkyCorrelation.buckets(points: points)
        let buckets = result.buckets.map { bucket in
            MoonSkyBucket(
                band: bucket.band,
                sampleCount: bucket.sampleCount,
                isLowConfidence: bucket.isLowConfidence,
                medianBackgroundEPerSecPerArcsec2: bucket.medianBackgroundEPerSecPerArcsec2,
                medianMagnitudePerArcsec2: bucket.medianBackgroundEPerSecPerArcsec2.flatMap {
                    MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: $0)
                }
            )
        }
        return MoonSkyCorrelationSummary(
            buckets: buckets, headlineRatio: result.headlineRatio, usableBucketCount: result.usableBucketCount
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

    /// Every capture group's measured trend row, across the whole library --
    /// the "Capture quality trends" card's data (`CaptureTrendPoint`'s own
    /// doc comment explains why per-capture, not per-session). Follows
    /// `NightsQueries.allNights`'s own "one batched read per target, not one
    /// per session" shape: `SessionStatsQueries.sessions`/`SessionQuality.
    /// summaries` are each called once per target, and their own
    /// `captureGroups` are joined by `id` exactly like `NightReportQuery.
    /// captureGroupRows` does for a single night -- never re-derives either
    /// side's FWHM/frame-count/integration math, only zips the two together.
    static func captureTrendPoints(db: Database, config: AstroConfig) throws -> [CaptureTrendPoint] {
        let targets = Set(try db.allSessionPairs().map { $0.target }).sorted()
        let resolver = try CaptureResolver.load(db: db)

        var rows: [CaptureTrendPoint] = []
        for target in targets {
            let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
            guard !sessions.isEmpty else { continue }

            let qualityByDate = Dictionary(
                uniqueKeysWithValues: try SessionQuality.summaries(target: target, db: db, config: config)
                    .map { ($0.date, $0) }
            )

            // One batched read of this target's own session lights (for the
            // per-capture setup-fingerprint vote below), not one per session
            // date -- same "one pass, not O(sessions x files)" discipline
            // `NightsQueries.allNights` documents for its own per-target passes.
            let targetLights = try db.allFiles(includeMissing: false).filter {
                $0.target == target && $0.area == .sessions && $0.role == .light
            }
            let targetMeta = try db.fitsMetaBatch(fileIDs: targetLights.compactMap(\.id))

            for session in sessions {
                let date = session.dateRaw
                guard !session.captureGroups.isEmpty else { continue }

                let parsedStart = SessionDateParser.parse(date, patterns: config.intentional)?.start
                let qualityByID = Dictionary(
                    uniqueKeysWithValues: (qualityByDate[date]?.captureGroups ?? []).map { ($0.id, $0) }
                )
                let groupRecords = try db.captureGroups(target: target, date: date)
                let setupDescriptors = Self.captureSetupDescriptors(
                    date: date, lights: targetLights, meta: targetMeta,
                    resolver: resolver, groups: groupRecords, config: config
                )

                for group in session.captureGroups where group.usableLightCount > 0 {
                    let quality = qualityByID[group.id]
                    // Same "deduped total minus rejected, over deduped
                    // total" shape `InsightsSnapshot.captureEfficiency`
                    // already uses at the whole-library level -- narrowed to
                    // this ONE capture group's own frames, deliberately
                    // excluding `rawLightCount`'s hardlinked-duplicate/
                    // artifact noise from the denominator (see
                    // `CaptureTrendPoint.efficiencyPercent`'s own doc
                    // comment).
                    let acceptedTotal = group.usableLightCount + group.rejectedCount
                    rows.append(CaptureTrendPoint(
                        target: target,
                        date: date,
                        sessionStartDate: parsedStart,
                        displayName: group.displayName,
                        filterLabel: group.filters.isEmpty ? "—" : group.filters.joined(separator: ", "),
                        setupDescriptor: setupDescriptors[group.id],
                        medianFWHMArcsec: quality?.medianFWHMArcsec,
                        medianFWHMPixels: quality?.medianFWHMPixels,
                        backgroundEPerSecPerArcsec2: quality?.backgroundEPerSecPerArcsec2,
                        efficiencyPercent: acceptedTotal > 0
                            ? Double(group.usableLightCount) / Double(acceptedTotal) * 100
                            : nil,
                        usableFrameCount: group.usableLightCount,
                        integrationSeconds: group.integrationSeconds,
                        groupKey: group.id
                    ))
                }
            }
        }

        rows.sort { lhs, rhs in
            let l = lhs.sessionStartDate ?? lhs.date
            let r = rhs.sessionStartDate ?? rhs.date
            if l != r { return l < r }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.groupKey < rhs.groupKey
        }
        return rows
    }

    /// This session's own capture groups' dominant equipment fingerprint
    /// (`EquipmentProfile.fingerprint`'s descriptor, majority vote over each
    /// group's own usable lights) -- keyed by `CaptureGroupSummary.id`.
    /// Reuses `CaptureResolver`/`FrameSet.lightBuckets`/`EquipmentProfile.
    /// fingerprint` exactly as `SessionStatsQueries`/`SessionQuality`
    /// themselves do to bucket frames into capture groups; only the per-group
    /// majority-vote reduction (a generic frequency count, not domain math)
    /// is new here -- neither `EquipmentProfile`'s per-frame fingerprint
    /// formula nor any of the reconciled FWHM/background/frame-count numbers
    /// are re-derived.
    private static func captureSetupDescriptors(
        date: String,
        lights: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        resolver: CaptureResolver,
        groups: [CaptureGroupRecord],
        config: AstroConfig
    ) -> [String: String] {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.compactMap { group in group.id.map { ($0, group) } })
        let dayLights = lights.filter { $0.sessionDate == date }
        let buckets = FrameSet.lightBuckets(files: dayLights, meta: meta, config: config)

        var counts: [String: [String: Int]] = [:]
        for file in buckets.usable {
            guard let id = file.id, let record = meta[id] else { continue }
            let resolved = resolver.resolve(file: file, meta: record)
            let key: String
            if let groupID = resolved.groupID, groupsByID[groupID] != nil {
                key = String(groupID)
            } else {
                key = "implicit"
            }
            guard let fingerprint = EquipmentProfile.fingerprint(meta: record, headerJSON: record.headerJSON) else { continue }
            counts[key, default: [:]][fingerprint.descriptor, default: 0] += 1
        }
        return counts.compactMapValues { descriptorCounts in
            descriptorCounts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        }
    }

    private static func tableExists(db: SQLiteDB, table: String) throws -> Bool {
        var exists = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", bind: [.text(table)]) { _ in
            exists = true
        }
        return exists
    }
}
