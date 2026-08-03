import Foundation

/// Greenwich and Local Mean Sidereal Time -- the IAU 1982 polynomial
/// (identical to the one Jean Meeus gives in *Astronomical Algorithms*,
/// Eq. 12.4), evaluated directly at any instant (not just 0h UT).
public enum SiderealTime {
    /// Greenwich Mean Sidereal Time, in hours, normalized to `[0, 24)`, at
    /// `julianDay` (UT).
    ///
    /// Validated bit-for-bit against Meeus's own worked examples
    /// (*Astronomical Algorithms*, 2nd ed., Examples 12.a/12.b):
    /// 1987-04-10T00:00:00Z -> 13h10m46.3668s, and 1987-04-10T19:21:00Z ->
    /// 8h34m57.0896s (see `SiderealTimeTests`).
    public static func gmstHours(julianDay jd: Double) -> Double {
        let d = jd - 2451545.0
        let T = d / 36525.0
        var gmstDeg = 280.46061837
            + 360.98564736629 * d
            + 0.000387933 * T * T
            - T * T * T / 38710000.0
        gmstDeg = gmstDeg.truncatingRemainder(dividingBy: 360.0)
        if gmstDeg < 0 { gmstDeg += 360.0 }
        return gmstDeg / 15.0
    }

    /// Local (Mean) Sidereal Time, in hours, normalized to `[0, 24)`, at
    /// `julianDay` (UT) for a site at `longitudeDeg` (east-positive, as
    /// every other longitude in this module).
    public static func lstHours(julianDay jd: Double, longitudeDeg: Double) -> Double {
        var lst = gmstHours(julianDay: jd) + longitudeDeg / 15.0
        lst = lst.truncatingRemainder(dividingBy: 24.0)
        if lst < 0 { lst += 24.0 }
        return lst
    }
}
