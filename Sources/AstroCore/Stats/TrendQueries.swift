import Foundation

/// One session's worth of long-term trend metrics -- the `Trendek` page's
/// (R11-T10/F7) unit of data. Reuses `NightsQueries.allNights`'s already-
/// computed per-session numbers (median FWHM, background e⁻/s/″², duty
/// cycle) rather than recomputing `SessionQuality`/`SessionTimeline` a
/// second time, and adds only what that cross-target browsing surface
/// doesn't carry: the session's dominant `EquipmentProfile` setup
/// descriptor (for the optional setup-fingerprint filter) and its parsed
/// canonical start date (for the optional date-range filter and for
/// chronological sorting -- `NightsQueries` itself sorts newest-first, the
/// opposite of what a time-series chart / moving average wants).
public struct TrendPoint: Codable, Sendable, Equatable {
    public var target: String
    /// Raw session date-dir name, verbatim -- same convention as
    /// `NightRow.date`.
    public var date: String
    /// The session's canonical `YYYY-MM-DD` start date, or `nil` when the
    /// date-dir name doesn't parse as one at all (e.g. a stray non-date
    /// folder) -- such sessions are excluded whenever a `from`/`to` range
    /// filter is active (see `TrendQueries.points`), but still sort (by
    /// their raw text) when browsing unfiltered.
    public var sessionStartDate: String?
    public var medianFWHMArcsec: Double?
    public var medianFWHMPixels: Double?
    public var backgroundEPerSecPerArcsec2: Double?
    /// From `NightRow.dutyCyclePercent` -- "hatékonyság%" (the fraction of
    /// the night's dark window actually spent integrating), already scaled
    /// to 0...100.
    public var efficiencyPercent: Double?
    /// This session's dominant `EquipmentProfile` setup fingerprint
    /// descriptor (`EquipmentProfile.dominant(...)?.descriptor`), `nil` when
    /// its lights carry no derivable fingerprint at all.
    public var setupDescriptor: String?
    /// Usable (deduped, non-rejected) acquisition volume. Unlike quality
    /// metrics these exist for an ordinary un-rated session too, allowing
    /// Trends to be useful from the very first night.
    public var integrationSeconds: Double
    public var usableFrameCount: Int
    /// The same resolved capture/FITS filter buckets shown on Nights and in
    /// reports; this is deliberately not rebuilt from raw FITS headers.
    public var filterBreakdown: [FilterIntegration]

    public init(
        target: String,
        date: String,
        sessionStartDate: String? = nil,
        medianFWHMArcsec: Double? = nil,
        medianFWHMPixels: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil,
        efficiencyPercent: Double? = nil,
        setupDescriptor: String? = nil,
        integrationSeconds: Double = 0,
        usableFrameCount: Int = 0,
        filterBreakdown: [FilterIntegration] = []
    ) {
        self.target = target
        self.date = date
        self.sessionStartDate = sessionStartDate
        self.medianFWHMArcsec = medianFWHMArcsec
        self.medianFWHMPixels = medianFWHMPixels
        self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        self.efficiencyPercent = efficiencyPercent
        self.setupDescriptor = setupDescriptor
        self.integrationSeconds = integrationSeconds
        self.usableFrameCount = usableFrameCount
        self.filterBreakdown = filterBreakdown
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case date
        case sessionStartDate
        case medianFWHMArcsec
        case medianFWHMPixels
        case backgroundEPerSecPerArcsec2
        case efficiencyPercent
        case setupDescriptor
        case integrationSeconds
        case usableFrameCount
        case filterBreakdown
    }

    /// Keeps CLI/API JSON from earlier releases readable after acquisition
    /// dashboard fields were added in v0.15.3.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(String.self, forKey: .target)
        date = try values.decode(String.self, forKey: .date)
        sessionStartDate = try values.decodeIfPresent(String.self, forKey: .sessionStartDate)
        medianFWHMArcsec = try values.decodeIfPresent(Double.self, forKey: .medianFWHMArcsec)
        medianFWHMPixels = try values.decodeIfPresent(Double.self, forKey: .medianFWHMPixels)
        backgroundEPerSecPerArcsec2 = try values.decodeIfPresent(Double.self, forKey: .backgroundEPerSecPerArcsec2)
        efficiencyPercent = try values.decodeIfPresent(Double.self, forKey: .efficiencyPercent)
        setupDescriptor = try values.decodeIfPresent(String.self, forKey: .setupDescriptor)
        integrationSeconds = try values.decodeIfPresent(Double.self, forKey: .integrationSeconds) ?? 0
        usableFrameCount = try values.decodeIfPresent(Int.self, forKey: .usableFrameCount) ?? 0
        filterBreakdown = try values.decodeIfPresent([FilterIntegration].self, forKey: .filterBreakdown) ?? []
    }

    /// The FWHM value the "Trendek" chart should actually plot, plus whether
    /// it's the px-fallback (no derivable pixel scale, so the RAW pixel
    /// FWHM stands in for the arcsec one) -- `TrendsPage`/`cmdTrends` share
    /// this so the app and the CLI never disagree about which of the two
    /// FWHM fields wins. `nil` when neither is available (session never
    /// rated, or rated with no FWHM at all).
    public var fwhmValue: (value: Double, isPixelFallback: Bool)? {
        if let arcsec = medianFWHMArcsec { return (arcsec, false) }
        if let pixels = medianFWHMPixels { return (pixels, true) }
        return nil
    }
}

/// Builds `TrendPoint` series across every target on record, for the
/// "Trendek" page (R11-T10/F7) and its `astrotool trends` CLI counterpart.
/// Read-only against `Database`; never touches the filesystem.
public enum TrendQueries {
    /// Every session on record whose parsed start date (when both it and
    /// the filter are present) falls within `[from, to]` and whose dominant
    /// setup descriptor matches `setupFingerprint` (when given), sorted
    /// chronologically ascending (oldest first -- the opposite of
    /// `NightsQueries.allNights`'s newest-first browsing order, since a time
    /// series / moving average reads left-to-right in calendar order).
    ///
    /// A session whose date-dir name doesn't parse as a real calendar date
    /// is excluded whenever `from`/`to` is given (there's no date to compare
    /// against), same "excluded from range filters, still listed
    /// unfiltered" convention `NightsQueries.allNights`'s own `year`/`month`
    /// filter already uses.
    public static func points(
        db: Database,
        config: AstroConfig,
        setupFingerprint: String? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) throws -> [TrendPoint] {
        let nights = try NightsQueries.allNights(db: db, config: config)

        var results: [TrendPoint] = []
        for night in nights {
            let parsedStart = SessionDateParser.parse(night.date, patterns: config.intentional)?.start
            guard matchesRange(parsedStart: parsedStart, from: from, to: to) else { continue }

            let fingerprintCounts = try EquipmentProfile.sessionFingerprints(
                target: night.target, date: night.date, db: db, config: config
            )
            let setupDescriptor = EquipmentProfile.dominant(fingerprintCounts)?.descriptor

            if let setupFingerprint, setupDescriptor != setupFingerprint { continue }

            results.append(
                TrendPoint(
                    target: night.target,
                    date: night.date,
                    sessionStartDate: parsedStart,
                    medianFWHMArcsec: night.medianFWHMArcsec,
                    medianFWHMPixels: night.medianFWHMPixels,
                    backgroundEPerSecPerArcsec2: night.backgroundEPerSecPerArcsec2,
                    efficiencyPercent: night.dutyCyclePercent,
                    setupDescriptor: setupDescriptor,
                    integrationSeconds: night.integrationSeconds,
                    usableFrameCount: night.usableLightCount,
                    filterBreakdown: night.filterBreakdown
                )
            )
        }

        results.sort { lhs, rhs in
            let l = lhs.sessionStartDate ?? lhs.date
            let r = rhs.sessionStartDate ?? rhs.date
            if l != r { return l < r }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.date < rhs.date
        }
        return results
    }

    /// Every distinct, non-nil `setupDescriptor` among `points`, sorted --
    /// what `TrendsPage`'s toolbar setup-fingerprint filter menu (and
    /// `cmdTrends`'s `--setup` validation) lists as choices.
    public static func distinctSetupDescriptors(_ points: [TrendPoint]) -> [String] {
        Array(Set(points.compactMap(\.setupDescriptor))).sorted()
    }

    private static func matchesRange(parsedStart: String?, from: Date?, to: Date?) -> Bool {
        guard from != nil || to != nil else { return true }
        guard let parsedStart, let date = ymdFormatter.date(from: parsedStart) else { return false }
        if let from, date < from { return false }
        if let to, date > to { return false }
        return true
    }

    /// `YYYY-MM-DD`, UTC -- parses `SessionDateParser`'s own canonical
    /// `start`/`end` text back into a `Date` purely for range comparison
    /// (never displayed).
    private static let ymdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Acquisition dashboard roll-ups

public struct TrendMonthSummary: Sendable, Equatable, Identifiable {
    public var month: String
    public var sessionCount: Int
    public var distinctNightCount: Int
    public var integrationSeconds: Double
    public var usableFrameCount: Int
    public var id: String { month }
}

public struct TrendTargetSummary: Sendable, Equatable, Identifiable {
    public var target: String
    public var sessionCount: Int
    public var integrationSeconds: Double
    public var usableFrameCount: Int
    public var lastDate: String
    public var id: String { target }
}

public struct TrendFilterSummary: Sendable, Equatable, Identifiable {
    public var filter: String
    public var sessionCount: Int
    public var integrationSeconds: Double
    public var usableFrameCount: Int
    public var id: String { filter }
}

public struct TrendDashboardSummary: Sendable, Equatable {
    public var sessionCount: Int
    public var distinctNightCount: Int
    public var integrationSeconds: Double
    public var usableFrameCount: Int
    public var firstDate: String?
    public var lastDate: String?
    public var averageEfficiencyPercent: Double?
    public var months: [TrendMonthSummary]
    public var targets: [TrendTargetSummary]
    public var filters: [TrendFilterSummary]
}

/// Pure report/dashboard composition over already-filtered Trend points.
/// App controls can therefore narrow once and every tile/chart/table stays
/// on exactly the same scope without another database query.
public enum TrendAnalytics {
    public static func summarize(_ points: [TrendPoint]) -> TrendDashboardSummary {
        let dated = points.sorted {
            ($0.sessionStartDate ?? $0.date, $0.target, $0.date)
                < ($1.sessionStartDate ?? $1.date, $1.target, $1.date)
        }
        let efficiencies = points.compactMap(\.efficiencyPercent)

        let byMonth = Dictionary(grouping: points) { point in
            monthKey(point.sessionStartDate ?? point.date)
        }
        let months = byMonth.map { month, values in
            TrendMonthSummary(
                month: month,
                sessionCount: values.count,
                distinctNightCount: Set(values.map { $0.sessionStartDate ?? $0.date }).count,
                integrationSeconds: values.reduce(0) { $0 + $1.integrationSeconds },
                usableFrameCount: values.reduce(0) { $0 + $1.usableFrameCount }
            )
        }.sorted { lhs, rhs in
            if lhs.month == "ismeretlen" { return false }
            if rhs.month == "ismeretlen" { return true }
            return lhs.month < rhs.month
        }

        let targets = Dictionary(grouping: points, by: \.target).map { target, values in
            TrendTargetSummary(
                target: target,
                sessionCount: values.count,
                integrationSeconds: values.reduce(0) { $0 + $1.integrationSeconds },
                usableFrameCount: values.reduce(0) { $0 + $1.usableFrameCount },
                lastDate: values.map { $0.sessionStartDate ?? $0.date }.max() ?? ""
            )
        }.sorted {
            if $0.integrationSeconds != $1.integrationSeconds {
                return $0.integrationSeconds > $1.integrationSeconds
            }
            return $0.target < $1.target
        }

        struct FilterAccumulator {
            var sessions = Set<String>()
            var seconds = 0.0
            var frames = 0
        }
        var filterTotals: [String: FilterAccumulator] = [:]
        for point in points {
            let sessionKey = "\(point.target)\u{1F}\(point.date)"
            for bucket in point.filterBreakdown {
                filterTotals[bucket.filter, default: FilterAccumulator()].sessions.insert(sessionKey)
                filterTotals[bucket.filter, default: FilterAccumulator()].seconds += bucket.integrationSeconds
                filterTotals[bucket.filter, default: FilterAccumulator()].frames += bucket.usableFrameCount
            }
        }
        let filters = filterTotals.map { filter, total in
            TrendFilterSummary(
                filter: filter,
                sessionCount: total.sessions.count,
                integrationSeconds: total.seconds,
                usableFrameCount: total.frames
            )
        }.sorted {
            if $0.integrationSeconds != $1.integrationSeconds {
                return $0.integrationSeconds > $1.integrationSeconds
            }
            return $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending
        }

        return TrendDashboardSummary(
            sessionCount: points.count,
            distinctNightCount: Set(points.map { $0.sessionStartDate ?? $0.date }).count,
            integrationSeconds: points.reduce(0) { $0 + $1.integrationSeconds },
            usableFrameCount: points.reduce(0) { $0 + $1.usableFrameCount },
            firstDate: dated.first.map { $0.sessionStartDate ?? $0.date },
            lastDate: dated.last.map { $0.sessionStartDate ?? $0.date },
            averageEfficiencyPercent: efficiencies.isEmpty
                ? nil
                : efficiencies.reduce(0, +) / Double(efficiencies.count),
            months: months,
            targets: targets,
            filters: filters
        )
    }

    private static func monthKey(_ date: String) -> String {
        guard date.count >= 7 else { return "ismeretlen" }
        let prefix = String(date.prefix(7))
        guard prefix.count == 7, prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-" else {
            return "ismeretlen"
        }
        return prefix
    }
}

/// Pure moving-average helper, shared by `TrendsPage`'s three charts and
/// (indirectly, via the same core function) anything else that ever wants a
/// smoothed trend line over a metric with gaps.
public enum TrendMath {
    /// A trailing moving average over the NON-NIL values in `values`, in
    /// order -- the result is the SAME LENGTH as `values`; a position where
    /// `values` itself is `nil` (no data point there at all) stays `nil` in
    /// the result too (there's nothing to average AROUND, and a chart line
    /// has no x-value to plot it at anyway). At a non-nil position, the
    /// average is taken over the last `min(window, k)` non-nil values up to
    /// and including that one, where `k` is how many non-nil values have
    /// been seen so far in the sequence -- so the first few real points
    /// (fewer than `window` real values behind them yet) still get an
    /// average over whatever IS available, rather than `nil` until the
    /// window fully fills.
    public static func movingAverage(_ values: [Double?], window: Int = 5) -> [Double?] {
        guard window > 0 else { return values.map { _ in nil } }

        var result: [Double?] = []
        result.reserveCapacity(values.count)
        var buffer: [Double] = []
        buffer.reserveCapacity(window)

        for value in values {
            guard let value else {
                result.append(nil)
                continue
            }
            buffer.append(value)
            if buffer.count > window { buffer.removeFirst() }
            result.append(buffer.reduce(0, +) / Double(buffer.count))
        }
        return result
    }
}
