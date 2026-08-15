import AstroApplication
import Charts
import SwiftUI

/// V2's "Sensor Profiles" screen: the read-only measured-history list
/// (`SensorProfilesStore.load`/`snapshot`) plus, unlike the classic-only
/// state this used to be stuck in, a real "Measure Sensors…" flow that runs
/// `SensorMeasurementCommand` through `OperationHost` -- progress, cancel,
/// and a refreshed list are all wired the same way any other V2 background
/// job works. Missing-profile combos (lights with no usable measured
/// profile yet) surface as their own warning section, and each profile row
/// exposes its measurement history as a small Swift Charts sparkline.
public struct SensorProfilesView: View {
    let rootURL: URL
    @State private var store = SensorProfilesStore()
    @State private var showsMeasureSheet = false
    @Environment(OperationHost.self) private var operationHost

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sensor").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Sensor Profiles").font(.title2.bold())
                    Text("Measured camera behavior from the local index.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Measure Sensors…") { showsMeasureSheet = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("v2.sensor-profiles.measure")
            }.padding(20)
            Divider()
            Group {
                if store.isLoading { ProgressView("Reading sensor measurements…") }
                else if let snapshot = store.snapshot, !snapshot.profiles.isEmpty {
                    List {
                        if !snapshot.missingCombos.isEmpty {
                            Section("Missing measurements") {
                                ForEach(snapshot.missingCombos) { combo in
                                    missingComboRow(combo)
                                }
                            }
                            .accessibilityIdentifier("v2.sensor-profiles.missing-combos")
                        }
                        Section("Measured profiles") {
                            ForEach(snapshot.profiles) { profile in
                                profileRow(profile)
                            }
                        }
                    }
                } else if let snapshot = store.snapshot {
                    ContentUnavailableView {
                        Label("No sensor measurements yet", systemImage: "sensor")
                    } description: {
                        Text("Run \"Measure Sensors…\" to derive bias level, read noise, dark current, and EGAIN from this library's tracked BIAS/DARK frames.")
                    } actions: {
                        Button("Measure Sensors…") { showsMeasureSheet = true }
                            .buttonStyle(.borderedProminent)
                        if !snapshot.missingCombos.isEmpty {
                            Text("\(snapshot.missingCombos.count) camera/gain/offset combo(s) in this library have no usable measurement.")
                                .font(.caption).foregroundStyle(AstroTokens.Color.warning)
                        }
                    }
                } else {
                    ContentUnavailableView("Profiles unavailable", systemImage: "exclamationmark.triangle", description: Text(store.errorMessage ?? "The index could not be read."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Label("Measurement writes only to this library's own index database, never to the image library itself.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 820, minHeight: 520).background(.background)
        .task { await store.load(rootURL: rootURL) }
        .sheet(isPresented: $showsMeasureSheet) {
            SensorMeasureConfirmSheet(store: store, operationHost: operationHost, dismiss: { showsMeasureSheet = false })
        }
        // Wave 3 Task 7: the Actions menu's "Measure Sensors" -- runs the
        // measurement straight through `OperationHost`, the same
        // "skip the confirm sheet" shortcut the menu bar's Rescan/Run Audit
        // items already give (this view's own button still opens the
        // explanatory confirm sheet first).
        .focusedSceneValue(
            \.sensorMeasure,
            SensorMeasureCommand(
                isAvailable: true,
                action: { Task { await store.measure(operationHost: operationHost) } }
            )
        )
        .accessibilityIdentifier("v2.sensor-profiles")
    }

    private func missingComboRow(_ combo: MissingSensorProfileCombo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AstroTokens.Color.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(comboText(camera: combo.camera, gain: combo.gain, offset: combo.offset)).font(.body.bold())
                Text("Light frames use this combo, but no usable sensor profile is on record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func profileRow(_ profile: SensorProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(comboText(camera: profile.camera, gain: profile.gain, offset: profile.offset)).font(.headline)
                if profile.isEstimatorStale {
                    Text("Stale").font(.caption2.bold()).foregroundStyle(AstroTokens.Color.warning)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(AstroTokens.Color.warning.opacity(0.15)))
                }
                Spacer()
                Text(profile.measuredAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                value("Bias ADU", profile.biasLevelADU)
                value("Read noise e⁻", profile.readNoiseElectrons)
                value("Dark e⁻/s", profile.darkRateElectronsPerSecond)
                value("Temp °C", profile.darkTemperatureCelsius)
                value("EGAIN", profile.electronsPerADU)
            }
            HStack(alignment: .top, spacing: 24) {
                Text("\(profile.frameCount) calibration frames").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if profile.history.count >= 2 {
                    historySparkline(profile.history)
                }
            }
        }.padding(.vertical, 8)
    }

    private func historySparkline(_ history: [SensorProfileHistoryPoint]) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Read noise history").font(.caption2).foregroundStyle(.secondary)
            Chart(history) { point in
                LineMark(x: .value("Measured", point.measuredAt), y: .value("Read noise e⁻", point.readNoiseElectrons ?? 0))
                    .foregroundStyle(.blue)
                PointMark(x: .value("Measured", point.measuredAt), y: .value("Read noise e⁻", point.readNoiseElectrons ?? 0))
                    .foregroundStyle(.blue)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(width: 140, height: 36)
            .accessibilityIdentifier("v2.sensor-profiles.history-chart")
        }
    }

    private func comboText(camera: String, gain: Double?, offset: Double?) -> String {
        let gainText = gain.map { String(format: "%g", $0) } ?? "—"
        let offsetText = offset.map { String(format: "%g", $0) } ?? "—"
        return "\(camera) · gain \(gainText) · offset \(offsetText)"
    }

    private func value(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.formatted(.number.precision(.fractionLength(0...3))) ?? "—").font(.headline)
        }
    }
}

/// "Measure Sensors…" confirmation sheet: explains what the operation reads
/// and writes, then, only on explicit confirmation, runs
/// `SensorProfilesStore.measure(operationHost:)`. While it runs, this shows
/// live progress and a Cancel button sourced straight from `OperationHost`
/// -- the same backbone the global toolbar's `OperationStatusView` already
/// surfaces, just inline here too since the sheet is already open.
private struct SensorMeasureConfirmSheet: View {
    let store: SensorProfilesStore
    let operationHost: OperationHost
    let dismiss: () -> Void
    @State private var started = false

    private var runningOperation: OperationHost.ActiveOperation? {
        operationHost.activeOperations.first { if case .sensorMeasurement = $0.kind { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure Sensors").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Reads this library's tracked BIAS/DARK frames per camera/gain/offset combo, and derives bias level, read noise, dark current, and EGAIN.")
                Text("Takes roughly a few seconds per combo.")
                Text("Every measurement joins the append-only history; the newest becomes the current profile. The image library itself is never touched.")
                    .bold()
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if started {
                HStack(spacing: 8) {
                    if let runningOperation {
                        ProgressView().controlSize(.small)
                        Text("Measuring… \(runningOperation.completed) combo(s) so far").foregroundStyle(.secondary)
                        Button("Cancel") { Task { await operationHost.cancel(id: runningOperation.id) } }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("v2.sensor-profiles.measure-cancel")
                    } else {
                        Text("Measurement finished. \(store.snapshot?.profiles.count ?? 0) profile(s) on record.")
                            .foregroundStyle(AstroTokens.Color.success)
                    }
                }
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage).foregroundStyle(AstroTokens.Color.danger)
            }

            HStack {
                Spacer()
                Button(started && runningOperation == nil ? "Close" : "Cancel") { dismiss() }
                if !started {
                    Button("Start Measurement") {
                        started = true
                        Task { await store.measure(operationHost: operationHost) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("v2.sensor-profiles.measure-start")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 220)
        .accessibilityIdentifier("v2.sensor-profiles.measure-sheet")
    }
}
