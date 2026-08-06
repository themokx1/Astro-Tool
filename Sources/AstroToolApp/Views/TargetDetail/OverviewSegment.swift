import AstroCore
import Charts
import SwiftUI

/// R9-T3/A.3's "Áttekintés" segment: coordinates, setup fingerprint,
/// tonight's visibility, the Expozíció-tanácsadó (moved here from the old
/// QualityView -- it's target-specific, not a global tool), an inline mosaic
/// panel table when applicable, and the target's calibration status.
struct OverviewSegment: View {
    @Environment(AppState.self) private var appState
    let target: String
    /// Shared with `TargetDetailPage` so the "Plate-solve…" button opens the
    /// same sheet the header/context menus use, rather than a second
    /// independent one.
    @Binding var solvingTarget: SolvingTarget?

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coordinatesBlock
                setupFingerprintBlock
                visibilityBlock
                skyChartBlock
                integrationTrendBlock
                exposureAdviceBlock
                if let panelReport, panelReport.isMosaic {
                    MosaicPanelTable(report: panelReport)
                }
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

    // MARK: - Mai láthatóság

    private var visibilityBlock: some View {
        section("Láthatóság ma este") {
            if let plan {
                HStack(spacing: 20) {
                    labeledValue("Kulminál", plan.culminationLocal ?? "-")
                    labeledValue("Max. mag.", plan.maxAltitudeDeg.map { String(format: "%.0f°", $0) } ?? "-")
                    labeledValue("Látható", visibleWindowText(plan))
                    labeledValue("Hold", moonText(plan))
                    verdictChip(plan.verdict)
                }
            } else {
                Text("Nincs terv-adat.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func visibleWindowText(_ plan: TargetPlan) -> String {
        guard let window = plan.visibleWindowLocal else { return "-" }
        guard let hours = plan.visibleHours else { return window }
        return "\(window) (\(String(format: "%.1f", hours)) ó)"
    }

    private func moonText(_ plan: TargetPlan) -> String {
        guard let illum = plan.moonIlluminationPercent else { return "-" }
        var text = "\(Int(illum.rounded()))%"
        if let sep = plan.moonSeparationDeg { text += " · \(Int(sep.rounded()))°" }
        return text
    }

    private func verdictChip(_ verdict: String) -> some View {
        Text(verdict)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill((verdict == "ma jó" ? Color.green : Color.secondary).opacity(0.2)))
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
                    Text("Nincs megfigyelési helyszín beállítva — állítsd be itt: Beállítások ▸ Helyszín.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    private var integrationTrendBlock: some View {
        section("Integráció-halmozódás") {
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
                .chartYAxisLabel("óra")
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
                .frame(height: 190)
            }
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
                    Text("cél: \(Int(goalHours.rounded())) ó")
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
            Text("flat: \(calib.flats.count)").font(.caption).foregroundStyle(.secondary)
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
