import SwiftUI

/// The `Settings { }` scene's content (R9-T1 spec: Beállítások moves out of
/// the sidebar/tabs into the standard macOS Settings window, ⌘,). R9-T4/B10
/// adds the "Helyszín" tab now (additively, ahead of T5's full per-spec
/// rebuild of the other four A.7 tabs) because the Ma este page's "Helyszín"
/// tile needs somewhere concrete to send its click to. `AppState.
/// settingsTab` is the router -- same "AppState property preselects,
/// `.tag`-based `TabView`/`List` selection reads it" pattern `currentPage`/
/// `auditSegment` already use, needed here because a `Button` on another
/// page (the "Helyszín" tile) has to land on a SPECIFIC tab of a scene that
/// opens fresh each time, not just "Settings in general".
struct SettingsWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.settingsTab) {
            LibrarySettingsView()
                .tabItem { Text("Könyvtár") }
                .tag(AppState.SettingsTab.library)
            LocationSettingsView()
                .tabItem { Text("Helyszín") }
                .tag(AppState.SettingsTab.location)
            CalibrationSettingsView()
                .tabItem { Text("Kalibráció") }
                .tag(AppState.SettingsTab.calibration)
            RatingSettingsView()
                .tabItem { Text("Pontozás & expozíció") }
                .tag(AppState.SettingsTab.rating)
            LibraryRulesSettingsView()
                .tabItem { Text("Könyvtár-szabályok") }
                .tag(AppState.SettingsTab.libraryRules)
        }
        .frame(width: 560, height: 480)
    }
}
