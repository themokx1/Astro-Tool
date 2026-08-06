import Foundation

/// One sampled point of an altitude-over-time track -- the raw series a
/// chart draws a target's or the Moon's curve from. `time` is always UTC
/// (existing module convention: everything internal is UTC, the view layer
/// formats to site-local) -- see `SkyTrack`'s own doc comment for exactly
/// how the sampling window is chosen.
public struct SkyTrackPoint: Sendable, Equatable {
    public let time: Date
    public let altitudeDeg: Double

    public init(time: Date, altitudeDeg: Double) {
        self.time = time
        self.altitudeDeg = altitudeDeg
    }
}

/// Twilight boundary markers for shading an altitude chart's background.
/// Astronomical (-18 deg) is the "true dark" band a chart would normally
/// shade darkest; nautical (-12 deg) is both the wider outer/fallback band
/// AND (see `SkyTrack.altitudeTrack`) the bound the sampled track itself is
/// sized to, so a chart can always draw SOME twilight shading even on a
/// night that never reaches real astronomical darkness.
///
/// `astroDuskUTC`/`astroDawnUTC` are `nil` together on a "white night" (the
/// Sun never reaches -18 deg -- common in summer at high latitude);
/// `nauticalDuskUTC`/`nauticalDawnUTC` are `nil` together only in the more
/// extreme case where even -12 deg is never reached (deep polar summer).
/// The nautical pair is never nil while the astronomical pair isn't --
/// -18 deg is strictly harder to reach than -12 deg on the same sweep.
public struct NightWindowMarkers: Sendable, Equatable {
    public let astroDuskUTC: Date?
    public let astroDawnUTC: Date?
    public let nauticalDuskUTC: Date?
    public let nauticalDawnUTC: Date?

    public init(astroDuskUTC: Date?, astroDawnUTC: Date?, nauticalDuskUTC: Date?, nauticalDawnUTC: Date?) {
        self.astroDuskUTC = astroDuskUTC
        self.astroDawnUTC = astroDawnUTC
        self.nauticalDuskUTC = nauticalDuskUTC
        self.nauticalDawnUTC = nauticalDawnUTC
    }
}

/// Chart-ready sky-track sampling for the altitude-over-the-night view
/// (R10-A2 core API; the chart view itself is R10-B2): pure, DB-free
/// wrappers around `AltAz`/`SunMoon`'s existing math -- no scanning, no
/// config resolution. Callers (the app layer) are expected to have already
/// resolved the observing site to concrete coordinates, e.g. via
/// `Planner.resolveSite(db:config:)`, the same way every other pure-math
/// function in `Sky/` (`AltAz.position`, `SunMoon.astronomicalTwilight`)
/// takes flat `latDeg`/`lonDeg` rather than a config-layer `SiteRule`.
///
/// `altitudeTrack`/`moonAltitudeTrack` both sample across the SAME window:
/// nautical dusk minus one hour to nautical dawn plus one hour, i.e. one
/// hour of margin either side of the wider (-12 deg) twilight bound, not
/// the narrower -18 deg one -- a chart reads better with a bit of daylight
/// context at both ends, and sizing to the wider bound means the track is
/// never accidentally narrower than `nightWindowMarkers`' own nautical
/// shading. When even nautical twilight never happens at all (deep polar
/// summer -- see `NightWindowMarkers`), sampling falls back to a plain
/// local-noon-to-noon span so the chart still has something to draw.
public enum SkyTrack {
    /// Altitude of a fixed RA/Dec target, sampled every `stepMinutes` across
    /// this night's sampling window (see the type's own doc comment).
    /// Never empty in practice -- even the most extreme site/date still
    /// resolves a fallback window.
    public static func altitudeTrack(
        raDeg: Double,
        decDeg: Double,
        nightOf date: Date,
        latDeg: Double,
        lonDeg: Double,
        stepMinutes: Int = 5
    ) -> [SkyTrackPoint] {
        let window = samplingWindow(nightOf: date, latDeg: latDeg, lonDeg: lonDeg)
        return sample(window: window, stepMinutes: stepMinutes) { t in
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            return AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg).altitudeDeg
        }
    }

    /// Same sampling window as `altitudeTrack`, for the Moon's altitude --
    /// its RA/Dec moves fast enough (unlike a fixed target's) that it's
    /// recomputed at every sample instant via `SunMoon.moonPosition`,
    /// rather than once for the whole night.
    public static func moonAltitudeTrack(
        nightOf date: Date,
        latDeg: Double,
        lonDeg: Double,
        stepMinutes: Int = 5
    ) -> [SkyTrackPoint] {
        let window = samplingWindow(nightOf: date, latDeg: latDeg, lonDeg: lonDeg)
        return sample(window: window, stepMinutes: stepMinutes) { t in
            let jd = JulianDate.julianDay(t)
            let moon = SunMoon.moonPosition(julianDay: jd)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            return AltAz.position(raDeg: moon.raDeg, decDeg: moon.decDeg, lstHours: lst, latDeg: latDeg).altitudeDeg
        }
    }

    /// Twilight boundary markers for shading the chart background -- see
    /// `NightWindowMarkers`'s own doc comment for the nil-together rules on
    /// white nights.
    public static func nightWindowMarkers(nightOf date: Date, latDeg: Double, lonDeg: Double) -> NightWindowMarkers {
        let dual = SunMoon.dualTwilight(nightOf: date, latDeg: latDeg, lonDeg: lonDeg, timeZone: TimeZone.current)
        return NightWindowMarkers(
            astroDuskUTC: dual.astroDuskUTC,
            astroDawnUTC: dual.astroDawnUTC,
            nauticalDuskUTC: dual.nauticalDuskUTC,
            nauticalDawnUTC: dual.nauticalDawnUTC
        )
    }

    // MARK: - Sampling window

    /// `[nauticalDusk - 1h, nauticalDawn + 1h]` when the night has a
    /// nautical twilight window at all; otherwise a plain local-noon-to-noon
    /// span (the "sites where the sun never reaches -12 deg" edge case --
    /// deep polar summer -- still needs SOME window to sample so the chart
    /// renders something meaningful rather than nothing).
    private static func samplingWindow(nightOf date: Date, latDeg: Double, lonDeg: Double) -> (start: Date, end: Date) {
        let timeZone = TimeZone.current
        let dual = SunMoon.dualTwilight(nightOf: date, latDeg: latDeg, lonDeg: lonDeg, timeZone: timeZone)
        if let duskUTC = dual.nauticalDuskUTC, let dawnUTC = dual.nauticalDawnUTC {
            return (duskUTC.addingTimeInterval(-3600), dawnUTC.addingTimeInterval(3600))
        }
        return noonToNoonWindow(nightOf: date, timeZone: timeZone)
    }

    /// Local noon of `date` to local noon of the following day -- the same
    /// span `SunMoon`'s own twilight scan sweeps internally, reused here as
    /// the clamped fallback when there's no twilight crossing at all to
    /// anchor the window to. Falls back further, to a bare +/-12h span
    /// around `date` itself, only on a pathological `Calendar` failure
    /// (essentially never in practice) -- `altitudeTrack`/
    /// `moonAltitudeTrack` must always get SOME window, never an empty one.
    private static func noonToNoonWindow(nightOf date: Date, timeZone: TimeZone) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: date)
        guard let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay),
              let nextNoon = calendar.date(byAdding: .hour, value: 24, to: noon)
        else {
            return (date.addingTimeInterval(-12 * 3600), date.addingTimeInterval(12 * 3600))
        }
        return (noon, nextNoon)
    }

    /// Evaluates `altitude` every `stepMinutes` across `[window.start,
    /// window.end]`, inclusive. `stepMinutes <= 0` is treated as `1` --
    /// guards against an infinite loop from a nonsensical caller-supplied
    /// step rather than trusting the default's positivity.
    private static func sample(window: (start: Date, end: Date), stepMinutes: Int, altitude: (Date) -> Double) -> [SkyTrackPoint] {
        let stepSeconds = Double(max(1, stepMinutes)) * 60
        var points: [SkyTrackPoint] = []
        var t = window.start
        while t <= window.end {
            points.append(SkyTrackPoint(time: t, altitudeDeg: altitude(t)))
            t = t.addingTimeInterval(stepSeconds)
        }
        return points
    }
}
