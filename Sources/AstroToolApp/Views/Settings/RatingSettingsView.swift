import AppKit
import AstroCore
import Foundation
import SwiftUI

/// Settings ▸ "Pontozás & expozíció" tab (R9-T5/A.7/B12, new): `RatingRule`
/// (workers/outlierZScore/sirilPath + a live Siril version probe + the four
/// `weights`, as normalized-to-1.00 sliders) and `ExposeRule`
/// (maxSubSeconds/noiseContributionC). Before this task `rating.weights` --
/// the pontozási modell maga -- had no GUI at all; a 0.4 fwhm/0.2 roundness/
/// 0.2 starCount/0.2 background split could only be changed by hand-editing
/// `config.json`.
struct RatingSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var outlierZScore: Double = 2.0
    @State private var workers: Int = 4
    @State private var sirilPathText: String = ""
    @State private var weights: [String: Double] = RatingRule().weights
    @State private var maxSubSeconds: Double = 300
    @State private var noiseContributionC: Double = 0.05

    @State private var sirilStatus: SirilProbeStatus = .checking

    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showResetConfirm = false
    /// R11-T3/F11(c): presented LOCALLY (not via the `.showSirilHelp`
    /// notification `QualitySegment`/the Súgó menü use) -- this view lives in
    /// the separate `Settings { }` scene/window, not the main `WindowGroup`
    /// `RootView` owns, so posting that notification would pop the sheet on
    /// a window the user isn't even looking at.
    @State private var showSirilHelp = false

    private let defaults = AstroConfig()

    /// Fixed display order for the 4 weight sliders -- `RatingRule.weights`
    /// is a `[String: Double]`, which has no ordering of its own.
    private static let weightOrder: [(key: String, label: String)] = [
        ("fwhm", "FWHM"),
        ("roundness", "Kerekség"),
        ("starCount", "Csillagszám"),
        ("background", "Háttér"),
    ]

    var body: some View {
        Form {
            Section("Pontozás") {
                numberRow(
                    "Outlier z-küszöb", value: $outlierZScore, defaultValue: defaults.rating.outlierZScore,
                    caption: "Ennél nagyobb |z-score|-jú keretek kiugrónak számítanak a pontozásban."
                )
                intRow(
                    "Worker-ek", value: $workers, defaultValue: defaults.rating.workers, range: 1...16,
                    caption: "Ennyi keret pontozása fut párhuzamosan."
                )
            }

            Section("Siril") {
                SettingsResetRow(
                    isModified: sirilPathText != defaults.rating.sirilPath,
                    caption: "A siril-cli futtatható elérési útja -- a natív pontozás emellett Siril nélkül is működik.",
                    reset: { sirilPathText = defaults.rating.sirilPath; checkSiril() }
                ) {
                    HStack {
                        TextField("Siril útvonal", text: $sirilPathText)
                            .onSubmit { checkSiril() }
                        Button("Tallózás…") { browseForSiril() }
                    }
                }
                sirilStatusView
            }

            Section("Pontozási súlyok") {
                Text("A négy súly mindig 1,00-ra normalizálva -- egy csúszka húzása a másik hármat arányosan skálázza.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsResetRow(
                    isModified: !weightsMatchDefault,
                    reset: { weights = defaults.rating.weights }
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.weightOrder, id: \.key) { entry in
                            weightSlider(key: entry.key, label: entry.label)
                        }
                    }
                }
            }

            Section("Expozíció-tanácsadó") {
                numberRow(
                    "Max. sub hossz (s)", value: $maxSubSeconds, defaultValue: defaults.expose.maxSubSeconds,
                    caption: "Ajánlott sub-expozíció hosszának felső korlátja (guiding-pontosság/műhold-nyom kockázat miatt)."
                )
                numberRow(
                    "Zaj-hozzájárulás (C)", value: $noiseContributionC, defaultValue: defaults.expose.noiseContributionC,
                    caption: "Mekkora extra leolvasási zajt enged meg a sub-hossz a tiszta ég-shot-zaj felett (0.05 = 5%)."
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
        .onAppear {
            loadFromConfig()
            checkSiril()
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
            "Biztosan alaphelyzetbe állítod a Pontozás & expozíció beállításokat?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Alaphelyzetbe állítás", role: .destructive) { resetAll() }
        }
        .sheet(isPresented: $showSirilHelp) {
            SirilHelpSheet()
        }
    }

    // MARK: - Weight sliders (normalized to sum 1.00)

    private var weightsMatchDefault: Bool {
        let defaultWeights = defaults.rating.weights
        return Self.weightOrder.allSatisfy { entry in
            abs((weights[entry.key] ?? 0) - (defaultWeights[entry.key] ?? 0)) < 0.001
        }
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés -- true
    /// whenever the draft differs from `appState.config` (as opposed to
    /// `weightsMatchDefault`/the two `numberRow` calls' own `↺`s, which
    /// compare against `AstroConfig()` DEFAULTS instead). Weight comparison
    /// uses the same tolerance `weightsMatchDefault` does, since floating-
    /// point rescaling in `adjustWeight` can leave a weight a hair off an
    /// exact round-trip of what was loaded even with no real user edit.
    private var isDirty: Bool {
        let cfg = appState.config
        if outlierZScore != cfg.rating.outlierZScore { return true }
        if workers != cfg.rating.workers { return true }
        if sirilPathText != cfg.rating.sirilPath { return true }
        if maxSubSeconds != cfg.expose.maxSubSeconds { return true }
        if noiseContributionC != cfg.expose.noiseContributionC { return true }
        return !Self.weightOrder.allSatisfy { entry in
            abs((weights[entry.key] ?? 0) - (cfg.rating.weights[entry.key] ?? 0)) < 0.001
        }
    }

    private func weightSlider(key: String, label: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(
                value: Binding(
                    get: { weights[key] ?? 0 },
                    set: { adjustWeight(key: key, to: $0) }
                ),
                in: 0...1
            )
            // R10-B7: was a read-only "NN%" `Text` -- now a two-way-bound
            // numeric field so an exact weight can be typed directly
            // instead of only dragged. Goes through the exact same
            // `adjustWeight` the slider itself uses, so typing e.g. 40 here
            // rescales the other three weights proportionally, identically
            // to dragging the slider to 40%.
            TextField(
                "",
                value: Binding(
                    get: { ((weights[key] ?? 0) * 100).rounded() },
                    set: { adjustWeight(key: key, to: $0 / 100) }
                ),
                format: .number
            )
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
            Text("%").foregroundStyle(.secondary)
        }
    }

    /// Sets `key`'s weight to `newValue`, then rescales every OTHER weight
    /// proportionally so the four still sum to 1.00 -- e.g. dragging `fwhm`
    /// up shrinks `roundness`/`starCount`/`background` in their existing
    /// ratio to each other, rather than clipping or leaving the total
    /// non-normalized.
    private func adjustWeight(key: String, to newValue: Double) {
        let clamped = min(max(newValue, 0), 1)
        let otherKeys = Self.weightOrder.map(\.key).filter { $0 != key }
        let remaining = 1 - clamped
        let othersSum = otherKeys.reduce(0) { $0 + (weights[$1] ?? 0) }

        weights[key] = clamped
        if othersSum > 0.0001 {
            for otherKey in otherKeys {
                weights[otherKey] = (weights[otherKey] ?? 0) / othersSum * remaining
            }
        } else {
            for otherKey in otherKeys {
                weights[otherKey] = remaining / Double(otherKeys.count)
            }
        }
    }

    /// Re-normalizes at save time too -- floating-point drift across many
    /// slider drags could otherwise leave the sum at, say, 0.998.
    private func normalizedWeightsForSave() -> [String: Double] {
        let sum = weights.values.reduce(0, +)
        guard sum > 0.0001 else { return defaults.rating.weights }
        return weights.mapValues { $0 / sum }
    }

    // MARK: - Siril live probe

    private enum SirilProbeStatus: Equatable {
        case checking
        case found(String)
        case notFound
    }

    @ViewBuilder
    private var sirilStatusView: some View {
        switch sirilStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Ellenőrzés…").foregroundStyle(.secondary)
            }
        case .found(let version):
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Siril megtalálva (\(version))").foregroundStyle(.green)
            }
        case .notFound:
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Siril nem található").foregroundStyle(.red)
                // R11-T3/F11(c): same `SirilHelpSheet` content `QualitySegment`'s
                // "Mi ez?" link and the Súgó menü's "A Sirilről…" item show --
                // presented locally here, see `showSirilHelp`'s doc comment.
                Button("Mi a Siril?") { showSirilHelp = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline()
            }
        }
    }

    private func checkSiril() {
        let path = sirilPathText
        sirilStatus = .checking
        Task {
            let result: SirilProbeStatus
            do {
                let cli = try await Task.detached(priority: .userInitiated) {
                    try SirilCLI(path: path)
                }.value
                result = .found(cli.version)
            } catch {
                result = .notFound
            }
            await MainActor.run { sirilStatus = result }
        }
    }

    private func browseForSiril() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Kiválasztás"
        panel.message = "Válaszd ki a siril-cli futtatható fájlt"
        if panel.runModal() == .OK, let url = panel.url {
            sirilPathText = url.path
            checkSiril()
        }
    }

    // MARK: - Shared rows

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

    @ViewBuilder
    private func intRow(_ label: String, value: Binding<Int>, defaultValue: Int, range: ClosedRange<Int>, caption: String) -> some View {
        SettingsResetRow(
            isModified: value.wrappedValue != defaultValue,
            caption: caption,
            reset: { value.wrappedValue = defaultValue }
        ) {
            Stepper("\(label): \(value.wrappedValue)", value: value, in: range)
        }
    }

    // MARK: - Load/save/reset

    private func resetAll() {
        let defaultConfig = AstroConfig()
        outlierZScore = defaultConfig.rating.outlierZScore
        workers = defaultConfig.rating.workers
        sirilPathText = defaultConfig.rating.sirilPath
        weights = defaultConfig.rating.weights
        maxSubSeconds = defaultConfig.expose.maxSubSeconds
        noiseContributionC = defaultConfig.expose.noiseContributionC
        checkSiril()
    }

    private func loadFromConfig() {
        outlierZScore = appState.config.rating.outlierZScore
        workers = appState.config.rating.workers
        sirilPathText = appState.config.rating.sirilPath
        weights = appState.config.rating.weights
        maxSubSeconds = appState.config.expose.maxSubSeconds
        noiseContributionC = appState.config.expose.noiseContributionC
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.rating = RatingRule(
            workers: workers,
            outlierZScore: outlierZScore,
            sirilPath: sirilPathText,
            weights: normalizedWeightsForSave()
        )
        newConfig.expose = ExposeRule(maxSubSeconds: maxSubSeconds, noiseContributionC: noiseContributionC)

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            weights = newConfig.rating.weights
            saveMessage = "Mentve."
        } catch let error as AstroError {
            saveError = describeSettingsError(error)
        } catch {
            saveError = "\(error)"
        }
    }
}
