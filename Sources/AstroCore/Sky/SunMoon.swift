import Foundation

/// Low-precision Sun/Moon position (Jean Meeus, *Astronomical Algorithms*,
/// Ch. 25 and Ch. 47/48 -- truncated to the largest-amplitude periodic
/// terms), illumination fraction, angular separation, and twilight-window
/// scanning. "Low precision" here means: Sun position good to a few
/// arcminutes, Moon position good to a few tenths of a degree -- more than
/// enough for "is this target above 30 deg tonight, and is the Moon nearby",
/// nowhere near enough for pointing a mount.
public enum SunMoon {
    public struct EquatorialPosition: Sendable, Equatable {
        public var raDeg: Double
        public var decDeg: Double

        public init(raDeg: Double, decDeg: Double) {
            self.raDeg = raDeg
            self.decDeg = decDeg
        }
    }

    // MARK: - Angle helpers

    static func normalizedDeg(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }

    private static func deg2rad(_ d: Double) -> Double { d * .pi / 180.0 }
    private static func rad2deg(_ r: Double) -> Double { r * 180.0 / .pi }

    // MARK: - Sun position

    /// Apparent geocentric equatorial position of the Sun at `jd` (UT),
    /// Meeus Ch. 25 low-precision solar coordinates (accuracy ~0.01 deg,
    /// i.e. a few tenths of an arcminute).
    public static func sunPosition(julianDay jd: Double) -> EquatorialPosition {
        let T = (jd - 2451545.0) / 36525.0
        let L0 = normalizedDeg(280.46646 + 36000.76983 * T + 0.0003032 * T * T)
        let M = normalizedDeg(357.52911 + 35999.05029 * T - 0.0001537 * T * T)
        let Mr = deg2rad(M)

        let C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * sin(Mr)
            + (0.019993 - 0.000101 * T) * sin(2 * Mr)
            + 0.000289 * sin(3 * Mr)

        let trueLong = L0 + C
        let omega = 125.04 - 1934.136 * T
        let apparentLong = trueLong - 0.00569 - 0.00478 * sin(deg2rad(omega))

        let epsilon0 = 23.0 + 26.0 / 60.0 + 21.448 / 3600.0
            - (46.8150 / 3600.0) * T
            - (0.00059 / 3600.0) * T * T
            + (0.001813 / 3600.0) * T * T * T
        let epsilon = epsilon0 + 0.00256 * cos(deg2rad(omega))

        let lambda = deg2rad(apparentLong)
        let eps = deg2rad(epsilon)

        let ra = normalizedDeg(rad2deg(atan2(cos(eps) * sin(lambda), cos(lambda))))
        let dec = rad2deg(asin(sin(eps) * sin(lambda)))

        return EquatorialPosition(raDeg: ra, decDeg: dec)
    }

    /// The Sun's altitude, in degrees, at `date` for a site at
    /// `latDeg`/`lonDeg`.
    public static func sunAltitude(date: Date, latDeg: Double, lonDeg: Double) -> Double {
        let jd = JulianDate.julianDay(date)
        let sun = sunPosition(julianDay: jd)
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
        return AltAz.position(raDeg: sun.raDeg, decDeg: sun.decDeg, lstHours: lst, latDeg: latDeg).altitudeDeg
    }

    // MARK: - Moon position

    /// One term of the Moon's longitude/distance (Table 47.A) or latitude
    /// (Table 47.B) periodic series: multipliers of D (mean elongation), M
    /// (Sun's mean anomaly), M' (Moon's mean anomaly), F (Moon's argument of
    /// latitude), and the term's coefficient in units of 0.000001 degree.
    private struct Term {
        let d: Double, m: Double, mp: Double, f: Double, coeff: Double
    }

    /// Truncated to the largest-amplitude terms of Meeus Table 47.A -- full
    /// table has ~60 terms for arcsecond precision; these ~25 keep longitude
    /// error well under the ~0.3 deg this tool needs (illumination fraction
    /// and target/Moon separation, not pointing).
    private static let longitudeTerms: [Term] = [
        Term(d: 0, m: 0, mp: 1, f: 0, coeff: 6_288_774),
        Term(d: 2, m: 0, mp: -1, f: 0, coeff: 1_274_027),
        Term(d: 2, m: 0, mp: 0, f: 0, coeff: 658_314),
        Term(d: 0, m: 0, mp: 2, f: 0, coeff: 213_618),
        Term(d: 0, m: 1, mp: 0, f: 0, coeff: -185_116),
        Term(d: 0, m: 0, mp: 0, f: 2, coeff: -114_332),
        Term(d: 2, m: 0, mp: -2, f: 0, coeff: 58_793),
        Term(d: 2, m: -1, mp: -1, f: 0, coeff: 57_066),
        Term(d: 2, m: 0, mp: 1, f: 0, coeff: 53_322),
        Term(d: 2, m: -1, mp: 0, f: 0, coeff: 45_758),
        Term(d: 0, m: 1, mp: -1, f: 0, coeff: -40_923),
        Term(d: 1, m: 0, mp: 0, f: 0, coeff: -34_720),
        Term(d: 0, m: 1, mp: 1, f: 0, coeff: -30_383),
        Term(d: 2, m: 0, mp: 2, f: 0, coeff: 15_327),
        Term(d: 0, m: 0, mp: 1, f: 2, coeff: -12_528),
        Term(d: 0, m: 0, mp: 1, f: -2, coeff: 10_980),
        Term(d: 4, m: 0, mp: -1, f: 0, coeff: 10_675),
        Term(d: 0, m: 0, mp: 3, f: 0, coeff: 10_034),
        Term(d: 4, m: 0, mp: -2, f: 0, coeff: 8_548),
        Term(d: 2, m: 1, mp: -1, f: 0, coeff: -7_888),
        Term(d: 2, m: 1, mp: 0, f: 0, coeff: -6_766),
        Term(d: 1, m: 0, mp: -1, f: 0, coeff: -5_163),
        Term(d: 1, m: 1, mp: 0, f: 0, coeff: 4_987),
        Term(d: 2, m: -1, mp: 1, f: 0, coeff: 4_036),
        Term(d: 2, m: 0, mp: 3, f: 0, coeff: 3_994),
    ]

    /// Truncated Table 47.B (ecliptic latitude).
    private static let latitudeTerms: [Term] = [
        Term(d: 0, m: 0, mp: 0, f: 1, coeff: 5_128_122),
        Term(d: 0, m: 0, mp: 1, f: 1, coeff: 280_602),
        Term(d: 0, m: 0, mp: 1, f: -1, coeff: 277_693),
        Term(d: 2, m: 0, mp: 0, f: -1, coeff: 173_237),
        Term(d: 2, m: 0, mp: -1, f: 1, coeff: 55_413),
        Term(d: 2, m: 0, mp: -1, f: -1, coeff: 46_271),
        Term(d: 2, m: 0, mp: 0, f: 1, coeff: 32_573),
        Term(d: 0, m: 0, mp: 2, f: 1, coeff: 17_198),
        Term(d: 2, m: 0, mp: 1, f: -1, coeff: 9_266),
        Term(d: 0, m: 0, mp: 2, f: -1, coeff: 8_822),
        Term(d: 2, m: -1, mp: 0, f: -1, coeff: 8_216),
        Term(d: 2, m: 0, mp: -2, f: -1, coeff: 4_324),
        Term(d: 2, m: 0, mp: 1, f: 1, coeff: 4_200),
        Term(d: 2, m: 1, mp: 0, f: -1, coeff: -3_359),
        Term(d: 2, m: -1, mp: -1, f: 1, coeff: 2_463),
        Term(d: 2, m: -1, mp: 0, f: 1, coeff: 2_211),
        Term(d: 2, m: -1, mp: -1, f: -1, coeff: 2_065),
    ]

    /// Mean obliquity of the ecliptic (deg) -- same series `sunPosition`
    /// uses, factored out since the Moon's ecliptic-to-equatorial
    /// conversion needs it too (nutation-free "mean" value; the arcsecond
    /// wobble it omits is irrelevant at this module's precision target).
    private static func meanObliquityDeg(T: Double) -> Double {
        23.0 + 26.0 / 60.0 + 21.448 / 3600.0
            - (46.8150 / 3600.0) * T
            - (0.00059 / 3600.0) * T * T
            + (0.001813 / 3600.0) * T * T * T
    }

    /// Apparent geocentric equatorial position of the Moon at `jd` (UT).
    public static func moonPosition(julianDay jd: Double) -> EquatorialPosition {
        let T = (jd - 2451545.0) / 36525.0

        let Lp = normalizedDeg(218.3164477 + 481267.88123421 * T - 0.0015786 * T * T + T * T * T / 538841.0)
        let D = normalizedDeg(297.8501921 + 445267.1114034 * T - 0.0018819 * T * T + T * T * T / 545868.0)
        let M = normalizedDeg(357.5291092 + 35999.0502909 * T - 0.0001536 * T * T + T * T * T / 24490000.0)
        let Mp = normalizedDeg(134.9633964 + 477198.8675055 * T + 0.0087414 * T * T + T * T * T / 69699.0)
        let F = normalizedDeg(93.2720950 + 483202.0175233 * T - 0.0036539 * T * T - T * T * T / 3526000.0)

        // Eccentricity-of-Earth's-orbit correction applied to every term
        // whose argument includes M (Sun's mean anomaly), per Meeus:
        // E for |M coefficient| == 1, E^2 for |M coefficient| == 2.
        let E = 1.0 - 0.002516 * T - 0.0000074 * T * T

        func sumSeries(_ terms: [Term]) -> Double {
            var sum = 0.0
            for term in terms {
                let argDeg = term.d * D + term.m * M + term.mp * Mp + term.f * F
                let eFactor = pow(E, abs(term.m))
                sum += term.coeff * eFactor * sin(deg2rad(argDeg))
            }
            return sum
        }

        let sigmaL = sumSeries(longitudeTerms) // units of 0.000001 deg
        let sigmaB = sumSeries(latitudeTerms)

        let eclipticLonDeg = normalizedDeg(Lp + sigmaL / 1_000_000.0)
        let eclipticLatDeg = sigmaB / 1_000_000.0

        let eps = deg2rad(meanObliquityDeg(T: T))
        let lambda = deg2rad(eclipticLonDeg)
        let beta = deg2rad(eclipticLatDeg)

        let raRad = atan2(
            sin(lambda) * cos(eps) - tan(beta) * sin(eps),
            cos(lambda)
        )
        let decRad = asin(sin(beta) * cos(eps) + cos(beta) * sin(eps) * sin(lambda))

        return EquatorialPosition(raDeg: normalizedDeg(rad2deg(raRad)), decDeg: rad2deg(decRad))
    }

    // MARK: - Angular separation

    /// Great-circle angular separation, in degrees, between two equatorial
    /// positions.
    public static func angularSeparationDeg(ra1: Double, dec1: Double, ra2: Double, dec2: Double) -> Double {
        let d1 = deg2rad(dec1)
        let d2 = deg2rad(dec2)
        let dRa = deg2rad(ra1 - ra2)
        let cosSep = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(dRa)
        return rad2deg(acos(max(-1, min(1, cosSep))))
    }

    // MARK: - Moon illumination

    /// Illuminated fraction of the Moon's disk, as a percentage (0...100),
    /// at `jd` (UT). Uses the geometric approximation `k = (1 - cos
    /// elongation) / 2` (elongation = Sun-Moon angular separation as seen
    /// from Earth) -- ignores the small (at most ~0.3%) correction the full
    /// phase-angle formula applies for the Earth-Moon/Earth-Sun distance
    /// ratio, which is irrelevant at the accuracy this tool needs.
    public static func moonIlluminationPercent(julianDay jd: Double) -> Double {
        let sun = sunPosition(julianDay: jd)
        let moon = moonPosition(julianDay: jd)
        let elongation = angularSeparationDeg(ra1: sun.raDeg, dec1: sun.decDeg, ra2: moon.raDeg, dec2: moon.decDeg)
        let k = (1 - cos(deg2rad(elongation))) / 2
        return k * 100
    }

    // MARK: - Twilight

    public struct TwilightResult: Sendable, Equatable {
        /// UTC instant the Sun crosses below the twilight altitude in the
        /// evening; `nil` if it never does within the scanned window.
        public var duskUTC: Date?
        /// UTC instant the Sun crosses back above the twilight altitude the
        /// following morning; `nil` under the same condition as `duskUTC`.
        public var dawnUTC: Date?
        /// `true` when the Sun never reached -18 deg (astronomical night)
        /// within the scanned window -- common in summer at high latitude
        /// -- and this result falls back to -12 deg (nautical twilight)
        /// instead.
        public var usedNauticalFallback: Bool

        public init(duskUTC: Date?, dawnUTC: Date?, usedNauticalFallback: Bool) {
            self.duskUTC = duskUTC
            self.dawnUTC = dawnUTC
            self.usedNauticalFallback = usedNauticalFallback
        }
    }

    /// Scans from local noon of `localDate` to local noon of the following
    /// day (a full night, regardless of DST shifts) at `stepMinutes`
    /// resolution, looking for the Sun crossing -18 deg (astronomical
    /// twilight): descending after local solar noon (dusk) and ascending
    /// before the next local noon (dawn). Falls back to -12 deg (nautical
    /// twilight) when -18 deg is never reached anywhere in the window.
    public static func astronomicalTwilight(
        nightOf localDate: Date,
        latDeg: Double,
        lonDeg: Double,
        timeZone: TimeZone,
        stepMinutes: Double = 2
    ) -> TwilightResult {
        let samples = sunAltitudeSamples(nightOf: localDate, latDeg: latDeg, lonDeg: lonDeg, timeZone: timeZone, stepMinutes: stepMinutes)
        guard !samples.isEmpty else {
            return TwilightResult(duskUTC: nil, dawnUTC: nil, usedNauticalFallback: false)
        }

        if let result = crossings(samples: samples, threshold: -18) {
            return TwilightResult(duskUTC: result.dusk, dawnUTC: result.dawn, usedNauticalFallback: false)
        }
        if let result = crossings(samples: samples, threshold: -12) {
            return TwilightResult(duskUTC: result.dusk, dawnUTC: result.dawn, usedNauticalFallback: true)
        }
        return TwilightResult(duskUTC: nil, dawnUTC: nil, usedNauticalFallback: true)
    }

    /// Both the -18 deg (astronomical) and -12 deg (nautical) twilight
    /// crossings for the same night, from a single altitude sweep. Returns
    /// a plain tuple rather than `TwilightResult` -- that type's
    /// `usedNauticalFallback` flag is specific to `astronomicalTwilight`'s
    /// single-answer fallback contract and doesn't mean anything here.
    /// Unlike `astronomicalTwilight` -- which only computes the -12 deg
    /// pair when -18 deg is never reached, since it only ever needs ONE
    /// "the dark window" answer -- this always reports both pairs, even on
    /// a night astronomical darkness also occurs. Callers that need an
    /// outer bound for a sampling range regardless of whether the night
    /// gets fully dark (e.g. `SkyTrack`'s altitude-track window, sized to
    /// the wider nautical bound on every night) need the nautical pair
    /// unconditionally, not just as a fallback.
    public static func dualTwilight(
        nightOf localDate: Date,
        latDeg: Double,
        lonDeg: Double,
        timeZone: TimeZone,
        stepMinutes: Double = 2
    ) -> (astroDuskUTC: Date?, astroDawnUTC: Date?, nauticalDuskUTC: Date?, nauticalDawnUTC: Date?) {
        let samples = sunAltitudeSamples(nightOf: localDate, latDeg: latDeg, lonDeg: lonDeg, timeZone: timeZone, stepMinutes: stepMinutes)
        let astro = crossings(samples: samples, threshold: -18)
        let nautical = crossings(samples: samples, threshold: -12)
        return (astro?.dusk, astro?.dawn, nautical?.dusk, nautical?.dawn)
    }

    /// Sun altitude sampled every `stepMinutes` from local noon of
    /// `localDate` to local noon of the following day (a full night,
    /// regardless of DST shifts) -- the shared sweep both
    /// `astronomicalTwilight` and `dualTwilight` scan for threshold
    /// crossings, so the Sun-position math itself (`sunAltitude`) runs from
    /// exactly one call site. `[]` only on a pathological `Calendar`
    /// failure (unresolvable start-of-day/noon; essentially never in
    /// practice).
    private static func sunAltitudeSamples(
        nightOf localDate: Date,
        latDeg: Double,
        lonDeg: Double,
        timeZone: TimeZone,
        stepMinutes: Double
    ) -> [(date: Date, alt: Double)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: localDate)
        guard let noon = calendar.date(byAdding: .hour, value: 12, to: startOfDay),
              let windowEnd = calendar.date(byAdding: .hour, value: 24, to: noon)
        else { return [] }

        let stepSeconds = stepMinutes * 60
        var samples: [(date: Date, alt: Double)] = []
        var t = noon
        while t <= windowEnd {
            samples.append((t, sunAltitude(date: t, latDeg: latDeg, lonDeg: lonDeg)))
            t = t.addingTimeInterval(stepSeconds)
        }
        return samples
    }

    /// Finds the first descending crossing of `threshold` (dusk) and the
    /// last ascending crossing (dawn) in a chronologically-sorted altitude
    /// series. `nil` if the Sun's altitude never goes below `threshold`
    /// anywhere in `samples`.
    private static func crossings(samples: [(date: Date, alt: Double)], threshold: Double) -> (dusk: Date, dawn: Date)? {
        guard samples.contains(where: { $0.alt < threshold }) else { return nil }

        var dusk: Date?
        for i in 1..<samples.count {
            if samples[i - 1].alt >= threshold, samples[i].alt < threshold {
                dusk = interpolatedCrossing(samples[i - 1], samples[i], threshold: threshold)
                break
            }
        }
        var dawn: Date?
        for i in stride(from: samples.count - 1, to: 0, by: -1) {
            if samples[i - 1].alt < threshold, samples[i].alt >= threshold {
                dawn = interpolatedCrossing(samples[i - 1], samples[i], threshold: threshold)
                break
            }
        }
        guard let dusk, let dawn else { return nil }
        return (dusk, dawn)
    }

    /// Linear interpolation between two consecutive samples straddling
    /// `threshold` -- sharpens the crossing instant beyond the raw sampling
    /// step without needing a full bisection pass.
    private static func interpolatedCrossing(_ a: (date: Date, alt: Double), _ b: (date: Date, alt: Double), threshold: Double) -> Date {
        let span = b.alt - a.alt
        guard span != 0 else { return a.date }
        let fraction = (threshold - a.alt) / span
        let seconds = b.date.timeIntervalSince(a.date) * fraction
        return a.date.addingTimeInterval(seconds)
    }
}
