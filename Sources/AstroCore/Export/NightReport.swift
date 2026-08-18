import Foundation

/// One night's self-contained HTML report card for a target's session
/// (R7-B5, `astrotool report`): pure composition of already-existing
/// queries -- `SessionStatsQueries` (frames/exposures/camera/README notes),
/// `SessionTimeline` (window/gaps/duty cycle), `SessionQuality` (FWHM/
/// background/rank), `NightHealth` (cooler/focus verdicts), `SessionMatcher`
/// (calibration status), `ExposureAdvisor` (sub-length advice when
/// available), and `ProjectStatusQueries` (this target's to-do list) -- plus
/// two computations nothing else in the tool surfaces yet:
///
/// - **Altitude/airmass track**: for every USABLE light's `DATE-OBS`, the
///   target's altitude at that instant (`AltAz` + `SiderealTime`, site from
///   `config.site`/median FITS headers via `Planner.resolveSite`, target
///   coordinates via `TargetCoordinates` including the plate-solved
///   fallback) -- min/median/max altitude, and the fraction of frames shot
///   below 30 degrees.
/// - **Achieved Moon geometry**: the Moon's illumination at the session
///   window's midpoint, the median target-Moon separation across the same
///   usable lights, and the Moon's own max altitude at the window's
///   start/mid/end.
///
/// Both are nil-safe: without a resolvable target coordinate AND site, the
/// "Magasság & Hold" section still renders, but with an explanatory note in
/// place of numbers, rather than guessing or crashing.
///
/// Read-only against `db`; the only filesystem write anywhere in this type
/// is `write`'s own call into `WriteGuard`.
public enum NightReport {
    // MARK: - Public API

    /// Renders the full report as a single self-contained HTML string --
    /// inline CSS, no external resources, no `<script>` anywhere. Throws
    /// `AstroError.pathNotFound` if `target`/`date` names no session on
    /// record at all.
    public static func render(target: String, date: String, db: Database, config: AstroConfig) throws -> String {
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        guard let session = sessions.first(where: { $0.dateRaw == date }) else {
            throw AstroError.pathNotFound(path: "sessions/\(target)/\(date)")
        }

        let timeline = try SessionTimeline.timeline(target: target, date: date, db: db, config: config)
        let quality = try SessionQuality.summaries(target: target, db: db, config: config).first { $0.date == date }
        let health = try NightHealth.report(target: target, date: date, db: db, config: config)
        let calib = try SessionMatcher.match(target: target, date: date, db: db, config: config)
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        let projectState = try ProjectStatusQueries.projects(db: db, config: config).first { $0.target == target }
        let projectTodos = projectState?.todos ?? []
        let displayName = projectState?.displayName ?? target.replacingOccurrences(of: "_", with: " ")
        let sky = try computeSkySections(target: target, date: date, timeline: timeline, db: db, config: config)
        let filterRows = try FilterBreakdownQueries.breakdown(
            db: db, config: config, target: target, date: date
        )

        return renderHTML(
            target: target,
            displayName: displayName,
            date: date,
            session: session,
            timeline: timeline,
            quality: quality,
            health: health,
            calib: calib,
            advice: advice,
            projectTodos: projectTodos,
            filterRows: filterRows,
            altitude: sky.altitude,
            moon: sky.moon
        )
    }

    /// Renders and writes the report to `.astro_tool/reports/
    /// <sanitized-target>-<date>.html` via `writeGuard` -- overwrites any
    /// earlier report for the same target/date, same "tool's own state, may
    /// freely be rewritten" convention as every other `.astro_tool/` write.
    /// `timestamp` is accepted for signature symmetry with
    /// `AcquisitionExport.write` but never used: this file's own name is
    /// deterministic (`target`/`date`, no timestamp component), so `write`'s
    /// output always equals `render`'s for the same inputs.
    @discardableResult
    public static func write(
        target: String,
        date: String,
        timestamp: Date,
        db: Database,
        config: AstroConfig,
        using writeGuard: WriteGuard
    ) throws -> URL {
        _ = timestamp
        let html = try render(target: target, date: date, db: db, config: config)
        let sanitizedTarget = Sanitizer.sanitize(target)
        let relativePath = "reports/\(sanitizedTarget)-\(date).html"
        return try writeGuard.writeToolFile(relativePath: relativePath, data: Data(html.utf8))
    }

    // MARK: - Sky sections (altitude track + achieved Moon geometry)

    /// Public since `NightReportQuery` (`AstroApplication`) assembles the
    /// exact same "Magasság & Hold" facts for the in-app night workspace --
    /// see `computeSkySections`'s own doc comment for why this stays the
    /// ONE place that computation lives rather than a second copy across
    /// the module boundary.
    public struct AltitudeTrack: Sendable, Equatable {
        public var minAltitudeDeg: Double
        public var medianAltitudeDeg: Double
        public var maxAltitudeDeg: Double
        public var belowThresholdPercent: Double
        public var frameCount: Int

        public init(minAltitudeDeg: Double, medianAltitudeDeg: Double, maxAltitudeDeg: Double, belowThresholdPercent: Double, frameCount: Int) {
            self.minAltitudeDeg = minAltitudeDeg
            self.medianAltitudeDeg = medianAltitudeDeg
            self.maxAltitudeDeg = maxAltitudeDeg
            self.belowThresholdPercent = belowThresholdPercent
            self.frameCount = frameCount
        }
    }

    public struct MoonGeometry: Sendable, Equatable {
        public var illuminationPercent: Double
        public var medianSeparationDeg: Double
        public var maxAltitudeDeg: Double

        public init(illuminationPercent: Double, medianSeparationDeg: Double, maxAltitudeDeg: Double) {
            self.illuminationPercent = illuminationPercent
            self.medianSeparationDeg = medianSeparationDeg
            self.maxAltitudeDeg = maxAltitudeDeg
        }
    }

    /// Public for the same reason `AltitudeTrack`/`MoonGeometry` are --
    /// `NightReportQuery.run` calls `computeSkySections` directly rather
    /// than re-deriving altitude/airmass or Moon geometry itself.
    public struct SkySections: Sendable, Equatable {
        public var altitude: AltitudeTrack?
        public var moon: MoonGeometry?
    }

    /// The altitude threshold "Magasság & Hold" reports the below-fraction
    /// against -- a fixed 30 degrees per the R7-B5 spec, independent of
    /// `Planner`'s own (configurable) `minAltitudeDeg`, since this section
    /// describes what actually happened, not a planning threshold.
    private static let altitudeThresholdDeg = 30.0

    /// Builds both sky sections from one pass over the session's usable
    /// lights' `DATE-OBS` -- `nil`/`nil` when there's no resolvable target
    /// coordinate, no resolvable site, or no usable light has a parseable
    /// `DATE-OBS` at all.
    public static func computeSkySections(
        target: String,
        date: String,
        timeline: SessionTimeline,
        db: Database,
        config: AstroConfig
    ) throws -> SkySections {
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

        guard let coord = TargetCoordinates.medianCoordinates(files: buckets.usable, meta: metaByFileID) else {
            return SkySections(altitude: nil, moon: nil)
        }
        let site = try Planner.resolveSite(db: db, config: config)
        guard let lat = site.latitudeDeg, let lon = site.longitudeDeg else {
            return SkySections(altitude: nil, moon: nil)
        }

        var instants: [Date] = []
        for file in buckets.usable {
            guard let id = file.id, let raw = metaByFileID[id]?.dateObs,
                  let instant = SessionTimeline.parseDateObs(raw)
            else { continue }
            instants.append(instant)
        }
        guard !instants.isEmpty else { return SkySections(altitude: nil, moon: nil) }

        var altitudes: [Double] = []
        var separations: [Double] = []
        for instant in instants {
            let jd = JulianDate.julianDay(instant)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lon)
            let position = AltAz.position(raDeg: coord.raDeg, decDeg: coord.decDeg, lstHours: lst, latDeg: lat)
            altitudes.append(position.altitudeDeg)

            let moonPos = SunMoon.moonPosition(julianDay: jd)
            separations.append(
                SunMoon.angularSeparationDeg(ra1: coord.raDeg, dec1: coord.decDeg, ra2: moonPos.raDeg, dec2: moonPos.decDeg)
            )
        }

        let belowCount = altitudes.filter { $0 < altitudeThresholdDeg }.count
        let track = AltitudeTrack(
            minAltitudeDeg: altitudes.min() ?? 0,
            medianAltitudeDeg: median(altitudes),
            maxAltitudeDeg: altitudes.max() ?? 0,
            belowThresholdPercent: Double(belowCount) / Double(altitudes.count) * 100,
            frameCount: altitudes.count
        )

        var moon: MoonGeometry?
        if let windowStartISO = timeline.windowStart, let windowEndISO = timeline.windowEnd,
           let start = parseISOZ(windowStartISO), let end = parseISOZ(windowEndISO)
        {
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let illum = SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(mid))
            let maxMoonAlt = [start, mid, end].map { instant -> Double in
                let jd = JulianDate.julianDay(instant)
                let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lon)
                let moonPos = SunMoon.moonPosition(julianDay: jd)
                return AltAz.position(raDeg: moonPos.raDeg, decDeg: moonPos.decDeg, lstHours: lst, latDeg: lat).altitudeDeg
            }.max() ?? 0
            moon = MoonGeometry(
                illuminationPercent: illum,
                medianSeparationDeg: median(separations),
                maxAltitudeDeg: maxMoonAlt
            )
        }

        return SkySections(altitude: track, moon: moon)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Parses the exact `"yyyy-MM-dd'T'HH:mm:ss'Z'"` shape
    /// `SessionTimeline.timeline`'s own `windowStart`/`windowEnd` are
    /// formatted in -- a plain round-trip of that one fixed format, not a
    /// general ISO 8601 parser.
    private static func parseISOZ(_ raw: String) -> Date? {
        isoZFormatter.date(from: raw)
    }

    private static let isoZFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    // MARK: - HTML rendering

    private static func renderHTML(
        target: String,
        displayName: String,
        date: String,
        session: SessionDetail,
        timeline: SessionTimeline,
        quality: SessionQualitySummary?,
        health: NightHealthReport,
        calib: SessionCalibration,
        advice: ExposureAdvice,
        projectTodos: [String],
        filterRows: [FilterIntegration],
        altitude: AltitudeTrack?,
        moon: MoonGeometry?
    ) -> String {
        var body = ""
        body += renderHeader(target: target, displayName: displayName, date: date, session: session)
        body += renderSummary(session: session, timeline: timeline)
        body += renderCaptureGroups(session.captureGroups, quality: quality)
        body += renderFilters(filterRows)
        body += renderTimeline(timeline: timeline)
        body += renderQuality(quality: quality, advice: advice)
        body += renderAltitudeAndMoon(altitude: altitude, moon: moon)
        body += renderHardware(health: health)
        body += renderCalibration(calib: calib)
        if let accepted = session.dssAcceptedCount, let rejected = session.dssRejectedCount {
            body += renderDSSVerdicts(accepted: accepted, rejected: rejected)
        }
        if !session.notes.isEmpty {
            body += renderNotes(notes: session.notes)
        }
        body += renderTodos(todos: projectTodos)

        return """
        <!doctype html>
        <html lang="hu">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Éjszaka-riport — \(escapeHTML(displayName)) — \(escapeHTML(date))</title>
        <style>\(ReportStyle.css)</style>
        </head>
        <body>
        <main>
        \(body)
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Capture groups

    private static func renderCaptureGroups(
        _ groups: [CaptureGroupSummary],
        quality: SessionQualitySummary?
    ) -> String {
        guard !groups.isEmpty else { return "" }
        let qualityByID = Dictionary(uniqueKeysWithValues: (quality?.captureGroups ?? []).map { ($0.id, $0) })
        var html = "<h2>Gyűjtések ebben a sessionben</h2>\n"
        for group in groups {
            let modes = (group.sensorModes.map(\.displayNameHU) + group.signalModes.map(\.displayNameHU))
                .joined(separator: " · ")
            let filters = group.filters.isEmpty ? "nincs megadva" : group.filters.joined(separator: ", ")
            let exposure = group.exposureBreakdown.sorted { lhs, rhs in
                (Double(lhs.key) ?? .infinity) < (Double(rhs.key) ?? .infinity)
            }.map { key, count -> String in
                guard key != "unknown", let seconds = Double(key) else { return "ismeretlen × \(count)" }
                let value = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
                return "\(value) s × \(count)"
            }.joined(separator: ", ")
            html += "<div class=\"card\">\n"
            html += "<strong>\(escapeHTML(group.displayName))</strong>"
            if let slug = group.slug { html += " <code>\(escapeHTML(slug))</code>" }
            html += "<p class=\"muted\">\(escapeHTML(modes)) · Filter: \(escapeHTML(filters))</p>\n"
            html += "<p>\(group.usableLightCount) használható light · \(formatHM(group.integrationSeconds))"
            if !exposure.isEmpty { html += " · \(escapeHTML(exposure))" }
            html += "</p>\n"
            html += "<p class=\"muted\">Kalibráció: \(group.flatCount) flat · \(group.darkCount) dark · \(group.biasCount) bias"
            if let q = qualityByID[group.id] {
                if let fwhm = q.medianFWHMArcsec { html += " · FWHM \(String(format: "%.2f\"", fwhm))" }
                else if let fwhm = q.medianFWHMPixels { html += " · FWHM \(String(format: "%.2f px", fwhm))" }
            }
            html += "</p>\n</div>\n"
        }
        return html
    }

    // MARK: - Header

    /// `"Cél: M 42 · Orion-köd (M42_Orion)"` when `displayName` resolved to
    /// something other than the raw folder name, just `"Cél: <target>"`
    /// otherwise (an unresolved/junk folder name, where printing the same
    /// text twice would be noise).
    private static func renderHeader(target: String, displayName: String, date: String, session: SessionDetail) -> String {
        let title = displayName != target ? "Cél: \(displayName) (\(target))" : "Cél: \(target)"
        var lines = [
            "<h1>\(escapeHTML(title))</h1>",
            "<p class=\"sub\">\(escapeHTML(date)) · <code>sessions/\(escapeHTML(target))/\(escapeHTML(date))</code>",
        ]
        if let descriptor = session.setupDescriptor {
            lines[lines.count - 1] += " · \(escapeHTML(descriptor))"
        }
        lines[lines.count - 1] += "</p>"
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Összefoglaló számok

    private static func renderSummary(session: SessionDetail, timeline: SessionTimeline) -> String {
        var stats: [(String, String)] = []
        if let start = timeline.windowStart, let end = timeline.windowEnd {
            stats.append(("Ablak", "\(shortTime(start)) – \(shortTime(end))"))
        }
        stats.append(("Integráció", formatHM(session.integrationSeconds)))
        if let duty = timeline.dutyCycle {
            stats.append(("Hatékonyság", formatPercent(duty * 100)))
        }
        stats.append(("Használható keretek", "\(session.usableLightCount)"))
        if session.rejectedCount > 0 {
            stats.append(("Elvetett keretek", "\(session.rejectedCount)"))
        }
        if session.duplicateLinkCount > 0 {
            stats.append(("Duplikált/link keretek", "\(session.duplicateLinkCount)"))
        }

        var html = "<h2>Összefoglaló számok</h2>\n<div class=\"grid\">\n"
        for (label, value) in stats {
            html += "<div class=\"stat\"><div class=\"label\">\(escapeHTML(label))</div><div class=\"value\">\(escapeHTML(value))</div></div>\n"
        }
        html += "</div>\n"
        return html
    }

    // MARK: - Szűrők

    private static func renderFilters(_ rows: [FilterIntegration]) -> String {
        var html = "<h2>Szűrők</h2>\n"
        guard !rows.isEmpty else {
            return html + "<p class=\"muted\">Nincs szűrőadat ebben a sessionben.</p>\n"
        }
        html += "<div class=\"table-wrap\">\n<table>\n"
        html += "<tr><th>Szűrő</th><th>Keretek</th><th>Integráció</th></tr>\n"
        for row in rows.sorted(by: {
            $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending
        }) {
            html += "<tr><td>\(escapeHTML(row.filter))</td><td>\(row.usableFrameCount)</td>"
            html += "<td>\(formatHM(row.integrationSeconds))</td></tr>\n"
        }
        html += "</table>\n</div>\n"
        return html
    }

    // MARK: - Idővonal

    private static func renderTimeline(timeline: SessionTimeline) -> String {
        var html = "<h2>Idővonal</h2>\n"

        if let bar = renderTimelineBar(timeline) {
            html += bar
        } else {
            html += "<p class=\"muted\">Nincs elég DATE-OBS adat az idővonalhoz.</p>\n"
        }

        if timeline.gaps.isEmpty {
            html += "<p class=\"muted\">Nem volt jelentős szünet.</p>\n"
        } else {
            html += "<ul class=\"notice\">\n"
            for gap in timeline.gaps {
                html += "<li>\(shortTime(gap.start)) → \(shortTime(gap.end)) (\(formatHM(gap.seconds)))</li>\n"
            }
            html += "</ul>\n"
        }
        return html
    }

    /// Pure CSS-bar timeline visualization: alternating "active" (integration)
    /// and "gap" segments, each sized proportionally to `timeline.windowSeconds`
    /// -- plain `<div>`s with inline `width:`, no JS. `nil` when the window
    /// itself can't be resolved (no usable light had a parseable `DATE-OBS`).
    private static func renderTimelineBar(_ timeline: SessionTimeline) -> String? {
        guard let windowStartISO = timeline.windowStart, let windowEndISO = timeline.windowEnd,
              let start = parseISOZ(windowStartISO), let end = parseISOZ(windowEndISO),
              let windowSeconds = timeline.windowSeconds, windowSeconds > 0
        else { return nil }

        var segments: [(widthPercent: Double, isGap: Bool)] = []
        var cursor = start
        for gap in timeline.gaps.sorted(by: { $0.start < $1.start }) {
            guard let gapStart = parseISOZ(gap.start), let gapEnd = parseISOZ(gap.end) else { continue }
            let activeSeconds = gapStart.timeIntervalSince(cursor)
            if activeSeconds > 0 {
                segments.append((activeSeconds / windowSeconds * 100, false))
            }
            segments.append((gap.seconds / windowSeconds * 100, true))
            cursor = gapEnd
        }
        let trailing = end.timeIntervalSince(cursor)
        if trailing > 0 {
            segments.append((trailing / windowSeconds * 100, false))
        }

        let bars = segments.map { segment in
            "<div class=\"\(segment.isGap ? "gap" : "active")\" style=\"width:\(String(format: "%.3f", segment.widthPercent))%\"></div>"
        }.joined()
        return "<div class=\"timeline-bar\">\(bars)</div>\n"
    }

    // MARK: - Minőség

    private static func renderQuality(quality: SessionQualitySummary?, advice: ExposureAdvice) -> String {
        var html = "<h2>Minőség</h2>\n"

        if let quality, quality.frameCount > 0 {
            html += "<div class=\"grid\">\n"
            if let fwhm = quality.medianFWHMArcsec {
                html += stat("FWHM", String(format: "%.2f\"", fwhm))
            } else if let fwhmPx = quality.medianFWHMPixels {
                html += stat("FWHM", String(format: "%.2f px", fwhmPx))
            }
            if let background = quality.backgroundEPerSecPerArcsec2 {
                html += stat("Háttér", String(format: "%.4f e⁻/s/arcsec²", background))
            }
            if let rank = quality.rankAmongSessions, let total = quality.sessionCountForTarget {
                html += stat("Rang", "\(rank) / \(total)")
            }
            if let outlier = quality.outlierFraction {
                html += stat("Kiugrók", formatPercent(outlier * 100))
            }
            html += "</div>\n"
        } else {
            html += "<p class=\"muted\">Nincs pontozott keret ehhez a session-höz.</p>\n"
        }

        if let reason = advice.notAvailableReason {
            html += "<p class=\"muted\">Expozíció-javaslat: n/a — \(escapeHTML(reason))</p>\n"
        } else if !advice.advice.isEmpty {
            html += "<p><strong>Expozíció-javaslat:</strong></p>\n<ul class=\"notice\">\n"
            for line in advice.advice {
                html += "<li>\(escapeHTML(line))</li>\n"
            }
            html += "</ul>\n"
        }

        return html
    }

    // MARK: - Magasság & Hold

    private static func renderAltitudeAndMoon(altitude: AltitudeTrack?, moon: MoonGeometry?) -> String {
        var html = "<h2>Magasság & Hold</h2>\n<div class=\"grid\">\n"

        if let altitude {
            html += stat("Min. magasság", String(format: "%.0f°", altitude.minAltitudeDeg))
            html += stat("Medián magasság", String(format: "%.0f°", altitude.medianAltitudeDeg))
            html += stat("Max. magasság", String(format: "%.0f°", altitude.maxAltitudeDeg))
            html += stat("30° alatt", formatPercent(altitude.belowThresholdPercent))
        }
        if let moon {
            html += stat("Hold megvilágítás", formatPercent(moon.illuminationPercent))
            html += stat("Hold-szeparáció (medián)", String(format: "%.0f°", moon.medianSeparationDeg))
            html += stat("Hold max. magasság", String(format: "%.0f°", moon.maxAltitudeDeg))
        }
        html += "</div>\n"

        if altitude == nil {
            html += "<p class=\"muted\">n/a — nincs koordináta vagy site adat a magasság-számításhoz.</p>\n"
        }
        if moon == nil {
            html += "<p class=\"muted\">n/a — nincs koordináta, site, vagy idővonal-ablak a Hold-geometriához.</p>\n"
        }

        return html
    }

    // MARK: - Hardver

    private static func renderHardware(health: NightHealthReport) -> String {
        var html = "<h2>Hardver</h2>\n<div class=\"grid\">\n"
        html += stat("Hűtő", health.cooler.verdict)
        html += stat("Fókusz", health.focus.verdict)
        html += "</div>\n"
        return html
    }

    // MARK: - Kalibráció

    private static func renderCalibration(calib: SessionCalibration) -> String {
        var html = "<h2>Kalibráció</h2>\n<div class=\"grid\">\n"
        html += stat("Flat", "\(calib.flats.count)")
        if calib.darks.isEmpty, let libraryDark = calib.libraryDark {
            html += stat("Dark", "library: \((libraryDark as NSString).lastPathComponent)")
        } else {
            html += stat("Dark", "\(calib.darks.count)")
        }
        html += stat("Bias", "\(calib.biases.count)")
        html += "</div>\n"

        if !calib.libraryDarkMismatchReasons.isEmpty {
            html += "<p class=\"muted\">Library dark eltérések: \(escapeHTML(calib.libraryDarkMismatchReasons.joined(separator: ", ")))</p>\n"
        }
        if !calib.problems.isEmpty {
            html += "<ul class=\"notice\">\n"
            for problem in calib.problems {
                html += "<li>\(escapeHTML(problem.message))</li>\n"
            }
            html += "</ul>\n"
        }
        return html
    }

    // MARK: - DSS-verdiktek

    private static func renderDSSVerdicts(accepted: Int, rejected: Int) -> String {
        """
        <h2>DSS-verdiktek</h2>
        <div class="grid">
        \(stat("Elfogadva", "\(accepted)"))\(stat("Elvetve", "\(rejected)"))
        </div>

        """
    }

    // MARK: - README-jegyzetek

    private static func renderNotes(notes: [String: String]) -> String {
        var html = "<h2>README-jegyzetek</h2>\n<table>\n"
        for key in notes.keys.sorted() {
            html += "<tr><td>\(escapeHTML(key))</td><td>\(escapeHTML(notes[key] ?? ""))</td></tr>\n"
        }
        html += "</table>\n"
        return html
    }

    // MARK: - Teendők

    private static func renderTodos(todos: [String]) -> String {
        var html = "<h2>Teendők</h2>\n"
        if todos.isEmpty {
            html += "<p class=\"muted\">Nincs teendő.</p>\n"
        } else {
            html += "<ul class=\"notice\">\n"
            for todo in todos {
                html += "<li>\(escapeHTML(todo))</li>\n"
            }
            html += "</ul>\n"
        }
        return html
    }

    // MARK: - Small shared helpers

    private static func stat(_ label: String, _ value: String) -> String {
        "<div class=\"stat\"><div class=\"label\">\(escapeHTML(label))</div><div class=\"value\">\(escapeHTML(value))</div></div>\n"
    }

    private static func formatHM(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// `"HH:mm"` out of `SessionTimeline`'s `"yyyy-MM-ddTHH:mm:ssZ"` ISO
    /// strings -- a plain substring slice, same convention as
    /// `AcquisitionExport.shortTime`.
    private static func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[start..<end])
    }

    /// Minimal HTML-entity escaping for user/library-derived text (target
    /// names, README note values, Finding messages, ...) landing inside this
    /// self-contained page -- never trust that a target/tag/note is free of
    /// `<`/`&`.
    private static func escapeHTML(_ raw: String) -> String {
        var result = raw
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }
}
