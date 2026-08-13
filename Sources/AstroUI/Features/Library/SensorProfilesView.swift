import AstroApplication
import SwiftUI

@MainActor @Observable
private final class SensorProfilesStore {
    var snapshot: SensorProfilesSnapshot?
    var isLoading = false
    var errorMessage: String?
    func load(rootURL: URL) async {
        isLoading = true; defer { isLoading = false }
        do { snapshot = try await SensorProfilesQuery.production(rootURL: rootURL).snapshot() }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct SensorProfilesView: View {
    let rootURL: URL
    let dismiss: () -> Void
    @State private var store = SensorProfilesStore()

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sensor").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Sensor Profiles").font(.title2.bold())
                    Text("Measured camera behavior from the local index.").foregroundStyle(.secondary)
                }
                Spacer(); Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            Group {
                if store.isLoading { ProgressView("Reading sensor measurements…") }
                else if let snapshot = store.snapshot, !snapshot.profiles.isEmpty {
                    List(snapshot.profiles) { profile in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(profile.camera).font(.headline)
                                Spacer(); Text(profile.measuredAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 18) {
                                value("Gain", profile.gain)
                                value("Offset", profile.offset)
                                value("Read noise e⁻", profile.readNoiseElectrons)
                                value("Bias ADU", profile.biasLevelADU)
                                value("Dark e⁻/s", profile.darkRateElectronsPerSecond)
                                value("Temp °C", profile.darkTemperatureCelsius)
                            }
                            Text("\(profile.frameCount) calibration frames").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                } else if store.snapshot != nil {
                    ContentUnavailableView("No sensor measurements", systemImage: "sensor", description: Text("Run sensor measurement in the classic workflow or CLI; V2 will display the resulting history here."))
                } else {
                    ContentUnavailableView("Profiles unavailable", systemImage: "exclamationmark.triangle", description: Text(store.errorMessage ?? "The index could not be read."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Label("Read-only history · measurement acquisition is not enabled in V2 yet", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 820, minHeight: 520).background(.background)
        .task { await store.load(rootURL: rootURL) }
        .accessibilityIdentifier("v2.sensor-profiles")
    }

    private func value(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.formatted(.number.precision(.fractionLength(0...3))) ?? "—").font(.headline)
        }
    }
}
