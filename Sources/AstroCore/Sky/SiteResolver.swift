import Foundation

/// R11-T15/F16: assigns ONE session to the nearest configured `SiteProfile`
/// -- the "session -> site" half of the multi-site feature (the other half,
/// "which site does the PLANNER use tonight", is `Planner.resolveSite`'s
/// `siteName` parameter). Pure, DB-free: callers hand in whatever they
/// already resolved (a session's tags, its median `SITELAT`/`SITELONG`
/// coordinate via `TargetCoordinates.medianSite`, and `config.sites`).
public enum SiteResolver {
    /// Earth's mean radius in km -- same constant every haversine
    /// implementation uses, precise enough for "which of my few observing
    /// sites is this" (not geodesy).
    private static let earthRadiusKm = 6371.0

    /// Great-circle distance between two lat/lon points, in km (haversine
    /// formula).
    public static func haversineDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let rLat1 = lat1 * .pi / 180
        let rLat2 = lat2 * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2) + cos(rLat1) * cos(rLat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return earthRadiusKm * c
    }

    /// The `site:<name>` session-tag override, if `tags` carries one --
    /// case-insensitive prefix, same lenient parsing convention `GoalTag`
    /// already establishes for `goal:`. The FIRST matching tag wins (same
    /// "first match wins" stance `GoalTag.parse(tags:)` takes); a tag with
    /// an empty name after the prefix is skipped, not treated as a match.
    public static func siteTagName(tags: [String]) -> String? {
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("site:") else { continue }
            let name = String(trimmed.dropFirst("site:".count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    /// Resolves one session's site:
    /// 1. An explicit `site:<name>` tag on the session wins outright --
    ///    matched case-insensitively against `sites`' own names; a tag
    ///    naming a site that ISN'T configured resolves to `nil` (an
    ///    intentional override that doesn't exist is still "no assignment",
    ///    never a silent fall-through to the nearest-distance guess below).
    /// 2. Otherwise, the nearest configured site to `(medianLat, medianLon)`
    ///    -- but only within `maxDistanceKm` (default 50 km, the ticket's
    ///    own suggested threshold): beyond that, the session's coordinate
    ///    doesn't actually describe any known site, so `nil` ("ismeretlen
    ///    helyszín") rather than a misleadingly confident nearest match.
    /// `nil` whenever `sites` is empty, there's no tag override AND no
    /// median coordinate to compare against, or nothing configured is
    /// within range.
    public static func resolve(
        sessionTags: [String],
        medianLat: Double?,
        medianLon: Double?,
        sites: [SiteProfile],
        maxDistanceKm: Double = 50
    ) -> SiteProfile? {
        if let overrideName = siteTagName(tags: sessionTags) {
            return sites.first { $0.name.caseInsensitiveCompare(overrideName) == .orderedSame }
        }

        guard let medianLat, let medianLon, !sites.isEmpty else { return nil }

        var best: (site: SiteProfile, distanceKm: Double)?
        for site in sites {
            let distance = haversineDistanceKm(
                lat1: medianLat, lon1: medianLon, lat2: site.latitudeDeg, lon2: site.longitudeDeg
            )
            if best == nil || distance < best!.distanceKm {
                best = (site, distance)
            }
        }
        guard let best, best.distanceKm <= maxDistanceKm else { return nil }
        return best.site
    }
}
