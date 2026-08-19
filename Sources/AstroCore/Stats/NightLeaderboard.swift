import Foundation

/// Ideation #7 ("Legjobb/legrosszabb éjszakák ranglistája" -- "best/worst
/// nights leaderboard"): ranks measured CAPTURES (not whole sessions) by a
/// transparent composite of three already-measured numbers -- median FWHM
/// (lower is better), capture accept rate (higher is better), and sky
/// background (lower is better) -- and returns the best 5 and worst 5.
///
/// GRAIN CHOICE: by the time this shipped, the Insights pipeline had already
/// moved its own quality trend charts to plot per CAPTURE GROUP
/// (`CaptureTrendPoint`, `AstroApplication`), not per whole session, exactly
/// because a session can hold more than one rig/filter combination and
/// blending their numbers together is physically meaningless (see that
/// type's own doc comment, W6-B: a Canon EOS R8 widefield rig and a ZWO
/// ASI2600MC narrowband rig the same night, folded into one line). A
/// leaderboard has the identical problem a blended trend line did --
/// ranking a NIGHT that mixed two rigs by one number would hide which half
/// of the night was actually good -- so this ranks the same per-capture
/// grain the trend charts already settled on, never `TrendQueries.
/// points`'s coarser whole-session `TrendPoint`. `AstroCore` itself has no
/// `CaptureTrendPoint` type (that's an `AstroApplication`-layer join this
/// lower layer cannot import -- `AstroApplication` depends on `AstroCore`,
/// never the reverse), so this operates on the plain `Input` struct below;
/// `InsightsQuery.nightLeaderboardSummary(points:)` is the one place that
/// maps `CaptureTrendPoint` down to `Input` and its `RankedEntry` results
/// back up to a display-ready row.
///
/// COMPOSITE, spelled out -- this doc comment is the entire algorithm,
/// nothing else feeds the ranking: for each of the three metrics, every
/// ELIGIBLE input (carries at least one of the three) that ALSO carries a
/// value for THAT metric gets a normalized rank in `0...1` (0 = best, 1 =
/// worst) among only the other inputs that carry the same metric -- tied
/// values share the average rank of the block they tie in, so an exact tie
/// never manufactures a fake ordering between them (`normalizedRanks`'s own
/// doc comment). An input's composite score is the plain average of
/// whichever of the three normalized ranks it actually has; a metric it
/// lacks simply isn't in that average -- nothing is imputed, defaulted, or
/// treated as "worst" on its behalf. This is what "a row missing a field
/// competes only on present fields" means: a capture with only FWHM
/// measured is ranked purely on its FWHM percentile, neither penalized nor
/// helped for the background/efficiency it doesn't have.
///
/// Every raw number a row was ranked on is exposed right back out on that
/// same row (`RankedEntry`) -- the UI shows those, never `compositeScore`
/// itself, so the order is auditable by eye without trusting a hidden
/// figure. "Transparent" means exactly that: no opaque number decides the
/// order, only the three measured quantities already on screen.
public enum NightLeaderboard {
    /// One capture's three ranking inputs, plus enough identity to report it
    /// and to break a tied composite score deterministically. Any of the
    /// three metrics may be `nil` -- the normal case for, say, a capture
    /// whose FWHM was never star-measured.
    public struct Input: Sendable, Equatable {
        public var id: String
        public var target: String
        public var date: String
        public var medianFWHMArcsec: Double?
        public var efficiencyPercent: Double?
        public var backgroundEPerSecPerArcsec2: Double?

        public init(
            id: String,
            target: String,
            date: String,
            medianFWHMArcsec: Double? = nil,
            efficiencyPercent: Double? = nil,
            backgroundEPerSecPerArcsec2: Double? = nil
        ) {
            self.id = id
            self.target = target
            self.date = date
            self.medianFWHMArcsec = medianFWHMArcsec
            self.efficiencyPercent = efficiencyPercent
            self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        }
    }

    /// One `Input` plus its resulting composite score -- `Result.best`/
    /// `.worst`'s own element type.
    public struct RankedEntry: Sendable, Equatable, Identifiable {
        public var id: String
        public var target: String
        public var date: String
        public var medianFWHMArcsec: Double?
        public var efficiencyPercent: Double?
        public var backgroundEPerSecPerArcsec2: Double?
        /// `0` (best measured capture in the whole eligible set) ... `1`
        /// (worst) -- see `NightLeaderboard`'s own doc comment for exactly
        /// how it's computed. Exposed for tests/auditing; the UI itself
        /// shows the three raw fields above, never this number.
        public var compositeScore: Double

        public init(
            id: String,
            target: String,
            date: String,
            medianFWHMArcsec: Double?,
            efficiencyPercent: Double?,
            backgroundEPerSecPerArcsec2: Double?,
            compositeScore: Double
        ) {
            self.id = id
            self.target = target
            self.date = date
            self.medianFWHMArcsec = medianFWHMArcsec
            self.efficiencyPercent = efficiencyPercent
            self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
            self.compositeScore = compositeScore
        }
    }

    public struct Result: Sendable, Equatable {
        /// Best-first, capped at `displayCount`.
        public var best: [RankedEntry]
        /// Worst-first, capped at `displayCount`. Can overlap `best` when
        /// fewer than `2 * displayCount` captures are eligible at all -- an
        /// honest reflection of a thin library, not a bug: with exactly 5
        /// eligible captures both lists show the same 5, one reversed.
        public var worst: [RankedEntry]
        /// Count of inputs that carried at least one of the three metrics --
        /// the number callers gate the empty-state hint on, not
        /// `inputs.count` itself (a capture with none of the three measured
        /// contributes nothing to rank and doesn't count toward "measured").
        public var measuredCount: Int

        public init(best: [RankedEntry], worst: [RankedEntry], measuredCount: Int) {
            self.best = best
            self.worst = worst
            self.measuredCount = measuredCount
        }
    }

    /// Below this many measured captures, ranking would be more noise than
    /// signal -- callers show an honest empty-state hint instead of a
    /// leaderboard nobody can trust yet.
    public static let minimumMeasuredCount = 5

    /// How many rows each of `best`/`worst` caps out at.
    public static let displayCount = 5

    public static func rank(_ inputs: [Input]) -> Result {
        let eligible = inputs.filter {
            $0.medianFWHMArcsec != nil || $0.efficiencyPercent != nil || $0.backgroundEPerSecPerArcsec2 != nil
        }
        guard eligible.count >= minimumMeasuredCount else {
            return Result(best: [], worst: [], measuredCount: eligible.count)
        }

        let fwhmRanks = normalizedRanks(
            eligible.compactMap { input in input.medianFWHMArcsec.map { (id: input.id, value: $0) } },
            higherIsBetter: false
        )
        let efficiencyRanks = normalizedRanks(
            eligible.compactMap { input in input.efficiencyPercent.map { (id: input.id, value: $0) } },
            higherIsBetter: true
        )
        let backgroundRanks = normalizedRanks(
            eligible.compactMap { input in input.backgroundEPerSecPerArcsec2.map { (id: input.id, value: $0) } },
            higherIsBetter: false
        )

        let entries: [RankedEntry] = eligible.map { input in
            var components: [Double] = []
            if let r = fwhmRanks[input.id] { components.append(r) }
            if let r = efficiencyRanks[input.id] { components.append(r) }
            if let r = backgroundRanks[input.id] { components.append(r) }
            // `input` is a member of `eligible`, so it carries at least one
            // of the three metrics -- `components` is therefore never empty
            // and this average is always well-defined.
            let score = components.reduce(0, +) / Double(components.count)
            return RankedEntry(
                id: input.id, target: input.target, date: input.date,
                medianFWHMArcsec: input.medianFWHMArcsec,
                efficiencyPercent: input.efficiencyPercent,
                backgroundEPerSecPerArcsec2: input.backgroundEPerSecPerArcsec2,
                compositeScore: score
            )
        }

        // Deterministic total order: composite score decides first, then
        // target/date/id purely to break an EXACT tie the same way every
        // time regardless of input order -- never a meaningful ranking
        // signal on their own.
        let best = entries.sorted {
            ($0.compositeScore, $0.target, $0.date, $0.id) < ($1.compositeScore, $1.target, $1.date, $1.id)
        }
        let worst = entries.sorted {
            (-$0.compositeScore, $0.target, $0.date, $0.id) < (-$1.compositeScore, $1.target, $1.date, $1.id)
        }

        return Result(
            best: Array(best.prefix(displayCount)),
            worst: Array(worst.prefix(displayCount)),
            measuredCount: eligible.count
        )
    }

    /// Fractional ("competition") rank of each `(id, value)` in `values`,
    /// normalized to `0...1` where `0` is the best value and `1` the worst --
    /// direction controlled by `higherIsBetter`. Tied values share the
    /// AVERAGE rank of the block they tie in (e.g. two values tied for
    /// best-and-second-best both land on the rank halfway between those two
    /// positions, rather than one arbitrarily placed ahead of the other) --
    /// which is what makes the result independent of `values`'s own input
    /// order, and what `NightLeaderboard`'s own tie-determinism guarantee
    /// ultimately rests on. A single value has no spread to rank against, so
    /// it gets the neutral midpoint `0.5` rather than a meaningless `0`.
    private static func normalizedRanks(
        _ values: [(id: String, value: Double)],
        higherIsBetter: Bool
    ) -> [String: Double] {
        guard values.count > 1 else {
            return Dictionary(uniqueKeysWithValues: values.map { ($0.id, 0.5) })
        }
        let sorted = values.sorted { higherIsBetter ? $0.value > $1.value : $0.value < $1.value }
        var ranks: [String: Double] = [:]
        let n = sorted.count
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n, sorted[j + 1].value == sorted[i].value { j += 1 }
            let averagePosition = Double(i + j) / 2.0
            let normalized = averagePosition / Double(n - 1)
            for k in i...j { ranks[sorted[k].id] = normalized }
            i = j + 1
        }
        return ranks
    }
}
