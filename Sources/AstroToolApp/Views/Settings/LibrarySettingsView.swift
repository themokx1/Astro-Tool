import AstroCore
import Foundation
import SwiftUI

/// Settings ▸ "Könyvtár" tab (R9-T5/A.7/B12 rebuild of the old, 2-field
/// `SettingsView`): the root path picker + recent roots + config.json
/// reveal, and `excludedDirNames`/`excludedPaths` as editable `List`s
/// (+/−) instead of a single comma-joined `TextField` -- the old
/// representation silently dropped a name containing a comma and made
/// reviewing a long list unreadable.
struct LibrarySettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var excludedDirNames: [String] = []
    @State private var excludedPaths: [String] = []

    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showResetConfirm = false

    private let defaults = AstroConfig()

    var body: some View {
        Form {
            Section("Gyökér") {
                LabeledContent("Útvonal", value: appState.config.rootPath)
                HStack {
                    Button("Mappa választása…") { appState.chooseRoot() }
                    if !appState.recentRoots.isEmpty {
                        Menu("Legutóbbi könyvtárak") {
                            ForEach(appState.recentRoots) { recent in
                                Button(URL(fileURLWithPath: recent.path, isDirectory: true).lastPathComponent) {
                                    appState.selectRecentRoot(recent)
                                }
                            }
                        }
                    }
                    Button("config.json megjelenítése") { appState.revealConfigInFinder() }
                }
            }

            Section("Kizárások") {
                SettingsResetRow(
                    isModified: excludedDirNames != defaults.excludedDirNames,
                    caption: "Ezekkel a nevekkel egyező mappák teljesen kihagyva a beolvasásból.",
                    reset: { excludedDirNames = defaults.excludedDirNames }
                ) {
                    EditableStringListView(title: "Kizárt mappanevek", items: $excludedDirNames)
                }

                SettingsResetRow(
                    isModified: excludedPaths != defaults.excludedPaths,
                    caption: "Gyökér-relatív útvonalak, az excludedDirNames-en felül.",
                    reset: { excludedPaths = defaults.excludedPaths }
                ) {
                    EditableStringListView(title: "Kizárt útvonalak", items: $excludedPaths)
                }
            }

            Section {
                HStack {
                    Button("Alaphelyzetbe állítás…") { showResetConfirm = true }
                    Spacer()
                    if isDirty {
                        Text("Nem mentett módosítások").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Mentés") { save() }
                    if let saveMessage {
                        Text(saveMessage).foregroundStyle(.green)
                    }
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadFromConfig() }
        .confirmationDialog(
            "Biztosan alaphelyzetbe állítod a Könyvtár beállításokat?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Alaphelyzetbe állítás", role: .destructive) {
                excludedDirNames = defaults.excludedDirNames
                excludedPaths = defaults.excludedPaths
            }
        }
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés -- true
    /// whenever the draft differs from what's actually loaded/saved in
    /// `appState.config` (as opposed to `SettingsResetRow`'s per-field
    /// `isModified`, which compares against `AstroConfig()` DEFAULTS above
    /// -- a different question: "did I change this from factory" vs. "do I
    /// have unsaved edits right now").
    private var isDirty: Bool {
        excludedDirNames != appState.config.excludedDirNames || excludedPaths != appState.config.excludedPaths
    }

    private func loadFromConfig() {
        excludedDirNames = appState.config.excludedDirNames
        excludedPaths = appState.config.excludedPaths
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.excludedDirNames = excludedDirNames
        newConfig.excludedPaths = excludedPaths

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            saveMessage = "Mentve."
        } catch let error as AstroError {
            saveError = describeSettingsError(error)
        } catch {
            saveError = "\(error)"
        }
    }
}
