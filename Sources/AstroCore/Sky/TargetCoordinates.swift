import Foundation

/// Resolves a target's sky position and the observing site's coordinates
/// from whatever FITS headers the scanned library already recorded --
/// never touches the filesystem itself, everything comes from
/// `FITSMetaRecord.headerJSON` (the raw keyword -> value-text dump
/// `Scanner` stores, see `FITSReader.allCards`).
public enum TargetCoordinates {
    /// One file's RA/Dec, in degrees, resolved from its header:
    /// 1. Plate-solved WCS (`CRVAL1`/`CRVAL2`) when both are present --
    ///    these are always in degrees already.
    /// 2. Fallback `RA`/`DEC` header keys: tried first as plain numeric
    ///    cards (already degrees, no conversion), then as a quoted
    ///    sexagesimal string (`"12 34 56"` or `"12:34:56"`) -- RA hours are
    ///    converted to degrees (x15) ONLY in that sexagesimal-string case;
    ///    a numeric `RA` card is assumed to already be in degrees.
    ///
    /// `nil` if the header has neither a usable WCS solution nor a
    /// parseable `RA`/`DEC` pair (e.g. no `header_json` at all, or every
    /// key is absent/unparseable) AND no `solvedRA`/`solvedDec` fallback was
    /// given either.
    ///
    /// `solvedRA`/`solvedDec` (R7-1): `PlateSolver`'s persisted
    /// `fits_meta.solved_ra`/`solved_dec` columns, tried only as a LAST
    /// resort after the header itself has been checked -- a wide-field
    /// Canon CR3 frame has no FITS header at all (`headerJSON == nil`), so
    /// this never short-circuits on that `nil` the way the original
    /// header-only implementation did.
    public static func coordinates(
        headerJSON: String?,
        solvedRA: Double? = nil,
        solvedDec: Double? = nil
    ) -> (raDeg: Double, decDeg: Double)? {
        if let header = parseHeader(headerJSON) {
            if let crval1 = header.double("CRVAL1"), let crval2 = header.double("CRVAL2") {
                return (crval1, crval2)
            }
            if let ra = resolveRA(header), let dec = resolveDec(header) {
                return (ra, dec)
            }
        }

        if let solvedRA, let solvedDec {
            return (solvedRA, solvedDec)
        }
        return nil
    }

    private static func resolveRA(_ header: FITSHeader) -> Double? {
        if let value = header.double("RA") { return value }
        if let raw = header.string("RA"), let hours = parseSexagesimal(raw) { return hours * 15 }
        return nil
    }

    private static func resolveDec(_ header: FITSHeader) -> Double? {
        if let value = header.double("DEC") { return value }
        if let raw = header.string("DEC") { return parseSexagesimal(raw) }
        return nil
    }

    /// Parses a sexagesimal `"H M S"` / `"H:M:S"` (or `D M S` / `D:M:S`)
    /// string into a single signed magnitude (hours or degrees, matching
    /// whatever unit the caller's first component is in) -- the sign, if
    /// any, is read off the first component only. `nil` if it doesn't
    /// split into exactly three numeric parts.
    static func parseSexagesimal(_ raw: String) -> Double? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: " ")
        let parts = normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3,
              let first = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }

        let sign: Double = first < 0 ? -1 : 1
        return sign * (abs(first) + minutes / 60.0 + seconds / 3600.0)
    }

    // MARK: - Median over a target's session lights

    /// Median RA/Dec (degrees) across every one of `files` (already
    /// filtered to the target of interest by the caller) whose
    /// `FITSMetaRecord` resolves to a coordinate pair -- header WCS/RA-DEC
    /// preferred, falling back to `PlateSolver`'s `solved_ra`/`solved_dec`
    /// columns per-file (see `coordinates(headerJSON:solvedRA:solvedDec:)`).
    /// `nil` if none do.
    public static func medianCoordinates(files: [FileRecord], meta: [Int64: FITSMetaRecord]) -> (raDeg: Double, decDeg: Double)? {
        var ras: [Double] = []
        var decs: [Double] = []
        for file in files {
            guard let id = file.id, let record = meta[id],
                  let coord = coordinates(headerJSON: record.headerJSON, solvedRA: record.solvedRA, solvedDec: record.solvedDec)
            else { continue }
            ras.append(coord.raDeg)
            decs.append(coord.decDeg)
        }
        guard !ras.isEmpty else { return nil }
        return (median(ras), median(decs))
    }

    // MARK: - Site (SITELAT/SITELONG) derivation

    /// Median `SITELAT`/`SITELONG` across every file in `files` whose
    /// header carries them -- the library-wide fallback used when
    /// `AstroConfig.site` doesn't already specify a coordinate.
    public static func medianSite(files: [FileRecord], meta: [Int64: FITSMetaRecord]) -> SiteRule {
        var lats: [Double] = []
        var lons: [Double] = []
        for file in files {
            guard let id = file.id, let record = meta[id], let header = parseHeader(record.headerJSON) else { continue }
            if let lat = header.double("SITELAT") { lats.append(lat) }
            if let lon = header.double("SITELONG") { lons.append(lon) }
        }
        return SiteRule(
            latitudeDeg: lats.isEmpty ? nil : median(lats),
            longitudeDeg: lons.isEmpty ? nil : median(lons)
        )
    }

    /// `config`'s explicit site coordinates win where present; any `nil`
    /// component falls back to the library-wide median derived from
    /// `files`/`meta`.
    public static func resolveSite(files: [FileRecord], meta: [Int64: FITSMetaRecord], config: SiteRule) -> SiteRule {
        guard config.latitudeDeg == nil || config.longitudeDeg == nil else { return config }
        let derived = medianSite(files: files, meta: meta)
        return SiteRule(
            latitudeDeg: config.latitudeDeg ?? derived.latitudeDeg,
            longitudeDeg: config.longitudeDeg ?? derived.longitudeDeg
        )
    }

    // MARK: - Helpers

    private static func parseHeader(_ headerJSON: String?) -> FITSHeader? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return FITSHeader(rawValues: cards)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
