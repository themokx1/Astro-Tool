import AstroCore
import SwiftUI

/// A scalable macOS Settings window. The sidebar keeps seven product areas
/// understandable without compressing them into a toolbar-sized tab strip;
/// existing deep links continue to route through `AppState.settingsTab`.
struct SettingsWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            List(selection: $appState.settingsTab) {
                Section {
                    settingsRow("Általános", symbol: "gearshape", tab: .general)
                }
                Section("KÖNYVTÁR") {
                    settingsRow("Könyvtár", symbol: "externaldrive", tab: .library)
                    settingsRow("Könyvtár-szabályok", symbol: "line.3.horizontal.decrease.circle", tab: .libraryRules)
                }
                Section("MEGFIGYELÉS") {
                    settingsRow("Helyszínek", symbol: "location", tab: .location)
                    settingsRow("Felszerelések", symbol: "camera.aperture", tab: .equipment)
                    settingsRow("Szűrők", symbol: "camera.filters", tab: .filters)
                    settingsRow("Minőség", symbol: "waveform.path.ecg", tab: .rating)
                    settingsRow("Kalibráció", symbol: "thermometer", tab: .calibration)
                }
                Section("SEGÍTSÉG") {
                    settingsRow("Adatvédelem és támogatás", symbol: "lock.shield", tab: .support)
                }
            }
            .navigationTitle("Beállítások")
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                ProductSectionHeader(title: title(for: appState.settingsTab), detail: detail(for: appState.settingsTab))
                    .padding(.horizontal, ProductMetrics.spacious)
                    .padding(.vertical, ProductMetrics.section)
                Divider()
                settingsDetail(appState.settingsTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 640)
    }

    private func settingsRow(_ title: String, symbol: String, tab: AppState.SettingsTab) -> some View {
        Label(title, systemImage: symbol).tag(tab)
    }

    @ViewBuilder
    private func settingsDetail(_ tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .library: LibrarySettingsView()
        case .location: LocationSettingsView()
        case .equipment: EquipmentSettingsView()
        case .filters: FilterProfilesPage()
        case .calibration: CalibrationSettingsView()
        case .rating: RatingSettingsView()
        case .libraryRules: LibraryRulesSettingsView()
        case .support: SupportSettingsView()
        }
    }

    private func title(for tab: AppState.SettingsTab) -> String {
        switch tab {
        case .general: "Általános"
        case .library: "Könyvtár"
        case .location: "Helyszínek"
        case .equipment: "Felszerelések"
        case .filters: "Szűrők"
        case .calibration: "Kalibráció"
        case .rating: "Minőség és expozíció"
        case .libraryRules: "Könyvtár-szabályok"
        case .support: "Adatvédelem és támogatás"
        }
    }

    private func detail(for tab: AppState.SettingsTab) -> String? {
        switch tab {
        case .general: "Az AstroTool alapvető működése és első lépései."
        case .library: "Könyvtárváltás, kizárások és exportkapcsolatok."
        case .location: "Tervezési helyszínek és opcionális időjárás."
        case .equipment: "Kamerák, szenzorok és optikák a látómezőhöz."
        case .filters: "Újrahasználható szűrőtár minden capture-höz."
        case .calibration: "Dark, flat és egyéb illesztési szabályok."
        case .rating: "Keretpontozás, Siril és expozíciós küszöbök."
        case .libraryRules: "Felismerési és munkafolyamat-konvenciók."
        case .support: "Helyi adatkezelés, verzió és biztonságos diagnosztika."
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("AstroTool") {
                LabeledContent("Verzió", value: ProductInfo.displayVersion)
                LabeledContent("Könyvtár", value: appState.config.rootPath.isEmpty ? "Nincs kiválasztva" : appState.config.rootPath)
                Button("Képkönyvtár kiválasztása…") { appState.chooseRoot() }
            }
            Section("Indulás") {
                Toggle("Automatikus beolvasás kötet csatlakozásakor", isOn: Binding(
                    get: { appState.autoScanOnMount },
                    set: { appState.autoScanOnMount = $0 }
                ))
                Button("Részletes személyre szabás…") { appState.requestOnboarding() }
                Text("A részletes beállítás minden oldala kihagyható, és nem hoz létre minta-felszerelést.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
