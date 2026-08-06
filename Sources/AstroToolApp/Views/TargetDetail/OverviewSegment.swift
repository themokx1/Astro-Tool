import AstroCore
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                coordinatesBlock
                setupFingerprintBlock
                visibilityBlock
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
            if let info = appState.targetCoordinateInfo {
                HStack(spacing: 20) {
                    labeledValue("RA", TDFormat.raHMS(info.raDeg))
                    labeledValue("Dec", TDFormat.decDMS(info.decDeg))
                    labeledValue("Forrás", info.sourceLabel)
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

    // MARK: - Expozíció-tanácsadó (moved from QualityView)

    private var exposureAdviceBlock: some View {
        section("Expozíció-tanácsadó") {
            if let advice = appState.exposureAdvice {
                if let reason = advice.notAvailableReason {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                        Button("Szenzor mérése…") { appState.currentPage = .sensor }
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
