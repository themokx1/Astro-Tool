import Foundation

/// One target's plan for "tonight": how much usable integration it already
/// has, its goal (if tagged), and the sky/Moon situation for the given (or
/// current) local night -- culmination, the window it's above
/// `minAltitudeDeg` during astronomical night, Moon phase and separation,
/// and a verdict summing all of that up in one line.
public struct TargetPlan: Codable, Sendable, Equatable {
    public var target: String
    /// Resolved catalog designation/Hungarian common name for `target`
    /// (via `TargetNameResolver`, `name:<text>` tag override applied via
    /// `NameTag`) -- see `TargetStats.displayName`'s own doc comment for
    /// the exact composition rules. Absent in JSON produced before this
    /// field existed; decodes to `target`'s cleaned form in that case (see
    /// the lenient `init(from:)`).
    public var displayName: String
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
    /// R11-T5/F2: this target's per-filter usable-vs-goal breakdown
    /// (`FilterGoalQueries.merge`), `[]` when it has no
    /// `goal:<filter>=<hours>h` tag at all -- `TonightPage`'s "Hiányzik"
    /// cell shows a popover with this breakdown exactly when it's
    /// non-empty. Deliberately NOT computed for every target unconditionally
    /// (see `Planner.plan`'s own comment): it needs its own
    /// `FilterBreakdownQueries.breakdown` pass, gated on the target actually
    /// having a filter goal tag to keep the common (no filter goals) case
    /// cheap.
    public var filterGoals: [FilterIntegration]
    /// R11-T6/F3: tonight's Hold-tudatos szűrő-ajánlás for this target --
    /// `nil` under the exact same conditions `moonSeparationDeg` is (no
    /// coordinate/site/night to evaluate the Moon against at all: comet,
    /// missing coordinate, or unresolvable site). Absent in JSON produced
    /// before this field existed; decodes to `nil` in that case.
    public var filterAdvice: FilterAdvisor.Advice?

    public init(
        target: String,
        displayName: String? = nil,
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
        score: Double,
        filterGoals: [FilterIntegration] = [],
        filterAdvice: FilterAdvisor.Advice? = nil
    ) {
        self.target = target
        self.displayName = displayName ?? target.replacingOccurrences(of: "_", with: " ")
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
        self.filterGoals = filterGoals
        self.filterAdvice = filterAdvice
    }

    private enum CodingKeys: String, CodingKey {
        case target, displayName, raDeg, decDeg, usableIntegrationSeconds, goalSeconds,
             culminationUTC, culminationLocal, maxAltitudeDeg, visibleWindowLocal, visibleHours,
             moonIlluminationPercent, moonSeparationDeg, verdict, score, filterGoals, filterAdvice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        // Absent in JSON produced before this field existed -- fall back to
        // the cleaned target name, same default the memberwise `init` uses.
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? target.replacingOccurrences(of: "_", with: " ")
        raDeg = try c.decodeIfPresent(Double.self, forKey: .raDeg)
        decDeg = try c.decodeIfPresent(Double.self, forKey: .decDeg)
        usableIntegrationSeconds = try c.decode(Double.self, forKey: .usableIntegrationSeconds)
        goalSeconds = try c.decodeIfPresent(Double.self, forKey: .goalSeconds)
        culminationUTC = try c.decodeIfPresent(String.self, forKey: .culminationUTC)
        culminationLocal = try c.decodeIfPresent(String.self, forKey: .culminationLocal)
        maxAltitudeDeg = try c.decodeIfPresent(Double.self, forKey: .maxAltitudeDeg)
        visibleWindowLocal = try c.decodeIfPresent(String.self, forKey: .visibleWindowLocal)
        visibleHours = try c.decodeIfPresent(Double.self, forKey: .visibleHours)
        moonIlluminationPercent = try c.decodeIfPresent(Double.self, forKey: .moonIlluminationPercent)
        moonSeparationDeg = try c.decodeIfPresent(Double.self, forKey: .moonSeparationDeg)
        verdict = try c.decode(String.self, forKey: .verdict)
        score = try c.decode(Double.self, forKey: .score)
        // Absent in JSON produced before this field existed -- falls back to
        // "no filter goals", same default the memberwise `init` uses.
        filterGoals = try c.decodeIfPresent([FilterIntegration].self, forKey: .filterGoals) ?? []
        filterAdvice = try c.decodeIfPresent(FilterAdvisor.Advice.self, forKey: .filterAdvice)
    }
}

/// One calendar night's planning-calendar summary (R7-B5, `astrotool plan
/// --month`) -- coarser than `TargetPlan` (no per-target verdict, no score),
/// built for a whole month at a glance rather than "what should I shoot
/// right now".
public struct NightSummary: Codable, Sendable, Equatable {
    /// One target's usable-overlap hours for this night -- see
    /// `Planner.month`'s doc comment for exactly what "usable" means.
    public struct BestWindow: Codable, Sendable, Equatable {
        public var target: String
        public var usableHours: Double

        public init(target: String, usableHours: Double) {
            self.target = target
            self.usableHours = usableHours
        }
    }

    /// Local night-of date, `"yyyy-MM-dd"`.
    public var date: String
    /// Hours of TRUE astronomical night (`SunMoon.astronomicalTwilight`
    /// without its nautical fallback) -- `nil` when the night never reaches
    /// -18° (common in summer at high latitude); `note` explains why
    /// whenever this is `nil`.
    public var astroDarkHours: Double?
    /// Set exactly when `astroDarkHours` is `nil`: either the night fell
    /// back to nautical twilight (-12°) or, at the extreme, never got dark
    /// at all ("fehér éjszaka" -- white night).
    public var note: String?
    /// Moon illumination at this night's dark-window midpoint (or, when
    /// there's no dark window at all, at local civil midnight) -- always
    /// computed, since it needs no target coordinate or site altitude math.
    public var moonIlluminationPercent: Double
    /// Top 3 targets (by `usableHours`, descending) with a resolvable
    /// coordinate whose usable overlap is `> 0` this night -- `[]` when no
    /// target clears the bar (no dark window, every target vetoed by the
    /// Moon, or the library has no target with a coordinate at all).
    public var bestTargets: [BestWindow]

    public init(
        date: String,
        astroDarkHours: Double? = nil,
        note: String? = nil,
        moonIlluminationPercent: Double,
        bestTargets: [BestWindow] = []
    ) {
        self.date = date
        self.astroDarkHours = astroDarkHours
        self.note = note
        self.moonIlluminationPercent = moonIlluminationPercent
        self.bestTargets = bestTargets
    }
}

/// Tonight's dark-time/Moon summary for the "Ma este" tile row (R9-T4/A.1) --
/// coarser than `TargetPlan` (no target coordinate involved at all), and
/// unlike `NightSummary.moonIlluminationPercent` (evaluated at the window's
/// midpoint or civil midnight) this also reports whether/when the Moon
/// crosses the horizon during the night, for the "Hold" tile's "felkel
/// 23:41" wording. See `Planner.nightInfo(date:site:)`.
public struct NightInfo: Codable, Sendable, Equatable {
    /// Hours of true astronomical night (`SunMoon.astronomicalTwilight`
    /// without its nautical fallback) -- `nil` under the same conditions
    /// `NightSummary.astroDarkHours` is: no resolvable site, no dark window
    /// at all ("fehér éjszaka"), or the window only reached nautical (-12°)
    /// twilight. `note` explains why whenever this is `nil`.
    public var darkHours: Double?
    /// Set exactly when `darkHours` is `nil` -- same convention as
    /// `NightSummary.note`.
    public var note: String?
    /// Moon illumination at the dark window's midpoint (site resolvable and
    /// a window exists) or otherwise at the reference date's local instant --
    /// always computed, same "illumination never needs site/altitude math"
    /// stance as `NightSummary.moonIlluminationPercent`.
    public var moonIlluminationPercent: Double
    /// One of `"felkel HH:mm"` / `"nyugszik HH:mm"` (the Moon crosses the
    /// horizon once during the dusk...dawn window) / `"egész éjjel fent"` /
    /// `"egész éjjel lent"` (it doesn't cross at all) -- `nil` only when
    /// there's no site/no dark window to evaluate the Moon's altitude
    /// against at all.
    public var moonEventLabel: String?

    public init(darkHours: Double?, note: String? = nil, moonIlluminationPercent: Double, moonEventLabel: String?) {
        self.darkHours = darkHours
        self.note = note
        self.moonIlluminationPercent = moonIlluminationPercent
        self.moonEventLabel = moonEventLabel
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
    ///
    /// The actual wording lives in `SkyVerdict` (R10-A4) -- shared with
    /// `DiscoveryPlanner.discover`, which surfaces the same judgment over
    /// the embedded catalog instead of the library.
    private typealias Verdict = SkyVerdict

    /// Resolves the effective observing site.
    ///
    /// R11-T15/F16: when `config.sites` is non-empty, THAT list is
    /// authoritative and `siteName` selects which entry -- `nil` (the
    /// default) picks `SiteProfile.defaultSite(in:)`; an explicit name picks
    /// that exact entry (case-insensitive), throwing `AstroError.
    /// invalidInput` with the full list of configured names when it doesn't
    /// match one (the CLI's `plan --site`/`night-info --site` surface this
    /// directly; the app validates its own site-Picker selection against
    /// `config.sites` before ever passing a name here, so it never hits this
    /// branch with a stale/deleted name).
    ///
    /// `config.sites` empty is the pre-T15 path, completely unchanged:
    /// `config.site`'s explicit values win; any `nil` component falls back
    /// to the median `SITELAT`/`SITELONG` across every scanned session
    /// light. Exposed separately from `plan(...)` so callers with a
    /// long-lived `AstroConfig` (the App) can cache the resolved value back
    /// into their in-memory config instance without ever writing it to disk.
    public static func resolveSite(db: Database, config: AstroConfig, siteName: String? = nil) throws -> SiteRule {
        if let configured = try resolveConfiguredSite(config: config, siteName: siteName) {
            return configured
        }
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.area == .sessions && $0.role == .light }
        let meta = try metaByFileID(for: lights, db: db)
        return TargetCoordinates.resolveSite(files: lights, meta: meta, config: config.site)
    }

    /// The `config.sites`-driven half of `resolveSite(db:config:siteName:)`,
    /// factored out (DB-free) so `plan(...)`/`month(...)` can reuse it
    /// against a `db.allFiles` pass they already had to make for their own
    /// per-target coordinate work, instead of `resolveSite` repeating that
    /// same query redundantly whenever `config.sites` is empty. `nil`
    /// return means "`config.sites` isn't authoritative here -- fall back
    /// to `config.site`/the FITS-median instead" (the only case this
    /// itself never throws): every other case either returns a resolved
    /// `SiteRule` or throws `AstroError.invalidInput` (an explicit
    /// `siteName` that doesn't match anything configured, including "not a
    /// single site is configured at all").
    private static func resolveConfiguredSite(config: AstroConfig, siteName: String?) throws -> SiteRule? {
        guard !config.sites.isEmpty else {
            if let siteName {
                throw AstroError.invalidInput(
                    "nincs konfigurált helyszín (\"\(siteName)\" nem választható) -- Beállítások ▸ Helyszín, vagy config.json \"sites\" tömb"
                )
            }
            return nil
        }
        if let siteName {
            guard let match = config.sites.first(where: { $0.name.caseInsensitiveCompare(siteName) == .orderedSame }) else {
                let names = config.sites.map(\.name).joined(separator: ", ")
                throw AstroError.invalidInput("ismeretlen helyszín: \"\(siteName)\" -- elérhető helyszínek: \(names)")
            }
            return SiteRule(latitudeDeg: match.latitudeDeg, longitudeDeg: match.longitudeDeg)
        }
        guard let def = SiteProfile.defaultSite(in: config.sites) else { return nil }
        return SiteRule(latitudeDeg: def.latitudeDeg, longitudeDeg: def.longitudeDeg)
    }

    /// Tonight's (or `date`'s) dark-time/Moon summary for the "Ma este" tile
    /// row (R9-T4/A.1) -- see `NightInfo`'s own doc for exactly what each
    /// field means. Unlike `plan(...)`, this never needs a target coordinate
    /// at all, only the resolved site -- callers already have that from
    /// `resolveSite(db:config:)` (cheap to call alongside `plan`, since both
    /// draw on the same already-resolved site).
    public static func nightInfo(date: Date? = nil, site: SiteRule) -> NightInfo {
        let referenceDate = date ?? Date()
        let timeZone = TimeZone.current

        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
            let illum = SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(referenceDate))
            return NightInfo(darkHours: nil, note: "nincs site-koordináta", moonIlluminationPercent: illum, moonEventLabel: nil)
        }

        let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: timeZone)
        guard let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC else {
            let illum = SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(referenceDate))
            return NightInfo(darkHours: nil, note: "nincs sötét ablak (fehér éjszaka)", moonIlluminationPercent: illum, moonEventLabel: nil)
        }

        let windowSeconds = dawnUTC.timeIntervalSince(duskUTC)
        let darkHours: Double? = night.usedNauticalFallback ? nil : windowSeconds / 3600.0
        let note: String? = night.usedNauticalFallback
            ? "nincs csillagászati éjszaka -- nautikus szürkület alapján számolva"
            : nil

        let midNight = duskUTC.addingTimeInterval(windowSeconds / 2)
        let midJD = JulianDate.julianDay(midNight)
        let moonIllum = SunMoon.moonIlluminationPercent(julianDay: midJD)
        let eventLabel = moonEventLabel(latDeg: lat, lonDeg: lon, duskUTC: duskUTC, dawnUTC: dawnUTC, timeZone: timeZone)

        return NightInfo(darkHours: darkHours, note: note, moonIlluminationPercent: moonIllum, moonEventLabel: eventLabel)
    }

    /// Samples the Moon's altitude every `stepMinutes` from dusk to dawn and
    /// reports whether/when it crosses the horizon -- the "felkel 23:41"/
    /// "nyugszik 02:15"/"egész éjjel fent"/"egész éjjel lent" wording for the
    /// "Hold" tile. A brute-force scan, same simplicity tradeoff as
    /// `sweepNight`'s altitude sweep.
    private static func moonEventLabel(
        latDeg: Double, lonDeg: Double, duskUTC: Date, dawnUTC: Date, timeZone: TimeZone, stepMinutes: Double = 5
    ) -> String {
        func moonAltitude(at date: Date) -> Double {
            let jd = JulianDate.julianDay(date)
            let moon = SunMoon.moonPosition(julianDay: jd)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            return AltAz.position(raDeg: moon.raDeg, decDeg: moon.decDeg, lstHours: lst, latDeg: latDeg).altitudeDeg
        }

        let stepSeconds = stepMinutes * 60
        var samples: [(date: Date, alt: Double)] = []
        var t = duskUTC
        while t <= dawnUTC {
            samples.append((t, moonAltitude(at: t)))
            t = t.addingTimeInterval(stepSeconds)
        }
        guard let first = samples.first else { return "egész éjjel lent" }

        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            if a.alt < 0, b.alt >= 0 {
                return "felkel \(formatLocalTime(interpolatedZeroCrossing(a, b), timeZone: timeZone))"
            }
            if a.alt >= 0, b.alt < 0 {
                return "nyugszik \(formatLocalTime(interpolatedZeroCrossing(a, b), timeZone: timeZone))"
            }
        }
        return first.alt >= 0 ? "egész éjjel fent" : "egész éjjel lent"
    }

    /// Linear interpolation of the instant altitude crosses zero between two
    /// consecutive samples -- same technique as `SunMoon`'s own (private,
    /// unreachable from here) `interpolatedCrossing`, specialized to a
    /// `threshold` of `0`.
    private static func interpolatedZeroCrossing(_ a: (date: Date, alt: Double), _ b: (date: Date, alt: Double)) -> Date {
        let span = b.alt - a.alt
        guard span != 0 else { return a.date }
        let fraction = -a.alt / span
        return a.date.addingTimeInterval(b.date.timeIntervalSince(a.date) * fraction)
    }

    /// Builds a month-at-a-glance planning calendar (R7-B5, `astrotool plan
    /// --month`): one `NightSummary` per night, starting at `from` (defaults
    /// to today, local time) and covering `nights` consecutive nights.
    ///
    /// Per night: resolves the dark window (`SunMoon.astronomicalTwilight`,
    /// same fallback behavior `plan(...)` already relies on) and the Moon's
    /// illumination at that window's midpoint, then -- for every target with
    /// a resolvable coordinate -- scores "usable overlap hours" as the
    /// intersection of (altitude ≥ `minAltitudeDeg`) AND (inside the dark
    /// window) AND (Moon OK: separation ≥ 40° from the target OR
    /// illumination < 60%, evaluated ONCE at the window's midpoint -- same
    /// rule, same single-point evaluation, as `plan(...)`'s own per-target
    /// verdict). A target the Moon vetoes contributes exactly `0` usable
    /// hours for that night (not a reduced number) and is therefore never
    /// among that night's `bestTargets` -- the veto is binary, not a partial
    /// penalty, since the Moon is either close and bright enough to ruin
    /// the exposure or it isn't.
    ///
    /// Sampling is coarsened to 10-minute steps for the overlap scan (vs.
    /// `plan`'s 2-minute steps): `nights x targets x samples-per-night`
    /// would otherwise scale poorly for a full month against a library with
    /// many targets, and a few minutes of granularity is more than enough
    /// accuracy at planning-calendar (not pointing) resolution.
    public static func month(
        from date: Date? = nil,
        nights: Int = 30,
        minAltitudeDeg: Double = 30,
        siteName: String? = nil,
        db: Database,
        config: AstroConfig
    ) throws -> [NightSummary] {
        let referenceDate = date ?? Date()
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let allFiles = try db.allFiles(includeMissing: false)
        let allLights = allFiles.filter { $0.area == .sessions && $0.role == .light }
        let allMeta = try metaByFileID(for: allLights, db: db)
        // R11-T15/F16: `config.sites`-aware priority (`resolveConfiguredSite`,
        // shared with `resolveSite(db:config:siteName:)`/`plan(...)`) rather
        // than calling `TargetCoordinates.resolveSite` unconditionally --
        // otherwise a selected named site (or even just a configured
        // DEFAULT site) would be silently ignored here while `plan(...)`/
        // the app's own tiles correctly used it. Reuses the `allLights`/
        // `allMeta` this function already fetched for its own per-target
        // coordinate work instead of letting `resolveSite` redo that same
        // `db.allFiles` pass whenever `config.sites` turns out to be empty.
        let site = try resolveConfiguredSite(config: config, siteName: siteName)
            ?? TargetCoordinates.resolveSite(files: allLights, meta: allMeta, config: config.site)

        var targetCoords: [(target: String, raDeg: Double, decDeg: Double)] = []
        if site.latitudeDeg != nil, site.longitudeDeg != nil {
            let stats = try StatsQueries.perTarget(db: db, config: config)
            for stat in stats {
                // Comets excluded entirely from the planning calendar's
                // best-target windows -- their session-derived coordinate is
                // stale by the time this calendar is even looked at (see
                // `Verdict.cometStaleCoordinate`'s doc comment), so any
                // "usable hours" computed from it would be meaningless.
                guard !TargetNameResolver.resolve(folderName: stat.target).isComet else { continue }
                let targetLights = allLights.filter { $0.target == stat.target }
                if let coord = TargetCoordinates.medianCoordinates(files: targetLights, meta: allMeta) {
                    targetCoords.append((stat.target, coord.raDeg, coord.decDeg))
                }
            }
        }

        var summaries: [NightSummary] = []
        for offset in 0..<nights {
            guard let day = calendar.date(byAdding: .day, value: offset, to: referenceDate) else { continue }
            let dateString = dateFormatter.string(from: day)

            guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
                let illum = civilMidnightMoonIllumination(day: day, calendar: calendar)
                summaries.append(NightSummary(date: dateString, note: "nincs site-koordináta", moonIlluminationPercent: illum))
                continue
            }

            let night = SunMoon.astronomicalTwilight(nightOf: day, latDeg: lat, lonDeg: lon, timeZone: timeZone)
            guard let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC else {
                let illum = civilMidnightMoonIllumination(day: day, calendar: calendar)
                summaries.append(NightSummary(date: dateString, note: "nincs sötét ablak (fehér éjszaka)", moonIlluminationPercent: illum))
                continue
            }

            let windowSeconds = dawnUTC.timeIntervalSince(duskUTC)
            let astroDarkHours: Double? = night.usedNauticalFallback ? nil : windowSeconds / 3600.0
            let note: String? = night.usedNauticalFallback
                ? "nincs csillagászati éjszaka -- nautikus szürkület alapján számolva"
                : nil

            let midNight = duskUTC.addingTimeInterval(windowSeconds / 2)
            let midJD = JulianDate.julianDay(midNight)
            let moonIllum = SunMoon.moonIlluminationPercent(julianDay: midJD)
            let moonAtMidnight = SunMoon.moonPosition(julianDay: midJD)

            var windows: [NightSummary.BestWindow] = []
            for entry in targetCoords {
                let separation = SunMoon.angularSeparationDeg(
                    ra1: entry.raDeg, dec1: entry.decDeg, ra2: moonAtMidnight.raDeg, dec2: moonAtMidnight.decDeg
                )
                let moonOK = separation >= 40 || moonIllum < 60
                guard moonOK else { continue }

                let usableSeconds = overlapSeconds(
                    raDeg: entry.raDeg, decDeg: entry.decDeg, latDeg: lat, lonDeg: lon,
                    duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg
                )
                guard usableSeconds > 0 else { continue }
                windows.append(NightSummary.BestWindow(target: entry.target, usableHours: usableSeconds / 3600.0))
            }

            let bestTargets = Array(windows.sorted { $0.usableHours > $1.usableHours }.prefix(3))
            summaries.append(NightSummary(
                date: dateString, astroDarkHours: astroDarkHours, note: note,
                moonIlluminationPercent: moonIllum, bestTargets: bestTargets
            ))
        }

        return summaries
    }

    /// Moon illumination at LOCAL civil midnight starting the night after
    /// `day` -- the fallback used when no dark window resolves at all (no
    /// site, or even nautical twilight never happens), since illumination
    /// itself needs no site/altitude math and shouldn't be withheld just
    /// because the rest of the night's numbers are unavailable.
    private static func civilMidnightMoonIllumination(day: Date, calendar: Calendar) -> Double {
        let startOfDay = calendar.startOfDay(for: day)
        let midnight = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(midnight))
    }

    /// Seconds, within `[duskUTC, dawnUTC]`, that the target's altitude is
    /// `>= minAltitudeDeg` -- a coarser (`stepMinutes`, default 10) sibling
    /// of `sweepNight`'s per-plan altitude scan, used only by `month`'s
    /// per-night x per-target overlap scoring.
    private static func overlapSeconds(
        raDeg: Double,
        decDeg: Double,
        latDeg: Double,
        lonDeg: Double,
        duskUTC: Date,
        dawnUTC: Date,
        minAltitudeDeg: Double,
        stepMinutes: Double = 10
    ) -> Double {
        var visibleSampleCount = 0
        let stepSeconds = stepMinutes * 60
        var t = duskUTC
        while t <= dawnUTC {
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let position = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg)
            if position.altitudeDeg >= minAltitudeDeg {
                visibleSampleCount += 1
            }
            t = t.addingTimeInterval(stepSeconds)
        }
        return Double(visibleSampleCount) * stepSeconds
    }

    /// Builds tonight's plan for every target on record, sorted by `score`
    /// descending (best target to shoot tonight first).
    public static func plan(
        date: Date? = nil,
        minAltitudeDeg: Double = 30,
        siteName: String? = nil,
        db: Database,
        config: AstroConfig
    ) throws -> [TargetPlan] {
        let referenceDate = date ?? Date()
        let stats = try StatsQueries.perTarget(db: db, config: config)

        let allFiles = try db.allFiles(includeMissing: false)
        let allLights = allFiles.filter { $0.area == .sessions && $0.role == .light }
        let allMeta = try metaByFileID(for: allLights, db: db)

        // R11-T15/F16: see `month(...)`'s identical comment -- same
        // `resolveConfiguredSite` reuse, same reason.
        let site = try resolveConfiguredSite(config: config, siteName: siteName)
            ?? TargetCoordinates.resolveSite(files: allLights, meta: allMeta, config: config.site)
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
            let isComet = TargetNameResolver.resolve(folderName: stat.target).isComet

            // R11-T5/F2: per-filter goal breakdown, gated on the target
            // actually having at least one `goal:<filter>=<hours>h` tag --
            // `FilterBreakdownQueries.breakdown` needs its own fresh
            // `db.allFiles` pass, so this keeps the (common) no-filter-goal
            // case from paying that cost for every target in the library.
            var filterGoals: [FilterIntegration] = []
            if !GoalTag.parseFilterGoals(tags: stat.tags).isEmpty {
                let breakdown = try FilterBreakdownQueries.breakdown(db: db, config: config, target: stat.target)
                filterGoals = FilterGoalQueries.merge(breakdown: breakdown, tags: stat.tags)
            }

            plans.append(buildPlan(
                target: stat.target,
                displayName: stat.displayName,
                usableIntegrationSeconds: stat.usableIntegrationSeconds,
                goalSeconds: goalSeconds,
                filterGoals: filterGoals,
                coord: coord,
                isComet: isComet,
                minAltitudeDeg: minAltitudeDeg,
                siteLat: siteLat,
                siteLon: siteLon,
                night: night,
                timeZone: timeZone,
                narrowbandFilters: config.plan.narrowbandFilters
            ))
        }

        return dedupeDisplayNames(plans.sorted { $0.score > $1.score })
    }

    // MARK: - Duplicate displayName disambiguation

    /// When two or more `TargetPlan`s share the same `displayName` (e.g. a
    /// comet's normal and `_Wide` folder variants both resolving to the same
    /// `"C/2025 R3"` designation), the plan table/"Ma este" box would render
    /// indistinguishable rows since both just print `displayName`. Appends,
    /// in parens, each colliding target's own raw-folder-name tokens beyond
    /// whatever prefix EVERY member of the group shares -- e.g.
    /// `"C/2025 R3 (Panstarrs)"` / `"C/2025 R3 (Panstarrs_Wide)"` for
    /// `"C2025_R3_Panstarrs"` / `"C2025_R3_Panstarrs_Wide"`. The shared
    /// prefix is capped one token short of the SHORTEST member's own length
    /// so every member always keeps at least one distinguishing token (never
    /// an empty, useless suffix) -- distinct `target` strings guarantee the
    /// appended text differs across the group even in a pathological case
    /// where the capped suffix still collides token-for-token. Targets with
    /// a unique `displayName` are returned unchanged.
    private static func dedupeDisplayNames(_ plans: [TargetPlan]) -> [TargetPlan] {
        var countByName: [String: Int] = [:]
        for plan in plans { countByName[plan.displayName, default: 0] += 1 }

        var indicesByName: [String: [Int]] = [:]
        for (index, plan) in plans.enumerated() where (countByName[plan.displayName] ?? 0) > 1 {
            indicesByName[plan.displayName, default: []].append(index)
        }
        guard !indicesByName.isEmpty else { return plans }

        var result = plans
        for indices in indicesByName.values {
            let tokenLists = indices.map { plans[$0].target.split(separator: "_").map(String.init) }
            let minTokenCount = tokenLists.map(\.count).min() ?? 0
            // Keep at least one trailing token for every member.
            let maxPrefixLength = max(0, minTokenCount - 1)
            let sharedPrefixLength = min(commonTokenPrefixLength(tokenLists), maxPrefixLength)

            for (listIndex, planIndex) in indices.enumerated() {
                let suffix = tokenLists[listIndex].dropFirst(sharedPrefixLength).joined(separator: "_")
                result[planIndex].displayName = "\(plans[planIndex].displayName) (\(suffix))"
            }
        }
        return result
    }

    /// Length of the longest token run every list in `tokenLists` starts
    /// with, identically.
    private static func commonTokenPrefixLength(_ tokenLists: [[String]]) -> Int {
        guard let first = tokenLists.first else { return 0 }
        var length = 0
        while length < first.count {
            let candidate = first[length]
            guard !tokenLists.contains(where: { $0.count <= length || $0[length] != candidate }) else { break }
            length += 1
        }
        return length
    }

    // MARK: - Per-target assembly

    private static func buildPlan(
        target: String,
        displayName: String,
        usableIntegrationSeconds: Double,
        goalSeconds: Double?,
        filterGoals: [FilterIntegration],
        coord: (raDeg: Double, decDeg: Double)?,
        isComet: Bool,
        minAltitudeDeg: Double,
        siteLat: Double?,
        siteLon: Double?,
        night: SunMoon.TwilightResult?,
        timeZone: TimeZone,
        narrowbandFilters: [String]
    ) -> TargetPlan {
        guard !isComet else {
            return TargetPlan(
                target: target,
                displayName: displayName,
                raDeg: coord?.raDeg,
                decDeg: coord?.decDeg,
                usableIntegrationSeconds: usableIntegrationSeconds,
                goalSeconds: goalSeconds,
                verdict: Verdict.cometStaleCoordinate,
                score: 0,
                filterGoals: filterGoals
            )
        }

        guard let coord, let siteLat, let siteLon, let night,
              let duskUTC = night.duskUTC, let dawnUTC = night.dawnUTC
        else {
            return TargetPlan(
                target: target,
                displayName: displayName,
                raDeg: coord?.raDeg,
                decDeg: coord?.decDeg,
                usableIntegrationSeconds: usableIntegrationSeconds,
                goalSeconds: goalSeconds,
                verdict: Verdict.noCoordinate,
                score: 0,
                filterGoals: filterGoals
            )
        }

        let sweep = NightSweep.sweep(
            raDeg: coord.raDeg, decDeg: coord.decDeg, latDeg: siteLat, lonDeg: siteLon,
            duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg
        )
        let moon = NightSweep.midnightMoon(duskUTC: duskUTC, dawnUTC: dawnUTC)
        let moonIllum = moon.illuminationPercent
        let moonSeparation = SunMoon.angularSeparationDeg(ra1: coord.raDeg, dec1: coord.decDeg, ra2: moon.raDeg, dec2: moon.decDeg)

        let visibleHours = sweep.visibleSeconds / 3600.0
        let culminationLocal = sweep.culminationUTC.map { formatLocalTime($0, timeZone: timeZone) }
        let visibleWindowLocal = NightSweep.visibleWindowLocal(sweep, timeZone: timeZone)

        let moonInterferes = moonIllum > 60 && moonSeparation < 40
        var verdict: String
        if sweep.maxAltitudeDeg < minAltitudeDeg {
            verdict = Verdict.tooLow(sweep.maxAltitudeDeg)
        } else if visibleHours < 0.5 {
            verdict = Verdict.notVisibleTonight
        } else if moonInterferes {
            verdict = Verdict.moonInterferes(separationDeg: moonSeparation, illuminationPercent: moonIllum)
        } else {
            verdict = Verdict.good
        }

        // R11-T6/F3: Hold-tudatos szűrő-ajánlás -- computed regardless of
        // which verdict branch fired above (a "Hold zavar"/"alacsony" night
        // can still be worth a filter suggestion), then folded ADDITIVELY
        // into the verdict text only for the plain "ma jó" case (see
        // `FilterAdvisor.augmentedVerdict`'s own doc comment).
        let filterAdvice = FilterAdvisor.advice(
            moonIlluminationPercent: moonIllum,
            moonSeparationDeg: moonSeparation,
            filterGoals: filterGoals,
            narrowbandFilters: narrowbandFilters
        )
        verdict = FilterAdvisor.augmentedVerdict(baseVerdict: verdict, advice: filterAdvice)

        let score = self.score(
            usableIntegrationSeconds: usableIntegrationSeconds,
            goalSeconds: goalSeconds,
            visibleHours: visibleHours,
            moonInterferes: moonInterferes
        )

        return TargetPlan(
            target: target,
            displayName: displayName,
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
            score: score,
            filterGoals: filterGoals,
            filterAdvice: filterAdvice
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
        return missingNeed
            * SkyScore.visibilityFactor(visibleHours: visibleHours)
            * SkyScore.moonPenalty(moonInterferes: moonInterferes)
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

    /// Thin forwarders to `NightSweep`'s formatting (R10-A4 extraction) --
    /// kept as same-named private members so every existing call site above
    /// (`moonEventLabel`, `buildPlan`) needed no changes at all.
    private static func formatLocalTime(_ date: Date, timeZone: TimeZone) -> String {
        NightSweep.formatLocalTime(date, timeZone: timeZone)
    }

    private static func isoString(_ date: Date) -> String {
        NightSweep.isoString(date)
    }
}
