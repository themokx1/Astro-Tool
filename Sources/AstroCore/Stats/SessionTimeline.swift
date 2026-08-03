import Foundation

/// One night's acquisition timeline for a target's session: when it started
/// and ended (from the usable lights' `DATE-OBS`), how much of that window
/// was actually spent integrating, and where the silent gaps were (clouds,
/// meridian flip, a dropped connection, ...). Pure query over `Database` --
/// never touches the filesystem.
public struct SessionTimeline: Codable, Sendable, Equatable {
    public struct Gap: Codable, Sendable, Equatable {
        /// ISO 8601 (UTC) instant the gap started -- the end of the frame
        /// exposure right before it.
        public var start: String
        /// ISO 8601 (UTC) instant the gap ended -- the start of the next
        /// frame's exposure.
        public var end: String
        public var seconds: Double

        public init(start: String, end: String, seconds: Double) {
            self.start = start
            self.end = end
            self.seconds = seconds
        }
    }

    public var target: String
    public var date: String
    /// ISO 8601 (UTC) instant of the first usable light's `DATE-OBS`; `nil`
    /// if no usable light has a parseable `DATE-OBS`.
    public var windowStart: String?
    /// ISO 8601 (UTC) instant the last usable light's exposure ENDED
    /// (its `DATE-OBS` plus its own `exptime`); `nil` under the same
    /// condition as `windowStart`.
    public var windowEnd: String?
    /// `windowEnd - windowStart`, in seconds; `nil` when either is `nil`.
    public var windowSeconds: Double?
    /// Sum of `exptime` over the session's usable lights -- same convention
    /// as `SessionDetail.integrationSeconds`, always computed regardless of
    /// whether any `DATE-OBS` parsed.
    public var integrationSeconds: Double
    /// `integrationSeconds / windowSeconds`; `nil` when `windowSeconds` is
    /// `nil` or `0`.
    public var dutyCycle: Double?
    /// Silent gaps between consecutive frames exceeding the gap threshold
    /// (`config.stats.gapThresholdSeconds`, or 3x the median nominal
    /// exptime when that's `0`/auto), in chronological order.
    public var gaps: [Gap]

    public init(
        target: String,
        date: String,
        windowStart: String? = nil,
        windowEnd: String? = nil,
        windowSeconds: Double? = nil,
        integrationSeconds: Double,
        dutyCycle: Double? = nil,
        gaps: [Gap] = []
    ) {
        self.target = target
        self.date = date
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.windowSeconds = windowSeconds
        self.integrationSeconds = integrationSeconds
        self.dutyCycle = dutyCycle
        self.gaps = gaps
    }

    // MARK: - Query

    /// Builds the timeline for one target/date session from its usable
    /// lights (deduped via `FrameSet`, same as `SessionStatsQueries`).
    public static func timeline(target: String, date: String, db: Database, config: AstroConfig) throws -> SessionTimeline {
        let files = try db.allFiles(includeMissing: false)
        let dayLights = files.filter {
            $0.target == target && $0.area == .sessions && $0.sessionDate == date && $0.role == .light
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)

        var integrationSeconds: Double = 0
        var timedFrames: [(start: Date, exptime: Double)] = []
        for file in buckets.usable {
            let meta = file.id.flatMap { metaByFileID[$0] }
            let exptime = meta?.exptime ?? 0
            integrationSeconds += exptime

            guard let rawDateObs = meta?.dateObs, let start = parseDateObs(rawDateObs) else { continue }
            timedFrames.append((start, exptime))
        }
        timedFrames.sort { $0.start < $1.start }

        guard let first = timedFrames.first, let last = timedFrames.last else {
            return SessionTimeline(target: target, date: date, integrationSeconds: integrationSeconds)
        }

        let windowStartDate = first.start
        let windowEndDate = last.start.addingTimeInterval(last.exptime)
        let windowSeconds = windowEndDate.timeIntervalSince(windowStartDate)

        let threshold = gapThreshold(config: config, timedFrames: timedFrames)
        var gaps: [Gap] = []
        for i in 1..<timedFrames.count {
            let prevEnd = timedFrames[i - 1].start.addingTimeInterval(timedFrames[i - 1].exptime)
            let nextStart = timedFrames[i].start
            let gapSeconds = nextStart.timeIntervalSince(prevEnd)
            if gapSeconds > threshold {
                gaps.append(Gap(start: iso(prevEnd), end: iso(nextStart), seconds: gapSeconds))
            }
        }

        let dutyCycle: Double? = windowSeconds > 0 ? integrationSeconds / windowSeconds : nil

        return SessionTimeline(
            target: target,
            date: date,
            windowStart: iso(windowStartDate),
            windowEnd: iso(windowEndDate),
            windowSeconds: windowSeconds,
            integrationSeconds: integrationSeconds,
            dutyCycle: dutyCycle,
            gaps: gaps
        )
    }

    /// `config.stats.gapThresholdSeconds` when positive; otherwise
    /// (`0` == auto) 3x the median NOMINAL exptime across the session's
    /// timed frames, absorbing float noise the same way rating/exposure-
    /// breakdown grouping does (see `NominalExposure`). `0` if no frame has
    /// an exptime at all -- degenerate, but never a crash.
    private static func gapThreshold(config: AstroConfig, timedFrames: [(start: Date, exptime: Double)]) -> Double {
        let configured = config.stats.gapThresholdSeconds
        guard configured <= 0 else { return configured }

        let nominalExptimes = timedFrames.map { NominalExposure.nominal($0.exptime) }.filter { $0 > 0 }
        guard !nominalExptimes.isEmpty else { return 0 }
        let sorted = nominalExptimes.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return median * 3
    }

    // MARK: - DATE-OBS parsing

    /// Parses either FITS-style (`"2026-04-18T04:36:24.123"`, optionally
    /// without the fractional part) or EXIF-style
    /// (`"2026:04:18 04:36:24"`) `DATE-OBS` text. `nil` if neither matches.
    /// All three formatters assume UTC -- consistent within one session's
    /// frames (same instrument/software), which is all gap/window math
    /// needs; no timezone offset is ever present in either source format.
    static func parseDateObs(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let date = fitsFormatterWithFraction.date(from: trimmed) { return date }
        if let date = fitsFormatterNoFraction.date(from: trimmed) { return date }
        if let date = exifFormatter.date(from: trimmed) { return date }
        return nil
    }

    private static func makeUTCFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static let fitsFormatterWithFraction = makeUTCFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")
    private static let fitsFormatterNoFraction = makeUTCFormatter("yyyy-MM-dd'T'HH:mm:ss")
    private static let exifFormatter = makeUTCFormatter("yyyy:MM:dd HH:mm:ss")

    private static func iso(_ date: Date) -> String {
        isoOutputFormatter.string(from: date)
    }

    /// `DateFormatter` (not `ISO8601DateFormatter`, which the Swift 6
    /// concurrency checker flags as non-`Sendable` shared mutable state for
    /// a `static let`) producing the same `"yyyy-MM-ddTHH:mm:ssZ"` shape,
    /// consistent with the UTC assumption `parseDateObs` already makes.
    private static let isoOutputFormatter = makeUTCFormatter("yyyy-MM-dd'T'HH:mm:ss'Z'")
}
