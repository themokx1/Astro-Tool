import Foundation

/// One catalog target's plan for "tonight" -- the `TargetPlan` shape,
/// re-cast over `TargetCatalog` instead of the user's own library. Built by
/// `DiscoveryPlanner.discover` for the "what should I shoot tonight that I
/// haven't shot yet" question (R10-A4); the app-side "Felfedezés" page
/// (R10-B4) is the only planned consumer.
public struct DiscoveryRow: Sendable, Equatable {
    public let target: CatalogTarget
    /// `nil` only when the site/night itself couldn't be resolved (no
    /// site coordinate, or no dark window at all tonight) -- unlike
    /// `TargetPlan`, a catalog target always HAS a coordinate, so that
    /// half of `TargetPlan`'s own "why is this nil" story never applies
    /// here.
    public let maxAltitudeDeg: Double?
    public let culminationLocal: String?
    public let visibleHours: Double?
    public let moonSeparationDeg: Double?
    /// Same Hungarian verdict vocabulary as `Planner.plan` (`SkyVerdict`) --
    /// see `discover`'s own doc comment for the priority order.
    public let verdict: String
    /// `visibilityFactor x moonPenalty` -- the same two factors
    /// `Planner.score` multiplies, just with no goal-derived leading
    /// factor (a catalog target has no integration history to have a goal
    /// against). Sort key, descending: higher means "point at this one
    /// tonight".
    public let score: Double
    /// `true` when `target.designation` matches one of the caller-supplied
    /// `existingDesignations` -- rows are NOT filtered on this, only
    /// flagged; the caller decides whether/how to de-emphasize a target
    /// already being shot.
    public let alreadyInLibrary: Bool
    /// `"befér"` / `"mozaik kellene"` / `"túl kicsi a képmezőhöz"` -- how
    /// `target.sizeArcmin` compares to the caller's `setupFOVDeg`. `nil`
    /// when either is unknown (no recorded size, or no FOV supplied).
    public let fovFitLabel: String?

    public init(
        target: CatalogTarget,
        maxAltitudeDeg: Double? = nil,
        culminationLocal: String? = nil,
        visibleHours: Double? = nil,
        moonSeparationDeg: Double? = nil,
        verdict: String,
        score: Double,
        alreadyInLibrary: Bool,
        fovFitLabel: String? = nil
    ) {
        self.target = target
        self.maxAltitudeDeg = maxAltitudeDeg
        self.culminationLocal = culminationLocal
        self.visibleHours = visibleHours
        self.moonSeparationDeg = moonSeparationDeg
        self.verdict = verdict
        self.score = score
        self.alreadyInLibrary = alreadyInLibrary
        self.fovFitLabel = fovFitLabel
    }
}

/// "What else is well-placed tonight?" -- sweeps `TargetCatalog.all`
/// against tonight's sky using the exact same math `Planner.plan` uses for
/// the user's own library (`NightSweep`/`SkyVerdict`/`SkyScore`, factored
/// out of `Planner` for this reuse). DB-free and pure: unlike `Planner`,
/// this type never touches `Database` itself -- `existingDesignations` and
/// `setupFOVDeg` are plain inputs the caller (the app layer, eventually
/// R10-B4) assembles from its own already-loaded state.
public enum DiscoveryPlanner {
    /// Maps a library's `TargetStats` (already computed by
    /// `StatsQueries.perTarget` -- this function takes no `Database` at
    /// all, keeping `DiscoveryPlanner` fully DB-free) to the set of catalog
    /// designations it represents, ready to pass as `discover`'s
    /// `existingDesignations`. A target with no recognizable catalog
    /// designation (a bare `M_Milky_Way`-style widefield, or a comet)
    /// contributes nothing -- there's no catalog entry it could match
    /// against anyway.
    public static func existingDesignations(stats: [TargetStats]) -> Set<String> {
        Set(stats.compactMap { TargetNameResolver.resolve(folderName: $0.target).designation })
    }

    /// Builds tonight's (`date`'s) `DiscoveryRow` for every entry in
    /// `TargetCatalog.all`, sorted by `score` descending.
    ///
    /// Verdict priority (see `SkyVerdict`, shared with `Planner.plan`):
    /// 1. `SkyVerdict.noCoordinate` when the site itself doesn't resolve
    ///    (`site.latitudeDeg`/`longitudeDeg` `nil`) or tonight never reaches
    ///    a dark window at all (astronomical-or-nautical twilight, per
    ///    `SunMoon.astronomicalTwilight`'s own fallback) -- every row gets
    ///    this same verdict and a `0` score in that case, since without a
    ///    site there's nothing target-specific left to compute (unlike
    ///    `Planner.plan`, where this verdict can ALSO mean "this one
    ///    target's own coordinate didn't resolve" -- moot here, a catalog
    ///    target's coordinate is always known).
    /// 2. `SkyVerdict.tooLow` when the target's max altitude tonight never
    ///    reaches `minAltitudeDeg`.
    /// 3. `SkyVerdict.notVisibleTonight` when it clears the bar for under
    ///    half an hour.
    /// 4. `SkyVerdict.moonInterferes` when the Moon (evaluated once, at the
    ///    dark window's midpoint) is within 40 deg and over 60% illuminated.
    /// 5. `SkyVerdict.good` otherwise.
    public static func discover(
        date: Date,
        site: SiteRule,
        minAltitudeDeg: Double = 30,
        existingDesignations: Set<String> = [],
        setupFOVDeg: (width: Double, height: Double)? = nil
    ) -> [DiscoveryRow] {
        let timeZone = TimeZone.current

        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
            return unresolvedRows(existingDesignations: existingDesignations, setupFOVDeg: setupFOVDeg)
        }
        let night = SunMoon.astronomicalTwilight(nightOf: date, latDeg: lat, lonDeg: lon, timeZone: timeZone)
        guard let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC else {
            return unresolvedRows(existingDesignations: existingDesignations, setupFOVDeg: setupFOVDeg)
        }

        let moon = NightSweep.midnightMoon(duskUTC: duskUTC, dawnUTC: dawnUTC)

        let rows = TargetCatalog.all.map { catalogTarget -> DiscoveryRow in
            let sweep = NightSweep.sweep(
                raDeg: catalogTarget.raDeg, decDeg: catalogTarget.decDeg, latDeg: lat, lonDeg: lon,
                duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg
            )
            let moonSeparation = SunMoon.angularSeparationDeg(
                ra1: catalogTarget.raDeg, dec1: catalogTarget.decDeg, ra2: moon.raDeg, dec2: moon.decDeg
            )
            let visibleHours = sweep.visibleSeconds / 3600.0
            let culminationLocal = sweep.culminationUTC.map { NightSweep.formatLocalTime($0, timeZone: timeZone) }

            let moonInterferes = moon.illuminationPercent > 60 && moonSeparation < 40
            let verdict: String
            if sweep.maxAltitudeDeg < minAltitudeDeg {
                verdict = SkyVerdict.tooLow(sweep.maxAltitudeDeg)
            } else if visibleHours < 0.5 {
                verdict = SkyVerdict.notVisibleTonight
            } else if moonInterferes {
                verdict = SkyVerdict.moonInterferes(separationDeg: moonSeparation, illuminationPercent: moon.illuminationPercent)
            } else {
                verdict = SkyVerdict.good
            }

            let score = SkyScore.visibilityFactor(visibleHours: visibleHours)
                * SkyScore.moonPenalty(moonInterferes: moonInterferes)

            return DiscoveryRow(
                target: catalogTarget,
                maxAltitudeDeg: sweep.maxAltitudeDeg,
                culminationLocal: culminationLocal,
                visibleHours: visibleHours,
                moonSeparationDeg: moonSeparation,
                verdict: verdict,
                score: score,
                alreadyInLibrary: existingDesignations.contains(catalogTarget.designation),
                fovFitLabel: fovFitLabel(sizeArcmin: catalogTarget.sizeArcmin, setupFOVDeg: setupFOVDeg)
            )
        }

        return rows.sorted { $0.score > $1.score }
    }

    /// Every catalog entry, all sharing the SAME `SkyVerdict.noCoordinate`
    /// verdict and a `0` score -- the site/night couldn't be resolved at
    /// all, so there's nothing target-specific left to compute (see
    /// `discover`'s own doc, case 1). `fovFitLabel`/`alreadyInLibrary` are
    /// still filled in -- both are independent of tonight's sky.
    private static func unresolvedRows(
        existingDesignations: Set<String>,
        setupFOVDeg: (width: Double, height: Double)?
    ) -> [DiscoveryRow] {
        TargetCatalog.all.map { catalogTarget in
            DiscoveryRow(
                target: catalogTarget,
                verdict: SkyVerdict.noCoordinate,
                score: 0,
                alreadyInLibrary: existingDesignations.contains(catalogTarget.designation),
                fovFitLabel: fovFitLabel(sizeArcmin: catalogTarget.sizeArcmin, setupFOVDeg: setupFOVDeg)
            )
        }
    }

    // MARK: - FOV fit

    /// Compares `sizeArcmin` to the setup's field of view: `nil` whenever
    /// either input is unknown (no recorded size, or no FOV supplied at
    /// all -- an equipment-less caller gets no opinion, not a guess).
    ///
    /// Only two cutoffs actually distinguish the three labels (the spec's
    /// own "fits when size <= 0.9x the smaller FOV dimension" and its
    /// "else fits" catch-all resolve to the SAME label, so there's no
    /// third branch to write): bigger than 1.1x the LARGER FOV dimension
    /// doesn't fit in one frame at all (`"mozaik kellene"`); smaller than
    /// 3% of the SMALLER FOV dimension is a speck lost in an otherwise-
    /// empty frame (`"túl kicsi a képmezőhöz"`); everything else,
    /// including the spec's own "comfortably smaller than the frame"
    /// example, is simply `"befér"`.
    static func fovFitLabel(sizeArcmin: Double?, setupFOVDeg: (width: Double, height: Double)?) -> String? {
        guard let sizeArcmin, let setupFOVDeg else { return nil }
        let widthArcmin = setupFOVDeg.width * 60.0
        let heightArcmin = setupFOVDeg.height * 60.0
        let minDim = min(widthArcmin, heightArcmin)
        let maxDim = max(widthArcmin, heightArcmin)

        if sizeArcmin > 1.1 * maxDim {
            return "mozaik kellene"
        }
        if sizeArcmin < 0.03 * minDim {
            return "túl kicsi a képmezőhöz"
        }
        return "befér"
    }
}
