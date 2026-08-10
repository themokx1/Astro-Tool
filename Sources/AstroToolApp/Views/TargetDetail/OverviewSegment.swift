import AstroCore
import Charts
import SwiftUI

/// R9-T3/A.3's "Áttekintés" segment: coordinates, setup fingerprint,
/// tonight's visibility, the Expozíció-tanácsadó (moved here from the old
/// QualityView -- it's target-specific, not a global tool), an inline mosaic
/// panel table when applicable, and the target's calibration status.
struct OverviewSegment: View {
    @Environment(AppState.self) private var appState
    // R10 review (item 15): needed for the "Ma esti ív" no-site hint's own
    // "Beállítás…" deep link -- same `settingsTab = .location;
    // openSettings()` pattern `TonightPage`/`DiscoveryPage` already use.
    @Environment(\.openSettings) private var openSettings
    let target: String
    /// Shared with `TargetDetailPage` so the "Plate-solve…" button opens the
    /// same sheet the header/context menus use, rather than a second
    /// independent one.
    @Binding var solvingTarget: SolvingTarget?
    let editGoals: () -> Void
    let openStacks: () -> Void
    /// Opens the latest session's capture editor, where the user can assign
    /// an inventory filter to one or more capture groups. Kept as a closure
    /// so this segment does not own a second, competing sheet lifecycle.
    let assignFilter: () -> Void

    private var sessions: [SessionDetail] { appState.sessionDetailsByTarget[target] ?? [] }
    private var plan: TargetPlan? { appState.plan?.first { $0.target == target } }
    private var panelReport: PanelReport? { appState.panelReportsByTarget[target] }
    private var targetFlats: [FlatDiscipline] { appState.calibHealth?.flats.filter { $0.target == target } ?? [] }
    /// Same lookup `TargetDetailPage`'s own header/goal tile already use --
    /// duplicated here (rather than threaded down as a parameter) since this
    /// segment is constructed with just `target`/`solvingTarget` today, and
    /// `AppState.projectStates` is already a live `@Observable` array cheap
    /// to re-filter per render.
    private var projectState: ProjectState? { appState.projectStates.first { $0.target == target } }
    /// This target's `TargetStats` -- the "Szűrők" card's own goal-tag merge
    /// (`mergedFilterBreakdown`) needs `.tags`, same lookup
    /// `TargetDetailPage`'s header already uses.
    private var stat: TargetStats? { appState.stats.first { $0.target == target } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coordinatesBlock
                setupFingerprintBlock
                // R11-T5/F1: right after "Setup", ahead of "Láthatóság ma
                // este" -- PLAN-R11's own UI-terv order.
                filtersBlock
                publishingReadinessBlock
                visibilityBlock
                // R11-T2: moved up from just before `calibrationBlock` -- for
                // a mosaic target, panel coverage IS the project-status
                // headline (PLAN-R11's own UI-terv order: Láthatóság →
                // [mozaiknál ITT] → Ma esti ív → Integráció-halmozódás →
                // Expozíció-tanácsadó → Kalibráció), so it belongs right
                // after "Láthatóság ma este", ahead of both the sky chart
                // and the integration/calibration blocks it used to trail.
                if let panelReport, panelReport.isMosaic {
                    MosaicPanelTable(report: panelReport)
                }
                skyChartBlock
                integrationTrendBlock
                exposureAdviceBlock
                calibrationBlock
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Koordináták

    private var coordinatesBlock: some View {
        section("Koordináták") {
            if let info = appState.targetCoordinateInfo, info.sourceLabel != "nincs" {
                HStack(spacing: 20) {
                    labeledValue("RA", TDFormat.raHMS(info.raDeg))
                    labeledValue("Dec", TDFormat.decDMS(info.decDeg))
                    labeledValue("Forrás", info.sourceLabel)
                }
            } else {
                // R9-D19: `info.sourceLabel == "nincs"` still means "no
                // usable coordinate" even though `targetCoordinateInfo`
                // itself is non-`nil` in that case -- the plate-solve button
                // used to only show for the `nil` case, so a target that
                // resolved to the literal "nincs" label had no way to
                // trigger a solve from here at all.
                HStack(spacing: 10) {
                    Text("Nincs plate-solve/fejléc koordináta.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Plate-solve…") { solvingTarget = SolvingTarget(target: target) }
                }
            }
        }
    }

    // MARK: - Setup-ujjlenyomat

    private var setupFingerprintBlock: some View {
        section("Setup") {
            if appState.targetSetupDescriptors.isEmpty {
                Text("Nincs setup-adat.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.targetSetupDescriptors, id: \.self) { descriptor in
                        HStack(spacing: 6) {
                            Text(descriptor).font(.callout)
                            Text("· \(sessionCount(for: descriptor)) session")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func sessionCount(for descriptor: String) -> Int {
        sessions.count { $0.setupDescriptor == descriptor }
    }

    // MARK: - Szűrők (R11-T5/F1)

    /// This target's whole-history per-filter breakdown, merged with its
    /// `goal:<filter>=<hours>h` tags (`FilterGoalQueries.merge`) -- the
    /// "Szűrők" card's own Cél/Hiányzik columns need the merge; the caption
    /// (top 3, `TDFormat.filterBreakdownSummary`) reads the UN-merged
    /// `appState.targetFilterBreakdown` directly instead (no goal data
    /// needed there).
    private var mergedFilterBreakdown: [FilterIntegration] {
        FilterGoalQueries.merge(breakdown: appState.targetFilterBreakdown, tags: stat?.tags ?? [])
    }

    /// `true` when the ONLY bucket this target has at all is the sentinel
    /// "no filter recorded" one -- the typical OSC/DSLR case (R11-T5/F1's
    /// own spec: "ha a célpontnak csak egyetlen, szűrő nélküli bucketje
    /// van... a kártya EGYETLEN diszkrét sorrá egyszerűsödjön").
    private var isFilterlessOnlyTarget: Bool {
        let breakdown = appState.targetFilterBreakdown
        return breakdown.count == 1 && breakdown[0].filter == FilterBreakdownQueries.noFilterSentinel
    }

    private var filtersBlock: some View {
        section("Szűrők") {
            if appState.targetFilterBreakdown.isEmpty {
                missingFilterCallout("Nincs szűrő-adat.")
            } else if isFilterlessOnlyTarget {
                missingFilterCallout("Nincs szűrő-adat — OSC/DSLR anyag.")
            } else {
                filtersTable
            }
        }
    }

    private func missingFilterCallout(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !sessions.isEmpty {
                Button("Szűrő hozzárendelése…") { assignFilter() }
                    .buttonStyle(.link)
            }
        }
    }

    /// Real (non-sentinel) filters first -- in `FilterGoalQueries.merge`'s
    /// own order (usable breakdown seconds-descending, then any goal-only
    /// filters by name) -- the sentinel "(nincs szűrő-adat)" bucket (if this
    /// target ALSO has unfiltered frames alongside real ones -- a mixed
    /// mono+OSC setup) always sorts last, dimmed, per spec ("külön sorként,
    /// szürkén").
    private var filtersTable: some View {
        let merged = mergedFilterBreakdown
        let real = merged.filter { $0.filter != FilterBreakdownQueries.noFilterSentinel }
        let sentinel = merged.first { $0.filter == FilterBreakdownQueries.noFilterSentinel }

        return VStack(alignment: .leading, spacing: 6) {
            filtersTableHeader
            ForEach(real, id: \.filter) { entry in
                filterRow(entry, dimmed: false)
            }
            if let sentinel {
                filterRow(sentinel, dimmed: true)
            }
        }
    }

    private var filtersTableHeader: some View {
        HStack {
            Text("Szűrő").frame(width: 70, alignment: .leading)
            Text("Usable keret").frame(width: 90, alignment: .trailing)
            Text("Integráció").frame(width: 80, alignment: .trailing)
            Text("Cél").frame(width: 70, alignment: .trailing)
            Text("Hiányzik").frame(width: 80, alignment: .trailing)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One filter's row: numbers on top, an optional thin progress bar
    /// below (only when this filter actually HAS a goal -- "cél nélkül sáv
    /// nélkül") colored orange while short of the goal, green once met.
    private func filterRow(_ entry: FilterIntegration, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.filter).frame(width: 70, alignment: .leading)
                Text("\(entry.usableFrameCount)").frame(width: 90, alignment: .trailing)
                Text(TDFormat.hm(entry.integrationSeconds)).frame(width: 80, alignment: .trailing)
                Text(entry.goalSeconds.map(TDFormat.hm) ?? TDFormat.missingCell).frame(width: 70, alignment: .trailing)
                Text(entry.missingSeconds.map(TDFormat.hm) ?? TDFormat.missingCell)
                    .foregroundStyle((entry.missingSeconds ?? 0) > 0 ? .orange : .secondary)
                    .frame(width: 80, alignment: .trailing)
                Spacer()
            }
            .font(.callout)
            if let goalSeconds = entry.goalSeconds, goalSeconds > 0 {
                filterProgressBar(entry, goalSeconds: goalSeconds)
            }
        }
        .opacity(dimmed ? 0.6 : 1.0)
    }

    private func filterProgressBar(_ entry: FilterIntegration, goalSeconds: Double) -> some View {
        let fraction = max(0, min(1, entry.integrationSeconds / goalSeconds))
        let isShort = (entry.missingSeconds ?? 0) > 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(isShort ? Color.orange : Color.green).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
    }

    // MARK: - Publikálásra kész

    private var publishingReadinessBlock: some View {
        section("Publikálásra kész") {
            if let readiness = appState.targetPublishingReadiness {
                if readiness.isReady {
                    Label("Kész a publikálási exportra", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(readiness.issues, id: \.rawValue) { issue in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(readinessLabel(issue))
                                Spacer()
                                Button(readinessActionLabel(issue)) {
                                    performReadinessAction(issue)
                                }
                                .buttonStyle(.link)
                            }
                            .font(.callout)
                        }
                    }
                }
                Text("Figyelmeztetés, nem tiltás — az export bármikor használható.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("A publikálási állapot betöltése…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readinessLabel(_ issue: PublishingReadiness.Issue) -> String {
        switch issue {
        case .projectNotComplete: return "A projekt munkafolyamata még nincs kész."
        case .outstandingOverallGoal: return "Az összcélból még hiányzik integráció."
        case .outstandingFilterGoal: return "Legalább egy szűrőcél még hiányos."
        case .unmappedAstroBinFilter:
            let names = appState.targetUnmappedAstroBinFilters.joined(separator: ", ")
            return names.isEmpty ? "Van leképezetlen AstroBin-szűrő." : "Nincs AstroBin ID: \(names)."
        case .missingProcessedOutput: return "Nincs feldolgozott kimenet a célponthoz."
        }
    }

    private func readinessActionLabel(_ issue: PublishingReadiness.Issue) -> String {
        switch issue {
        case .outstandingOverallGoal, .outstandingFilterGoal: return "Célok…"
        case .unmappedAstroBinFilter: return "Beállítások…"
        case .projectNotComplete, .missingProcessedOutput: return "Stackek"
        }
    }

    private func performReadinessAction(_ issue: PublishingReadiness.Issue) {
        switch issue {
        case .outstandingOverallGoal, .outstandingFilterGoal:
            editGoals()
        case .unmappedAstroBinFilter:
            appState.settingsTab = .library
            openSettings()
        case .projectNotComplete, .missingProcessedOutput:
            openStacks()
        }
    }

    // MARK: - Mai láthatóság

    private var visibilityBlock: some View {
        section("Láthatóság ma este") {
            if let plan {
                HStack(spacing: 20) {
                    labeledValue("Kulminál", TDFormat.tile(plan.culminationLocal))
                    labeledValue("Max. mag.", TDFormat.tile(plan.maxAltitudeDeg.map { String(format: "%.0f°", $0) }))
                    labeledValue("Látható", visibleWindowText(plan))
                    labeledValue("Hold", moonText(plan))
                    // R11-T12/F11(d): clickable -- same popover
                    // (`VerdictExplainPopover`) `TonightPage.planTable`'s
                    // Döntés column uses, sourced from this same `plan`.
                    VerdictExplainPopover(
                        verdict: plan.verdict,
                        maxAltitudeDeg: plan.maxAltitudeDeg,
                        visibleHours: plan.visibleHours,
                        moonIlluminationPercent: plan.moonIlluminationPercent,
                        moonSeparationDeg: plan.moonSeparationDeg
                    )
                }
            } else {
                Text("Nincs terv-adat.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func visibleWindowText(_ plan: TargetPlan) -> String {
        guard let window = plan.visibleWindowLocal else { return TDFormat.missingTile }
        guard let hours = plan.visibleHours else { return window }
        return "\(window) (\(String(format: "%.1f", hours)) ó)"
    }

    private func moonText(_ plan: TargetPlan) -> String {
        guard let illum = plan.moonIlluminationPercent else { return TDFormat.missingTile }
        var text = "\(Int(illum.rounded()))%"
        if let sep = plan.moonSeparationDeg { text += " · \(Int(sep.rounded()))°" }
        return text
    }

    // MARK: - Ma esti ív (R10-B2)

    /// Same industry-standard altitude-over-the-night chart as `TonightPage`'s
    /// selected-row panel, here always for TONIGHT specifically (this segment
    /// has no calendar-night concept) and using the target's resolved
    /// coordinate the "Koordináták" card above already surfaces via
    /// `targetCoordinateInfo` -- `sourceLabel == "nincs"` means the same "no
    /// usable coordinate" case that card's own `Plate-solve…` button handles,
    /// reused verbatim here.
    private var skyChartBlock: some View {
        section("Ma esti ív") {
            if let info = appState.targetCoordinateInfo, info.sourceLabel != "nincs" {
                if let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg {
                    let now = Date()
                    SkyChartView(
                        targetName: plan?.displayName ?? target,
                        targetTrack: SkyTrack.altitudeTrack(raDeg: info.raDeg, decDeg: info.decDeg, nightOf: now, latDeg: lat, lonDeg: lon),
                        moonTrack: SkyTrack.moonAltitudeTrack(nightOf: now, latDeg: lat, lonDeg: lon),
                        markers: SkyTrack.nightWindowMarkers(nightOf: now, latDeg: lat, lonDeg: lon),
                        minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                        isTonight: true,
                        nightOf: now,
                        moonIlluminationPercent: plan?.moonIlluminationPercent
                    )
                } else {
                    // R10 review (item 15): a real deep link (same
                    // `settingsTab = .location; openSettings()` pattern
                    // `TonightPage.noSiteChartHint`/the "Helyszín" tile
                    // elsewhere already use), replacing a plain sentence
                    // that just NAMED the settings location without a way
                    // to jump there.
                    HStack(spacing: 8) {
                        Text("Nincs megfigyelési helyszín beállítva.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Beállítás…") {
                            appState.settingsTab = .location
                            openSettings()
                        }
                        .buttonStyle(.link)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text("Nincs plate-solve/fejléc koordináta.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Plate-solve…") { solvingTarget = SolvingTarget(target: target) }
                }
            }
        }
    }

    // MARK: - Integráció-halmozódás (R10-B5)

    /// One session's contribution to the cumulative-integration trend --
    /// `Identifiable` (not `ForEach(..., id: \.date)`) because a
    /// `runSuffix`/labeled session sharing its calendar day with another
    /// (`SessionDateParser`'s own "more than one session, same night"
    /// cases) would otherwise collide on that shared `date` value.
    private struct IntegrationPoint: Identifiable {
        let id = UUID()
        let date: Date
        let cumulativeHours: Double
    }

    /// Running sum of `integrationSeconds` over this target's sessions,
    /// sorted by calendar date ascending -- same "usable" convention
    /// `AcquisitionExport`'s own per-target rollups use (`for session in
    /// sessions where !session.isExcludedFromTotals`): an excluded
    /// (`_hibas`-tagged) session contributes NOTHING to the running total
    /// and isn't plotted as its own point either. That's a deliberate
    /// simplification over drawing it as a "gap" -- this tool already
    /// treats that session's data as not counting toward the target's real
    /// progress everywhere else (`TargetStats`, the goal tile), so plotting
    /// it here even as a non-contributing marker would suggest otherwise.
    /// A session whose date-dir name doesn't even parse as a calendar date
    /// (shouldn't happen in practice -- `SessionDateParser` gates what
    /// reaches `sessionDate` in the first place) is silently skipped too,
    /// same "skip rather than guess" rule as everywhere else in this app.
    private var integrationPoints: [IntegrationPoint] {
        let parsed = sessions
            .filter { !$0.isExcludedFromTotals }
            .compactMap { session -> (date: Date, dateRaw: String, seconds: Double)? in
                guard let date = Self.parseSessionDate(session.dateRaw) else { return nil }
                return (date, session.dateRaw, session.integrationSeconds)
            }
            .sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date < rhs.date : lhs.dateRaw < rhs.dateRaw
            }

        var runningSeconds = 0.0
        return parsed.map { entry in
            runningSeconds += entry.seconds
            return IntegrationPoint(date: entry.date, cumulativeHours: runningSeconds / 3600.0)
        }
    }

    /// `projectState.goalSeconds` in hours -- `nil` when no goal tag is set,
    /// same as the goal tile on `TargetDetailPage`'s own header.
    private var goalHours: Double? {
        projectState?.goalSeconds.map { $0 / 3600.0 }
    }

    // MARK: - Per-filter cumulative points (R11-T5/F1)

    /// One filter's cumulative hours as of one session date -- same
    /// `Identifiable`-not-`\.date` reasoning as `IntegrationPoint` (a
    /// same-night labeled/run-suffix session collides on the bare date).
    private struct FilterIntegrationPoint: Identifiable {
        let id = UUID()
        let date: Date
        let filter: String
        let cumulativeHours: Double
    }

    /// `true` when this target has ever recorded a REAL filter (anything
    /// other than `FilterBreakdownQueries.noFilterSentinel`) -- gates
    /// whether `integrationTrendBlock` draws the per-filter-colored chart or
    /// falls back to the original single accent-colored line (R11-T5/F1:
    /// "szűrőtlen anyagnál a mostani egyvonalas forma maradjon").
    private var hasRealFilterData: Bool {
        appState.targetFilterBreakdown.contains { $0.filter != FilterBreakdownQueries.noFilterSentinel }
    }

    /// Running per-filter sum across this target's sessions (excluded/
    /// `_hibas` sessions skipped, same as `integrationPoints` above), reading
    /// each session's OWN filter breakdown from `appState.
    /// targetFilterBreakdownByDate`. Emits one point per (date, filter EVER
    /// SEEN so far) -- including a filter this particular night didn't
    /// contribute to at all -- so `.stepEnd` keeps that filter's own line
    /// flat instead of just stopping, the same way the single-line chart's
    /// step interpolation already reads as "no change" between sessions.
    /// The no-filter sentinel bucket is dropped entirely (a per-filter chart
    /// has nothing meaningful to plot for "no filter recorded").
    private var filterIntegrationPoints: [FilterIntegrationPoint] {
        let parsedSessions = sessions
            .filter { !$0.isExcludedFromTotals }
            .compactMap { session -> (date: Date, dateRaw: String)? in
                guard let date = Self.parseSessionDate(session.dateRaw) else { return nil }
                return (date, session.dateRaw)
            }
            .sorted { lhs, rhs in
                lhs.date != rhs.date ? lhs.date < rhs.date : lhs.dateRaw < rhs.dateRaw
            }

        var runningSecondsByFilter: [String: Double] = [:]
        var points: [FilterIntegrationPoint] = []
        for entry in parsedSessions {
            let dayBreakdown = appState.targetFilterBreakdownByDate[entry.dateRaw] ?? []
            for filterEntry in dayBreakdown where filterEntry.filter != FilterBreakdownQueries.noFilterSentinel {
                runningSecondsByFilter[filterEntry.filter, default: 0] += filterEntry.integrationSeconds
            }
            for (filter, seconds) in runningSecondsByFilter {
                points.append(FilterIntegrationPoint(date: entry.date, filter: filter, cumulativeHours: seconds / 3600.0))
            }
        }
        return points
    }

    private var integrationTrendBlock: some View {
        section("Integráció-halmozódás") {
            if hasRealFilterData {
                filterIntegrationChart
            } else {
                singleLineIntegrationChart
            }
        }
    }

    @ViewBuilder
    private var singleLineIntegrationChart: some View {
        if integrationPoints.count < 2 {
            Text("Egy sessionnél még nincs mit halmozni.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Chart {
                integrationArea
                integrationLine
                integrationPointMarks
                goalRule
            }
            .chartLegend(.hidden)
            // R10 review (item 21): "óra" alone reads as "current hour
            // of day" at a glance -- this axis is a RUNNING TOTAL
            // (`IntegrationPoint.cumulativeHours`), not a point-in-time
            // value.
            .chartYAxisLabel("óra (halmozott)")
            .integrationChartAxes()
            .frame(height: 190)
        }
    }

    /// R11-T5/F1: session-önkénti kumulatív vonal szűrőnként bontva,
    /// `foregroundStyle(by:)` szerint színezve -- same step interpolation
    /// and Y-axis label as the single-line chart, plus a visible legend
    /// (hidden there since there's only ever one series to distinguish).
    @ViewBuilder
    private var filterIntegrationChart: some View {
        let points = filterIntegrationPoints
        if points.count < 2 {
            Text("Egy sessionnél még nincs mit halmozni.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Dátum", point.date),
                        y: .value("Halmozott óra", point.cumulativeHours)
                    )
                    .foregroundStyle(by: .value("Szűrő", point.filter))
                    .interpolationMethod(.stepEnd)
                }
                ForEach(points) { point in
                    PointMark(
                        x: .value("Dátum", point.date),
                        y: .value("Halmozott óra", point.cumulativeHours)
                    )
                    .foregroundStyle(by: .value("Szűrő", point.filter))
                    .symbolSize(20)
                }
                goalRule
            }
            .chartYAxisLabel("óra (halmozott)")
            .integrationChartAxes()
            .frame(height: 190)
        }
    }

    @ChartContentBuilder
    private var integrationArea: some ChartContent {
        ForEach(integrationPoints) { point in
            AreaMark(
                x: .value("Dátum", point.date),
                y: .value("Halmozott óra", point.cumulativeHours)
            )
        }
        .interpolationMethod(.stepEnd)
        .foregroundStyle(Color.accentColor.opacity(0.15))
    }

    @ChartContentBuilder
    private var integrationLine: some ChartContent {
        ForEach(integrationPoints) { point in
            LineMark(
                x: .value("Dátum", point.date),
                y: .value("Halmozott óra", point.cumulativeHours)
            )
        }
        .interpolationMethod(.stepEnd)
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2))
    }

    @ChartContentBuilder
    private var integrationPointMarks: some ChartContent {
        ForEach(integrationPoints) { point in
            PointMark(
                x: .value("Dátum", point.date),
                y: .value("Halmozott óra", point.cumulativeHours)
            )
        }
        .foregroundStyle(Color.accentColor)
        .symbolSize(24)
    }

    @ChartContentBuilder
    private var goalRule: some ChartContent {
        if let goalHours {
            RuleMark(y: .value("Cél", goalHours))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                .annotation(position: .top, alignment: .trailing) {
                    // R10 review (item 21): h:mm (`TDFormat.hm`) is this
                    // app's canonical duration format (see that type's own
                    // doc comment) -- was a bare rounded-hours integer
                    // ("cél: 10 ó"), inconsistent with every other duration
                    // this app shows. `goalHours` is already in HOURS (the
                    // chart's own Y unit, needed as-is for the `RuleMark`
                    // above); `* 3600` recovers the seconds `hm` expects.
                    Text("cél: \(TDFormat.hm(goalHours * 3600))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// `"yyyy-MM-dd"` prefix of a session's raw date-dir name -- every
    /// `SessionDate` shape (`canonical`/`runSuffix`/`range`/`labeled`,
    /// `SessionDateParser.swift`) starts with a real 10-character calendar
    /// date, so a plain prefix slice is enough without pulling in the
    /// parser itself. `en_US_POSIX`/`.current`, same convention as
    /// `TonightPage.isoDateFormatter`.
    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseSessionDate(_ dateRaw: String) -> Date? {
        guard dateRaw.count >= 10 else { return nil }
        return sessionDateFormatter.date(from: String(dateRaw.prefix(10)))
    }

    // MARK: - Expozíció-tanácsadó (moved from QualityView)

    private var exposureAdviceBlock: some View {
        section("Expozíció-tanácsadó") {
            if let advice = appState.exposureAdvice {
                if let reason = advice.notAvailableReason {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                        // R9-D20: previously only navigated to the Szenzor
                        // page without actually starting a measurement --
                        // `MainShellView`'s own "Szenzor mérése…" button
                        // (line 97) posts this same notification alongside
                        // the navigation, which is what makes `SensorPage`
                        // actually kick off the measurement sheet.
                        Button("Szenzor mérése…") {
                            appState.currentPage = .sensor
                            NotificationCenter.default.post(name: .measureSensorRequested, object: nil)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(advice.advice.enumerated()), id: \.offset) { _, line in
                            Text("•  \(line)").font(.caption)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Kalibráció-státusz (célpontra szűrve)

    private var calibrationBlock: some View {
        section("Kalibráció") {
            if appState.targetSessionCalibrations.isEmpty {
                Text("Nincs session ehhez a célponthoz.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.targetSessionCalibrations.sorted(by: { $0.date < $1.date }), id: \.date) { calib in
                        calibrationLine(calib)
                    }
                }
            }
            if !targetFlats.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flat-higiénia").font(.subheadline).padding(.top, 4)
                    ForEach(targetFlats.sorted(by: { $0.date < $1.date }), id: \.date) { flat in
                        HStack(spacing: 6) {
                            Text(flat.date).font(.caption)
                            Text(flat.status)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill((flat.status == "rendben" ? Color.green : Color.orange).opacity(0.2)))
                            if !flat.reasons.isEmpty {
                                Text(flat.reasons.joined(separator: "; "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func calibrationLine(_ calib: SessionCalibration) -> some View {
        HStack(spacing: 8) {
            Text(calib.date).font(.caption).frame(width: 90, alignment: .leading)
            Text(flatSummaryText(calib)).font(.caption).foregroundStyle(.secondary)
            if calib.darks.isEmpty, let libraryDark = calib.libraryDark {
                Text("dark: library (\((libraryDark as NSString).lastPathComponent))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("dark: \(calib.darks.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text("bias: \(calib.biases.count)").font(.caption).foregroundStyle(.secondary)
            if !calib.problems.isEmpty {
                Text(calib.problems.map(\.message).joined(separator: "; "))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// R11-T16/F17: per-filter flat status, e.g. "flat: Ha ✓ · OIII ✗" for a
    /// multi-filter mono session -- a filterless (OSC/DSLR) session with
    /// exactly one bucket collapses to a bare "flat: ✓"/"flat: ✗" (no
    /// invented "(nincs szűrő)" label, same "don't generate fake noise"
    /// rule `CalibAnalyzer.flatCoverage` itself follows). Falls back to the
    /// old raw flat-file count when `flatsByFilter` is empty (no usable
    /// lights this session, e.g. every frame was rejected).
    private func flatSummaryText(_ calib: SessionCalibration) -> String {
        guard !calib.flatsByFilter.isEmpty else { return "flat: \(calib.flats.count)" }
        let parts = calib.flatsByFilter.map { entry -> String in
            let mark = entry.covered ? "✓" : "✗"
            guard let filter = entry.filter else { return mark }
            return "\(filter) \(mark)"
        }
        return "flat: " + parts.joined(separator: " · ")
    }

    // MARK: - Shared block chrome

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}

/// Shared X/Y axis styling for both `OverviewSegment.integrationTrendBlock`
/// variants (single-line and per-filter-colored, R11-T5/F1) -- pulled out so
/// the two chart shapes can never visually drift apart from each other.
private extension View {
    func integrationChartAxes() -> some View {
        self
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.secondary)
                    AxisTick()
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.secondary)
                    AxisTick()
                    AxisValueLabel()
                }
            }
    }
}
