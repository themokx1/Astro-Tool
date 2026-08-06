import AstroCore
import SwiftUI

/// R9-T5/A.6 -- full rebuild of the "eltemetett oldal" the review flagged:
/// 3 header tiles, a permanent "mire jó?" explainer (so this page's own
/// purpose is visible without reading docs), the profile table with a new
/// `Mért` column and a freshness warning for anything measured before the
/// read-noise-estimator fix, and a confirm-first "Szenzor mérése…" (A.10
/// rename from bare "Mérés") that spells out what it reads, how long it
/// takes, and that it only ever writes ONE database row.
struct SensorPage: View {
    @Environment(AppState.self) private var appState
    @State private var showMeasureSheet = false

    /// The read-noise estimator fix date (commit `0928189`, "sample all
    /// bayer parities in native stats; keep sensor noise tail in
    /// read-noise estimate", 2026-08-05) -- any `SensorProfileRecord`
    /// measured before this instant used the OLD (biased) estimator and is
    /// flagged stale here so a user notices before trusting its numbers.
    /// Hardcoded (not derived from the CHANGELOG) since this is a one-time
    /// migration marker, not a config knob.
    static let readNoiseEstimatorFixDate: Date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: "2026-08-05") ?? Date()
    }()

    private var profiles: [SensorProfileRecord] { appState.sensorProfiles }
    private var distinctCameraCount: Int { Set(profiles.map(\.camera)).count }
    private var latestMeasurementText: String {
        guard let latest = profiles.map(\.measuredAt).max() else { return "-" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: latest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if profiles.isEmpty {
                emptyState
            } else {
                tiles
                explainerBlock

                if let lastError = appState.lastError {
                    Text(lastError).foregroundStyle(.red)
                }

                SensorProfileTable(profiles: profiles, freshnessCutoff: Self.readNoiseEstimatorFixDate)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if appState.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                        Button("Mégse") { appState.cancelCurrentOperation() }
                    }
                } else {
                    Button("Szenzor mérése…") { showMeasureSheet = true }
                        .disabled(appState.db == nil)
                }
            }
        }
        .onAppear {
            if appState.sensorProfiles.isEmpty { appState.loadSensorProfiles() }
        }
        .sheet(isPresented: $showMeasureSheet) {
            SensorMeasureConfirmSheet()
        }
        // R9-T6/B14: the Műveletek menu's (toolbar AND menu bar) "Szenzor
        // mérése…" navigates here and posts this so the confirm sheet opens
        // automatically, rather than landing on a page with nothing
        // pre-selected.
        .onReceive(NotificationCenter.default.publisher(for: .measureSensorRequested)) { _ in
            showMeasureSheet = true
        }
    }

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "Profilok", value: "\(profiles.count)")
            StatTile(title: "Kamerák", value: "\(distinctCameraCount)")
            StatTile(title: "Legutóbbi mérés", value: latestMeasurementText)
        }
    }

    private var explainerBlock: some View {
        Text(
            "Mire jó? A mért bias-szint, leolvasási zaj és dark-áram nélkül az "
                + "Expozíció-tanácsadó és a valós égi háttér (e⁻/s/″²) nem számolható."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Még nincs mért szenzor-profil", systemImage: "cpu")
        } description: {
            Text(
                "Mire jó? A mért bias-szint, leolvasási zaj és dark-áram nélkül az "
                    + "Expozíció-tanácsadó és a valós égi háttér (e⁻/s/″²) nem számolható."
            )
        } actions: {
            Button("Szenzor mérése…") { showMeasureSheet = true }
                .disabled(appState.db == nil)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// "Szenzor mérése…" confirmation sheet (A.6): explains what the operation
/// reads (`calibration_library` bias/dark frames already on record), that
/// it only writes ONE database row per `(camera, gain, offset)` combo, and
/// roughly how long it takes -- then, only on explicit confirmation, runs
/// the existing `AppState.measureSensorProfiles()`.
private struct SensorMeasureConfirmSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Szenzor mérése").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mit tesz: beolvassa a tracked BIAS/DARK kereteket kamera/gain/offset kombónként, és kiszámolja a bias-szintet, a leolvasási zajt, a dark-áramot és az EGAIN-t.")
                Text("Meddig tart: néhány másodperc kombónként.")
                Text("Csak egy adatbázis-sort ír kombónként, a könyvtárhoz nem nyúl.")
                    .bold()
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if started {
                HStack(spacing: 8) {
                    if appState.isBusy {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                    } else {
                        Text("Kész: \(appState.sensorProfiles.count) kombináció mérve.")
                            .foregroundStyle(.green)
                    }
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(started && !appState.isBusy ? "Bezárás" : "Mégse") { dismiss() }
                if !started {
                    Button("Mérés indítása") {
                        started = true
                        appState.measureSensorProfiles()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 220)
    }
}

/// Read-only list of measured sensor profiles (R7-B1 item C) -- one row per
/// `(camera, gain, offset)` combo, bias level/read noise/dark rate/EGAIN as
/// measured by `SensorProfiler.measure`. R9-T5/A.6 adds the `Mért` column
/// (`measuredAt`) and a freshness warning (yellow row background + caption)
/// for any profile measured before `freshnessCutoff`. Never edits anything
/// itself; the "Szenzor mérése…" button that actually runs a measurement
/// lives on `SensorPage` above this table.
struct SensorProfileTable: View {
    let profiles: [SensorProfileRecord]
    let freshnessCutoff: Date

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

    private func isStale(_ profile: SensorProfileRecord) -> Bool {
        profile.measuredAt < freshnessCutoff.timeIntervalSince1970
    }

    /// Every column's cell is wrapped with this so a stale row reads as a
    /// solid yellow row -- `Table` has no per-row background modifier of its
    /// own, so tinting every cell identically is what actually produces
    /// that look.
    @ViewBuilder
    private func cell(_ row: Row, text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isStale(row.profile) ? Color.yellow.opacity(0.25) : Color.clear)
    }

    /// D32: this table's computed-metric columns, explained -- same
    /// "one button per table" `MetricInfoButton` pattern the target-detail
    /// segments already established. Explicitly covers the "mikor hazudik"
    /// caveats `SensorProfiler.measure`'s own doc comments call out.
    private static let metricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Leolvasási zaj (e⁻)",
            explanation: "Két BIAS-keret különbségének szórásából számolt zaj, elektronra váltva az EGAIN-nel. Mikor hazudik: „n/a” ha kevesebb, mint 2 BIAS-keret van ehhez a kombóhoz, vagy nincs EGAIN; egyetlen rossz/kozmikus-sugár-foltos BIAS-pár is elronthatja."
        ),
        .init(
            title: "Dark (e⁻/s)",
            explanation: "A DARK-keret és a BIAS-szint különbsége elektron/másodpercre normálva. Mikor hazudik: „n/a” EGAIN vagy DARK-keret nélkül; hőmérséklet-függő, egy másik szenzor-hőfokon mért dark-áram nem ugyanaz."
        ),
        .init(
            title: "EGAIN",
            explanation: "Elektron/ADU átváltási tényező, a FITS-fejlécből (EGAIN kulcs) vagy a BIAS-keretek szórásából becsülve. Mikor hazudik: „n/a” ha sem a fejléc, sem a becslés nem ad értéket; egy hibás gain-beállítás a kamerán ezt is elcsúsztatja."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                MetricInfoButton(metrics: Self.metricInfo)
            }
            Table(rows) {
                TableColumn("Kamera") { row in cell(row, text: row.profile.camera) }
                    .width(min: 100, ideal: 140)
                TableColumn("Gain") { row in cell(row, text: row.profile.gain.map { String(format: "%g", $0) } ?? "-") }
                    .width(60)
                TableColumn("Offset") { row in cell(row, text: row.profile.offset.map { String(format: "%g", $0) } ?? "-") }
                    .width(60)
                TableColumn("Bias (ADU)") { row in cell(row, text: row.profile.biasLevelADU.map { String(format: "%.0f", $0) } ?? "n/a") }
                    .width(90)
                TableColumn("Leolvasási zaj (e⁻)") { row in cell(row, text: row.profile.readNoiseE.map { String(format: "%.2f", $0) } ?? "n/a") }
                    .width(130)
                TableColumn("Dark (e⁻/s)") { row in cell(row, text: row.profile.darkRateEPerS.map { String(format: "%.4f", $0) } ?? "n/a") }
                    .width(100)
                TableColumn("Dark hőm. (°C)") { row in cell(row, text: row.profile.darkTempC.map { String(format: "%.1f", $0) } ?? "-") }
                    .width(100)
                TableColumn("EGAIN") { row in cell(row, text: row.profile.egain.map { String(format: "%.3f", $0) } ?? "n/a") }
                    .width(80)
                TableColumn("Mért") { row in
                    cell(row, text: Self.dateFormatter.string(from: Date(timeIntervalSince1970: row.profile.measuredAt)))
                }
                .width(90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

            if rows.contains(where: { isStale($0.profile) }) {
                Text("Újramérés javasolt — a leolvasási zaj becslő javult.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
