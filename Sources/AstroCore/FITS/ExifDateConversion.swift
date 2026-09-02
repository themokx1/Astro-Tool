import Foundation

/// Converts a DSLR/mirrorless frame's Exif `DateTimeOriginal` -- camera-LOCAL
/// wall-clock time, e.g. `"2026:04:18 04:36:24"` -- into the same UTC
/// instant string shape `fits_meta.date_obs` uses for a real FITS `DATE-OBS`
/// card (`"yyyy-MM-dd'T'HH:mm:ss"`, no trailing `Z`, parseable by
/// `SessionTimeline.parseDateObs`'s `fitsFormatterNoFraction`).
///
/// Before this conversion existed, the scanner stored the raw Exif string
/// verbatim in `fits_meta.date_obs`, and `SessionTimeline.parseDateObs`
/// parses every `date_obs` value as UTC -- so every DSLR/mirrorless frame's
/// recorded instant was silently off by the observer's UTC offset (e.g. a
/// CEST shooter's frames landed two hours into the future). Exif
/// `OffsetTimeOriginal` (when the body writes it -- most don't) gives the
/// exact offset; lacking that, this falls back to the Mac's own current time
/// zone, on the documented assumption that the machine doing the scan
/// usually sits wherever the camera was used.
public enum ExifDateConversion {
    /// `nil` when `dateTaken` doesn't match Exif's `"yyyy:MM:dd HH:mm:ss"`
    /// shape at all (never guesses at a malformed value).
    public static func utcDateObsString(
        dateTaken: String,
        offsetTimeOriginal: String?,
        fallbackTimeZone: TimeZone = .current
    ) -> String? {
        let zone = offsetTimeOriginal.flatMap(parseExifOffset) ?? fallbackTimeZone
        let localFormatter = exifLocalFormatter(timeZone: zone)
        guard let instant = localFormatter.date(from: dateTaken) else { return nil }
        return utcFormatter.string(from: instant)
    }

    /// Parses Exif `OffsetTimeOriginal`'s `"±HH:mm"` form (e.g. `"+02:00"`,
    /// `"-05:30"`; also accepts a bare `"Z"` for UTC). `nil` for anything
    /// else, including a malformed or unexpected value -- callers fall back
    /// to `fallbackTimeZone` in that case rather than guessing.
    static func parseExifOffset(_ raw: String) -> TimeZone? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.uppercased() == "Z" { return TimeZone(identifier: "UTC") }

        guard trimmed.count == 6,
              let sign = trimmed.first, sign == "+" || sign == "-",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] == ":"
        else { return nil }

        let hoursText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)..<trimmed.index(trimmed.startIndex, offsetBy: 3)]
        let minutesText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)...]
        guard let hours = Int(hoursText), let minutes = Int(minutesText) else { return nil }

        let totalSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: totalSeconds)
    }

    private static func exifLocalFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    /// Same UTC, no-fraction shape `SessionTimeline`'s own FITS `DATE-OBS`
    /// formatters parse (see that type's `fitsFormatterNoFraction`) -- kept
    /// as its own private formatter here rather than reaching across module
    /// files for a `private` one.
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
