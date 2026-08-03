import Foundation

/// Julian Day conversion -- the time axis every other `Sky` calculation
/// (sidereal time, Sun/Moon position) is built on. UT-based (no TT/UTC
/// leap-second distinction): for the low-precision astronomy this tool does
/// (culmination times, twilight windows, Moon phase), the sub-minute
/// difference between UT and TT is irrelevant.
public enum JulianDate {
    /// Julian Day for `date` (interpreted in UTC, matching `Date`'s own
    /// timezone-free instant semantics). Exact for any `Date` backed by a
    /// finite `timeIntervalSince1970`, since the Unix epoch
    /// (1970-01-01T00:00:00 UTC) is exactly JD 2440587.5 by definition.
    ///
    /// Reference: 2000-01-01T12:00:00Z -> JD 2451545.0 exactly (the J2000.0
    /// epoch every low-precision solar/lunar formula in this module is
    /// expressed relative to).
    public static func julianDay(_ date: Date) -> Double {
        2440587.5 + date.timeIntervalSince1970 / 86400.0
    }

    /// The inverse of `julianDay(_:)` -- mainly useful for tests and for
    /// turning a scanned instant (e.g. a twilight crossing found by
    /// bisection) back into a `Date`.
    public static func date(fromJulianDay jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2440587.5) * 86400.0)
    }
}
