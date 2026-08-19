import AstroCore
import Foundation

/// Resolves the sky-geometry inputs `NightRibbonBuilder` needs -- site
/// coordinates for the twilight/Moon bands, target coordinates for the
/// target-visibility band -- and hands them, together with the SAME
/// `SessionTimeline` `NightReportQuery.Result.timeline` already carries, to
/// that pure builder. Capture/gap spans come from that already-loaded
/// timeline (`NightRibbonBuilder`'s own doc comment); the only work this
/// type does that `NightReportQuery` didn't already do is the sky-geometry
/// resolution itself, which nothing else in the app surfaces as a time
/// window today (`NightReport.computeSkySections`'s own `AltitudeTrack`/
/// `MoonGeometry` are aggregate statistics, not windows).
///
/// `resolveTargetCoordinates` below deliberately mirrors
/// `NightReport.computeSkySections`'s own median-coordinate resolution
/// (same `db.allFiles` → `FrameSet.lightBuckets` → `TargetCoordinates.
/// medianCoordinates` shape) rather than sharing it -- the same "each query
/// type owns its own tiny resolver instead of a cross-cutting dependency"
/// precedent `NightReportQuery.resolvedTarget`'s own doc comment documents
/// against `ExportService`'s identical duplicate.
public struct NightRibbonQuery: Sendable {
    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    /// Opens the production index DB/config for `rootURL` -- same
    /// `.production(rootURL:)` shape `NightReportQuery`/`ExportService`/
    /// `CalibrationQuery`/`FrameQualityQuery` already follow.
    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config)
    }

    /// `timeline` is the caller's already-loaded `NightReportQuery.Result.
    /// timeline` for this exact `target`/`date` -- passing a mismatched one
    /// would silently mislabel the capture/gap bands, so callers must fetch
    /// it from the same report load this ribbon accompanies.
    public func run(target: String, date: String, timeline: SessionTimeline) throws -> NightRibbonModel {
        let sky = try resolveSkyWindows(target: target, date: date)
        return try NightRibbonBuilder.build(timeline: timeline, sky: sky)
    }

    private func resolveSkyWindows(target: String, date: String) throws -> NightRibbonBuilder.SkyWindows {
        let site = try Planner.resolveSite(db: db, config: config)
        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg,
              let nightOf = Self.nightOfDate(date, config: config)
        else {
            return NightRibbonBuilder.SkyWindows()
        }

        let timeZone = TimeZone.current
        let dual = SunMoon.dualTwilight(nightOf: nightOf, latDeg: lat, lonDeg: lon, timeZone: timeZone)
        let twilight: DateInterval? = {
            guard let dusk = dual.astroDuskUTC, let dawn = dual.astroDawnUTC, dawn > dusk else { return nil }
            return DateInterval(start: dusk, end: dawn)
        }()

        let moonTrack = SkyTrack.moonAltitudeTrack(nightOf: nightOf, latDeg: lat, lonDeg: lon)
        let moonUp = Self.aboveHorizonWindow(moonTrack)

        var targetVisible: DateInterval?
        if let coord = try resolveTargetCoordinates(target: target, date: date) {
            let targetTrack = SkyTrack.altitudeTrack(
                raDeg: coord.raDeg, decDeg: coord.decDeg, nightOf: nightOf, latDeg: lat, lonDeg: lon
            )
            targetVisible = Self.aboveHorizonWindow(targetTrack)
        }

        return NightRibbonBuilder.SkyWindows(
            astronomicalTwilight: twilight, moonUp: moonUp, targetVisible: targetVisible
        )
    }

    /// Same shape as `NightReport.computeSkySections` -- see this type's
    /// own doc comment for why it's duplicated rather than shared.
    private func resolveTargetCoordinates(target: String, date: String) throws -> (raDeg: Double, decDeg: Double)? {
        let allFiles = try db.allFiles(includeMissing: false)
        let dayLights = allFiles.filter {
            $0.target == target && $0.area == .sessions && $0.sessionDate == date && $0.role == .light
        }
        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }
        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)
        return TargetCoordinates.medianCoordinates(files: buckets.usable, meta: metaByFileID)
    }

    /// The span of a sampled altitude track during which the body sits at
    /// or above the horizon (0 deg) -- `nil` when it never does anywhere in
    /// the sample. A body that rises, sets, then rises again within one
    /// sampling window (rare at this tool's night-window granularity) folds
    /// into a single first-to-last span rather than multiple separate
    /// bands; acceptable at the ribbon's own visual scale, and the same
    /// simplification `NightSweep.sweep`'s own single `visibleStart`/
    /// `visibleEnd` pair makes for a target's altitude-above-threshold
    /// span.
    private static func aboveHorizonWindow(_ points: [SkyTrackPoint]) -> DateInterval? {
        let above = points.filter { $0.altitudeDeg >= 0 }
        guard let first = above.first?.time, let last = above.last?.time, last > first else { return nil }
        return DateInterval(start: first, end: last)
    }

    /// Turns a bare `session_date` folder name into a `Date` safe to pass
    /// as `SunMoon`/`SkyTrack`'s own `nightOf:` -- the same "parse
    /// `YYYY-MM-DD`, offset by 12h so it lands mid-day and never drifts
    /// into the neighboring civil day" trick `astrotool`'s own
    /// `parsePlanDate` (`Sources/astrotool/Commands.swift`) already applies
    /// for the identical reason; duplicated rather than shared because that
    /// helper lives in an executable target `AstroApplication` cannot
    /// depend on. `date` is resolved through `SessionDateParser` first
    /// (`config.intentional`) so a run-suffixed/labeled date-dir (e.g.
    /// `"2026-05-24-2"`) still parses to its own canonical calendar day,
    /// same canonicalization `NightReportQuery.run` performs for its own
    /// sibling-session merge.
    private static func nightOfDate(_ date: String, config: AstroConfig) -> Date? {
        let canonical = SessionDateParser.parse(date, patterns: config.intentional)?.start ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: canonical) else { return nil }
        return parsed.addingTimeInterval(12 * 3600)
    }
}
