import AstroCore
import Foundation
import SwiftUI

/// Settings ▸ "Könyvtár-szabályok" tab (R9-T5/A.7/B12, new): every list-of-
/// strings config field that drives the audit/stats engines --
/// `residuePatterns`/`residueDirNames`/`toolOutputDirNames`/
/// `intentional.labels` (+ its 2 toggles) and `wideField.*` -- plus the
/// `stats.*` numeric knobs. Before this task NONE of these were reachable
/// from Settings; the review specifically called out `residuePatterns` (the
/// exact list that decides whether a `.DS_Store`/Siril leftover reads as
/// "gyanús" or "takarítható") as one of the ~33 missing keys.
struct LibraryRulesSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var residuePatterns: [String] = []
    @State private var residueDirNames: [String] = []
    @State private var toolOutputDirNames: [String] = []
    @State private var intentionalLabels: [String] = []
    @State private var runSuffix: Bool = true
    @State private var dateRange: Bool = true
    @State private var wideFieldExtensions: [String] = []
    @State private var wideFieldNameMarkers: [String] = []
    @State private var maxFocalLengthMM: Double = 135
    /// R11-T3/F20: `wideField.overrides` -- per-target manual wide-field/
    /// deep-sky classification, entered via the "Besorolás" context menu
    /// (`AllTargetsPage`/`TargetDetailPage`, `WideFieldClassificationMenu` in
    /// SharedComponents.swift). This tab only ever DISPLAYS + DELETES
    /// entries (spec: "Új felvétel itt nem kell") -- so it can be reviewed/
    /// undone from Settings without hunting down the target that was
    /// overridden.
    @State private var wideFieldOverrides: [String: Bool] = [:]
    @State private var statsExcludeLabels: [String] = []
    @State private var gapThresholdSeconds: Double = 0
    @State private var collectingThresholdSeconds: Double = 7200

    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showResetConfirm = false

    private let defaults = AstroConfig()

    var body: some View {
        Form {
            Section("Residue (takarítható)") {
                SettingsResetRow(
                    isModified: residuePatterns != defaults.residuePatterns,
                    caption: "Glob-minták (pl. *.seq), amik automatikusan \"takarítható\" (nem \"gyanús\") találatnak számítanak.",
                    reset: { residuePatterns = defaults.residuePatterns }
                ) {
                    EditableStringListView(title: "Residue-minták", items: $residuePatterns)
                }
                SettingsResetRow(
                    isModified: residueDirNames != defaults.residueDirNames,
                    caption: "Mappanevek, amik teljes tartalma automatikusan residue-nak számít.",
                    reset: { residueDirNames = defaults.residueDirNames }
                ) {
                    EditableStringListView(title: "Residue mappanevek", items: $residueDirNames)
                }
                SettingsResetRow(
                    isModified: toolOutputDirNames != defaults.toolOutputDirNames,
                    caption: "Ismert kiegészítő-eszköz kimeneti mappái -- az audit nem jelöli gyanúsnak őket.",
                    reset: { toolOutputDirNames = defaults.toolOutputDirNames }
                ) {
                    EditableStringListView(title: "Eszköz-kimenet mappanevek", items: $toolOutputDirNames)
                }
            }

            Section("Szándékos dátum-eltérések") {
                SettingsResetRow(
                    isModified: runSuffix != IntentionalPatterns().runSuffix,
                    caption: "Numerikus run-utótag felismerése, pl. 2026-04-06-2 (ugyanaz az éjszaka, második futás).",
                    reset: { runSuffix = IntentionalPatterns().runSuffix }
                ) {
                    Toggle("Run-utótag felismerése", isOn: $runSuffix)
                }
                SettingsResetRow(
                    isModified: dateRange != IntentionalPatterns().dateRange,
                    caption: "Második, - vagy _ jellel összekapcsolt dátum felismerése (több éjszaka egy mappában).",
                    reset: { dateRange = IntentionalPatterns().dateRange }
                ) {
                    Toggle("Dátum-tartomány felismerése", isOn: $dateRange)
                }
                SettingsResetRow(
                    isModified: intentionalLabels != IntentionalPatterns().labels,
                    caption: "Ismert, informális dátum-mappa utótagok (pl. hibas, OSC).",
                    reset: { intentionalLabels = IntentionalPatterns().labels }
                ) {
                    EditableStringListView(title: "Ismert utótagok", items: $intentionalLabels)
                }
            }

            Section("Wide-field felismerés") {
                SettingsResetRow(
                    isModified: wideFieldExtensions != defaults.wideField.extensions,
                    caption: "Ezekkel a kiterjesztésekkel a fájl wide-field jelöltnek számít.",
                    reset: { wideFieldExtensions = defaults.wideField.extensions }
                ) {
                    EditableStringListView(title: "Wide-field kiterjesztések", items: $wideFieldExtensions)
                }
                SettingsResetRow(
                    isModified: wideFieldNameMarkers != defaults.wideField.nameMarkers,
                    caption: "Fájlnévben szereplő jelölők, amik wide-field-re utalnak.",
                    reset: { wideFieldNameMarkers = defaults.wideField.nameMarkers }
                ) {
                    EditableStringListView(title: "Wide-field név-jelölők", items: $wideFieldNameMarkers)
                }
                numberRow(
                    "Max. fókusztávolság (mm)", value: $maxFocalLengthMM, defaultValue: defaults.wideField.maxFocalLengthMM,
                    caption: "Ennél kisebb/egyenlő FOCALLEN wide-field-re utal."
                )
                wideFieldOverridesList
            }

            Section("Statisztika") {
                SettingsResetRow(
                    isModified: statsExcludeLabels != defaults.stats.excludeLabels,
                    caption: "Ilyen címkéjű éjszakák teljesen kimaradnak az összesített statisztikákból.",
                    reset: { statsExcludeLabels = defaults.stats.excludeLabels }
                ) {
                    EditableStringListView(title: "Kizárt éjszaka-címkék", items: $statsExcludeLabels)
                }
                numberRow(
                    "Gap-küszöb (s)", value: $gapThresholdSeconds, defaultValue: defaults.stats.gapThresholdSeconds,
                    caption: "0 = automatikus, 3× a medián expozíció."
                )
                numberRow(
                    "Gyűjtés-küszöb (s)", value: $collectingThresholdSeconds, defaultValue: defaults.stats.collectingThresholdSeconds,
                    caption: "Ennél kevesebb, stack nélküli integráció még \"gyűjtés\" fázisnak számít."
                )
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
            "Biztosan alaphelyzetbe állítod a Könyvtár-szabályok beállításokat?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Alaphelyzetbe állítás", role: .destructive) { resetAll() }
        }
    }

    @ViewBuilder
    private func numberRow(_ label: String, value: Binding<Double>, defaultValue: Double, caption: String) -> some View {
        SettingsResetRow(
            isModified: value.wrappedValue != defaultValue,
            caption: caption,
            reset: { value.wrappedValue = defaultValue }
        ) {
            HStack {
                Text(label)
                Spacer()
                TextField("", value: value, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// R11-T3/F20: read-only-plus-delete list of `wideField.overrides` --
    /// entries are only ever ADDED via the "Besorolás" context menu
    /// (`WideFieldClassificationMenu`), never here; this is purely for
    /// review/undo. Sorted by target name so the list doesn't reorder
    /// itself as entries are deleted (a `[String: Bool]` has no order of
    /// its own).
    @ViewBuilder
    private var wideFieldOverridesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kézi felülbírálások").font(.subheadline)
            if wideFieldOverrides.isEmpty {
                Text("Nincs kézi felülbírálás — minden célpont besorolása a fenti szabályok szerint automatikus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(wideFieldOverrides.keys.sorted(), id: \.self) { targetName in
                    HStack {
                        Text(targetName)
                        Spacer()
                        Text(wideFieldOverrides[targetName] == true ? "wide-field" : "deep-sky")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            wideFieldOverrides.removeValue(forKey: targetName)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés -- true
    /// whenever the draft differs from `appState.config` (as opposed to
    /// each row's own `↺`, which compares against `AstroConfig()`/
    /// `IntentionalPatterns()` DEFAULTS instead).
    private var isDirty: Bool {
        let config = appState.config
        return residuePatterns != config.residuePatterns
            || residueDirNames != config.residueDirNames
            || toolOutputDirNames != config.toolOutputDirNames
            || intentionalLabels != config.intentional.labels
            || runSuffix != config.intentional.runSuffix
            || dateRange != config.intentional.dateRange
            || wideFieldExtensions != config.wideField.extensions
            || wideFieldNameMarkers != config.wideField.nameMarkers
            || maxFocalLengthMM != config.wideField.maxFocalLengthMM
            || wideFieldOverrides != config.wideField.overrides
            || statsExcludeLabels != config.stats.excludeLabels
            || gapThresholdSeconds != config.stats.gapThresholdSeconds
            || collectingThresholdSeconds != config.stats.collectingThresholdSeconds
    }

    private func resetAll() {
        let defaultConfig = AstroConfig()
        let defaultIntentional = IntentionalPatterns()
        residuePatterns = defaultConfig.residuePatterns
        residueDirNames = defaultConfig.residueDirNames
        toolOutputDirNames = defaultConfig.toolOutputDirNames
        intentionalLabels = defaultIntentional.labels
        runSuffix = defaultIntentional.runSuffix
        dateRange = defaultIntentional.dateRange
        wideFieldExtensions = defaultConfig.wideField.extensions
        wideFieldNameMarkers = defaultConfig.wideField.nameMarkers
        maxFocalLengthMM = defaultConfig.wideField.maxFocalLengthMM
        wideFieldOverrides = defaultConfig.wideField.overrides
        statsExcludeLabels = defaultConfig.stats.excludeLabels
        gapThresholdSeconds = defaultConfig.stats.gapThresholdSeconds
        collectingThresholdSeconds = defaultConfig.stats.collectingThresholdSeconds
    }

    private func loadFromConfig() {
        let config = appState.config
        residuePatterns = config.residuePatterns
        residueDirNames = config.residueDirNames
        toolOutputDirNames = config.toolOutputDirNames
        intentionalLabels = config.intentional.labels
        runSuffix = config.intentional.runSuffix
        dateRange = config.intentional.dateRange
        wideFieldExtensions = config.wideField.extensions
        wideFieldNameMarkers = config.wideField.nameMarkers
        maxFocalLengthMM = config.wideField.maxFocalLengthMM
        wideFieldOverrides = config.wideField.overrides
        statsExcludeLabels = config.stats.excludeLabels
        gapThresholdSeconds = config.stats.gapThresholdSeconds
        collectingThresholdSeconds = config.stats.collectingThresholdSeconds
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.residuePatterns = residuePatterns
        newConfig.residueDirNames = residueDirNames
        newConfig.toolOutputDirNames = toolOutputDirNames

        var intentional = newConfig.intentional
        intentional.labels = intentionalLabels
        intentional.runSuffix = runSuffix
        intentional.dateRange = dateRange
        newConfig.intentional = intentional

        var wideField = newConfig.wideField
        wideField.extensions = wideFieldExtensions
        wideField.nameMarkers = wideFieldNameMarkers
        wideField.maxFocalLengthMM = maxFocalLengthMM
        wideField.overrides = wideFieldOverrides
        newConfig.wideField = wideField

        var stats = newConfig.stats
        stats.excludeLabels = statsExcludeLabels
        stats.gapThresholdSeconds = gapThresholdSeconds
        stats.collectingThresholdSeconds = collectingThresholdSeconds
        newConfig.stats = stats

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
