import Foundation

/// Which acquisition-export shape `AcquisitionExport.render`/`write`
/// produces -- see each case's renderer for the exact column/section layout.
public enum ExportFormat: String, Codable, Sendable {
    /// AstroBin's "long acquisition" bulk-import CSV: one row per (session,
    /// nominal exposure) group of USABLE lights.
    case astrobin
    /// A richer, generic per-session CSV (target/date/frames/integration/
    /// equipment/quality/tags) -- not tied to any external tool's schema.
    case csv
    /// A human-readable Markdown session log, Hungarian labels.
    case md
}

/// Turns already-scanned library data into a publish-ready acquisition
/// report for one target -- the numbers a user would otherwise hand-collect
/// from `stats --sessions`/`quality`/`timeline` before writing an AstroBin
/// listing or a processing note. Every number comes from the TRUE (deduped,
/// non-rejected) bucket the same way `SessionStatsQueries`/`SessionQuality`/
/// `SessionTimeline` already compute it -- this type adds no new frame
/// semantics, it only re-shapes their output into the three formats above.
/// Pure query over `Database` -- never touches the filesystem except via
/// `write`'s `WriteGuard` call.
public enum AcquisitionExport {
    // MARK: - Public API

    /// Renders `target`'s acquisition report in `format`, as a `String`
    /// ready to hand to a file or stdout. Never touches the filesystem.
    public static func render(target: String, format: ExportFormat, db: Database, config: AstroConfig) throws -> String {
        switch format {
        case .astrobin:
            return try renderAstrobin(target: target, db: db, config: config)
        case .csv:
            return try renderCSV(target: target, db: db, config: config)
        case .md:
            return try renderMarkdown(target: target, db: db, config: config)
        }
    }

    /// Renders and writes the report under `.astro_tool/exports/
    /// <sanitized-target>-<yyyyMMdd-HHmmss>.<csv|md>` via `writeGuard`
    /// (`astrobin`/`csv` both land as `.csv`, `md` as `.md`). `timestamp` is
    /// the stamp source (not the wall clock) so callers/tests stay
    /// deterministic, same convention as `SuggestionScript.write`.
    @discardableResult
    public static func write(
        target: String,
        format: ExportFormat,
        timestamp: Date,
        db: Database,
        config: AstroConfig,
        using writeGuard: WriteGuard
    ) throws -> URL {
        let content = try render(target: target, format: format, db: db, config: config)
        let stamp = filenameDateFormatter.string(from: timestamp)
        let ext = format == .md ? "md" : "csv"
        let sanitizedTarget = Sanitizer.sanitize(target)
        let relativePath = "exports/\(sanitizedTarget)-\(stamp).\(ext)"
        return try writeGuard.writeToolFile(relativePath: relativePath, data: Data(content.utf8))
    }

    // MARK: - astrobin

    private static let astrobinHeader =
        "date,filter,number,duration,binning,gain,sensorCooling,darks,flats,flatDarks,bias,bortle,meanSqm"

    /// One row per (session, nominal exposure) group of the session's USABLE
    /// lights. Excluded (`_hibas`-labeled) sessions are skipped entirely --
    /// their integration is never meant to be published, so listing them
    /// here would misreport what's actually going up on AstroBin. A session
    /// contributes no rows at all if none of its usable lights have a
    /// parseable `exptime` (there's no nominal-exposure group to key a row
    /// on).
    private static func renderAstrobin(target: String, db: Database, config: AstroConfig) throws -> String {
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        let allFiles = try db.allFiles(includeMissing: false)
        let sessionFiles = allFiles.filter { $0.target == target && $0.area == .sessions }

        var lines = [astrobinHeader]

        for session in sessions where !session.isExcludedFromTotals {
            let equipment = try usableFrameEquipment(date: session.dateRaw, sessionFiles: sessionFiles, db: db, config: config)
            guard !equipment.isEmpty else { continue }

            let dateText = SessionDateParser.parse(session.dateRaw, patterns: config.intentional)?.start ?? session.dateRaw
            let filterText = mode(equipment.compactMap(\.filter)) ?? ""
            let gainText = mode(equipment.compactMap(\.gain)).map(formatTrimmed) ?? ""
            let coolingText = median(equipment.compactMap(\.cooling)).map { String(Int($0.rounded())) } ?? ""
            let flatDarks = try flatDarksCount(sessionFiles: sessionFiles, date: session.dateRaw, db: db)

            var countsByExposure: [Double: Int] = [:]
            for e in equipment { countsByExposure[e.nominalExptime, default: 0] += 1 }

            for exposure in countsByExposure.keys.sorted() {
                let row: [String] = [
                    dateText,
                    filterText,
                    String(countsByExposure[exposure] ?? 0),
                    formatTrimmed(exposure),
                    "", // binning -- never captured per light frame, see CalibRule.matchBinning's doc.
                    gainText,
                    coolingText,
                    String(session.darkCount),
                    String(session.flatCount),
                    String(flatDarks),
                    String(session.biasCount),
                    "", // bortle -- future README indexing.
                    "", // meanSqm -- future README indexing.
                ]
                lines.append(row.map(csvField).joined(separator: ","))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - csv (generic)

    private static let csvHeader =
        "target,date,frames_usable,frames_rejected,exposure_s,integration_s,camera,gain_iso,sensor_temp_c,focal_length_mm,filters,fwhm_arcsec_median,background_e_s_arcsec2,tags"

    /// One row per session date-dir on record (`SessionStatsQueries`
    /// details), joined with that date's `SessionQuality` summary when one
    /// exists. Unlike `astrobin`, excluded (`_hibas`) sessions are still
    /// included -- this format is a complete per-session log, not a
    /// publish-ready listing.
    private static func renderCSV(target: String, db: Database, config: AstroConfig) throws -> String {
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        let qualityByDate = Dictionary(
            uniqueKeysWithValues: try SessionQuality.summaries(target: target, db: db, config: config).map { ($0.date, $0) }
        )

        var lines = [csvHeader]

        for session in sessions {
            let quality = qualityByDate[session.dateRaw]
            let dominantExposure = dominantExposureBreakdownKey(session.exposureBreakdown)

            let fwhmText: String = quality?.medianFWHMArcsec.map { String(format: "%.2f", $0) } ?? ""
            let backgroundText: String = quality?.backgroundEPerSecPerArcsec2.map { String(format: "%.4f", $0) } ?? ""
            let row: [String] = [
                session.target,
                session.dateRaw,
                String(session.usableLightCount),
                String(session.rejectedCount),
                dominantExposure.map(formatTrimmed) ?? "",
                formatTrimmed(session.integrationSeconds),
                session.cameras.joined(separator: ", "),
                session.gains.map(formatTrimmed).joined(separator: ", "),
                session.sensorTempsC.map(formatTrimmed).joined(separator: ", "),
                session.focalLengthsMM.map(formatTrimmed).joined(separator: ", "),
                session.filters.joined(separator: ", "),
                fwhmText,
                backgroundText,
                session.tags.joined(separator: ", "),
            ]
            lines.append(row.map(csvField).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The exposure (in seconds) with the most usable-light frames in
    /// `breakdown` -- the session's "typical sub length". Ties break on the
    /// smaller exposure value for a deterministic result. `nil` when
    /// `breakdown` has no numeric key at all (every frame landed in
    /// `"unknown"`, or there are no frames).
    private static func dominantExposureBreakdownKey(_ breakdown: [String: Int]) -> Double? {
        let numeric: [(value: Double, count: Int)] = breakdown.compactMap { key, count in
            guard key != "unknown", let value = Double(key) else { return nil }
            return (value, count)
        }
        guard let maxCount = numeric.map(\.count).max() else { return nil }
        return numeric.filter { $0.count == maxCount }.map(\.value).min()
    }

    // MARK: - md

    /// Target heading, one subsection per session (date/README/frames/
    /// exposures/equipment/quality/timeline, excluded sessions marked
    /// "kizárva"), and a target summary footer.
    private static func renderMarkdown(target: String, db: Database, config: AstroConfig) throws -> String {
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        let qualityByDate = Dictionary(
            uniqueKeysWithValues: try SessionQuality.summaries(target: target, db: db, config: config).map { ($0.date, $0) }
        )
        let stats = try StatsQueries.target(target, db: db, config: config)

        var lines: [String] = ["# \(target)", ""]

        for session in sessions {
            let excludedSuffix = session.isExcludedFromTotals ? " (kizárva)" : ""
            lines.append("## \(session.dateRaw)\(excludedSuffix)")
            lines.append("")
            lines.append("- **README:** \(session.hasReadme ? "van" : "nincs")")
            lines.append("- **Keretek:** \(frameCountText(session))")
            lines.append("- **Integráció:** \(formatHoursMinutes(session.integrationSeconds))")
            lines.append("- **Expozíciók:** \(exposureSummaryText(session.exposureBreakdown))")
            lines.append("- **Kamera/optika:** \(equipmentText(session))")
            if let quality = qualityByDate[session.dateRaw], quality.frameCount > 0 {
                lines.append("- **Minőség:** \(qualityLineText(quality))")
            }
            let timeline = try SessionTimeline.timeline(target: target, date: session.dateRaw, db: db, config: config)
            if timeline.windowStart != nil {
                lines.append("- **Idővonal:** \(timelineLineText(timeline))")
            }
            if session.isExcludedFromTotals {
                lines.append("- **Megjegyzés:** kizárva a célpont-összegzésből (hibás session)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("**Összegzés**")
        lines.append("")
        let actionableSessions = sessions.filter { !$0.isExcludedFromTotals }
        let totalUsableIntegration = stats?.usableIntegrationSeconds
            ?? actionableSessions.reduce(0) { $0 + $1.integrationSeconds }
        lines.append("- Session-ök száma: \(actionableSessions.count)")
        lines.append("- Összes usable integráció: \(formatHoursMinutes(totalUsableIntegration))")
        if let tags = stats?.tags, let goalSeconds = GoalTag.parse(tags: tags), goalSeconds > 0 {
            let percent = min(100, totalUsableIntegration / goalSeconds * 100)
            lines.append(
                "- Cél haladás: \(formatHoursMinutes(totalUsableIntegration)) / \(formatHoursMinutes(goalSeconds)) (\(String(format: "%.0f%%", percent)))"
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func frameCountText(_ s: SessionDetail) -> String {
        var base = "\(s.usableLightCount) light, \(s.flatCount) flat, \(s.darkCount) dark, \(s.biasCount) bias"
        var extras: [String] = []
        if s.rejectedCount > 0 { extras.append("\(s.rejectedCount) elvetett") }
        if s.duplicateLinkCount > 0 { extras.append("\(s.duplicateLinkCount) link") }
        if !extras.isEmpty { base += "  (+\(extras.joined(separator: " · ")))" }
        return base
    }

    private static func exposureSummaryText(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count in
                if key == "unknown" { return "?×\(count)" }
                let label = Double(key).map(formatTrimmed) ?? key
                return "\(label)s×\(count)"
            }
            .joined(separator: ", ")
    }

    private static func equipmentText(_ s: SessionDetail) -> String {
        var parts: [String] = []
        if !s.cameras.isEmpty { parts.append(s.cameras.joined(separator: "/")) }
        if !s.focalLengthsMM.isEmpty {
            parts.append(s.focalLengthsMM.map { "\(formatTrimmed($0)) mm" }.joined(separator: "/"))
        }
        if !s.gains.isEmpty { parts.append("gain \(s.gains.map(formatTrimmed).joined(separator: "/"))") }
        if !s.sensorTempsC.isEmpty {
            parts.append(s.sensorTempsC.map { "\(formatTrimmed($0)) °C" }.joined(separator: "/"))
        }
        if !s.filters.isEmpty { parts.append(s.filters.joined(separator: "/")) }
        return parts.isEmpty ? "-" : parts.joined(separator: " · ")
    }

    private static func qualityLineText(_ q: SessionQualitySummary) -> String {
        var parts: [String] = []
        if let fwhm = q.medianFWHMArcsec {
            parts.append(String(format: "FWHM %.2f\"", fwhm))
        } else if let fwhmPx = q.medianFWHMPixels {
            parts.append(String(format: "FWHM %.2fpx", fwhmPx))
        }
        if let background = q.backgroundEPerSecPerArcsec2 {
            parts.append(String(format: "háttér %.4f e-/s/arcsec²", background))
        }
        if let rank = q.rankAmongSessions, let total = q.sessionCountForTarget {
            parts.append("rang \(rank)/\(total)")
        }
        return parts.isEmpty ? "-" : parts.joined(separator: ", ")
    }

    private static func timelineLineText(_ t: SessionTimeline) -> String {
        var parts: [String] = []
        if let start = t.windowStart, let end = t.windowEnd {
            parts.append("ablak \(shortTime(start)) → \(shortTime(end))")
        }
        if let duty = t.dutyCycle {
            parts.append("duty cycle \(String(format: "%.0f%%", duty * 100))")
        }
        if !t.gaps.isEmpty {
            parts.append("\(t.gaps.count) szünet")
        }
        return parts.joined(separator: ", ")
    }

    /// `"HH:mm"` out of `SessionTimeline`'s `"yyyy-MM-ddTHH:mm:ssZ"` ISO
    /// strings -- a plain substring slice, since the shape is always fixed
    /// (produced by `SessionTimeline`'s own formatter).
    private static func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[start..<end])
    }

    private static func formatHoursMinutes(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    // MARK: - Per-session frame-level aggregates (astrobin only)

    private struct FrameEquipment {
        var nominalExptime: Double
        var filter: String?
        var gain: Double?
        /// `setTemp` when present, else `ccdTemp` (e.g. a DSLR frame with
        /// no cooling telemetry at all leaves this `nil`).
        var cooling: Double?
    }

    /// This session's USABLE (deduped, non-rejected) lights that have a
    /// parseable `exptime`, one `FrameEquipment` each -- the raw material
    /// `renderAstrobin` groups by nominal exposure and reduces to a
    /// dominant filter/gain and median cooling.
    private static func usableFrameEquipment(
        date: String,
        sessionFiles: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> [FrameEquipment] {
        let dayLights = sessionFiles.filter { $0.sessionDate == date && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)

        var result: [FrameEquipment] = []
        for file in buckets.usable {
            guard let id = file.id, let meta = metaByFileID[id], let exptime = meta.exptime else { continue }
            result.append(FrameEquipment(
                nominalExptime: NominalExposure.nominal(exptime),
                filter: meta.filter,
                gain: meta.gain,
                cooling: meta.setTemp ?? meta.ccdTemp
            ))
        }
        return result
    }

    /// Count of this session's own (raw, undeduped -- calibration frames
    /// never go through `FrameSet` dedup) dark frames whose nominal exptime
    /// matches the flats' dominant nominal exptime -- i.e. the darks that
    /// are actually flat-darks rather than light-darks. `0` when the
    /// session has no flats with a parseable exptime at all.
    private static func flatDarksCount(sessionFiles: [FileRecord], date: String, db: Database) throws -> Int {
        let dayFlats = sessionFiles.filter { $0.sessionDate == date && $0.role == .flat }
        let dayDarks = sessionFiles.filter { $0.sessionDate == date && $0.role == .dark }

        guard let dominantFlatExptime = mode(try nominalExptimes(dayFlats, db: db)) else { return 0 }
        let darkExptimes = try nominalExptimes(dayDarks, db: db)
        return darkExptimes.filter { $0 == dominantFlatExptime }.count
    }

    private static func nominalExptimes(_ files: [FileRecord], db: Database) throws -> [Double] {
        var result: [Double] = []
        for file in files {
            guard let id = file.id, let meta = try db.fitsMeta(fileID: id), let exptime = meta.exptime else { continue }
            result.append(NominalExposure.nominal(exptime))
        }
        return result
    }

    // MARK: - Small shared helpers

    /// The most frequent value in `values`, `nil` when empty. Ties break
    /// arbitrarily (dictionary iteration order) -- same convention as
    /// `CalibAnalyzer`'s private `mode` helper, duplicated here since that
    /// one is file-private.
    private static func mode<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Whole numbers print without a decimal point (`"300"`, not
    /// `"300.0"`), everything else with exactly one decimal digit
    /// (`"6.8"`) -- matches `NominalExposure`'s own rounding granularity
    /// (whole seconds at/above 10s, 0.1s below).
    private static func formatTrimmed(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// Standard CSV field escaping: wrap in quotes (doubling any embedded
    /// quote) when the field contains a comma, a quote, or a newline;
    /// otherwise emit as-is.
    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Filename timestamp

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
