import AstroCore
import Foundation

/// One instant's altitude sample along a target's night-long sweep.
public struct SkyPathSample: Equatable, Sendable {
    public let time: Date
    public let altitudeDeg: Double

    public init(time: Date, altitudeDeg: Double) {
        self.time = time
        self.altitudeDeg = altitudeDeg
    }
}

/// The selected target's altitude across one planned night -- "how high will
/// it be and when", restoring the V1 sky-chart feature natively rather than
/// importing the old `SkyChartView` file (see the planning-workbench plan's
/// Task 3). Every number here comes from the SAME engine the rest of Planning
/// already trusts (`SunMoon`/`AltAz`/`SiderealTime`/`JulianDate`, and, for the
/// authoritative peak, `DiscoveryPlanner.discover` itself) -- no second
/// astrophysics implementation.
public struct SkyPathResult: Equatable, Sendable {
    public let target: CatalogTarget
    /// Roughly 5-minute-resolution altitude samples spanning
    /// `duskUTC...dawnUTC` -- enough for a smooth curve without resampling
    /// the whole night at pointing precision (this is a planning chart, not
    /// a mount driver).
    public let samples: [SkyPathSample]
    public let duskUTC: Date
    public let dawnUTC: Date
    /// The exact `DiscoveryPlanner.discover` result for this target/night --
    /// NOT re-derived from `samples`' own coarser grid, so this can never
    /// silently disagree with the Planning table's own "max alt" column for
    /// the same row.
    public let maxAltitudeDeg: Double
    /// The sampled point closest to culmination, for marking the peak on the
    /// chart -- may sit a few minutes off `maxAltitudeDeg`'s own true instant
    /// at this sampling resolution, which is expected and harmless for a
    /// planning-grade chart.
    public let culminationTime: Date?
    /// The imaging-altitude threshold this query was evaluated against (the
    /// same value `PlanningQuery.minAltitudeDeg` uses) -- carried along so
    /// the chart can draw its own threshold line without a second input.
    public let minAltitudeDeg: Double
    /// The Moon's angular separation from the target at the dark window's
    /// midpoint, same reference instant `DiscoveryPlanner.discover` itself
    /// uses (`NightSweep.midnightMoon`) -- `nil` only if the underlying
    /// `DiscoveryRow` never resolved.
    public let moonSeparationDeg: Double?

    public init(
        target: CatalogTarget,
        samples: [SkyPathSample],
        duskUTC: Date,
        dawnUTC: Date,
        maxAltitudeDeg: Double,
        culminationTime: Date?,
        minAltitudeDeg: Double,
        moonSeparationDeg: Double?
    ) {
        self.target = target
        self.samples = samples
        self.duskUTC = duskUTC
        self.dawnUTC = dawnUTC
        self.maxAltitudeDeg = maxAltitudeDeg
        self.culminationTime = culminationTime
        self.minAltitudeDeg = minAltitudeDeg
        self.moonSeparationDeg = moonSeparationDeg
    }
}

public enum SkyPathQuery {
    /// Samples `target`'s altitude from dusk to dawn on `date`'s night at
    /// `site`, plus the night's authoritative culmination (sourced from
    /// `DiscoveryPlanner.discover`, not re-derived here). `nil` when the site
    /// doesn't resolve or the night never reaches a dark window at all --
    /// same "no site, no invented chart" honesty `PlanningQuery.site` already
    /// documents, never a guessed curve.
    public static func samples(
        target: CatalogTarget,
        site: SiteRule,
        date: Date,
        minAltitudeDeg: Double = PlanningQuery.defaultMinAltitudeDeg,
        stepMinutes: Double = 5
    ) -> SkyPathResult? {
        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else { return nil }
        let twilight = SunMoon.astronomicalTwilight(
            nightOf: date, latDeg: lat, lonDeg: lon, timeZone: .current
        )
        guard let dusk = twilight.duskUTC, let dawn = twilight.dawnUTC, dawn > dusk else { return nil }

        var samples: [SkyPathSample] = []
        let stepSeconds = stepMinutes * 60
        var t = dusk
        while t <= dawn {
            let julianDay = JulianDate.julianDay(t)
            let lstHours = SiderealTime.lstHours(julianDay: julianDay, longitudeDeg: lon)
            let (altitudeDeg, _) = AltAz.position(
                raDeg: target.raDeg, decDeg: target.decDeg, lstHours: lstHours, latDeg: lat
            )
            samples.append(SkyPathSample(time: t, altitudeDeg: altitudeDeg))
            t = t.addingTimeInterval(stepSeconds)
        }

        // Authoritative peak: the SAME engine call the Planning table's own
        // "max alt" column and `PlanningRecommendation.maxAltitudeDeg` use --
        // reused directly rather than re-derived from this chart's own
        // coarser 5-minute grid, so the two numbers can never drift apart.
        // Sweep THIS target explicitly. Letting the engine default to the
        // built-in catalog meant every downloaded (LBN/Sh2/vdB/Barnard)
        // target fell out of the lookup and the chart reported "altitude
        // sweep could not be computed" — while the table, which passes its
        // own catalog, happily showed that target's max altitude two rows
        // above. Passing the single target is also far cheaper than sweeping
        // thousands of rows to read one of them.
        let discoveryRows = DiscoveryPlanner.discover(
            date: date, site: site, minAltitudeDeg: minAltitudeDeg, targets: [target]
        )
        guard let row = discoveryRows.first(where: { $0.target.designation == target.designation }),
              let maxAltitudeDeg = row.maxAltitudeDeg
        else { return nil }

        let culminationTime = samples.max(by: { $0.altitudeDeg < $1.altitudeDeg })?.time

        return SkyPathResult(
            target: target,
            samples: samples,
            duskUTC: dusk,
            dawnUTC: dawn,
            maxAltitudeDeg: maxAltitudeDeg,
            culminationTime: culminationTime,
            minAltitudeDeg: minAltitudeDeg,
            moonSeparationDeg: row.moonSeparationDeg
        )
    }
}
