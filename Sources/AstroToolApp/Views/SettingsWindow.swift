import SwiftUI

/// The `Settings { }` scene's content (R9-T1 spec: Beállítások moves out of
/// the sidebar/tabs into the standard macOS Settings window, ⌘,). Content
/// is `SettingsView`, moved here unchanged -- T5 rebuilds it in full.
struct SettingsWindow: View {
    var body: some View {
        SettingsView()
    }
}
