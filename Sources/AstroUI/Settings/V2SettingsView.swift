import AppKit
import AstroApplication
import AstroCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct V2SettingsView: View {
    @State private var store = SettingsStore()
    private let appModel: AppModel

    public init(appModel: AppModel) {
        self.appModel = appModel
    }

    public var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            LibrariesSettingsView(appModel: appModel).tabItem { Label("Libraries & Safety", systemImage: "externaldrive.badge.checkmark") }
            PlanningSettingsView().tabItem { Label("Planning", systemImage: "sparkles") }
            EquipmentEvaluationSettingsView(store: store).tabItem { Label("Equipment", systemImage: "camera.aperture") }
            IntegrationsSupportSettingsView(appModel: appModel, store: store).tabItem { Label("Support", systemImage: "lifepreserver") }
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
                if showGuidance {
                    Text("This safety rule is part of AstroTool and is not a preference.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.settings.general.guidance-caption")
                }
            }
        }.formStyle(.grouped)
    }
}

private struct LibrariesSettingsView: View {
    @AppStorage("v2.library.scanOnOpen") private var scanOnOpen = true
    @AppStorage("v2.library.enableWriteOperations") private var enableWriteOperations = false
    let appModel: AppModel

    var body: some View {
        Form {
            Section("Library behavior") {
                Toggle("Refresh the external index when opening a library", isOn: $scanOnOpen)
                Label("Metadata and indexes live outside the image library.", systemImage: "internaldrive")
                Text(
                    scanOnOpen
                        ? "AstroTool restores and re-indexes your last library automatically at launch."
                        : "AstroTool waits for you to choose a library at launch; it will not reopen the last one automatically."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent Libraries") {
                if appModel.recentLibraries.isEmpty {
                    Text("No library has been opened yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.recentLibraries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName).font(.body)
                                Text(entry.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if entry.path == appModel.currentLibraryRootURL?.path {
                                Text("Current").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Switch") { appModel.requestLibrarySwitch(to: entry.url) }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("v2.settings.recent-libraries")
            Section("Safety") {
                Toggle("Enable write operations", isOn: $enableWriteOperations)
                    .accessibilityIdentifier("v2.settings.enable-write-operations")
                Label(
                    enableWriteOperations
                        ? "Approved operations (quarantine apply, calibration linking) may now write to your library."
                        : "Image folders are read-only unless you explicitly approve a physical operation.",
                    systemImage: "lock.shield"
                )
                Text("Every write still requires its own separate confirmation — this only unlocks the option.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct PlanningSettingsView: View {
    @AppStorage(PlanningStore.referenceHoursKey) private var referenceHours = IntegrationTimeModel.referenceHours
    @AppStorage(PlanningStore.referenceFocalRatioKey) private var referenceFocalRatio = 5.0
    @AppStorage(PlanningStore.referenceSurfaceBrightnessKey) private var referenceBrightness = IntegrationTimeModel.referenceSurfaceBrightness
    var body: some View {
        Form {
            Section("Integration baseline") {
                LabeledContent("Reference integration") { TextField("Hours", value: $referenceHours, format: .number).frame(width: 90) }
                LabeledContent("Reference focal ratio") { TextField("f/", value: $referenceFocalRatio, format: .number).frame(width: 90) }
                LabeledContent("Surface brightness") { TextField("mag/arcsec²", value: $referenceBrightness, format: .number).frame(width: 90) }
                Text("Default: 10 hours at f/5 and μ22 mag/arcsec². Each target is calculated relative to this baseline.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Applied to every Planning recommendation's integration estimate.")
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
                // A `maxHeight` cap, not a `minHeight` floor: this table sits
                // in a `Form` `Section`, not a `ScrollView`, so it is not the
                // ScrollView-nesting shape the freeze diagnosis (build 20017)
                // describes -- but capping it still keeps a long
                // user-managed filter list from pushing the rest of the
                // settings tab off screen.
                .frame(maxHeight: 220)
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

/// A read-only projection of the library's own external index, built purely
/// from the existing query layer (`MetadataStore`, `SensorProfilesQuery`) --
/// no new engine, no path/target-name field, so it is safe by construction
/// to feed straight into `SupportDiagnostics`.
struct LibraryDiagnosticsSnapshot: Equatable, Sendable {
    let schemaVersion: Int
    let projectCount: Int
    let nightCount: Int
    let sensorProfileCount: Int
}

enum LibraryDiagnosticsQuery {
    /// `metadata` must be a store the caller already has open (e.g.
    /// `ProjectsStore.metadataStore` via `AppModel.currentMetadataStore`) --
    /// `MetadataStore`'s confined-open path is meant to have a single owner
    /// at a time, so this deliberately never constructs its own instance.
    /// `indexDatabase` only needs a path (`SensorProfilesQuery` opens it
    /// read-only), so it carries no such restriction.
    static func snapshot(metadata: MetadataStore, indexDatabase: URL) async -> LibraryDiagnosticsSnapshot? {
        guard let schemaVersion = try? await metadata.schemaVersion(),
              let projectCount = try? await metadata.projectCount(),
              let nights = try? await metadata.nights()
        else { return nil }
        let sensorProfileCount = (try? await SensorProfilesQuery(indexDatabase: indexDatabase).snapshot().profiles.count) ?? 0
        return LibraryDiagnosticsSnapshot(
            schemaVersion: schemaVersion,
            projectCount: projectCount,
            nightCount: nights.count,
            sensorProfileCount: sensorProfileCount
        )
    }
}

/// Writes a diagnostics snapshot to disk -- separated from the "Save…"
/// button's `NSSavePanel` call so the actual write path is unit-testable
/// (`NSSavePanel.runModal()` cannot run headlessly; this function can).
enum SupportDiagnosticsFileWriter {
    static func write(_ snapshot: SupportDiagnostics, to url: URL) throws {
        try snapshot.plainText.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct IntegrationsSupportSettingsView: View {
    let appModel: AppModel
    let store: SettingsStore
    @State private var diagnostics: SupportDiagnostics?
    @State private var copied = false
    @State private var saveErrorMessage: String?
    @State private var isGenerating = false

    var body: some View {
        Form {
            Section("Privacy") {
                Label("All library analysis runs locally on this Mac.", systemImage: "hand.raised")
                Label("No account or cloud upload is required.", systemImage: "icloud.slash")
                Link("Privacy notice", destination: URL(string: ProductInfo.privacyURL)!)
            }
            Section("Support") {
                LabeledContent("Release channel", value: ProductInfo.releaseChannel)
                LabeledContent("Diagnostics", value: "Privacy-safe and local")
                Text("Diagnostics contain only a version, system data, anonymous counts, and operation categories. No path, file name, target, coordinate, note, FITS header, or error message is included.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Generate Diagnostics") { generateDiagnostics() }
                        .disabled(isGenerating)
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .disabled(diagnostics == nil)
                    Button("Save…") { saveDiagnostics() }
                        .disabled(diagnostics == nil)
                        .accessibilityIdentifier("v2.settings.support.save")
                    if copied { Label("Copied", systemImage: "checkmark").foregroundStyle(.green) }
                }
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
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
            Section("Application") {
                LabeledContent("Version", value: ProductInfo.displayVersion)
                LabeledContent("Operating system", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: SupportDiagnostics.currentArchitecture)
                Link("Documentation", destination: URL(string: ProductInfo.documentationURL)!)
                Link("Support", destination: URL(string: ProductInfo.supportURL)!)
                Link("Source", destination: URL(string: ProductInfo.sourceURL)!)
            }
            .accessibilityIdentifier("v2.settings.support.links")
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.settings.diagnostics")
    }

    private func generateDiagnostics() {
        copied = false
        saveErrorMessage = nil
        isGenerating = true
        let filterProfileCount = store.filters.count
        let rootURL = appModel.currentLibraryRootURL
        let metadataStore = appModel.currentMetadataStore
        Task {
            defer { isGenerating = false }
            var librarySnapshot: LibraryDiagnosticsSnapshot?
            if let rootURL, let metadataStore,
               let storage = try? AppStoragePaths.production(
                   libraryID: LibraryIdentity(rootURL: rootURL), libraryRoot: rootURL
               ) {
                librarySnapshot = await LibraryDiagnosticsQuery.snapshot(
                    metadata: metadataStore, indexDatabase: storage.indexDatabase
                )
            }
            diagnostics = SupportDiagnostics(
                databaseSchemaVersion: librarySnapshot?.schemaVersion,
                libraryConnected: librarySnapshot != nil,
                targetCount: librarySnapshot?.projectCount ?? 0,
                sessionCount: librarySnapshot?.nightCount ?? 0,
                filterProfileCount: filterProfileCount,
                sensorProfileCount: librarySnapshot?.sensorProfileCount ?? 0,
                weatherEnabled: false,
                recentOperations: []
            )
        }
    }

    private func copyDiagnostics() {
        guard let diagnostics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.plainText, forType: .string)
        copied = true
    }

    private func saveDiagnostics() {
        guard let diagnostics else { return }
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.nameFieldStringValue = diagnostics.suggestedFilename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SupportDiagnosticsFileWriter.write(diagnostics, to: url)
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = "Could not save diagnostics. Choose a different folder."
        }
    }
}
