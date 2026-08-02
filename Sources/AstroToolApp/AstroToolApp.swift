import SwiftUI

@main
struct AstroToolApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appState.resolveRootOnLaunch()
                }
        }
    }
}

/// Switches between the guidance screen (`AccessDeniedView`, for a TCC
/// problem or an unmounted volume) and the normal six-tab UI, based on
/// `AppState.rootStatus`.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: AppTab = .overview

    var body: some View {
        switch appState.rootStatus {
        case .accessDenied, .notMounted:
            AccessDeniedView(status: appState.rootStatus) {
                appState.retryRootAccess()
            }
        case .noRoot, .notScanned, .ok:
            TabView(selection: $selectedTab) {
                OverviewView(selectedTab: $selectedTab)
                    .tabItem { Label("Áttekintés", systemImage: "house") }
                    .tag(AppTab.overview)

                AuditView()
                    .tabItem { Label("Audit", systemImage: "checkmark.shield") }
                    .tag(AppTab.audit)

                QualityView()
                    .tabItem { Label("Minőség", systemImage: "star") }
                    .tag(AppTab.quality)

                CalibrationView()
                    .tabItem { Label("Kalibráció", systemImage: "thermometer") }
                    .tag(AppTab.calibration)

                StatsView()
                    .tabItem { Label("Statisztika", systemImage: "chart.bar") }
                    .tag(AppTab.stats)

                SettingsView()
                    .tabItem { Label("Beállítások", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
        }
    }
}
