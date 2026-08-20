import AstroCore
import Foundation
import SwiftUI

/// Settings ▸ Felszerelés: user-defined camera + optic combinations used by
/// Discovery when no existing image/WCS should dictate tonight's setup.
struct EquipmentSettingsView: View {
    @Environment(AppState.self) private var appState

    private enum SensorPreset: String, CaseIterable, Identifiable {
        case apsc
        case fullFrame
        case custom

        var id: String { rawValue }
        var label: String {
            switch self {
            case .apsc: "APS-C · 23,5 × 15,7 mm"
            case .fullFrame: "Full frame · 36 × 24 mm"
            case .custom: "Egyedi méret"
            }
        }

        var dimensions: (width: Double, height: Double)? {
            switch self {
            case .apsc: (23.5, 15.7)
            case .fullFrame: (36, 24)
            case .custom: nil
            }
        }
    }

    private enum OpticMode: String, CaseIterable, Identifiable {
        case fixed
        case zoom

        var id: String { rawValue }
        var label: String { self == .fixed ? "Fix fókusztáv" : "Zoom / tartomány" }
    }

    private struct SetupDraft: Identifiable {
        var id: String
        var name: String
        var cameraName: String
        var cameraKind: CameraKind
        var sensorPreset: SensorPreset
        var sensorWidthText: String
        var sensorHeightText: String
        var opticMode: OpticMode
        var focalMinText: String
        var focalMaxText: String
        var defaultFocalText: String
        var fNumberText: String
        var relativeEfficiencyText: String
        var isDefault: Bool
    }

    @State private var drafts: [SetupDraft] = []
    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Képalkotó setupok").font(.headline)
                    Text("A Felfedezés ezekből számolja a látómezőt; setup nélkül továbbra is a képek WCS-adatait használja.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                addSetupMenu
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 10)

            Divider()

            if drafts.isEmpty {
                ContentUnavailableView {
                    Label("Nincs kézi setup", systemImage: "camera.aperture")
                } description: {
                    Text("Adj hozzá egy kamerát és optikát, vagy hagyd automatikus WCS-felismerésen a Felfedezést.")
                } actions: {
                    addSetupMenu
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach($drafts) { $draft in
                            setupCard($draft)
                        }
                    }
                    .padding()
                }
            }

            Divider()
            footer
        }
        .onAppear { loadFromConfig() }
        .confirmationDialog(
            "Minden kézi setup törlése?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Összes törlése", role: .destructive) { drafts = [] }
        } message: {
            Text("Mentés után a Felfedezés ismét a könyvtár WCS-adataiból próbál látómezőt felismerni.")
        }
    }

    private var addSetupMenu: some View {
        Menu {
            Button("APS-C szenzorméret") { addTemplate(sensorPreset: .apsc) }
            Button("Full frame szenzorméret") { addTemplate(sensorPreset: .fullFrame) }
            Divider()
            Button("Egyedi szenzorméret") { addTemplate(sensorPreset: .custom) }
        } label: {
            Label("Setup hozzáadása", systemImage: "plus")
        }
    }

    private func setupCard(_ draft: Binding<SetupDraft>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Setup neve", text: draft.name)
                        .font(.headline)
                    Button {
                        setDefault(draft.wrappedValue.id)
                    } label: {
                        Label(
                            draft.wrappedValue.isDefault ? "Alapértelmezett" : "Legyen alapértelmezett",
                            systemImage: draft.wrappedValue.isDefault ? "star.fill" : "star"
                        )
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(draft.wrappedValue.isDefault ? .yellow : .secondary)
                    .help("Ezt választja elsőként a Felfedezés")
                    Button(role: .destructive) {
                        removeSetup(draft.wrappedValue.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Setup törlése")
                }

                HStack {
                    LabeledContent("Kamera") {
                        TextField("Kamera neve", text: draft.cameraName)
                            .frame(minWidth: 180)
                    }
                    LabeledContent("Jelleg") {
                        Picker("", selection: draft.cameraKind) {
                            ForEach(CameraKind.allCases, id: \.self) { kind in
                                Text(kind.settingsLabel).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                HStack {
                    LabeledContent("F-szám") {
                        TextField("f/", text: draft.fNumberText).frame(width: 70)
                    }
                    LabeledContent("Relatív rendszerhatékonyság") {
                        TextField("1,0", text: draft.relativeEfficiencyText).frame(width: 70)
                        Text("×").foregroundStyle(.secondary)
                    }
                    Text("Az automatikus integrációs cél számításához; 1,0 = referencia.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    LabeledContent("Szenzor") {
                        Picker("", selection: draft.sensorPreset) {
                            ForEach(SensorPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        .onChange(of: draft.wrappedValue.sensorPreset) { _, preset in
                            applySensorPreset(preset, to: draft.wrappedValue.id)
                        }
                    }
                    if draft.wrappedValue.sensorPreset == .custom {
                        TextField("Szél. mm", text: draft.sensorWidthText)
                            .frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Mag. mm", text: draft.sensorHeightText)
                            .frame(width: 80)
                    } else {
                        Text("\(draft.wrappedValue.sensorWidthText) × \(draft.wrappedValue.sensorHeightText) mm")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                HStack {
                    LabeledContent("Optika") {
                        Picker("", selection: draft.opticMode) {
                            ForEach(OpticMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    if draft.wrappedValue.opticMode == .fixed {
                        LabeledContent("Fókusztáv") {
                            TextField("mm", text: draft.focalMinText)
                                .frame(width: 75)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent("Tartomány") {
                            TextField("Min.", text: draft.focalMinText).frame(width: 62)
                            Text("–").foregroundStyle(.secondary)
                            TextField("Max.", text: draft.focalMaxText).frame(width: 62)
                            Text("mm").foregroundStyle(.secondary)
                        }
                        LabeledContent("Alapérték") {
                            TextField("mm", text: draft.defaultFocalText).frame(width: 62)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            Button("Összes törlése…", role: .destructive) { showDeleteAllConfirmation = true }
                .disabled(drafts.isEmpty)
            Spacer()
            if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.green) }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            Button("Mentés") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func addTemplate(
        sensorPreset: SensorPreset
    ) {
        let dimensions = sensorPreset.dimensions
        drafts.append(
            SetupDraft(
                id: UUID().uuidString, name: uniqueDraftName("Új setup"), cameraName: "",
                cameraKind: .unspecified, sensorPreset: sensorPreset,
                sensorWidthText: dimensions.map { Self.numberText($0.width) } ?? "",
                sensorHeightText: dimensions.map { Self.numberText($0.height) } ?? "", opticMode: .fixed,
                focalMinText: "", focalMaxText: "", defaultFocalText: "",
                fNumberText: "", relativeEfficiencyText: "1",
                isDefault: drafts.isEmpty
            )
        )
        clearFeedback()
    }

    private func uniqueDraftName(_ proposed: String) -> String {
        let existing = Set(drafts.map { $0.name.lowercased() })
        guard existing.contains(proposed.lowercased()) else { return proposed }
        var suffix = 2
        while existing.contains("\(proposed) \(suffix)".lowercased()) { suffix += 1 }
        return "\(proposed) \(suffix)"
    }

    private func setDefault(_ id: String) {
        for index in drafts.indices { drafts[index].isDefault = drafts[index].id == id }
        clearFeedback()
    }

    private func removeSetup(_ id: String) {
        let removedDefault = drafts.first { $0.id == id }?.isDefault == true
        drafts.removeAll { $0.id == id }
        if removedDefault, !drafts.isEmpty { drafts[0].isDefault = true }
        clearFeedback()
    }

    private func applySensorPreset(_ preset: SensorPreset, to id: String) {
        guard let dimensions = preset.dimensions,
              let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].sensorWidthText = Self.numberText(dimensions.width)
        drafts[index].sensorHeightText = Self.numberText(dimensions.height)
    }

    private func loadFromConfig() {
        drafts = appState.config.imagingSetups.map(Self.draft(from:))
        clearFeedback()
    }

    private static func draft(from profile: ImagingSetupProfile) -> SetupDraft {
        let preset = sensorPreset(width: profile.sensorWidthMM, height: profile.sensorHeightMM)
        return SetupDraft(
            id: profile.id, name: profile.name, cameraName: profile.cameraName,
            cameraKind: profile.cameraKind, sensorPreset: preset,
            sensorWidthText: numberText(profile.sensorWidthMM),
            sensorHeightText: numberText(profile.sensorHeightMM),
            opticMode: profile.isZoom ? .zoom : .fixed,
            focalMinText: numberText(profile.focalLengthMinMM),
            focalMaxText: numberText(profile.focalLengthMaxMM),
            defaultFocalText: numberText(profile.defaultFocalLengthMM),
            fNumberText: numberText(profile.fNumber),
            relativeEfficiencyText: numberText(profile.relativeEfficiency),
            isDefault: profile.isDefault
        )
    }

    private static func sensorPreset(width: Double, height: Double) -> SensorPreset {
        for preset in SensorPreset.allCases {
            guard let dimensions = preset.dimensions else { continue }
            if abs(width - dimensions.width) < 0.01, abs(height - dimensions.height) < 0.01 {
                return preset
            }
        }
        return .custom
    }

    private func save() {
        clearFeedback()
        do {
            var profiles: [ImagingSetupProfile] = []
            var names = Set<String>()
            for draft in drafts {
                let min = try parseNumber(draft.focalMinText)
                let max = draft.opticMode == .fixed ? min : try parseNumber(draft.focalMaxText)
                let defaultFocal = draft.opticMode == .fixed ? min : try parseNumber(draft.defaultFocalText)
                let profile = ImagingSetupProfile(
                    id: draft.id,
                    name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    cameraName: draft.cameraName.trimmingCharacters(in: .whitespacesAndNewlines),
                    cameraKind: draft.cameraKind,
                    sensorWidthMM: try parseNumber(draft.sensorWidthText),
                    sensorHeightMM: try parseNumber(draft.sensorHeightText),
                    focalLengthMinMM: min, focalLengthMaxMM: max,
                    defaultFocalLengthMM: defaultFocal,
                    fNumber: try parseNumber(draft.fNumberText),
                    relativeEfficiency: try parseNumber(draft.relativeEfficiencyText),
                    isDefault: draft.isDefault
                )
                try profile.validate()
                let normalizedName = profile.name.lowercased()
                guard names.insert(normalizedName).inserted else {
                    throw EquipmentSettingsError.duplicateName(profile.name)
                }
                profiles.append(profile)
            }

            if !profiles.isEmpty {
                if !profiles.contains(where: \.isDefault) { profiles[0].isDefault = true }
                var foundDefault = false
                for index in profiles.indices where profiles[index].isDefault {
                    if foundDefault { profiles[index].isDefault = false }
                    foundDefault = true
                }
            }

            var newConfig = appState.config
            newConfig.imagingSetups = profiles
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            if let currentID = appState.selectedImagingSetupID,
               !profiles.contains(where: { $0.id == currentID }) {
                appState.selectedImagingSetupID = ImagingSetupProfile.defaultSetup(in: profiles)?.id
            }
            drafts = profiles.map(Self.draft(from:))
            saveMessage = profiles.isEmpty ? "Mentve — automatikus WCS mód." : "Mentve."
            appState.refreshDiscoveryAfterEquipmentChange()
        } catch let error as ImagingSetupValidationError {
            saveError = Self.validationMessage(error)
        } catch let error as EquipmentSettingsError {
            saveError = error.message
        } catch let error as AstroError {
            saveError = describeSettingsError(error)
        } catch {
            saveError = "\(error)"
        }
    }

    private func parseNumber(_ text: String) throws -> Double {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else {
            throw EquipmentSettingsError.invalidNumber(text)
        }
        return value
    }

    private static func numberText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func validationMessage(_ error: ImagingSetupValidationError) -> String {
        switch error {
        case .emptyName: "Minden setupnak nevet kell adni."
        case .emptyCameraName: "Minden setupnál add meg a kamera nevét."
        case .unspecifiedCameraKind: "Minden setupnál válaszd ki a kamera jellegét."
        case .invalidSensorSize: "A szenzor szélessége és magassága pozitív szám legyen."
        case .invalidFocalRange: "A fókusztáv pozitív legyen, és a minimum nem lehet nagyobb a maximumnál."
        case .defaultFocalLengthOutsideRange: "Az alapértelmezett fókusztávnak a zoomtartományba kell esnie."
        case .invalidFNumber: "Az f-szám pozitív szám legyen."
        case .invalidRelativeEfficiency: "A relatív rendszerhatékonyság pozitív szám legyen (1,0 = referencia)."
        }
    }

    private func clearFeedback() {
        saveMessage = nil
        saveError = nil
    }
}

private enum EquipmentSettingsError: Error {
    case duplicateName(String)
    case invalidNumber(String)

    var message: String {
        switch self {
        case .duplicateName(let name): "Kétszer szerepel ez a setupnév: \(name)."
        case .invalidNumber(let text): "Nem értelmezhető szám: „\(text)”."
        }
    }
}

private extension CameraKind {
    var settingsLabel: String {
        switch self {
        case .unspecified: "Válassz típust"
        case .dedicatedAstro: "Dedikált asztrokamera"
        case .unmodifiedColor: "Nem modifikált színes"
        case .modifiedColor: "Asztromodifikált színes"
        case .monochrome: "Monokróm"
        }
    }
}
