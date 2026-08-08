import Foundation

/// Hold-tudatos szűrő-ajánlás (R11-T6/F3): given tonight's Moon state
/// (illumination + the specific target's angular separation from it) and the
/// target's own per-filter goals (`TargetPlan.filterGoals`, R11-T5/F2), works
/// out whether tonight favors narrowband over broadband/OSC imaging on this
/// target, and -- when the target actually has filter goals -- which
/// specific filter in that category is the biggest outstanding deficit. Pure
/// and `Database`-free (same "computed straight off already-known numbers"
/// shape as `SkyScore`), so `Planner.buildPlan` can call it inline for every
/// target without any extra query. Deliberately just a recommendation --
/// never folds into the hard visibility/Moon-interference verdict rules
/// `Planner.buildPlan` already applies, only ever ADDS a filter suggestion
/// on top of an already-"ma jó" verdict (`augmentedVerdict`).
public enum FilterAdvisor {
    /// The Moon-illumination threshold (>) that alone is enough to call
    /// tonight a narrowband night, regardless of separation.
    public static let narrowbandIlluminationThreshold: Double = 40
    /// The target-separation threshold (<, degrees) that alone is enough to
    /// call tonight a narrowband night, regardless of illumination.
    public static let narrowbandSeparationThreshold: Double = 60

    /// Tonight's Moon-driven recommendation for this target: shoot
    /// narrowband (Moon bright and/or close) or broadband/OSC (dark sky, or
    /// the Moon is far enough not to matter).
    public enum SkyState: String, Codable, Sendable, Equatable {
        case narrowband, dark
    }

    /// One target's filter advice for tonight -- see `advice(...)`'s own doc
    /// comment for exactly how each field is derived.
    public struct Advice: Codable, Sendable, Equatable {
        public var skyState: SkyState
        /// Hungarian label: `"keskenysáv-éjszaka"` / `"sötét ég"`.
        public var label: String
        /// The biggest-deficit filter goal (`FilterGoalQueries.
        /// biggestDeficit`) among `filterGoals` in the category `skyState`
        /// favors (narrowband filters -- `AstroConfig.plan.
        /// narrowbandFilters` -- on a narrowband night, everything else on a
        /// dark one) -- `nil` when the target has no filter goal in that
        /// category at all, or every one of them is already met
        /// (`missingSeconds <= 0`).
        public var recommendedFilter: FilterIntegration?
        /// Hungarian justification for `skyState`, e.g. `"Hold 82%,
        /// szeparáció 41° — keskenysáv ajánlott"` -- always populated,
        /// regardless of whether a specific filter got recommended.
        public var reason: String

        public init(skyState: SkyState, label: String, recommendedFilter: FilterIntegration?, reason: String) {
            self.skyState = skyState
            self.label = label
            self.recommendedFilter = recommendedFilter
            self.reason = reason
        }
    }

    /// Threshold rule (R11-T6/F3 spec): a narrowband night is one where the
    /// Moon is either more than 40% illuminated OR closer than 60° to the
    /// target -- either condition alone is enough (an OR, not an AND), since
    /// either one alone already washes out broadband/OSC contrast on its
    /// own. A dark night is simply "neither condition holds".
    public static func advice(
        moonIlluminationPercent: Double,
        moonSeparationDeg: Double,
        filterGoals: [FilterIntegration],
        narrowbandFilters: [String]
    ) -> Advice {
        let isNarrowbandNight = moonIlluminationPercent > narrowbandIlluminationThreshold
            || moonSeparationDeg < narrowbandSeparationThreshold
        let skyState: SkyState = isNarrowbandNight ? .narrowband : .dark
        let label = isNarrowbandNight ? "keskenysáv-éjszaka" : "sötét ég"
        let reason = String(
            format: "Hold %.0f%%, szeparáció %.0f° — %@",
            moonIlluminationPercent, moonSeparationDeg,
            isNarrowbandNight ? "keskenysáv ajánlott" : "sötét ég ajánlott"
        )

        let narrowbandSet = Set(narrowbandFilters.map { $0.lowercased() })
        let categoryGoals = filterGoals.filter { entry in
            narrowbandSet.contains(entry.filter.lowercased()) == isNarrowbandNight
        }
        let recommendedFilter = FilterGoalQueries.biggestDeficit(categoryGoals)

        return Advice(skyState: skyState, label: label, recommendedFilter: recommendedFilter, reason: reason)
    }

    /// Illumination-only narrowband/dark judgment (R11-T6/F3's calendar
    /// "NB"/"sötét" label) -- `TonightPage`'s calendar segment has no
    /// per-target separation to fold in (`NightSummary` carries no target
    /// coordinate at all), so it only ever checks the Moon-illumination half
    /// of `advice(...)`'s OR rule. Shares `narrowbandIlluminationThreshold`
    /// with `advice(...)` rather than hardcoding a second "> 40" literal, so
    /// the two can never quietly drift apart.
    public static func isNarrowbandByIlluminationAlone(moonIlluminationPercent: Double) -> Bool {
        moonIlluminationPercent > narrowbandIlluminationThreshold
    }

    /// Compact "Szűrő ma" text (`TonightPage`'s plan-table chip, the CLI/app
    /// plan-export columns): the biggest-deficit filter with its outstanding
    /// hours (`"Ha (-6,2h)"`) when tonight's recommended category has one;
    /// the target's OWN filter-goal names joined by `"/"` (`"Ha/SII"`) when
    /// it has filter goals but none has an outstanding deficit in that
    /// category (either they're all already met, or they're all in the
    /// OTHER category); `nil` when the target has no filter goal at all --
    /// callers render their own "no data" glyph for that case (`TDFormat.
    /// missingCell` for a table cell, an empty CSV field, `"-"` for the
    /// clipboard export).
    public static func chipText(advice: Advice, filterGoals: [FilterIntegration]) -> String? {
        guard !filterGoals.isEmpty else { return nil }
        if let recommended = advice.recommendedFilter, (recommended.missingSeconds ?? 0) > 0 {
            return "\(recommended.filter) (-\(decimalHours(recommended.missingSeconds ?? 0))h)"
        }
        return filterGoals.map(\.filter).joined(separator: "/")
    }

    /// `"ma jó — Ha-ra"` -- `Planner.buildPlan`'s verdict augmentation
    /// (R11-T6/F3): only ever applied on top of the plain "ma jó" verdict,
    /// and only when tonight actually favors narrowband on this target AND
    /// there's a real outstanding NB deficit to point at -- everything else
    /// (no filter goals, dark night, goal already met) leaves the verdict
    /// untouched.
    public static func augmentedVerdict(baseVerdict: String, advice: Advice) -> String {
        guard baseVerdict == SkyVerdict.good,
              advice.skyState == .narrowband,
              let recommended = advice.recommendedFilter,
              (recommended.missingSeconds ?? 0) > 0
        else { return baseVerdict }
        return "\(baseVerdict) — \(recommended.filter)\(sublativeSuffix(for: recommended.filter))"
    }

    /// Hungarian sublative suffix ("-ra"/"-re") for appending a filter name
    /// directly onto a verdict string (`"ma jó"` -> `"ma jó — Ha-ra"`) --
    /// picked by the LAST vowel in `filter`'s name (back vowel -> "-ra",
    /// front vowel -> "-re"), the same vowel-harmony rule Hungarian grammar
    /// always applies to this suffix. Falls back to "-ra" for a name with no
    /// vowel at all (shouldn't happen for any real filter name).
    static func sublativeSuffix(for filter: String) -> String {
        let backVowels: Set<Character> = ["a", "á", "o", "ó", "u", "ú"]
        let frontVowels: Set<Character> = ["e", "é", "i", "í", "ö", "ő", "ü", "ű"]
        let lowered = filter.lowercased()
        if let lastVowel = lowered.reversed().first(where: { backVowels.contains($0) || frontVowels.contains($0) }) {
            return frontVowels.contains(lastVowel) ? "-re" : "-ra"
        }
        return "-ra"
    }

    /// `"6,2"` -- decimal hours (one decimal place) with the Hungarian comma
    /// separator, ASCII decimal point swapped for `,` -- same trick
    /// `ExposureAdvisor`'s own private `hu` helper established first, kept
    /// as its own tiny copy here rather than a shared export since
    /// `AstroCore` has no single shared "Hungarian number formatting" type
    /// yet (`TDFormat`, the app-layer equivalent, can't be reached from
    /// here).
    private static func decimalHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        return String(format: "%.1f", hours).replacingOccurrences(of: ".", with: ",")
    }
}
