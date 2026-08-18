import Foundation

/// One target's altitude sweep across a night window: the maximum altitude
/// reached (culmination) and the extent of the above-`minAltitudeDeg` span.
/// Shared result type for `NightSweep.sweep` -- see that function's own doc
/// comment.
struct NightSweepResult: Sendable, Equatable {
    var maxAltitudeDeg: Double
    var culminationUTC: Date?
    var visibleSeconds: Double
    var visibleStart: Date?
    var visibleEnd: Date?
    /// `false` when `culminationUTC` is only the EDGE of the sampled
    /// dusk...dawn window (the target was still climbing at dawn, or was
    /// already past its peak at dusk) rather than a genuine meridian
    /// transit captured inside the window -- W7-A audit finding: a target
    /// still rising at dawn gets a "culminationUTC" that is really just
    /// "when we stopped looking", and labeling that "delelés HH:mm"
    /// (culmination) is dishonest. `false` (never `true`) when there was no
    /// sample at all. See `sweep`'s own doc comment for exactly how this is
    /// derived.
    var isGenuineCulmination: Bool
}

/// Brute-force night-window altitude sweep, plus the local-time formatting
/// built directly on top of it -- factored out of `Planner` (R10-A4) so
/// `DiscoveryPlanner.discover` reuses the EXACT same math rather than a
/// second copy that could silently drift from `Planner.plan`'s. `Planner`
/// itself was changed to call through to this type; its public behavior and
/// existing tests are unaffected by the move.
enum NightSweep {
    /// Samples the target's altitude every `stepMinutes` from dusk to dawn,
    /// tracking the maximum (culmination) and the extent of the
    /// above-`minAltitudeDeg` span. A brute-force scan rather than solving
    /// the transit time in closed form -- simpler to get right, and this
    /// tool only ever needs night-window granularity, not observatory
    /// pointing precision.
    ///
    /// `isGenuineCulmination` is derived from the SAME scan: when the
    /// tracked maximum sits at either the first or the last sample, the
    /// target was still rising (or already falling) at the very edge of
    /// `[duskUTC, dawnUTC]` -- the real transit lies outside the window
    /// entirely, and what got recorded as `culminationUTC` is merely "the
    /// last instant we looked", not a genuine meridian passage.
    static func sweep(
        raDeg: Double,
        decDeg: Double,
        latDeg: Double,
        lonDeg: Double,
        duskUTC: Date,
        dawnUTC: Date,
        minAltitudeDeg: Double,
        stepMinutes: Double = 2
    ) -> NightSweepResult {
        var maxAlt = -Double.infinity
        var maxAltDate: Date?
        var visibleSampleCount = 0
        var visibleStart: Date?
        var visibleEnd: Date?
        var firstSampleDate: Date?
        var lastSampleDate: Date?

        let stepSeconds = stepMinutes * 60
        var t = duskUTC
        while t <= dawnUTC {
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let (alt, _) = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg)

            if firstSampleDate == nil { firstSampleDate = t }
            lastSampleDate = t

            if alt > maxAlt {
                maxAlt = alt
                maxAltDate = t
            }

            if alt >= minAltitudeDeg {
                visibleSampleCount += 1
                if visibleStart == nil { visibleStart = t }
                visibleEnd = t
            }

            t = t.addingTimeInterval(stepSeconds)
        }

        let isGenuineCulmination: Bool
        if let maxAltDate, let firstSampleDate, let lastSampleDate {
            isGenuineCulmination = maxAltDate != firstSampleDate && maxAltDate != lastSampleDate
        } else {
            isGenuineCulmination = false
        }

        return NightSweepResult(
            maxAltitudeDeg: maxAlt.isFinite ? maxAlt : -90,
            culminationUTC: maxAltDate,
            visibleSeconds: Double(visibleSampleCount) * stepSeconds,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            isGenuineCulmination: isGenuineCulmination
        )
    }

    static func formatLocalTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    /// `"HH:mm–HH:mm"` (site-local time) window during which the target is
    /// at or above `minAltitudeDeg`, built from a sweep's
    /// `visibleStart`/`visibleEnd` -- `nil` whenever the sweep never was
    /// (either field `nil`). Shared by `Planner.buildPlan` and
    /// `DiscoveryPlanner.discover`, which both need the exact same
    /// "start–end" formatting on top of a `NightSweepResult`.
    static func visibleWindowLocal(_ result: NightSweepResult, timeZone: TimeZone) -> String? {
        guard let start = result.visibleStart, let end = result.visibleEnd else { return nil }
        return "\(formatLocalTime(start, timeZone: timeZone))–\(formatLocalTime(end, timeZone: timeZone))"
    }

    /// The Moon's position/illumination at the midpoint of `[duskUTC,
    /// dawnUTC]` -- both `Planner.buildPlan` and `DiscoveryPlanner.discover`
    /// evaluate the Moon ONCE at this single reference instant (not swept
    /// across the night) as their "is the Moon a problem tonight" check;
    /// see `Planner.buildPlan`'s own doc for why a single midpoint sample is
    /// good enough at this tool's planning-not-pointing precision.
    static func midnightMoon(duskUTC: Date, dawnUTC: Date) -> MidnightMoon {
        let midNight = duskUTC.addingTimeInterval(dawnUTC.timeIntervalSince(duskUTC) / 2)
        let midJD = JulianDate.julianDay(midNight)
        let moon = SunMoon.moonPosition(julianDay: midJD)
        let illuminationPercent = SunMoon.moonIlluminationPercent(julianDay: midJD)
        return MidnightMoon(illuminationPercent: illuminationPercent, raDeg: moon.raDeg, decDeg: moon.decDeg)
    }

    /// The Moon's own altitude, sampled every `stepMinutes` across
    /// `[startUTC, endUTC]` -- the ONE "walk the Moon across time" engine.
    /// `Planner.moonEventLabel` (rise/set wording for the "Hold" tile) and
    /// `moonAboveHorizonFraction` (the Moon-penalty altitude weighting
    /// `Planner.buildPlan`/`Planner.month`/`DiscoveryPlanner.discover` all
    /// share -- W7-A audit finding) both walk this exact loop rather than
    /// each keeping a private copy that could silently drift from the
    /// other. `[]` when `startUTC > endUTC` (nothing to sample).
    static func moonAltitudeSamples(
        latDeg: Double, lonDeg: Double, startUTC: Date, endUTC: Date, stepMinutes: Double = 5
    ) -> [(date: Date, altitudeDeg: Double)] {
        guard startUTC <= endUTC else { return [] }
        var samples: [(date: Date, altitudeDeg: Double)] = []
        let stepSeconds = stepMinutes * 60
        var t = startUTC
        while t <= endUTC {
            let jd = JulianDate.julianDay(t)
            let moon = SunMoon.moonPosition(julianDay: jd)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let altitudeDeg = AltAz.position(raDeg: moon.raDeg, decDeg: moon.decDeg, lstHours: lst, latDeg: latDeg).altitudeDeg
            samples.append((t, altitudeDeg))
            t = t.addingTimeInterval(stepSeconds)
        }
        return samples
    }

    /// Fraction (0...1) of `[startUTC, endUTC]`'s samples during which the
    /// Moon is above the horizon -- `nil` when the window is empty/
    /// degenerate (no samples at all, e.g. the target is never visible so
    /// there is no visible window to weight against).
    ///
    /// `Planner.buildPlan`/`Planner.month`/`DiscoveryPlanner.discover` all
    /// weight `SkyScore.moonFactor` by this: a Moon that has already set
    /// (or not yet risen) for the target's entire visible window cannot be
    /// brightening the sky during it, no matter how full it is or how
    /// close it sits to the target's coordinate -- the W7-A audit's central
    /// finding (verified against pyephem: on 2026-08-18 the Moon sits at
    /// −28.8° at the dark-window midpoint, yet the OLD illum×separation-only
    /// penalty applied in full).
    static func moonAboveHorizonFraction(
        latDeg: Double, lonDeg: Double, startUTC: Date, endUTC: Date, stepMinutes: Double = 5
    ) -> Double? {
        let samples = moonAltitudeSamples(latDeg: latDeg, lonDeg: lonDeg, startUTC: startUTC, endUTC: endUTC, stepMinutes: stepMinutes)
        guard !samples.isEmpty else { return nil }
        let aboveCount = samples.filter { $0.altitudeDeg >= 0 }.count
        return Double(aboveCount) / Double(samples.count)
    }
}

/// The Moon's position and illumination at one reference instant -- see
/// `NightSweep.midnightMoon`'s own doc comment.
struct MidnightMoon: Sendable, Equatable {
    var illuminationPercent: Double
    var raDeg: Double
    var decDeg: Double
}

/// Hungarian verdict vocabulary shared by `Planner.plan` and
/// `DiscoveryPlanner.discover` -- both surface the same "is this worth
/// pointing at tonight" judgment, just over a different universe of targets
/// (the user's library vs. the embedded catalog), so they must always agree
/// on wording. `Planner` alone still has a couple of lead-in cases that
/// never apply to `DiscoveryPlanner` (a catalog target always has a
/// coordinate and is never a comet), which is why those two stay put in
/// `Planner`'s own verdict priority list rather than becoming dead code
/// here.
public enum SkyVerdict {
    static let noCoordinate = "nincs koordináta"
    static func tooLow(_ maxAlt: Double) -> String { String(format: "alacsony (max %.0f°)", maxAlt) }
    static let notVisibleTonight = "nem látszik ma éjjel"
    static func moonInterferes(separationDeg: Double, illuminationPercent: Double) -> String {
        String(format: "Hold zavar (%.0f°, %.0f%%)", separationDeg, illuminationPercent)
    }
    static let good = "ma jó"
    /// Comets move degrees per day -- a session-derived coordinate (from
    /// whenever those frames were actually shot, possibly months ago) says
    /// nothing about where the comet is TONIGHT, so `Planner.plan` never
    /// computes a real "ma jó"/altitude/Moon verdict for one.
    /// `DiscoveryPlanner` never needs this case at all: the static catalog
    /// carries no comets (their positions aren't static), so this exists
    /// purely for `Planner`'s own use.
    static let cometStaleCoordinate = "üstökös — a tárolt koordináta a felvétel idejéből való, ma már nem érvényes"

    /// Parses one of this enum's own generated strings into a structured,
    /// locale-independent classification -- `Planner.plan`/
    /// `DiscoveryPlanner.discover` still generate the Hungarian sentence
    /// directly into `TargetPlan`/`DiscoveryRow` (V1's and the `astrotool`
    /// CLI's own consumers, unchanged), so this is the seam V2 -- and any
    /// future locale -- renders from instead of the engine emitting a
    /// second, pre-formatted sentence per locale. `SkyVerdictKind.english`
    /// is today's only renderer; a later localization pass adds siblings
    /// (e.g. a `.hungarian` that would just replay the constants above) over
    /// these SAME cases rather than re-deriving them from text again.
    /// Anything this doesn't recognize (there is no such case in today's
    /// closed vocabulary) is carried through as `.unrecognized` rather than
    /// silently dropped.
    public static func parse(_ verdict: String) -> SkyVerdictKind {
        switch verdict {
        case noCoordinate: return .noCoordinates
        case notVisibleTonight: return .notVisibleTonight
        case good: return .goodTonight
        case cometStaleCoordinate: return .cometStaleCoordinate
        default: break
        }
        if verdict.hasPrefix("alacsony (max "), verdict.hasSuffix("°)") {
            let inner = verdict.dropFirst("alacsony (max ".count).dropLast("°)".count)
            if let maxDeg = Double(inner) {
                return .lowAltitude(maxDeg: maxDeg)
            }
        }
        if verdict.hasPrefix("Hold zavar ("), verdict.hasSuffix("%)") {
            let inner = verdict.dropFirst("Hold zavar (".count).dropLast("%)".count)
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].hasSuffix("°"),
               let separationDeg = Double(parts[0].dropLast()),
               let illuminationPercent = Double(parts[1])
            {
                return .moonInterferes(separationDeg: separationDeg, illuminationPercent: illuminationPercent)
            }
        }
        return .unrecognized(verdict)
    }

    /// Convenience for callers that only ever want the English sentence --
    /// `parse(verdict).english`. Kept alongside `parse` because both V2 call
    /// sites (`PlanningQuery.recommendations()`, `HomeView`) want exactly
    /// this and nothing else from the structured value today.
    public static func english(_ verdict: String) -> String {
        parse(verdict).english
    }
}

/// `SkyVerdict.parse`'s own structured result -- see that function's doc for
/// why this exists instead of the engine emitting a second pre-formatted
/// sentence per locale. Carries the same numbers the Hungarian sentence
/// would have carried, so a renderer never has to re-parse text.
public enum SkyVerdictKind: Equatable, Sendable {
    case noCoordinates
    case notVisibleTonight
    case goodTonight
    case cometStaleCoordinate
    case lowAltitude(maxDeg: Double)
    case moonInterferes(separationDeg: Double, illuminationPercent: Double)
    /// `SkyVerdict.parse` didn't recognize the input (there is no such case
    /// in today's closed vocabulary) -- carries the original text through so
    /// no information is silently hidden.
    case unrecognized(String)

    /// Today's only renderer. A future localization pass adds a sibling
    /// (e.g. `hungarian`) over these same cases.
    public var english: String {
        switch self {
        case .noCoordinates: return "no coordinates"
        case .notVisibleTonight: return "not visible tonight"
        case .goodTonight: return "good tonight"
        case .cometStaleCoordinate:
            return "comet -- stored coordinate is from capture time, not valid for tonight"
        case let .lowAltitude(maxDeg):
            return String(format: "low (max %.0f°)", maxDeg)
        case let .moonInterferes(separationDeg, illuminationPercent):
            return String(format: "Moon interferes (%.0f°, %.0f%%)", separationDeg, illuminationPercent)
        case let .unrecognized(raw):
            return raw
        }
    }
}

/// `visibilityFactor` / `moonFactor` -- the two score components
/// `Planner.score`, `Planner.month`, and `DiscoveryPlanner`'s own scoring
/// all multiply against their own goal-related (`Planner`) or absent
/// (`DiscoveryPlanner`, "no goal component" per its own doc) leading
/// factor. Shared so these features can never silently disagree about what
/// "good visibility" or "the Moon is ruining this" numerically means.
enum SkyScore {
    /// `1` once `visibleHours` reaches 4, scaling linearly below that,
    /// floored at `0` (never negative).
    static func visibilityFactor(visibleHours: Double) -> Double {
        min(max(visibleHours, 0) / 4.0, 1.0)
    }

    /// Beyond this much separation the Moon is treated as out of the way
    /// even when full. Deliberately the same number
    /// `PlanningScore.moonIrrelevantSeparationDeg` uses in the
    /// `AstroApplication` module -- two independent implementations of the
    /// same design language (this module cannot import `AstroApplication`),
    /// kept numerically identical on purpose.
    static let moonIrrelevantSeparationDeg = 90.0

    /// Continuous Moon-interference factor, `0...1`, where `1` means "the
    /// Moon is no problem". Same "illumination × proximity" shape
    /// `PlanningScore.moonFactor` uses in `AstroApplication`, additionally
    /// weighted by `aboveHorizonFraction` -- the fraction of the TARGET's
    /// own visible window during which the Moon itself is above the
    /// horizon (`NightSweep.moonAboveHorizonFraction`).
    ///
    /// W7-A audit finding: the OLD binary form (`moonInterferes ? 0.2 : 1`,
    /// and `Planner.month`'s `separation >= 40 || illum < 60` OR-gated
    /// veto) both ignored Moon altitude entirely AND cliffed sharply at
    /// their thresholds (59% @ 41° kept full hours, 61% @ 39° zeroed them).
    /// This single continuous function replaces both call sites --
    /// `Planner.score`'s per-target ranking penalty and `Planner.month`'s
    /// usable-hours scaling -- so score and veto can never again diverge.
    ///
    /// `aboveHorizonFraction == 0` (Moon below the horizon for the target's
    /// entire visible window) always returns exactly `1`: a set Moon cannot
    /// brighten a sky it isn't lighting, regardless of illumination or
    /// separation -- "no penalty, no veto". The factor reaches exactly `0`
    /// (the documented "hours go to zero" limit) only for a 100%-illuminated
    /// Moon at 0° separation, above the horizon for the target's ENTIRE
    /// visible window; every other combination is a continuous reduction,
    /// never a step.
    static func moonFactor(
        separationDeg: Double,
        illuminationPercent: Double,
        aboveHorizonFraction: Double
    ) -> Double {
        let illumination = min(max(illuminationPercent / 100, 0), 1)
        let proximity = min(max(1 - separationDeg / moonIrrelevantSeparationDeg, 0), 1)
        let fraction = min(max(aboveHorizonFraction, 0), 1)
        let penalty = illumination * proximity * fraction
        return min(max(1 - penalty, 0), 1)
    }
}
