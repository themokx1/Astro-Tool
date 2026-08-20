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
    /// `false` when `culminationLocal` is only the EDGE of tonight's scanned
    /// window rather than a genuine meridian transit -- see
    /// `NightSweepResult.isGenuineCulmination`'s own doc comment. `nil`
    /// under the same conditions `culminationLocal` is (no resolvable site/
    /// night at all).
    public let isGenuineCulmination: Bool?
    public let visibleHours: Double?
    /// `"HH:mm–HH:mm"` (site-local time) window during which the target is
    /// at or above the caller's `minAltitudeDeg`, same
    /// `NightSweep.visibleWindowLocal(_:timeZone:)` formatting `Planner
    /// .buildPlan`'s own `TargetPlan.visibleWindowLocal` uses -- `nil` under
    /// the same conditions `visibleHours` is (no resolvable site/night, or
    /// the target never clears the threshold). W7-B: `PlanningQuery` (an
    /// `AstroApplication` consumer with no access to `NightSweep` itself,
    /// which is internal to this module) needs this to render an honest
    /// window-edge culmination label instead of `culminationLocal` alone.
    public let visibleWindowLocal: String?
    public let moonSeparationDeg: Double?
    /// The Moon's own above-horizon fraction across THIS target's visible
    /// window (`NightSweep.moonAboveHorizonFraction`, sampled over
    /// `sweep.visibleStart`...`sweep.visibleEnd`) -- the exact number this
    /// row's own `score` already folds into `SkyScore.moonFactor` (W7-A).
    /// Exposed here too because `PlanningQuery` (`AstroApplication`) computes
    /// its OWN, differently-weighted composite score (`PlanningScore
    /// .composite`) over the same sky facts, and has no access to
    /// `NightSweep` (internal to this module) to derive this itself --
    /// W7-B's "PlanningScore CALLER wiring" leftover. Defaults to `1` (Moon
    /// treated as up the whole window) in `unresolvedRows`, matching
    /// `PlanningScore.moonFactor`'s own conservative default for "unknown".
    public let moonAboveHorizonFraction: Double
    /// Same Hungarian verdict vocabulary as `Planner.plan` (`SkyVerdict`) --
    /// see `discover`'s own doc comment for the priority order.
    public let verdict: String
    /// `visibilityFactor x SkyScore.moonFactor x compositionScoreFactor`
    /// (the last factor is neutral when no setup FOV is known). Sort key,
    /// descending: higher means both well placed tonight AND usefully
    /// framed by the
    /// selected setup -- merely being a tiny visible speck is not enough.
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
    /// Approximate target diameter divided by the setup FOV's short edge.
    /// `0.06` means the object fills only about 6% of the frame height.
    public let fovShortEdgeFillFraction: Double?
    /// Continuous 0...1 recommendation multiplier derived from framing.
    /// `nil` means no size/FOV comparison was possible and is treated as
    /// neutral rather than as evidence for or against the target.
    public let compositionScoreFactor: Double?

    public init(
        target: CatalogTarget,
        maxAltitudeDeg: Double? = nil,
        culminationLocal: String? = nil,
        isGenuineCulmination: Bool? = nil,
        visibleHours: Double? = nil,
        visibleWindowLocal: String? = nil,
        moonSeparationDeg: Double? = nil,
        moonAboveHorizonFraction: Double = 1,
        verdict: String,
        score: Double,
        alreadyInLibrary: Bool,
        fovFitLabel: String? = nil,
        fovShortEdgeFillFraction: Double? = nil,
        compositionScoreFactor: Double? = nil
    ) {
        self.target = target
        self.maxAltitudeDeg = maxAltitudeDeg
        self.culminationLocal = culminationLocal
        self.isGenuineCulmination = isGenuineCulmination
        self.visibleHours = visibleHours
        self.visibleWindowLocal = visibleWindowLocal
        self.moonSeparationDeg = moonSeparationDeg
        self.moonAboveHorizonFraction = moonAboveHorizonFraction
        self.verdict = verdict
        self.score = score
        self.alreadyInLibrary = alreadyInLibrary
        self.fovFitLabel = fovFitLabel
        self.fovShortEdgeFillFraction = fovShortEdgeFillFraction
        self.compositionScoreFactor = compositionScoreFactor
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
    ///    dark window's midpoint, for separation/illumination) is within 40
    ///    deg and over 60% illuminated -- AND is above the horizon for at
    ///    least part of the target's own visible window (W7-A: a Moon that
    ///    never rises during that window cannot be brightening it, checked
    ///    via `NightSweep.moonAboveHorizonFraction` sampled across
    ///    `sweep.visibleStart`...`sweep.visibleEnd`, same fix `Planner.
    ///    buildPlan` applies).
    /// 5. `SkyVerdict.good` otherwise.
    public static func discover(
        date: Date,
        site: SiteRule,
        minAltitudeDeg: Double = 30,
        /// The catalog to sweep. Defaults to the built-in table; the Planning
        /// workbench passes the merged built-in + downloaded extended catalog,
        /// because a target with no sky row here is treated as unobservable
        /// and silently vanishes from the planner.
        targets: [CatalogTarget] = TargetCatalog.all,
        existingDesignations: Set<String> = [],
        setupFOVDeg: (width: Double, height: Double)? = nil
    ) -> [DiscoveryRow] {
        let timeZone = TimeZone.current

        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
            return unresolvedRows(targets: targets, existingDesignations: existingDesignations, setupFOVDeg: setupFOVDeg)
        }
        let night = SunMoon.astronomicalTwilight(nightOf: date, latDeg: lat, lonDeg: lon, timeZone: timeZone)
        guard let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC else {
            return unresolvedRows(targets: targets, existingDesignations: existingDesignations, setupFOVDeg: setupFOVDeg)
        }

        let moon = NightSweep.midnightMoon(duskUTC: duskUTC, dawnUTC: dawnUTC)

        let rows = targets.map { catalogTarget -> DiscoveryRow in
            let sweep = NightSweep.sweep(
                raDeg: catalogTarget.raDeg, decDeg: catalogTarget.decDeg, latDeg: lat, lonDeg: lon,
                duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg
            )
            let moonSeparation = SunMoon.angularSeparationDeg(
                ra1: catalogTarget.raDeg, dec1: catalogTarget.decDeg, ra2: moon.raDeg, dec2: moon.decDeg
            )
            let visibleHours = sweep.visibleSeconds / 3600.0
            let culminationLocal = sweep.culminationUTC.map { NightSweep.formatLocalTime($0, timeZone: timeZone) }
            let visibleWindowLocal = NightSweep.visibleWindowLocal(sweep, timeZone: timeZone)

            // W7-A audit fix -- same reasoning as `Planner.buildPlan`: the
            // Moon must actually be above the horizon for at least part of
            // the target's own visible window to interfere with it at all.
            let moonAboveHorizonFraction: Double
            if let visStart = sweep.visibleStart, let visEnd = sweep.visibleEnd {
                moonAboveHorizonFraction = NightSweep.moonAboveHorizonFraction(
                    latDeg: lat, lonDeg: lon, startUTC: visStart, endUTC: visEnd
                ) ?? 0
            } else {
                moonAboveHorizonFraction = 0
            }
            let moonScoreFactor = SkyScore.moonFactor(
                separationDeg: moonSeparation, illuminationPercent: moon.illuminationPercent,
                aboveHorizonFraction: moonAboveHorizonFraction
            )
            let moonInterferes = moon.illuminationPercent > 60 && moonSeparation < 40 && moonAboveHorizonFraction > 0
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

            let composition = fovComposition(
                sizeArcmin: catalogTarget.sizeArcmin,
                setupFOVDeg: setupFOVDeg
            )
            let score = SkyScore.visibilityFactor(visibleHours: visibleHours)
                * moonScoreFactor
                * (composition?.scoreFactor ?? 1)

            return DiscoveryRow(
                target: catalogTarget,
                maxAltitudeDeg: sweep.maxAltitudeDeg,
                culminationLocal: culminationLocal,
                isGenuineCulmination: sweep.isGenuineCulmination,
                visibleHours: visibleHours,
                visibleWindowLocal: visibleWindowLocal,
                moonSeparationDeg: moonSeparation,
                moonAboveHorizonFraction: moonAboveHorizonFraction,
                verdict: verdict,
                score: score,
                alreadyInLibrary: existingDesignations.contains(catalogTarget.designation),
                fovFitLabel: composition?.label,
                fovShortEdgeFillFraction: composition?.shortEdgeFillFraction,
                compositionScoreFactor: composition?.scoreFactor
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
        targets: [CatalogTarget] = TargetCatalog.all,
        existingDesignations: Set<String>,
        setupFOVDeg: (width: Double, height: Double)?
    ) -> [DiscoveryRow] {
        targets.map { catalogTarget in
            let composition = fovComposition(
                sizeArcmin: catalogTarget.sizeArcmin,
                setupFOVDeg: setupFOVDeg
            )
            return DiscoveryRow(
                target: catalogTarget,
                verdict: SkyVerdict.noCoordinate,
                score: 0,
                alreadyInLibrary: existingDesignations.contains(catalogTarget.designation),
                fovFitLabel: composition?.label,
                fovShortEdgeFillFraction: composition?.shortEdgeFillFraction,
                compositionScoreFactor: composition?.scoreFactor
            )
        }
    }

    // MARK: - FOV fit

    /// Compares `sizeArcmin` to the setup's field of view: `nil` whenever
    /// either input is unknown (no recorded size, or no FOV supplied at
    /// all -- an equipment-less caller gets no opinion, not a guess).
    ///
    /// Labels describe composition quality rather than a permissive
    /// geometric yes/no. The catalog currently stores one representative
    /// angular diameter, so this remains an honest approximation for very
    /// elongated targets and arbitrary camera rotation.
    static func fovFitLabel(sizeArcmin: Double?, setupFOVDeg: (width: Double, height: Double)?) -> String? {
        fovComposition(sizeArcmin: sizeArcmin, setupFOVDeg: setupFOVDeg)?.label
    }

    struct FOVComposition: Sendable, Equatable {
        let label: String
        let shortEdgeFillFraction: Double
        let scoreFactor: Double
    }

    /// A deliberately continuous recommendation factor. Thresholds only
    /// choose the human label; targets immediately either side of a label
    /// boundary do not jump wildly in the actual ordering.
    static func fovComposition(
        sizeArcmin: Double?,
        setupFOVDeg: (width: Double, height: Double)?
    ) -> FOVComposition? {
        guard let sizeArcmin, sizeArcmin > 0, let setupFOVDeg else { return nil }
        let widthArcmin = setupFOVDeg.width * 60.0
        let heightArcmin = setupFOVDeg.height * 60.0
        let minDim = min(widthArcmin, heightArcmin)
        let maxDim = max(widthArcmin, heightArcmin)
        guard minDim > 0, maxDim > 0 else { return nil }
        let fill = sizeArcmin / minDim

        if sizeArcmin > 1.1 * maxDim {
            return FOVComposition(label: "mozaik kellene", shortEdgeFillFraction: fill, scoreFactor: 0.10)
        }
        if fill < 0.08 {
            let factor = max(0.05, 0.20 * (fill / 0.08))
            return FOVComposition(
                label: "nagyon kicsi a képmezőben",
                shortEdgeFillFraction: fill,
                scoreFactor: factor
            )
        }
        if fill < 0.18 {
            let progress = (fill - 0.08) / 0.10
            return FOVComposition(
                label: "kicsi, tág kompozíció",
                shortEdgeFillFraction: fill,
                scoreFactor: 0.25 + 0.45 * progress
            )
        }
        if fill <= 0.75 {
            let factor: Double
            if fill < 0.35 {
                factor = 0.85 + 0.15 * ((fill - 0.18) / 0.17)
            } else {
                factor = 1.0 - 0.08 * ((fill - 0.35) / 0.40)
            }
            return FOVComposition(
                label: "jó kitöltés",
                shortEdgeFillFraction: fill,
                scoreFactor: factor
            )
        }
        return FOVComposition(
            label: "szorosan fér be",
            shortEdgeFillFraction: fill,
            scoreFactor: sizeArcmin <= minDim ? 0.82 : 0.65
        )
    }
}
