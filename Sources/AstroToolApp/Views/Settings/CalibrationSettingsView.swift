import AstroCore
import Foundation
import SwiftUI

/// Settings ▸ "Kalibráció" tab (R9-T5/A.7/B12, new): every `CalibRule` field
/// -- 8 numeric tolerances plus the four `match*` toggles -- editable, each
/// with a one-line caption and a `↺` reset that shows only when the value
/// differs from `AstroConfig()`'s built-in default. None of this was
/// reachable from Settings before this task; `darkMaxAgeMonths`/
/// `tempToleranceC` were the only two exposed (on the old, since-split
/// `SettingsView`).
struct CalibrationSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var darkMaxAgeMonths: Int = 12
    @State private var tempToleranceC: Double = 1.0
    @State private var exposureToleranceS: Double = 0.0
    @State private var exposureToleranceFraction: Double = 0.02
    @State private var coolerToleranceC: Double = 1.0
    @State private var flatMaxAgeDays: Int = 30
    @State private var rotatorToleranceDeg: Double = 2.0
    @State private var gainTolerance: Double = 0
    @State private var matchGain: Bool = true
    @State private var matchOffset: Bool = true
    @State private var matchBinning: Bool = true
    @State private var matchCamera: Bool = true

    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showResetConfirm = false

    private let defaults = CalibRule()

    var body: some View {
        Form {
            Section("Dark-elévülés") {
                SettingsResetRow(
                    isModified: darkMaxAgeMonths != defaults.darkMaxAgeMonths,
                    caption: "Ennyi hónapnál régebbi master dark \"elavult\"-nak számít.",
                    reset: { darkMaxAgeMonths = defaults.darkMaxAgeMonths }
                ) {
                    Stepper("Dark elévülés: \(darkMaxAgeMonths) hónap", value: $darkMaxAgeMonths, in: 1...36)
                }

                SettingsResetRow(
                    isModified: flatMaxAgeDays != defaults.flatMaxAgeDays,
                    caption: "Ennyi napnál régebbi flat a session lightjaihoz képest \"túl régi\"-nek számít.",
                    reset: { flatMaxAgeDays = defaults.flatMaxAgeDays }
                ) {
                    Stepper("Flat elévülés: \(flatMaxAgeDays) nap", value: $flatMaxAgeDays, in: 1...365)
                }
            }

            Section("Tolerancia") {
                numberRow(
                    "Hőmérséklet-tolerancia (°C)", value: $tempToleranceC, defaultValue: defaults.tempToleranceC,
                    caption: "A dark master és a light közti megengedett hőmérséklet-eltérés."
                )
                numberRow(
                    "Expozíció-tolerancia (s)", value: $exposureToleranceS, defaultValue: defaults.exposureToleranceS,
                    caption: "Fix, másodperces tolerancia a nominális expozíció-illesztéshez."
                )
                numberRow(
                    "Expozíció-tolerancia (arány)", value: $exposureToleranceFraction, defaultValue: defaults.exposureToleranceFraction,
                    caption: "Extra tolerancia a light expozíciójának arányában, a fixen felül."
                )
                numberRow(
                    "Hűtő-tolerancia (°C)", value: $coolerToleranceC, defaultValue: defaults.coolerToleranceC,
                    caption: "Ennél nagyobb |CCD-TEMP − SET-TEMP| eltérés a hűtőt \"nem tartja a hőfokot\"-nak jelöli."
                )
                numberRow(
                    "Rotátor-tolerancia (°)", value: $rotatorToleranceDeg, defaultValue: defaults.rotatorToleranceDeg,
                    caption: "A flat és a light ROTATOR-szöge közt megengedett eltérés."
                )
                numberRow(
                    "Gain-tolerancia", value: $gainTolerance, defaultValue: defaults.gainTolerance,
                    caption: "A master és a light GAIN-je közt megengedett eltérés (0 = pontos egyezés)."
                )
            }

            Section("Egyeztetési szempontok") {
                SettingsResetRow(
                    isModified: matchGain != defaults.matchGain,
                    caption: "Eltérő GAIN esetén a master ne illeszkedjen.",
                    reset: { matchGain = defaults.matchGain }
                ) {
                    Toggle("GAIN egyezés megkövetelése", isOn: $matchGain)
                }
                SettingsResetRow(
                    isModified: matchOffset != defaults.matchOffset,
                    caption: "Eltérő OFFSET esetén a master ne illeszkedjen (csak ha mindkét oldalon van érték).",
                    reset: { matchOffset = defaults.matchOffset }
                ) {
                    Toggle("OFFSET egyezés megkövetelése", isOn: $matchOffset)
                }
                SettingsResetRow(
                    isModified: matchBinning != defaults.matchBinning,
                    caption: "Eltérő XBINNING esetén a master ne illeszkedjen (csak ha mindkét oldalon van érték).",
                    reset: { matchBinning = defaults.matchBinning }
                ) {
                    Toggle("Binning egyezés megkövetelése", isOn: $matchBinning)
                }
                SettingsResetRow(
                    isModified: matchCamera != defaults.matchCamera,
                    caption: "Eltérő INSTRUME (kamera) esetén a master ne illeszkedjen.",
                    reset: { matchCamera = defaults.matchCamera }
                ) {
                    Toggle("Kamera egyezés megkövetelése", isOn: $matchCamera)
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
            "Biztosan alaphelyzetbe állítod a Kalibráció beállításokat?",
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

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés -- true
    /// whenever the draft differs from `appState.config.calib` (as opposed
    /// to each row's own `↺`, which compares against `CalibRule()`
    /// DEFAULTS instead).
    private var isDirty: Bool {
        let calib = appState.config.calib
        return darkMaxAgeMonths != calib.darkMaxAgeMonths
            || tempToleranceC != calib.tempToleranceC
            || exposureToleranceS != calib.exposureToleranceS
            || exposureToleranceFraction != calib.exposureToleranceFraction
            || coolerToleranceC != calib.coolerToleranceC
            || flatMaxAgeDays != calib.flatMaxAgeDays
            || rotatorToleranceDeg != calib.rotatorToleranceDeg
            || gainTolerance != calib.gainTolerance
            || matchGain != calib.matchGain
            || matchOffset != calib.matchOffset
            || matchBinning != calib.matchBinning
            || matchCamera != calib.matchCamera
    }

    private func resetAll() {
        darkMaxAgeMonths = defaults.darkMaxAgeMonths
        tempToleranceC = defaults.tempToleranceC
        exposureToleranceS = defaults.exposureToleranceS
        exposureToleranceFraction = defaults.exposureToleranceFraction
        coolerToleranceC = defaults.coolerToleranceC
        flatMaxAgeDays = defaults.flatMaxAgeDays
        rotatorToleranceDeg = defaults.rotatorToleranceDeg
        gainTolerance = defaults.gainTolerance
        matchGain = defaults.matchGain
        matchOffset = defaults.matchOffset
        matchBinning = defaults.matchBinning
        matchCamera = defaults.matchCamera
    }

    private func loadFromConfig() {
        let calib = appState.config.calib
        darkMaxAgeMonths = calib.darkMaxAgeMonths
        tempToleranceC = calib.tempToleranceC
        exposureToleranceS = calib.exposureToleranceS
        exposureToleranceFraction = calib.exposureToleranceFraction
        coolerToleranceC = calib.coolerToleranceC
        flatMaxAgeDays = calib.flatMaxAgeDays
        rotatorToleranceDeg = calib.rotatorToleranceDeg
        gainTolerance = calib.gainTolerance
        matchGain = calib.matchGain
        matchOffset = calib.matchOffset
        matchBinning = calib.matchBinning
        matchCamera = calib.matchCamera
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.calib = CalibRule(
            tempToleranceC: tempToleranceC,
            exposureToleranceS: exposureToleranceS,
            darkMaxAgeMonths: darkMaxAgeMonths,
            matchGain: matchGain,
            matchOffset: matchOffset,
            matchBinning: matchBinning,
            matchCamera: matchCamera,
            gainTolerance: gainTolerance,
            exposureToleranceFraction: exposureToleranceFraction,
            flatMaxAgeDays: flatMaxAgeDays,
            rotatorToleranceDeg: rotatorToleranceDeg,
            coolerToleranceC: coolerToleranceC
        )

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
