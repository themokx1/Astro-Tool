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

        let stepSeconds = stepMinutes * 60
        var t = duskUTC
        while t <= dawnUTC {
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let (alt, _) = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg)

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

        return NightSweepResult(
            maxAltitudeDeg: maxAlt.isFinite ? maxAlt : -90,
            culminationUTC: maxAltDate,
            visibleSeconds: Double(visibleSampleCount) * stepSeconds,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd
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

/// `visibilityFactor` / `moonPenalty` -- the two score components
/// `Planner.score` and `DiscoveryPlanner`'s own scoring both multiply
/// against their own goal-related (`Planner`) or absent (`DiscoveryPlanner`,
/// "no goal component" per its own doc) leading factor. Shared so the two
/// features can never silently disagree about what "good visibility" or
/// "the Moon is ruining this" numerically means.
enum SkyScore {
    /// `1` once `visibleHours` reaches 4, scaling linearly below that,
    /// floored at `0` (never negative).
    static func visibilityFactor(visibleHours: Double) -> Double {
        min(max(visibleHours, 0) / 4.0, 1.0)
    }

    /// `0.2` when the Moon verdict fired (see `SkyVerdict.moonInterferes`'s
    /// call site in both `Planner` and `DiscoveryPlanner`), else `1`.
    static func moonPenalty(moonInterferes: Bool) -> Double {
        moonInterferes ? 0.2 : 1.0
    }
}
