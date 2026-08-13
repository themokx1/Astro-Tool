import AppKit
import AstroCore
import SwiftUI

public struct V2SettingsView: View {
    @State private var store = SettingsStore()

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            LibrariesSettingsView().tabItem { Label("Libraries & Safety", systemImage: "externaldrive.badge.checkmark") }
            PlanningSettingsView().tabItem { Label("Planning", systemImage: "sparkles") }
            EquipmentEvaluationSettingsView(store: store).tabItem { Label("Equipment", systemImage: "camera.aperture") }
            IntegrationsSupportSettingsView().tabItem { Label("Support", systemImage: "lifepreserver") }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .accessibilityIdentifier("v2.settings")
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("v2.general.showGuidance") private var showGuidance = true
    var body: some View {
        Form {
            Section("Experience") {
                Toggle("Show contextual guidance", isOn: $showGuidance)
                Label("Operations that can change files always require confirmation.", systemImage: "lock.shield")
                Text("This safety rule is part of AstroTool and is not a preference.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct LibrariesSettingsView: View {
    @AppStorage("v2.library.scanOnOpen") private var scanOnOpen = true
    var body: some View {
        Form {
            Section("Library behavior") {
                Toggle("Refresh the external index when opening a library", isOn: $scanOnOpen)
                Label("Image folders are read-only unless you explicitly approve a physical operation.", systemImage: "lock.shield")
                Label("Metadata and indexes live outside the image library.", systemImage: "internaldrive")
            }
        }.formStyle(.grouped)
    }
}

private struct PlanningSettingsView: View {
    @AppStorage("v2.planning.referenceHours") private var referenceHours = 10.0
    @AppStorage("v2.planning.referenceFocalRatio") private var referenceFocalRatio = 5.0
    @AppStorage("v2.planning.referenceSurfaceBrightness") private var referenceBrightness = 22.0
    var body: some View {
        Form {
            Section("Integration baseline") {
                LabeledContent("Reference integration") { TextField("Hours", value: $referenceHours, format: .number).frame(width: 90) }
                LabeledContent("Reference focal ratio") { TextField("f/", value: $referenceFocalRatio, format: .number).frame(width: 90) }
                LabeledContent("Surface brightness") { TextField("mag/arcsec²", value: $referenceBrightness, format: .number).frame(width: 90) }
                Text("Default: 10 hours at f/5 and μ22 mag/arcsec². Each target is calculated relative to this baseline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct EquipmentEvaluationSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var manufacturer = ""
    @State private var model = ""
    @State private var passband = EquipmentFilterPassband.unknown
    @State private var errorMessage: String?
    @State private var selectedFilterID: UUID?

    var body: some View {
        Form {
            Section("Filters") {
                if store.filters.isEmpty { Text("No filters added yet.").foregroundStyle(.secondary) }
                Table(store.filters, selection: $selectedFilterID) {
                    TableColumn("Filter") { filter in
                        Text([filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " "))
                    }
                    TableColumn("Passband") { filter in Text(filter.passband.title) }
                }
                .frame(minHeight: 150)
                .contextMenu(forSelectionType: UUID.self) { filterIDs in
                    if let id = filterIDs.first {
                        Button("Remove Filter", role: .destructive) { store.removeFilter(id: id) }
                    }
                }
                .accessibilityIdentifier("v2.settings.filters-table")
                Button("Remove Selected", role: .destructive) {
                    if let selectedFilterID { store.removeFilter(id: selectedFilterID) }
                }
                .disabled(selectedFilterID == nil)
            }
            Section("Add filter") {
                TextField("Manufacturer, e.g. SVBONY", text: $manufacturer)
                TextField("Model, e.g. SV220", text: $model)
                Picker("Passband", selection: $passband) {
                    ForEach(EquipmentFilterPassband.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button("Add Filter") {
                    do {
                        _ = try store.createFilter(manufacturer: manufacturer, model: model, passband: passband)
                        manufacturer = ""; model = ""; passband = .unknown; errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.formStyle(.grouped)
    }
}

private struct IntegrationsSupportSettingsView: View {
    @State private var diagnostics: SupportDiagnostics?
    @State private var copied = false

    var body: some View {
        Form {
            Section("Privacy") {
                Label("All library analysis runs locally on this Mac.", systemImage: "hand.raised")
                Label("No account or cloud upload is required.", systemImage: "icloud.slash")
            }
            Section("Support") {
                LabeledContent("Release channel", value: "V2 Beta")
                LabeledContent("Diagnostics", value: "Privacy-safe and local")
                HStack {
                    Button("Generate Diagnostics") { generateDiagnostics() }
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .disabled(diagnostics == nil)
                    if copied { Label("Copied", systemImage: "checkmark") .foregroundStyle(.green) }
                }
                if let diagnostics {
                    ScrollView {
                        Text(diagnostics.plainText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.settings.diagnostics")
    }

    private func generateDiagnostics() {
        diagnostics = SupportDiagnostics(
            databaseSchemaVersion: nil,
            libraryConnected: false,
            targetCount: 0,
            sessionCount: 0,
            filterProfileCount: 0,
            sensorProfileCount: 0,
            weatherEnabled: false,
            recentOperations: []
        )
        copied = false
    }

    private func copyDiagnostics() {
        guard let diagnostics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.plainText, forType: .string)
        copied = true
    }
}
