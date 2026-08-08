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

    public init(
        target: String,
        date: String,
        sessionStartDate: String? = nil,
        medianFWHMArcsec: Double? = nil,
        medianFWHMPixels: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil,
        efficiencyPercent: Double? = nil,
        setupDescriptor: String? = nil
    ) {
        self.target = target
        self.date = date
        self.sessionStartDate = sessionStartDate
        self.medianFWHMArcsec = medianFWHMArcsec
        self.medianFWHMPixels = medianFWHMPixels
        self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        self.efficiencyPercent = efficiencyPercent
        self.setupDescriptor = setupDescriptor
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
                    setupDescriptor: setupDescriptor
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
