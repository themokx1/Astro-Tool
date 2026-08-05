import AstroCore
import SwiftUI

struct CalibrationView: View {
    @Environment(AppState.self) private var appState

    private struct Row: Identifiable {
        let id = UUID()
        let need: CalibNeed
    }

    private var todos: [CalibNeed] {
        appState.calibNeeds.filter { $0.todo != nil }
    }

    private var rows: [Row] {
        appState.calibNeeds.map(Row.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Frissítés") { appState.loadCalib() }
                    .disabled(appState.isBusy || appState.db == nil)
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                    Button("Mégse") { appState.cancelCurrentOperation() }
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Text("Teendők").font(.headline)
            if todos.isEmpty {
                Text("Nincs teendő — minden kombináció friss.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, need in
                        Text("• \(need.todo ?? "")")
                    }
                }
            }

            Text("Lefedettség").font(.headline)
            Table(rows) {
                TableColumn("Exp. (s)") { row in Text(formattedExposure(row.need.exposureSeconds)) }
                    .width(70)
                TableColumn("Hőm. (°C)") { row in Text(row.need.tempC.map { String(format: "%.1f", $0) } ?? "-") }
                    .width(80)
                TableColumn("Light-ok") { row in Text("\(row.need.lightCount)") }
                    .width(70)
                TableColumn("Master") { row in
                    Text(row.need.matchedMasterPath ?? "hiányzik")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.need.matchedMasterPath ?? "hiányzik")
                }
                .width(min: 180, ideal: 260)
                TableColumn("Kor (nap)") { row in Text(row.need.masterAgeDays.map(String.init) ?? "-") }
                    .width(80)
                TableColumn("Állapot") { row in
                    if row.need.isStale {
                        Text("⚠️ elavult").foregroundStyle(.orange)
                    } else if row.need.matchedMasterPath != nil {
                        Text("friss").foregroundStyle(.green)
                    } else {
                        Text("hiányzik").foregroundStyle(.red)
                    }
                }
                .width(90)
                TableColumn("Megjegyzés") { row in
                    if !row.need.mismatchReasons.isEmpty {
                        Text(row.need.mismatchReasons.joined(separator: ", "))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.need.mismatchReasons.joined(separator: ", "))
                    }
                }
                .width(min: 140, ideal: 200)
            }

            Divider()

            HStack {
                Text("Kalibráció-egészség").font(.headline)
                Spacer()
                Button("Frissítés") { appState.loadCalibHealth() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if let health = appState.calibHealth {
                CalibHealthSections(health: health)
            } else {
                Text("Még nincs betöltve.").foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Szenzor-profilok").font(.headline)
                Spacer()
                Button("Frissítés") { appState.loadSensorProfiles() }
                    .disabled(appState.isBusy || appState.db == nil)
                Button("Mérés") { appState.measureSensorProfiles() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            SensorProfileSection(profiles: appState.sensorProfiles)
        }
        .onAppear {
            // One combined load for whichever of the three data sets is
            // missing: three conditional `loadX()` calls back-to-back would
            // cancel each other (see AppState's refresh-core comment).
            appState.loadCalibTabIfNeeded()
        }
        .padding()
    }

    private func formattedExposure(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// The "Kalibráció-egészség" section's three collapsible blocks (flat
/// discipline, bias inventory, dark master health) -- a plain summary view
/// over `CalibHealthReport`, no state of its own.
private struct CalibHealthSections: View {
    let health: CalibHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Flat-fegyelem (\(health.flats.count) session)") {
                if health.flats.isEmpty {
                    Text("Nincs session usable lighttal.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sortedFlats().enumerated()), id: \.offset) { _, flat in
                            HStack(alignment: .top, spacing: 6) {
                                statusDot(flatColor(flat.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(flat.target) / \(flat.date) — \(flat.status)")
                                    if !flat.reasons.isEmpty {
                                        Text(flat.reasons.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            DisclosureGroup("Bias-készlet (\(health.biasGroups.count) csoport)") {
                VStack(alignment: .leading, spacing: 6) {
                    if health.biasGroups.isEmpty {
                        Text("Nincs bias frame.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(health.biasGroups.enumerated()), id: \.offset) { _, group in
                        HStack(alignment: .top, spacing: 6) {
                            statusDot(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(biasLabel(group))
                                Text("\(group.frameCount) frame — \(group.locations.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !health.missingBiasCombos.isEmpty {
                        Divider()
                        ForEach(health.missingBiasCombos, id: \.self) { combo in
                            HStack(alignment: .top, spacing: 6) {
                                statusDot(.red)
                                Text(combo)
                            }
                        }
                    }
                }
            }

            DisclosureGroup("Dark-készlet egészség (\(health.darkMasters.count) master)") {
                VStack(alignment: .leading, spacing: 6) {
                    if health.darkMasters.isEmpty {
                        Text("Nincs master dark.").foregroundStyle(.secondary)
                    }
                    ForEach(sortedDarkMasters(), id: \.path) { master in
                        HStack(alignment: .top, spacing: 6) {
                            statusDot(darkColor(master))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(master.path) — \(master.frameCount) frame, \(master.ageDays.map(String.init) ?? "-") napos")
                                if !master.warnings.isEmpty {
                                    Text(master.warnings.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sortedFlats() -> [FlatDiscipline] {
        health.flats.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                // Problems ("nincs flat"/"flat nem illik") first, "rendben" last.
                return (lhs.status == "rendben" ? 1 : 0) < (rhs.status == "rendben" ? 1 : 0)
            }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.date < rhs.date
        }
    }

    private func sortedDarkMasters() -> [DarkMasterHealth] {
        health.darkMasters.sorted { lhs, rhs in
            let lhsProblem = lhs.isStale || lhs.isUnused || !lhs.warnings.isEmpty
            let rhsProblem = rhs.isStale || rhs.isUnused || !rhs.warnings.isEmpty
            if lhsProblem != rhsProblem { return lhsProblem && !rhsProblem }
            return lhs.path < rhs.path
        }
    }

    private func flatColor(_ status: String) -> Color {
        switch status {
        case "rendben": return .green
        case "nincs flat": return .red
        default: return .orange
        }
    }

    private func darkColor(_ master: DarkMasterHealth) -> Color {
        if master.isUnused || !master.warnings.isEmpty { return .orange }
        if master.isStale { return .orange }
        return .green
    }

    private func biasLabel(_ group: BiasGroup) -> String {
        var parts: [String] = []
        if let gain = group.gain { parts.append("gain\(String(format: "%g", gain))") }
        if let offset = group.offset { parts.append("offset\(String(format: "%g", offset))") }
        if let camera = group.camera { parts.append(camera) }
        return parts.isEmpty ? "(ismeretlen kombó)" : parts.joined(separator: "/")
    }

    private func statusDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
    }
}

/// Read-only list of measured sensor profiles (R7-B1 item C) -- one row per
/// `(camera, gain, offset)` combo, bias level/read noise/dark rate/EGAIN as
/// measured by `SensorProfiler.measure`. Never edits anything itself; the
/// "Mérés" button that actually runs a measurement lives on `CalibrationView`
/// above this section.
private struct SensorProfileSection: View {
    let profiles: [SensorProfileRecord]

    private struct Row: Identifiable {
        let id: String
        let profile: SensorProfileRecord
    }

    private var rows: [Row] {
        let sorted = profiles.sorted { lhs, rhs in
            if lhs.camera != rhs.camera { return lhs.camera < rhs.camera }
            return (lhs.gain ?? -.infinity) < (rhs.gain ?? -.infinity)
        }
        return sorted.map { Row(id: rowID(for: $0), profile: $0) }
    }

    private func rowID(for profile: SensorProfileRecord) -> String {
        let gainText = profile.gain.map { String($0) } ?? "-"
        let offsetText = profile.offset.map { String($0) } ?? "-"
        return "\(profile.camera)|\(gainText)|\(offsetText)"
    }

    var body: some View {
        if profiles.isEmpty {
            Text("Még nincs mért szenzor-profil — nyomd meg a Mérés gombot.")
                .foregroundStyle(.secondary)
        } else {
            Table(rows) {
                TableColumn("Kamera") { row in Text(row.profile.camera) }
                    .width(min: 100, ideal: 140)
                TableColumn("Gain") { row in Text(row.profile.gain.map { String(format: "%g", $0) } ?? "-") }
                    .width(60)
                TableColumn("Offset") { row in Text(row.profile.offset.map { String(format: "%g", $0) } ?? "-") }
                    .width(60)
                TableColumn("Bias (ADU)") { row in Text(row.profile.biasLevelADU.map { String(format: "%.0f", $0) } ?? "n/a") }
                    .width(90)
                TableColumn("Leolvasási zaj (e⁻)") { row in Text(row.profile.readNoiseE.map { String(format: "%.2f", $0) } ?? "n/a") }
                    .width(130)
                TableColumn("Dark (e⁻/s)") { row in Text(row.profile.darkRateEPerS.map { String(format: "%.4f", $0) } ?? "n/a") }
                    .width(100)
                TableColumn("Dark hőm. (°C)") { row in Text(row.profile.darkTempC.map { String(format: "%.1f", $0) } ?? "-") }
                    .width(100)
                TableColumn("EGAIN") { row in Text(row.profile.egain.map { String(format: "%.3f", $0) } ?? "n/a") }
                    .width(80)
            }
        }
    }
}
