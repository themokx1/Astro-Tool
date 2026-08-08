import AstroCore
import Charts
import SwiftUI

/// R9-T5/A.6 -- full rebuild of the "eltemetett oldal" the review flagged:
/// 3 header tiles, a permanent "mire jó?" explainer (so this page's own
/// purpose is visible without reading docs), the profile list with a
/// staleness warning for anything measured with an outdated estimator, and
/// a confirm-first "Szenzor mérése…" (A.10 rename from bare "Mérés") that
/// spells out what it reads, how long it takes, and that it only ever
/// writes to this library's own database.
///
/// R11-T10/F8: staleness is now `SensorProfileRecord.isEstimatorStale`
/// (estimator_version-based, generalizing the earlier hardcoded 2026-08-05
/// fix-date check), and each row is a `DisclosureGroup` that expands into
/// its full measurement history (`AppState.sensorProfileHistoryByCombo`)
/// plus two mini sparklines (read noise, dark rate over time).
struct SensorPage: View {
    @Environment(AppState.self) private var appState
    @State private var showMeasureSheet = false

    private var profiles: [SensorProfileRecord] { appState.sensorProfiles }
    private var distinctCameraCount: Int { Set(profiles.map(\.camera)).count }
    // R10 review (item 20): TILES use "n/a" for a missing value, not "-"
    // -- see `TDFormat`'s doc comment for the full rule. This tile can
    // only ever be reached with `profiles` non-empty (the `emptyState`
    // branch below covers that case instead), so `-` was unreachable in
    // practice, but the fallback should still say the right thing.
    private var latestMeasurementText: String {
        guard let latest = profiles.map(\.measuredAt).max() else { return TDFormat.missingTile }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: latest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if profiles.isEmpty {
                emptyState
            } else {
                tiles
                explainerBlock

                SensorProfileList(profiles: profiles, historyByCombo: appState.sensorProfileHistoryByCombo)
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
/// every measurement joins the append-only history and becomes the new
/// "latest" per combo (R11-T10/F8), and roughly how long it takes -- then,
/// only on explicit confirmation, runs the existing
/// `AppState.measureSensorProfiles()`.
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
                Text("Minden mérés bekerül a mérés-történetbe; a legfrissebb lesz az érvényes. A könyvtárhoz nem nyúl.")
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

/// Read-only, expandable list of measured sensor profiles (R7-B1 item C) --
/// one row per `(camera, gain, offset)` combo, bias level/read noise/dark
/// rate/EGAIN as measured by `SensorProfiler.measure`. R9-T5/A.6 added the
/// `Mért` column and a freshness warning; R11-T10/F8 replaces the fixed
/// `Table` with a `List` of `DisclosureGroup`s (a `Table` has no per-row
/// expansion of its own) so each combo's full measurement history + two
/// mini sparklines (read noise, dark rate) are one click away, and swaps
/// the hardcoded fix-date staleness check for `SensorProfileRecord
/// .isEstimatorStale`. Never edits anything itself; the "Szenzor mérése…"
/// button that actually runs a measurement lives on `SensorPage` above this.
struct SensorProfileList: View {
    let profiles: [SensorProfileRecord]
    let historyByCombo: [String: [SensorProfileHistoryRecord]]

    private var sortedProfiles: [SensorProfileRecord] {
        profiles.sorted { lhs, rhs in
            if lhs.camera != rhs.camera { return lhs.camera < rhs.camera }
            return (lhs.gain ?? -.infinity) < (rhs.gain ?? -.infinity)
        }
    }

    private func history(for profile: SensorProfileRecord) -> [SensorProfileHistoryRecord] {
        historyByCombo[profile.comboKey] ?? []
    }

    /// D32: this list's computed-metric columns, explained -- same
    /// "one button per table" `MetricInfoButton` pattern the target-detail
    /// segments already established. Explicitly covers the "mikor hazudik"
    /// caveats `SensorProfiler.measure`'s own doc comments call out.
    private static let metricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Leolvasási zaj (e⁻)",
            explanation: "Két BIAS-keret különbségének szórásából számolt zaj, elektronra váltva az EGAIN-nel. Mikor hazudik: „-” ha kevesebb, mint 2 BIAS-keret van ehhez a kombóhoz, vagy nincs EGAIN; egyetlen rossz/kozmikus-sugár-foltos BIAS-pár is elronthatja."
        ),
        .init(
            title: "Dark (e⁻/s)",
            explanation: "A DARK-keret és a BIAS-szint különbsége elektron/másodpercre normálva. Mikor hazudik: „-” EGAIN vagy DARK-keret nélkül; hőmérséklet-függő, egy másik szenzor-hőfokon mért dark-áram nem ugyanaz."
        ),
        .init(
            title: "EGAIN",
            explanation: "Elektron/ADU átváltási tényező, a FITS-fejlécből (EGAIN kulcs) vagy a BIAS-keretek szórásából becsülve. Mikor hazudik: „-” ha sem a fejléc, sem a becslés nem ad értéket; egy hibás gain-beállítás a kamerán ezt is elcsúsztatja."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                MetricInfoButton(metrics: Self.metricInfo)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(sortedProfiles, id: \.comboKey) { profile in
                    DisclosureGroup {
                        SensorHistoryDetail(history: history(for: profile))
                            .padding(.leading, 8)
                            .padding(.vertical, 6)
                    } label: {
                        SensorProfileRow(profile: profile)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(profile.isEstimatorStale ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.05))
                    )
                }
            }

            if sortedProfiles.contains(where: \.isEstimatorStale) {
                Text("Újramérés javasolt — a mérés-becslő verziója elavult (\(SensorProfiler.estimatorVersion)-nél régebbi vagy ismeretlen).")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One profile's `DisclosureGroup` label -- the same fields the old `Table`
/// showed, laid out as a two-line card instead of fixed table columns
/// (a `DisclosureGroup` label has no column grid of its own to slot into).
private struct SensorProfileRow: View {
    let profile: SensorProfileRecord

    private var comboText: String {
        let gainText = TDFormat.cell(profile.gain.map { String(format: "%g", $0) })
        let offsetText = TDFormat.cell(profile.offset.map { String(format: "%g", $0) })
        return "\(profile.camera) · gain \(gainText) · offset \(offsetText)"
    }

    private var biasText: String { TDFormat.cell(profile.biasLevelADU.map { String(format: "%.0f ADU", $0) }) }
    private var readNoiseText: String { TDFormat.cell(profile.readNoiseE.map { String(format: "%.2f e⁻", $0) }) }
    private var darkText: String {
        guard let darkRate = profile.darkRateEPerS else { return TDFormat.missingCell }
        let tempText = profile.darkTempC.map { String(format: "%.1f°C", $0) } ?? "?"
        return String(format: "%.4f e⁻/s (%@)", darkRate, tempText)
    }
    private var egainText: String { TDFormat.cell(profile.egain.map { String(format: "%.3f", $0) }) }
    private var measuredText: String { Self.dateFormatter.string(from: Date(timeIntervalSince1970: profile.measuredAt)) }
    private var estimatorVersionText: String {
        profile.estimatorVersion.map { "becslő v\($0)" } ?? "becslő: ismeretlen"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comboText).font(.body.bold())
                if profile.isEstimatorStale {
                    Text("elavult").font(.caption2.bold()).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
                Spacer()
                Text("Mért: \(measuredText) · \(estimatorVersionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("Bias: \(biasText)")
                Text("Leolvasási zaj: \(readNoiseText)")
                Text("Dark: \(darkText)")
                Text("EGAIN: \(egainText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One profile's expanded history -- oldest-first entries (date, read
/// noise, dark rate, estimator version) plus two mini sparklines. `history`
/// is `Database.sensorProfileHistory`'s own ascending order.
private struct SensorHistoryDetail: View {
    let history: [SensorProfileHistoryRecord]

    var body: some View {
        if history.isEmpty {
            Text("Nincs mérés-történet ehhez a kombóhoz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 20) {
                    Sparkline(title: "Leolvasási zaj (e⁻)", values: history.map(\.readNoiseE))
                    Sparkline(title: "Dark (e⁻/s)", values: history.map(\.darkRateEPerS))
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Newest first for readability -- the sparklines above
                    // stay chronological (oldest first), this is purely the
                    // list's own display order.
                    ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, entry in
                        historyRow(entry)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: SensorProfileHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: entry.measuredAt)))
                .frame(width: 84, alignment: .leading)
            Text("zaj \(TDFormat.cell(entry.readNoiseE.map { String(format: "%.2f e⁻", $0) }))")
                .frame(width: 120, alignment: .leading)
            Text("dark \(TDFormat.cell(entry.darkRateEPerS.map { String(format: "%.4f e⁻/s", $0) }))")
                .frame(width: 150, alignment: .leading)
            Text(entry.estimatorVersion.map { "becslő v\($0)" } ?? "becslő: ismeretlen")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// A tiny, axis-less line+point chart over one metric's history values --
/// `nil` entries (not every measurement derives every metric, see
/// `SensorProfileHistoryRecord`'s own doc comment) are simply skipped
/// rather than plotted as zero.
private struct Sparkline: View {
    let title: String
    let values: [Double?]

    private struct Point: Identifiable {
        let index: Int
        let value: Double
        var id: Int { index }
    }

    private var points: [Point] {
        values.enumerated().compactMap { index, value in value.map { Point(index: index, value: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if points.count < 2 {
                Text(TDFormat.missingCell).font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 110, height: 28, alignment: .leading)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Mérés", point.index), y: .value(title, point.value))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Mérés", point.index), y: .value(title, point.value))
                        .foregroundStyle(Color.accentColor)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(width: 110, height: 28)
            }
        }
    }
}
