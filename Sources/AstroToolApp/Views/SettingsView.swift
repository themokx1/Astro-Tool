import AstroCore
import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var excludedDirsText: String = ""
    @State private var sirilPathText: String = ""
    @State private var darkMaxAgeMonths: Int = 12
    @State private var tempTolerance: Double = 1.0
    @State private var outlierZScore: Double = 2.0
    @State private var maxFocalLength: Double = 135

    @State private var saveMessage: String?
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Gyökér") {
                LabeledContent("Útvonal", value: appState.config.rootPath)
                Button("Mappa választása…") { appState.chooseRoot() }
            }

            Section("Kizárások") {
                TextField("Kizárt mappák (vesszővel elválasztva)", text: $excludedDirsText)
            }

            Section("Siril") {
                TextField("Siril útvonal", text: $sirilPathText)
            }

            Section("Kalibráció") {
                Stepper("Dark elévülés: \(darkMaxAgeMonths) hónap", value: $darkMaxAgeMonths, in: 1...36)
                HStack {
                    Text("Hőmérséklet-tolerancia (°C)")
                    Spacer()
                    TextField("", value: $tempTolerance, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Pontozás") {
                HStack {
                    Text("Outlier z-küszöb")
                    Spacer()
                    TextField("", value: $outlierZScore, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Wide-field") {
                HStack {
                    Text("Max. fókusztávolság (mm)")
                    Spacer()
                    TextField("", value: $maxFocalLength, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                HStack {
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
    }

    private func loadFromConfig() {
        excludedDirsText = appState.config.excludedDirNames.joined(separator: ", ")
        sirilPathText = appState.config.rating.sirilPath
        darkMaxAgeMonths = appState.config.calib.darkMaxAgeMonths
        tempTolerance = appState.config.calib.tempToleranceC
        outlierZScore = appState.config.rating.outlierZScore
        maxFocalLength = appState.config.wideField.maxFocalLengthMM
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        newConfig.excludedDirNames = excludedDirsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        newConfig.rating.sirilPath = sirilPathText
        newConfig.calib.darkMaxAgeMonths = darkMaxAgeMonths
        newConfig.calib.tempToleranceC = tempTolerance
        newConfig.rating.outlierZScore = outlierZScore
        newConfig.wideField.maxFocalLengthMM = maxFocalLength

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            saveMessage = "Mentve."
        } catch let error as AstroError {
            saveError = describe(error)
        } catch {
            saveError = "\(error)"
        }
    }

    private func describe(_ error: AstroError) -> String {
        switch error {
        case .accessDenied(let path):
            return "Hozzáférés megtagadva: \(path)"
        case .volumeNotMounted(let path):
            return "A kötet nincs csatlakoztatva: \(path)"
        case .pathNotFound(let path):
            return "Az útvonal nem található: \(path)"
        case .writeForbidden(let path):
            return "Írás nem engedélyezett: \(path)"
        case .corruptFITS(let path, let reason):
            return "Sérült FITS fájl (\(path)): \(reason)"
        case .databaseError(let message):
            return "Adatbázis hiba: \(message)"
        case .sirilNotFound(let path):
            return "Siril nem található itt: \(path)"
        case .invalidInput(let reason):
            return "Érvénytelen bemenet: \(reason)"
        }
    }
}
