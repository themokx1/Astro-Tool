import AppKit
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
    /// R11-T16/F20: `astrobin.filterIds` draft -- see `astrobinExportSection`.
    @State private var astrobinFilterIds: [String: Int] = [:]
    @State private var newAstrobinFilterName: String = ""
    @State private var newAstrobinFilterID: String = ""

    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showResetConfirm = false

    private let defaults = AstroConfig()

    var body: some View {
        @Bindable var appState = appState

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

                // R11-T9/F5: opt-in, default OFF -- a live toggle (no
                // "Mentés" needed, same "takes effect immediately" shape
                // `QualitySegment`'s own `@AppStorage`-backed toggle uses),
                // since `AppState.autoScanOnMount` round-trips straight to
                // `UserDefaults` on every write, unlike this tab's
                // `excludedDirNames`/`excludedPaths` draft below (those are
                // library-shape config, checked into `config.json`).
                Toggle("Automatikus beolvasás kötet csatlakozásakor", isOn: $appState.autoScanOnMount)
                Text("Ha be van kapcsolva, a beolvasás automatikusan elindul, amikor a kötet csatlakozik és a gyökér elérhetővé válik (csak ha épp nem fut más művelet).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // V3 pre-stack program, section 5.1 (Ingest-figyelő): a
                // MÁSIK, külön kapcsoló -- ez a V2 Home-kártyát vezérli
                // (`IngestWatcher`, `Sources/AstroUI/Features/Library/
                // IngestWatcher.swift`), nem ezt a beolvasást. Ugyanaz a
                // "sima UserDefaults boolean, alapból KI" minta, mint az
                // `autoScanOnMount`-é fentebb -- lásd `AppState
                // .ingestWatcherEnabled`'s doc komment.
                Toggle("Ingest-figyelő (kártya-előretöltés a Home oldalon)", isOn: $appState.ingestWatcherEnabled)
                Text("Ha be van kapcsolva, egy új memóriakártya vagy hálózati megosztás csatlakozásakor a Home oldal felajánlja az import varázslót, már kitöltött burst-csoportokkal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // V3 pre-stack program, section 5.6 (Élő éjszaka-mód): egy
                // HARMADIK, külön kapcsoló -- ez a V2 Home élő-kártyáját
                // vezérli (`LiveNightWatcher`, `Sources/AstroUI/Features/
                // LiveNight/LiveNightWatcher.swift`), nem az `autoScanOnMount`
                // vagy az `ingestWatcherEnabled` beolvasás/import útvonalait.
                // Ugyanaz a "sima UserDefaults boolean, alapból KI" minta.
                Toggle("Élő éjszaka-figyelő (élő kártya a Home oldalon)", isOn: $appState.liveNightWatcherEnabled)
                Text("Ha be van kapcsolva, a Home oldal élőben mutatja egy figyelt mappa keretszámlálóját, egy közelítő FWHM-et és a cél-teljesítés becslését, amíg a rig éjszaka fényez. Csak akkor figyel, ha az AstroTool éppen fut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Figyelt mappa kiválasztása…") { appState.chooseLiveNightFolder() }
                    if let path = appState.liveNightWatchFolderDisplayPath {
                        Text(path).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Nincs mappa kiválasztva").font(.caption).foregroundStyle(.secondary)
                    }
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

            Section("AstroBin export") {
                SettingsResetRow(
                    isModified: astrobinFilterIds != defaults.astrobin.filterIds,
                    caption: "Szűrőnév → AstroBin equipment-adatbázis filter-ID. Leképezett szűrőnél az export ID-t ír, egyébként a szűrő neve marad (+ figyelmeztetés).",
                    reset: { astrobinFilterIds = defaults.astrobin.filterIds }
                ) {
                    astrobinFilterIdsList
                }
            }

            Section("Beállítóvarázsló") {
                Button("Onboarding újraindítása…") {
                    appState.requestOnboarding()
                    NSApp.keyWindow?.performClose(nil)
                }
                Text("Újra végigvezet a helyszín, setupok, szűrők, minőség és integrációs referencia oldalain. Minden oldal ismét kihagyható.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onAppear {
            loadFromConfig()
            appState.loadUsedUnmappedAstroBinFilters()
        }
        // R10 review (item 17): clears stale save feedback the moment a
        // fresh edit re-dirties the draft -- see `LocationSettingsView`'s
        // identical modifier for the full "only false -> true" reasoning.
        .onChange(of: isDirty) { _, newValue in
            if newValue {
                saveMessage = nil
                saveError = nil
            }
        }
        .confirmationDialog(
            "Biztosan alaphelyzetbe állítod a Könyvtár beállításokat?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Alaphelyzetbe állítás", role: .destructive) {
                excludedDirNames = defaults.excludedDirNames
                excludedPaths = defaults.excludedPaths
                astrobinFilterIds = defaults.astrobin.filterIds
            }
        }
    }

    // MARK: - AstroBin export (R11-T16/F20)

    /// Key-value list-editor for `astrobin.filterIds` -- szűrőnév + numerikus
    /// ID soronként, törlés gombbal, "+ sor" az új sorhoz. Sorted by filter
    /// name so the list doesn't reorder itself as entries are added/removed
    /// (a `[String: Int]` has no order of its own) -- same convention
    /// `LibraryRulesSettingsView.wideFieldOverridesList` already uses for
    /// its own dictionary-backed list.
    private var astrobinFilterIdsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link("Az ID-t az AstroBin equipment-adatbázisából keresd ki →", destination: astrobinEquipmentExplorerURL)
                .font(.caption)

            if !appState.usedUnmappedAstroBinFilters.isEmpty {
                Text("Használt, még nem leképezett szűrők")
                    .font(.caption.bold())
                    .padding(.top, 4)
                ForEach(appState.usedUnmappedAstroBinFilters, id: \.self) { filter in
                    HStack {
                        Text(filter)
                        Spacer()
                        Button("ID megadása") {
                            newAstrobinFilterName = filter
                            newAstrobinFilterID = ""
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if astrobinFilterIds.isEmpty {
                Text("Nincs leképezett szűrő -- az export minden szűrőnevet nyersen ír ki.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(astrobinFilterIds.keys.sorted(), id: \.self) { filterName in
                    HStack {
                        Text(filterName)
                        Spacer()
                        Text("\(astrobinFilterIds[filterName] ?? 0)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            astrobinFilterIds.removeValue(forKey: filterName)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("Szűrő neve (pl. Ha)", text: $newAstrobinFilterName)
                TextField("ID", text: $newAstrobinFilterID)
                    .frame(width: 70)
                Button("+ sor", action: addAstrobinFilterRow)
                    .disabled(
                        newAstrobinFilterName.trimmingCharacters(in: .whitespaces).isEmpty
                            || Int(newAstrobinFilterID.trimmingCharacters(in: .whitespaces)) == nil
                    )
            }
        }
    }

    private var astrobinEquipmentExplorerURL: URL {
        URL(string: "https://app.astrobin.com/equipment/explorer/filter")!
    }

    private func addAstrobinFilterRow() {
        let name = newAstrobinFilterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = Int(newAstrobinFilterID.trimmingCharacters(in: .whitespaces)) else { return }
        var rule = AstroBinRule(filterIds: astrobinFilterIds)
        rule.setFilterID(id, for: name)
        astrobinFilterIds = rule.filterIds
        newAstrobinFilterName = ""
        newAstrobinFilterID = ""
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés -- true
    /// whenever the draft differs from what's actually loaded/saved in
    /// `appState.config` (as opposed to `SettingsResetRow`'s per-field
    /// `isModified`, which compares against `AstroConfig()` DEFAULTS above
    /// -- a different question: "did I change this from factory" vs. "do I
    /// have unsaved edits right now").
    private var isDirty: Bool {
        excludedDirNames != appState.config.excludedDirNames
            || excludedPaths != appState.config.excludedPaths
            || astrobinFilterIds != appState.config.astrobin.filterIds
    }

    private func loadFromConfig() {
        excludedDirNames = appState.config.excludedDirNames
        excludedPaths = appState.config.excludedPaths
        astrobinFilterIds = appState.config.astrobin.filterIds
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.excludedDirNames = excludedDirNames
        newConfig.excludedPaths = excludedPaths
        var normalizedRule = AstroBinRule()
        for key in astrobinFilterIds.keys.sorted() where normalizedRule.filterID(for: key) == nil {
            normalizedRule.setFilterID(astrobinFilterIds[key] ?? 0, for: key)
        }
        newConfig.astrobin = normalizedRule

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            appState.loadUsedUnmappedAstroBinFilters()
            saveMessage = "Mentve."
        } catch let error as AstroError {
            saveError = describeSettingsError(error)
        } catch {
            saveError = "\(error)"
        }
    }
}
