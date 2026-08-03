import Foundation

/// One target's plan for "tonight": how much usable integration it already
/// has, its goal (if tagged), and the sky/Moon situation for the given (or
/// current) local night -- culmination, the window it's above
/// `minAltitudeDeg` during astronomical night, Moon phase and separation,
/// and a verdict summing all of that up in one line.
public struct TargetPlan: Codable, Sendable, Equatable {
    public var target: String
    public var raDeg: Double?
    public var decDeg: Double?
    public var usableIntegrationSeconds: Double
    public var goalSeconds: Double?
    /// ISO 8601 (UTC) instant of tonight's meridian transit, within the
    /// scanned night window. `nil` if there's no coordinate, or the target
    /// never rises during the window.
    public var culminationUTC: String?
    /// `culminationUTC`, formatted in the site's local time as `"HH:mm"`.
    public var culminationLocal: String?
    public var maxAltitudeDeg: Double?
    /// `"HH:mm–HH:mm"` (site-local time) window during which the target is
    /// at or above `minAltitudeDeg` within tonight's astronomical-night
    /// scan; `nil` if it never is.
    public var visibleWindowLocal: String?
    public var visibleHours: Double?
    public var moonIlluminationPercent: Double?
    public var moonSeparationDeg: Double?
    public var verdict: String
    /// Sort key (descending): missing-need x visibility x Moon-penalty.
    /// Higher means "point at this one tonight".
    public var score: Double

    public init(
        target: String,
        raDeg: Double? = nil,
        decDeg: Double? = nil,
        usableIntegrationSeconds: Double,
        goalSeconds: Double? = nil,
        culminationUTC: String? = nil,
        culminationLocal: String? = nil,
        maxAltitudeDeg: Double? = nil,
        visibleWindowLocal: String? = nil,
        visibleHours: Double? = nil,
        moonIlluminationPercent: Double? = nil,
        moonSeparationDeg: Double? = nil,
        verdict: String,
        score: Double
    ) {
        self.target = target
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.usableIntegrationSeconds = usableIntegrationSeconds
        self.goalSeconds = goalSeconds
        self.culminationUTC = culminationUTC
        self.culminationLocal = culminationLocal
        self.maxAltitudeDeg = maxAltitudeDeg
        self.visibleWindowLocal = visibleWindowLocal
        self.visibleHours = visibleHours
        self.moonIlluminationPercent = moonIlluminationPercent
        self.moonSeparationDeg = moonSeparationDeg
        self.verdict = verdict
        self.score = score
    }
}

/// Builds tonight's `TargetPlan` for every target the library knows about
/// (same target universe as `StatsQueries.perTarget`).
public enum Planner {
    /// Verdict text, Hungarian, in priority order:
    /// 1. no coordinate at all,
    /// 2. never gets above `minAltitudeDeg` tonight,
    /// 3. up for less than half an hour,
    /// 4. Moon within 40 deg and more than 60% illuminated,
    /// 5. otherwise fine.
    private enum Verdict {
        static let noCoordinate = "nincs koordináta"
        static func tooLow(_ maxAlt: Double) -> String { String(format: "alacsony (max %.0f°)", maxAlt) }
        static let notVisibleTonight = "nem látszik ma éjjel"
        static func moonInterferes(separationDeg: Double, illuminationPercent: Double) -> String {
            String(format: "Hold zavar (%.0f°, %.0f%%)", separationDeg, illuminationPercent)
        }
        static let good = "ma jó"
    }

    /// Resolves the effective observing site: `config.site`'s explicit
    /// values win; any `nil` component falls back to the median
    /// `SITELAT`/`SITELONG` across every scanned session light. Exposed
    /// separately from `plan(...)` so callers with a long-lived
    /// `AstroConfig` (the App) can cache the resolved value back into their
    /// in-memory config instance without ever writing it to disk.
    public static func resolveSite(db: Database, config: AstroConfig) throws -> SiteRule {
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.area == .sessions && $0.role == .light }
        let meta = try metaByFileID(for: lights, db: db)
        return TargetCoordinates.resolveSite(files: lights, meta: meta, config: config.site)
    }

    /// Builds tonight's plan for every target on record, sorted by `score`
    /// descending (best target to shoot tonight first).
    public static func plan(
        date: Date? = nil,
        minAltitudeDeg: Double = 30,
        db: Database,
        config: AstroConfig
    ) throws -> [TargetPlan] {
        let referenceDate = date ?? Date()
        let stats = try StatsQueries.perTarget(db: db, config: config)

        let allFiles = try db.allFiles(includeMissing: false)
        let allLights = allFiles.filter { $0.area == .sessions && $0.role == .light }
        let allMeta = try metaByFileID(for: allLights, db: db)

        let site = TargetCoordinates.resolveSite(files: allLights, meta: allMeta, config: config.site)
        let timeZone = TimeZone.current

        var night: SunMoon.TwilightResult?
        var siteLat: Double?
        var siteLon: Double?
        if let lat = site.latitudeDeg, let lon = site.longitudeDeg {
            siteLat = lat
            siteLon = lon
            night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: timeZone)
        }

        var plans: [TargetPlan] = []
        for stat in stats {
            let targetLights = allLights.filter { $0.target == stat.target }
            let coord = TargetCoordinates.medianCoordinates(files: targetLights, meta: allMeta)
            let goalSeconds = GoalTag.parse(tags: stat.tags)

            plans.append(buildPlan(
                target: stat.target,
                usableIntegrationSeconds: stat.usableIntegrationSeconds,
                goalSeconds: goalSeconds,
                coord: coord,
                minAltitudeDeg: minAltitudeDeg,
                siteLat: siteLat,
                siteLon: siteLon,
                night: night,
                timeZone: timeZone
            ))
        }

        return plans.sorted { $0.score > $1.score }
    }

    // MARK: - Per-target assembly

    private static func buildPlan(
        target: String,
        usableIntegrationSeconds: Double,
        goalSeconds: Double?,
        coord: (raDeg: Double, decDeg: Double)?,
        minAltitudeDeg: Double,
        siteLat: Double?,
        siteLon: Double?,
        night: SunMoon.TwilightResult?,
        timeZone: TimeZone
    ) -> TargetPlan {
        guard let coord, let siteLat, let siteLon, let night,
              let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC
        else {
            return TargetPlan(
                target: target,
                raDeg: coord?.raDeg,
                decDeg: coord?.decDeg,
                usableIntegrationSeconds: usableIntegrationSeconds,
                goalSeconds: goalSeconds,
                verdict: Verdict.noCoordinate,
                score: 0
            )
        }

        let sweep = sweepNight(
            raDeg: coord.raDeg, decDeg: coord.decDeg, latDeg: siteLat, lonDeg: siteLon,
            duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg
        )
        let midNight = duskUTC.addingTimeInterval(dawnUTC.timeIntervalSince(duskUTC) / 2)
        let midJD = JulianDate.julianDay(midNight)
        let moon = SunMoon.moonPosition(julianDay: midJD)
        let moonIllum = SunMoon.moonIlluminationPercent(julianDay: midJD)
        let moonSeparation = SunMoon.angularSeparationDeg(ra1: coord.raDeg, dec1: coord.decDeg, ra2: moon.raDeg, dec2: moon.decDeg)

        let visibleHours = sweep.visibleSeconds / 3600.0
        let culminationLocal = sweep.culminationUTC.map { formatLocalTime($0, timeZone: timeZone) }
        let visibleWindowLocal = sweep.visibleStart.flatMap { start -> String? in
            guard let end = sweep.visibleEnd else { return nil }
            return "\(formatLocalTime(start, timeZone: timeZone))–\(formatLocalTime(end, timeZone: timeZone))"
        }

        let moonInterferes = moonIllum > 60 && moonSeparation < 40
        let verdict: String
        if sweep.maxAltitudeDeg < minAltitudeDeg {
            verdict = Verdict.tooLow(sweep.maxAltitudeDeg)
        } else if visibleHours < 0.5 {
            verdict = Verdict.notVisibleTonight
        } else if moonInterferes {
            verdict = Verdict.moonInterferes(separationDeg: moonSeparation, illuminationPercent: moonIllum)
        } else {
            verdict = Verdict.good
        }

        let score = self.score(
            usableIntegrationSeconds: usableIntegrationSeconds,
            goalSeconds: goalSeconds,
            visibleHours: visibleHours,
            moonInterferes: moonInterferes
        )

        return TargetPlan(
            target: target,
            raDeg: coord.raDeg,
            decDeg: coord.decDeg,
            usableIntegrationSeconds: usableIntegrationSeconds,
            goalSeconds: goalSeconds,
            culminationUTC: sweep.culminationUTC.map(isoString),
            culminationLocal: culminationLocal,
            maxAltitudeDeg: sweep.maxAltitudeDeg,
            visibleWindowLocal: visibleWindowLocal,
            visibleHours: visibleHours,
            moonIlluminationPercent: moonIllum,
            moonSeparationDeg: moonSeparation,
            verdict: verdict,
            score: score
        )
    }

    // MARK: - Score

    /// `missingNeed x visibilityFactor x moonPenalty`. `missingNeed` is 1.0
    /// when there's no goal (every target with data is equally "worth
    /// finishing"), otherwise the outstanding fraction of the goal, capped
    /// at 99 (so a wildly under-shot goal doesn't dwarf everything else)
    /// and floored at a small positive value once the goal is already met
    /// (still shootable, just deprioritized under anything still missing
    /// hours). `visibilityFactor` is `min(visibleHours/4, 1)`.
    /// `moonPenalty` is 0.2 when the verdict is "Hold zavar", else 1.
    private static func score(
        usableIntegrationSeconds: Double,
        goalSeconds: Double?,
        visibleHours: Double,
        moonInterferes: Bool
    ) -> Double {
        let missingNeed: Double
        if let goalSeconds {
            let missingHours = max(0, (goalSeconds - usableIntegrationSeconds) / 3600.0)
            missingNeed = missingHours > 0 ? min(missingHours, 99) : 0.1
        } else {
            missingNeed = 1.0
        }
        let visibilityFactor = min(max(visibleHours, 0) / 4.0, 1.0)
        let moonPenalty = moonInterferes ? 0.2 : 1.0
        return missingNeed * visibilityFactor * moonPenalty
    }

    // MARK: - Night sweep (culmination, max altitude, visibility window)

    private struct NightSweep {
        var maxAltitudeDeg: Double
        var culminationUTC: Date?
        var visibleSeconds: Double
        var visibleStart: Date?
        var visibleEnd: Date?
    }

    /// Samples the target's altitude every `stepMinutes` from dusk to dawn,
    /// tracking the maximum (culmination) and the extent of the
    /// above-`minAltitudeDeg` span. A brute-force scan rather than solving
    /// the transit time in closed form -- simpler to get right, and this
    /// tool only ever needs night-window granularity, not observatory
    /// pointing precision.
    private static func sweepNight(
        raDeg: Double,
        decDeg: Double,
        latDeg: Double,
        lonDeg: Double,
        duskUTC: Date,
        dawnUTC: Date,
        minAltitudeDeg: Double,
        stepMinutes: Double = 2
    ) -> NightSweep {
        var maxAlt = -Double.infinity
        var maxAltDate: Date?
        var visibleSampleCount = 0
        var visibleStart: Date?
        var visibleEnd: Date?

        let stepSeconds = stepMinutes * 60
        var t = duskUTC
        while t <= dawnUTC {
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let (alt, _) = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg)

            if alt > maxAlt {
                maxAlt = alt
                maxAltDate = t
            }

            if alt >= minAltitudeDeg {
                visibleSampleCount += 1
                if visibleStart == nil { visibleStart = t }
                visibleEnd = t
            }

            t = t.addingTimeInterval(stepSeconds)
        }

        return NightSweep(
            maxAltitudeDeg: maxAlt.isFinite ? maxAlt : -90,
            culminationUTC: maxAltDate,
            visibleSeconds: Double(visibleSampleCount) * stepSeconds,
            visibleStart: visibleStart,
            visibleEnd: visibleEnd
        )
    }

    // MARK: - Helpers

    private static func metaByFileID(for files: [FileRecord], db: Database) throws -> [Int64: FITSMetaRecord] {
        var result: [Int64: FITSMetaRecord] = [:]
        for file in files {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) {
                result[id] = meta
            }
        }
        return result
    }

    private static func formatLocalTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
