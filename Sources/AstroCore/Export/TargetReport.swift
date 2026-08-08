import Foundation

/// The full "everything about one target" self-contained HTML report (R8-2)
/// -- modeled on `NightReport` (same dark theme via `ReportStyle`, inline
/// CSS, no external resources, no `<script>` anywhere, Hungarian), but for
/// one target across EVERY session it has, rather than one night. Pure
/// composition of already-existing queries -- `StatsQueries` (headline
/// numbers), `SessionStatsQueries` (per-session detail), `SessionQuality`
/// (FWHM/background/rank), `ExposureAdvisor` (sub-length + relative-SNR
/// guidance), `StackDiscovery` (R8-1, already-created stacks anywhere in the
/// library), `SessionMatcher`/`CalibHealth` (calibration status/flat
/// discipline), `FieldGeometry` (mosaic panels), `Planner` (tonight's
/// visibility/verdict), and `ProjectStatusQueries` (pipeline phase + to-dos)
/// -- nothing here re-derives a number any of those doesn't already own.
///
/// Every section header renders unconditionally; a section with nothing to
/// show prints an explanatory Hungarian note in its place instead of being
/// omitted, so the page's outline never depends on which data happens to
/// exist for a given target. Read-only against `db`; the only filesystem
/// write anywhere in this type is `write`'s own call into `WriteGuard`
/// (`.astro_tool/reports/target-<sanitized>.html`), and the only OTHER
/// filesystem touch is a read-only `FileManager.fileExists` stat, used to
/// annotate a session row with "van éjszaka-riport" when that night already
/// has its own `NightReport` on disk.
public enum TargetReport {
    // MARK: - Public API

    /// Renders the full report as a single self-contained HTML string.
    /// Throws `AstroError.pathNotFound` if `target` names no
    /// session/stack/processed file at all (i.e. `StatsQueries.target`
    /// itself would return `nil` -- the same target universe `stats`/
    /// `projects` use).
    public static func render(target: String, db: Database, config: AstroConfig) throws -> String {
        guard let stat = try StatsQueries.target(target, db: db, config: config) else {
            throw AstroError.pathNotFound(path: "sessions/\(target)")
        }

        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        let qualitySummaries = try SessionQuality.summaries(target: target, db: db, config: config)
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        let stacks = try StackDiscovery.stacks(target: target, db: db, config: config)
        let projectState = try ProjectStatusQueries.projects(db: db, config: config).first { $0.target == target }
        let panelReport = try FieldGeometry.panels(target: target, db: db, config: config)
        let plan = try Planner.plan(db: db, config: config).first { $0.target == target }
        let calibHealth = try CalibHealth.report(db: db, config: config)
        let targetFlats = calibHealth.flats.filter { $0.target == target }
        let filterRows = FilterGoalQueries.merge(
            breakdown: try FilterBreakdownQueries.breakdown(db: db, config: config, target: target),
            tags: stat.tags
        )

        var sessionCalibrations: [SessionCalibration] = []
        for session in sessions {
            sessionCalibrations.append(try SessionMatcher.match(target: target, date: session.dateRaw, db: db, config: config))
        }

        let coordinateInfo = try resolveCoordinateInfo(target: target, db: db)
        let resolved = TargetNameResolver.resolve(folderName: target)
        let setupDescriptors = Array(Set(sessions.compactMap(\.setupDescriptor))).sorted()

        return renderHTML(
            target: target,
            stat: stat,
            resolved: resolved,
            coordinateInfo: coordinateInfo,
            setupDescriptors: setupDescriptors,
            sessions: sessions,
            qualitySummaries: qualitySummaries,
            advice: advice,
            stacks: stacks,
            sessionCalibrations: sessionCalibrations,
            targetFlats: targetFlats,
            panelReport: panelReport,
            plan: plan,
            projectState: projectState,
            filterRows: filterRows,
            config: config
        )
    }

    /// Renders and writes the report to `.astro_tool/reports/
    /// target-<sanitized-target>.html` via `writeGuard` -- overwrites any
    /// earlier target-report for the same target, same "tool's own state,
    /// may freely be rewritten" convention as every other `.astro_tool/`
    /// write.
    @discardableResult
    public static func write(
        target: String,
        db: Database,
        config: AstroConfig,
        using writeGuard: WriteGuard
    ) throws -> URL {
        let html = try render(target: target, db: db, config: config)
        let sanitizedTarget = Sanitizer.sanitize(target)
        let relativePath = "reports/target-\(sanitizedTarget).html"
        return try writeGuard.writeToolFile(relativePath: relativePath, data: Data(html.utf8))
    }

    // MARK: - Coordinate resolution + source label

    struct CoordinateInfo {
        var raDeg: Double
        var decDeg: Double
        var sourceLabel: String
    }

    /// Median coordinate across the target's usable session lights (header
    /// WCS/RA-DEC or plate-solved fallback, via `TargetCoordinates`), plus a
    /// Hungarian label for WHICH of those sources actually contributed --
    /// `nil` when not a single light resolves a coordinate at all.
    private static func resolveCoordinateInfo(target: String, db: Database) throws -> CoordinateInfo? {
        let allFiles = try db.allFiles(includeMissing: false)
        let targetLights = allFiles.filter { $0.target == target && $0.area == .sessions && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in targetLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        guard let coord = TargetCoordinates.medianCoordinates(files: targetLights, meta: metaByFileID) else {
            return nil
        }

        let metas = targetLights.compactMap { $0.id.flatMap { metaByFileID[$0] } }
        return CoordinateInfo(raDeg: coord.raDeg, decDeg: coord.decDeg, sourceLabel: coordinateSourceLabel(metas: metas))
    }

    /// Prefers a plate-solved WCS header (`CRVAL1`/`CRVAL2`) over a plain
    /// header `RA`/`DEC` card over the `PlateSolver`-persisted
    /// `solved_ra`/`solved_dec` fallback -- same priority order
    /// `TargetCoordinates.coordinates` itself uses, just surfaced as a label
    /// rather than folded silently into the number.
    private static func coordinateSourceLabel(metas: [FITSMetaRecord]) -> String {
        var hasWCS = false
        var hasRADEC = false
        var hasSolved = false
        for meta in metas {
            if let header = parseHeader(meta.headerJSON) {
                if header.double("CRVAL1") != nil, header.double("CRVAL2") != nil {
                    hasWCS = true
                } else if header.double("RA") != nil || header.string("RA") != nil {
                    hasRADEC = true
                }
            }
            if meta.solvedRA != nil, meta.solvedDec != nil { hasSolved = true }
        }
        if hasWCS { return "fejléc (WCS)" }
        if hasRADEC { return "fejléc (RA/DEC)" }
        if hasSolved { return "plate-solve (Siril)" }
        return "n/a"
    }

    private static func parseHeader(_ headerJSON: String?) -> FITSHeader? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return FITSHeader(rawValues: cards)
    }

    // MARK: - HTML rendering

    private static func renderHTML(
        target: String,
        stat: TargetStats,
        resolved: ResolvedTargetName,
        coordinateInfo: CoordinateInfo?,
        setupDescriptors: [String],
        sessions: [SessionDetail],
        qualitySummaries: [SessionQualitySummary],
        advice: ExposureAdvice,
        stacks: [StackFile],
        sessionCalibrations: [SessionCalibration],
        targetFlats: [FlatDiscipline],
        panelReport: PanelReport,
        plan: TargetPlan?,
        projectState: ProjectState?,
        filterRows: [FilterIntegration],
        config: AstroConfig
    ) -> String {
        var body = ""
        body += renderHeader(target: target, stat: stat, resolved: resolved, coordinateInfo: coordinateInfo, setupDescriptors: setupDescriptors)
        body += renderOverview(stat: stat, sessions: sessions, projectState: projectState)
        body += renderFilters(filterRows)
        body += renderSessionsTable(target: target, sessions: sessions, config: config)
        body += renderQuality(qualitySummaries: qualitySummaries, advice: advice)
        body += renderStacks(stacks: stacks)
        body += renderCalibration(sessionCalibrations: sessionCalibrations, targetFlats: targetFlats)
        body += renderPanels(panelReport: panelReport)
        body += renderPlanning(plan: plan, projectState: projectState, advice: advice)
        body += renderNotes(sessions: sessions)
        body += renderFooter()

        return """
        <!doctype html>
        <html lang="hu">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Célpont-riport — \(escapeHTML(stat.displayName))</title>
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

    // MARK: - Fejléc

    private static func renderHeader(
        target: String,
        stat: TargetStats,
        resolved: ResolvedTargetName,
        coordinateInfo: CoordinateInfo?,
        setupDescriptors: [String]
    ) -> String {
        var html = "<h1>\(escapeHTML(stat.displayName))</h1>\n"

        var subParts = ["<code>\(escapeHTML(target))</code>"]
        if let designation = resolved.designation, designation != stat.displayName {
            subParts.append(escapeHTML(designation))
        }
        html += "<p class=\"sub\">" + subParts.joined(separator: " · ") + "</p>\n"

        if let coordinateInfo {
            html += "<div class=\"grid\">\n"
            html += statBox("RA", raHMS(coordinateInfo.raDeg))
            html += statBox("Dec", decDMS(coordinateInfo.decDeg))
            html += statBox("Koordináta forrása", coordinateInfo.sourceLabel)
            html += "</div>\n"
        } else {
            html += "<p class=\"muted\">n/a — nincs plate-solve/fejléc koordináta ehhez a célponthoz.</p>\n"
        }

        if !setupDescriptors.isEmpty {
            html += "<p><strong>Setup:</strong> \(escapeHTML(setupDescriptors.joined(separator: "; ")))</p>\n"
        }

        var badges = ""
        if stat.isWideField {
            badges += "<span class=\"badge good\">Wide-field</span>"
        }
        for tag in stat.tags {
            let isGoal = tag.lowercased().hasPrefix("goal:")
            badges += "<span class=\"badge \(isGoal ? "warn" : "good")\">\(escapeHTML(tag))</span>"
        }
        if !badges.isEmpty {
            html += "<p>\(badges)</p>\n"
        }

        return html
    }

    // MARK: - Összkép

    private static func renderOverview(stat: TargetStats, sessions: [SessionDetail], projectState: ProjectState?) -> String {
        var html = "<h2>Összkép</h2>\n<div class=\"grid\">\n"
        html += statBox("Használható integráció", formatHM(stat.usableIntegrationSeconds), big: true)
        html += statBox("Bruttó integráció", formatHM(stat.grossIntegrationSeconds))
        html += statBox("Használható keretek", "\(stat.usableFrameCount)")
        if stat.rejectedFrameCount > 0 {
            html += statBox("Elvetett keretek", "\(stat.rejectedFrameCount)")
        }
        if stat.duplicateLinkCount > 0 {
            html += statBox("Duplikált/link keretek", "\(stat.duplicateLinkCount)")
        }
        if stat.nonFrameFileCount > 0 {
            html += statBox("Nem keret fájlok", "\(stat.nonFrameFileCount)")
        }
        html += statBox("Sessionök száma", "\(sessions.count)")
        if let first = stat.sessionDates.first, let last = stat.sessionDates.last {
            html += statBox("Első–utolsó session", first == last ? first : "\(first) – \(last)")
        }
        html += "</div>\n"

        if let projectState {
            html += "<p><span class=\"badge \(phaseBadgeClass(projectState.phase))\">\(escapeHTML(phaseLabel(projectState.phase)))</span></p>\n"
            if projectState.todos.isEmpty {
                html += "<p class=\"muted\">Nincs teendő.</p>\n"
            } else {
                html += "<ul class=\"notice\">\n"
                for todo in projectState.todos {
                    html += "<li>\(escapeHTML(todo))</li>\n"
                }
                html += "</ul>\n"
            }
        } else {
            html += "<p class=\"muted\">n/a — nincs projekt-státusz adat ehhez a célponthoz.</p>\n"
        }
        return html
    }

    private static func phaseLabel(_ phase: ProjectPhase) -> String {
        switch phase {
        case .collecting: return "Gyűjtés"
        case .readyToStack: return "Stackelhető"
        case .stacked: return "Feldolgozásra vár"
        case .done: return "Kész"
        }
    }

    private static func phaseBadgeClass(_ phase: ProjectPhase) -> String {
        phase == .done ? "good" : "warn"
    }

    // MARK: - Szűrők

    private static func renderFilters(_ rows: [FilterIntegration]) -> String {
        var html = "<h2>Szűrők</h2>\n"
        guard !rows.isEmpty else {
            return html + "<p class=\"muted\">Nincs használható szűrőadat ehhez a célponthoz.</p>\n"
        }
        html += "<div class=\"table-wrap\">\n<table>\n"
        html += "<tr><th>Szűrő</th><th>Keretek</th><th>Megvan</th><th>Cél</th><th>Hiányzik</th></tr>\n"
        for row in rows.sorted(by: {
            $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending
        }) {
            html += "<tr><td>\(escapeHTML(row.filter))</td>"
            html += "<td>\(row.usableFrameCount)</td>"
            html += "<td>\(formatHM(row.integrationSeconds))</td>"
            html += "<td>\(row.goalSeconds.map(formatHM) ?? "n/a")</td>"
            html += "<td>\(row.missingSeconds.map(formatHM) ?? "n/a")</td></tr>\n"
        }
        html += "</table>\n</div>\n"
        return html
    }

    // MARK: - Sessionök táblázat

    private static func renderSessionsTable(target: String, sessions: [SessionDetail], config: AstroConfig) -> String {
        var html = "<h2>Sessionök</h2>\n"
        guard !sessions.isEmpty else {
            html += "<p class=\"muted\">Nincs rögzített session ehhez a célponthoz.</p>\n"
            return html
        }

        let sanitizedTarget = Sanitizer.sanitize(target)
        let reportsDir = URL(fileURLWithPath: config.rootPath, isDirectory: true)
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)

        html += "<div class=\"table-wrap\">\n<table>\n"
        html += "<tr><th>Dátum</th><th>Keretek</th><th>Integráció</th><th>Expozíciók</th><th>Kamera</th>"
            + "<th>Gyújtótáv</th><th>Gain</th><th>Hőm.</th><th>Szűrő</th><th>Jelzők</th></tr>\n"

        for session in sessions.sorted(by: { $0.dateRaw < $1.dateRaw }) {
            var flags: [String] = []
            if session.hasReadme { flags.append("README") }
            if let accepted = session.dssAcceptedCount, let rejected = session.dssRejectedCount {
                flags.append("DSS \(accepted)✓/\(rejected)✗")
            }
            if session.isExcludedFromTotals { flags.append("KIZÁRVA") }
            let reportURL = reportsDir.appendingPathComponent("\(sanitizedTarget)-\(session.dateRaw).html")
            if FileManager.default.fileExists(atPath: reportURL.path) {
                flags.append("van éjszaka-riport")
            }

            html += "<tr\(session.isExcludedFromTotals ? " class=\"highlight\"" : "")>"
            html += "<td>\(escapeHTML(session.dateRaw))</td>"
            html += "<td>\(session.usableLightCount)</td>"
            html += "<td>\(formatHM(session.integrationSeconds))</td>"
            html += "<td>\(escapeHTML(formatExposureBreakdown(session.exposureBreakdown)))</td>"
            html += "<td>\(escapeHTML(session.cameras.joined(separator: "/")))</td>"
            html += "<td>\(escapeHTML(formatDoubleList(session.focalLengthsMM, suffix: "mm")))</td>"
            html += "<td>\(escapeHTML(formatDoubleList(session.gains, suffix: "")))</td>"
            html += "<td>\(escapeHTML(formatDoubleList(session.sensorTempsC, suffix: "°C")))</td>"
            html += "<td>\(escapeHTML(session.filters.joined(separator: "/")))</td>"
            html += "<td>\(escapeHTML(flags.joined(separator: ", ")))</td>"
            html += "</tr>\n"
        }
        html += "</table>\n</div>\n"
        return html
    }

    // MARK: - Minőség

    private static func renderQuality(qualitySummaries: [SessionQualitySummary], advice: ExposureAdvice) -> String {
        var html = "<h2>Minőség</h2>\n"
        let rated = qualitySummaries.filter { $0.frameCount > 0 }

        if rated.isEmpty {
            html += "<p class=\"muted\">Nincs pontozott keret ehhez a célponthoz.</p>\n"
        } else {
            html += "<div class=\"table-wrap\">\n<table>\n"
            html += "<tr><th>Dátum</th><th>FWHM</th><th>Háttér</th><th>Csillagok</th><th>Kiugró</th><th>Rang</th></tr>\n"
            for summary in qualitySummaries.sorted(by: { $0.date < $1.date }) {
                let isBest = summary.rankAmongSessions == 1
                html += "<tr\(isBest ? " class=\"highlight\"" : "")>"
                html += "<td>\(escapeHTML(summary.date))</td>"
                if let arcsec = summary.medianFWHMArcsec {
                    html += "<td>\(String(format: "%.2f\"", arcsec))</td>"
                } else if let px = summary.medianFWHMPixels {
                    html += "<td>\(String(format: "%.2f px", px))</td>"
                } else {
                    html += "<td class=\"muted\">n/a</td>"
                }
                if let background = summary.backgroundEPerSecPerArcsec2 {
                    html += "<td>\(String(format: "%.4f e⁻/s/arcsec²", background))</td>"
                } else {
                    html += "<td class=\"muted\">n/a</td>"
                }
                html += "<td>\(summary.medianStarCount.map { "\($0)" } ?? "–")</td>"
                html += "<td>\(summary.outlierFraction.map { formatPercent($0 * 100) } ?? "–")</td>"
                if let rank = summary.rankAmongSessions, let total = summary.sessionCountForTarget {
                    html += "<td>\(rank) / \(total)\(isBest ? " ★ legjobb" : "")</td>"
                } else {
                    html += "<td>–</td>"
                }
                html += "</tr>\n"
            }
            html += "</table>\n</div>\n"
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

    // MARK: - Stackek (R8-1)

    private static func renderStacks(stacks: [StackFile]) -> String {
        var html = "<h2>Stackek</h2>\n"
        guard !stacks.isEmpty else {
            html += "<p class=\"muted\">Nincs felderített stack-fájl ehhez a célponthoz.</p>\n"
            return html
        }

        let bestPath = stacks
            .filter { $0.totalSecondsFromName != nil }
            .max(by: { ($0.totalSecondsFromName ?? 0) < ($1.totalSecondsFromName ?? 0) })?.path

        html += "<div class=\"table-wrap\">\n<table>\n"
        html += "<tr><th>Fájl</th><th>Hely</th><th>Keretek×sub</th><th>Összidő</th><th>Méret</th><th>Dátum</th><th>Fajta</th></tr>\n"
        for stackFile in stacks {
            let isBest = bestPath != nil && stackFile.path == bestPath
            html += "<tr\(isBest ? " class=\"highlight\"" : "")>"
            html += "<td><code>\(escapeHTML((stackFile.path as NSString).lastPathComponent))</code></td>"
            html += "<td>\(escapeHTML((stackFile.path as NSString).deletingLastPathComponent))</td>"
            if let frames = stackFile.framesFromName, let sub = stackFile.subSecondsFromName {
                html += "<td>\(frames)×\(formatSeconds(sub))</td>"
            } else {
                html += "<td class=\"muted\">n/a</td>"
            }
            html += "<td>\(stackFile.totalSecondsFromName.map { formatHM($0) } ?? "–")</td>"
            html += "<td>\(formatBytes(stackFile.sizeBytes))</td>"
            html += "<td>\(escapeHTML(stackFile.sessionDate ?? "–"))</td>"
            html += "<td>\(escapeHTML(stackFile.kind))\(isBest ? " ★ legjobb" : "")</td>"
            html += "</tr>\n"
        }
        html += "</table>\n</div>\n"
        return html
    }

    // MARK: - Kalibráció

    private static func renderCalibration(sessionCalibrations: [SessionCalibration], targetFlats: [FlatDiscipline]) -> String {
        var html = "<h2>Kalibráció</h2>\n"

        if sessionCalibrations.isEmpty {
            html += "<p class=\"muted\">Nincs session ehhez a célponthoz.</p>\n"
        } else {
            html += "<div class=\"table-wrap\">\n<table>\n"
            html += "<tr><th>Dátum</th><th>Flat</th><th>Dark</th><th>Bias</th><th>Problémák</th></tr>\n"
            for calib in sessionCalibrations.sorted(by: { $0.date < $1.date }) {
                html += "<tr>"
                html += "<td>\(escapeHTML(calib.date))</td>"
                html += "<td>\(calib.flats.count)</td>"
                if calib.darks.isEmpty, let libraryDark = calib.libraryDark {
                    html += "<td>library: \(escapeHTML((libraryDark as NSString).lastPathComponent))</td>"
                } else if calib.darks.isEmpty, !calib.libraryDarkMismatchReasons.isEmpty {
                    html += "<td class=\"muted\">nincs (library eltér: \(escapeHTML(calib.libraryDarkMismatchReasons.joined(separator: ", ")))</td>"
                } else {
                    html += "<td>\(calib.darks.count)</td>"
                }
                html += "<td>\(calib.biases.count)</td>"
                if calib.problems.isEmpty {
                    html += "<td class=\"muted\">–</td>"
                } else {
                    html += "<td>\(escapeHTML(calib.problems.map(\.message).joined(separator: "; ")))</td>"
                }
                html += "</tr>\n"
            }
            html += "</table>\n</div>\n"
        }

        if targetFlats.isEmpty {
            html += "<p class=\"muted\">Nincs flat-higiénia adat ehhez a célponthoz.</p>\n"
        } else {
            html += "<p><strong>Flat-higiénia:</strong></p>\n<div class=\"table-wrap\">\n<table>\n"
            html += "<tr><th>Dátum</th><th>Státusz</th><th>Megjegyzés</th></tr>\n"
            for flat in targetFlats.sorted(by: { $0.date < $1.date }) {
                let badgeClass = flat.status == "rendben" ? "good" : "warn"
                html += "<tr><td>\(escapeHTML(flat.date))</td>"
                html += "<td><span class=\"badge \(badgeClass)\">\(escapeHTML(flat.status))</span></td>"
                html += "<td>\(escapeHTML(flat.reasons.joined(separator: "; ")))</td></tr>\n"
            }
            html += "</table>\n</div>\n"
        }
        return html
    }

    // MARK: - Panelek (mozaik)

    private static func renderPanels(panelReport: PanelReport) -> String {
        var html = "<h2>Panelek</h2>\n"
        guard panelReport.isMosaic else {
            if panelReport.panels.isEmpty {
                html += "<p class=\"muted\">Nincs plate-solve adat a panel-elemzéshez.</p>\n"
            } else {
                html += "<p class=\"muted\">Nem mozaik célpont — egyetlen mező.</p>\n"
            }
            return html
        }

        html += "<div class=\"table-wrap\">\n<table>\n"
        html += "<tr><th>Panel</th><th>Közép (RA/Dec)</th><th>Keretek</th><th>Integráció</th><th>Rotáció</th><th>Skála</th></tr>\n"
        for panel in panelReport.panels {
            html += "<tr>"
            html += "<td>\(escapeHTML(panel.label))</td>"
            html += "<td>\(raHMS(panel.centerRaDeg)) / \(decDMS(panel.centerDecDeg))</td>"
            html += "<td>\(panel.frameCount)</td>"
            html += "<td>\(formatHM(panel.integrationSeconds))</td>"
            html += "<td>\(panel.rotationDeg.map { String(format: "%.1f°", $0) } ?? "–")</td>"
            html += "<td>\(panel.pixelScaleArcsec.map { String(format: "%.2f\"/px", $0) } ?? "–")</td>"
            html += "</tr>\n"
        }
        html += "</table>\n</div>\n"

        if panelReport.isUnbalanced {
            html += "<p class=\"muted\">Kiegyenlítetlen integráció a panelek között.</p>\n"
        }
        return html
    }

    // MARK: - Tervezés

    private static func renderPlanning(plan: TargetPlan?, projectState: ProjectState?, advice: ExposureAdvice) -> String {
        var html = "<h2>Tervezés</h2>\n"

        if let plan {
            html += "<div class=\"grid\">\n"
            html += statBox("Verdikt", plan.verdict)
            if let window = plan.visibleWindowLocal {
                html += statBox("Látható ablak", window)
            }
            if let maxAlt = plan.maxAltitudeDeg {
                html += statBox("Max. magasság", String(format: "%.0f°", maxAlt))
            }
            if let culmination = plan.culminationLocal {
                html += statBox("Kulmináció", culmination)
            }
            if let illum = plan.moonIlluminationPercent {
                html += statBox("Hold megvilágítás", formatPercent(illum))
            }
            if let sep = plan.moonSeparationDeg {
                html += statBox("Hold-szeparáció", String(format: "%.0f°", sep))
            }
            html += "</div>\n"
        } else {
            html += "<p class=\"muted\">n/a — nincs terv-adat ehhez a célponthoz.</p>\n"
        }

        if let goalSeconds = projectState?.goalSeconds {
            html += "<p>Cél: \(escapeHTML(formatHM(goalSeconds)))"
            if let missing = projectState?.missingSeconds, missing > 0 {
                html += " — még hiányzik \(escapeHTML(formatHM(missing)))"
            } else {
                html += " — elérve"
            }
            html += "</p>\n"
        } else {
            html += "<p class=\"muted\">Nincs kitűzött cél (goal tag).</p>\n"
        }

        if advice.notAvailableReason == nil {
            var line = "+10% relatív SNR-hez még \(String(format: "%.2f", advice.snrPlus10PercentHours)) óra szükséges"
            if let multiplier = advice.snrPlus3hMultiplier {
                line += " (+3 h → relatív SNR ×\(String(format: "%.2f", multiplier)))"
            }
            html += "<p class=\"muted\">\(escapeHTML(line)).</p>\n"
        }

        return html
    }

    // MARK: - Jegyzetek

    private static func renderNotes(sessions: [SessionDetail]) -> String {
        var html = "<h2>Jegyzetek</h2>\n"
        let withNotes = sessions.filter { !$0.notes.isEmpty }
        guard !withNotes.isEmpty else {
            html += "<p class=\"muted\">Nincs README-jegyzet ehhez a célponthoz.</p>\n"
            return html
        }

        for session in withNotes.sorted(by: { $0.dateRaw < $1.dateRaw }) {
            html += "<p><strong>\(escapeHTML(session.dateRaw))</strong></p>\n<table>\n"
            for key in session.notes.keys.sorted() {
                html += "<tr><td>\(escapeHTML(key))</td><td>\(escapeHTML(session.notes[key] ?? ""))</td></tr>\n"
            }
            html += "</table>\n"
        }
        return html
    }

    // MARK: - Lábléc

    private static func renderFooter() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let generated = formatter.string(from: Date())
        return "<footer class=\"report-footer\">Generálva: \(escapeHTML(generated)) · astrotool 0.1.0</footer>\n"
    }

    // MARK: - Small shared helpers

    private static func statBox(_ label: String, _ value: String, big: Bool = false) -> String {
        "<div class=\"stat\(big ? " big" : "")\"><div class=\"label\">\(escapeHTML(label))</div><div class=\"value\">\(escapeHTML(value))</div></div>\n"
    }

    private static func formatHM(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded() { return "\(Int(seconds))s" }
        return String(format: "%.1fs", seconds)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.0f MB", mb)
    }

    private static func formatDoubleList(_ values: [Double], suffix: String) -> String {
        guard !values.isEmpty else { return "–" }
        return values.map { formattedNumber($0) + suffix }.joined(separator: "/")
    }

    private static func formattedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// `"12×300s, 3×600s"` -- sorted by frame count descending (ties broken
    /// by the key text) so the dominant exposure length always leads. The
    /// `"unknown"` bucket (no `exptime` at all) prints as `"N×?"`.
    private static func formatExposureBreakdown(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "–" }
        let parts = breakdown.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map { key, count -> String in
            if key == "unknown" { return "\(count)×?" }
            let seconds = Double(key) ?? 0
            return "\(count)×\(formattedNumber(seconds))s"
        }
        return parts.joined(separator: ", ")
    }

    /// `"05h 34m 32.0s"` -- right ascension in hours/minutes/seconds,
    /// normalized to `[0, 360)` degrees before the /15 hour conversion.
    private static func raHMS(_ deg: Double) -> String {
        var normalized = deg.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let hours = normalized / 15.0
        let h = Int(hours)
        let minutesFull = (hours - Double(h)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return String(format: "%02dh %02dm %04.1fs", h, m, s)
    }

    /// `"+22° 00' 52.0\""` -- declination in signed degrees/arcmin/arcsec.
    private static func decDMS(_ deg: Double) -> String {
        let sign = deg < 0 ? "-" : "+"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let minutesFull = (absDeg - Double(d)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return "\(sign)\(String(format: "%02d° %02d' %04.1f\"", d, m, s))"
    }

    /// Minimal HTML-entity escaping for user/library-derived text landing
    /// inside this self-contained page -- never trust that a target/tag/
    /// note/README value is free of `<`/`&`.
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
