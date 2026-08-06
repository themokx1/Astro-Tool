import AstroCore
import SwiftUI

/// "Szenzor-profilok" (R9-T1): moved out of `CalibrationView` into its own
/// sidebar page (spec A.10 rename: `Mérés` → `Szenzor mérése…`, now living
/// here instead of on the Kalibráció page) -- same
/// `AppState.sensorProfiles`/`loadSensorProfiles()`/`measureSensorProfiles()`
/// underneath, only the surrounding page chrome is new. T5 rebuilds this
/// page's content in full; for now it's the same list, relocated.
struct SensorPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Szenzor-profilok").font(.largeTitle).bold()
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                    Button("Mégse") { appState.cancelCurrentOperation() }
                }
            }

            HStack {
                Button("Frissítés") { appState.loadSensorProfiles() }
                    .disabled(appState.isBusy || appState.db == nil)
                Button("Szenzor mérése…") { appState.measureSensorProfiles() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            SensorProfileTable(profiles: appState.sensorProfiles)

            Spacer(minLength: 0)
        }
        .onAppear {
            if appState.sensorProfiles.isEmpty { appState.loadSensorProfiles() }
        }
        .padding()
    }
}

/// Read-only list of measured sensor profiles (R7-B1 item C) -- one row per
/// `(camera, gain, offset)` combo, bias level/read noise/dark rate/EGAIN as
/// measured by `SensorProfiler.measure`. Never edits anything itself; the
/// "Szenzor mérése…" button that actually runs a measurement lives on
/// `SensorPage` above this table.
struct SensorProfileTable: View {
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
            Text("Még nincs mért szenzor-profil — nyomd meg a Szenzor mérése… gombot.")
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
