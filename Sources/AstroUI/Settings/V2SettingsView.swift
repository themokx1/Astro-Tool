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
            LocationSettingsView(appModel: appModel).tabItem { Label("Location", systemImage: "location") }
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
    @State private var selectedLanguage = AppLanguage.current()

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
            Section("Language") {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("v2.settings.language")
                .onChange(of: selectedLanguage) { _, newValue in newValue.apply() }
                Text("Changing the language takes effect the next time you restart AstroTool -- it does not apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.settings.language.restart-notice")
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

/// Task 1 (V2 UI/UX audit section 2.1): `PlanningView`'s `.noSite` empty
/// state, `HomeView`'s "Site not set" night-context rail, and `NightsView`'s
/// 30-night calendar empty state all send the user here to set a site --
/// this is that control, the only one anywhere in the app that writes
/// `AstroConfig.site`/`sites` (previously only editable by hand-editing
/// `<library-root>/.astro_tool/config.json` outside the app entirely).
private struct LocationSettingsView: View {
    let appModel: AppModel
    @State private var store: SiteSettingsStore

    init(appModel: AppModel) {
        self.appModel = appModel
        _store = State(initialValue: SiteSettingsStore(rootURL: appModel.currentLibraryRootURL))
    }

    var body: some View {
        Form {
            if !store.hasLibraryOpen {
                Section {
                    Label("Open a library to set an observing site.", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("v2.settings.site.no-library")
            } else {
                Section("Observing site") {
                    TextField("Name (optional)", text: Binding(get: { store.nameText }, set: { store.setNameText($0) }))
                        .accessibilityIdentifier("v2.settings.site.name")
                    TextField("Latitude (°)", text: Binding(get: { store.latitudeText }, set: { store.setLatitudeText($0) }))
                        .accessibilityIdentifier("v2.settings.site.latitude")
                    TextField("Longitude (°)", text: Binding(get: { store.longitudeText }, set: { store.setLongitudeText($0) }))
                        .accessibilityIdentifier("v2.settings.site.longitude")
                    Text("Used to rank tonight's targets in Planning, Home's night-context rail, and the 30-night calendar in Nights.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Currently in effect") {
                    if let effective = store.effectiveSite, let lat = effective.latitudeDeg, let lon = effective.longitudeDeg {
                        LabeledContent("Latitude", value: AstroFormat.degrees(lat))
                        LabeledContent("Longitude", value: AstroFormat.degrees(lon))
                        Text(effectiveSourceCaption(effective.source))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.settings.site.effective-source")
                    } else {
                        Text("No site configured, and none could be derived from this library's FITS headers yet.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.settings.site.effective-source")
                    }
                }
                Section {
                    HStack {
                        Button("Save") {
                            guard store.save() else { return }
                            Task { await store.refreshEffectiveSite() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.settings.site.save")
                        if let saveMessage = store.saveMessage {
                            Text(saveMessage).foregroundStyle(AstroTokens.Color.ok)
                        }
                        if let errorMessage = store.errorMessage {
                            Text(errorMessage).foregroundStyle(AstroTokens.Color.critical)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: appModel.currentLibraryRootURL) { await store.refreshEffectiveSite() }
        .onChange(of: appModel.currentLibraryRootURL) { _, newRootURL in
            // Settings is a separate scene: it can be opened before any
            // library is open at all, in which case `store` was built with
            // `rootURL: nil` -- since that's a `let`, rebuilding the whole
            // store is the only way this tab notices a library opening (or
            // switching) afterward, rather than permanently showing the
            // "no library open" state from whenever Settings first launched.
            store = SiteSettingsStore(rootURL: newRootURL)
        }
        .accessibilityIdentifier("v2.settings.site")
    }

    private func effectiveSourceCaption(_ source: SiteSettingsStore.EffectiveSiteSource) -> String {
        switch source {
        case .configured: "From this library's configured observing site."
        case .derivedFromFITS: "Derived automatically from this library's own scanned FITS headers -- no site is explicitly configured."
        case .notSet: ""
        }
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
            ExtendedCatalogSettingsSection()
        }.formStyle(.grouped)
    }
}

/// Opt-in "wider catalog" section (wave-5 Task 5): same posture as the
/// Open-Meteo weather integration -- OFF by default, and Settings itself
/// states exactly what a query sends (catalogue names/coordinates only,
/// never anything about the user's own library). Drives its own private
/// `OperationHost`/`OperationCenter` pair rather than reaching for the main
/// window's shared one: Settings is built inside `AstroToolApp`'s separate
/// `Settings { }` scene (see `AstroToolApp.swift`), never a child of the
/// `WindowGroup` that owns `V2RootView`'s `OperationHost`, so there is no
/// shared instance to borrow here.
private struct ExtendedCatalogSettingsSection: View {
    @AppStorage("v2.settings.extended-catalog") private var extendedCatalogEnabled = true
    @State private var store = ExtendedCatalogUpdateStore()

    var body: some View {
        Section("Extended target catalog") {
            Toggle("Look up additional targets online (SIMBAD/VizieR)", isOn: $extendedCatalogEnabled)
                .accessibilityIdentifier("v2.settings.extended-catalog")
                .task { store.activate() }
            Text(
                "When on, \"Update Catalog\" sends only catalogue names and coordinates (e.g. \"IC 4604\") to SIMBAD/VizieR -- never your library's files, paths, targets, or notes. Downloaded objects are cached on this Mac; Planning keeps working offline afterward."
            )
            .font(.caption).foregroundStyle(.secondary)

            if let activeOperation = store.operationHost.activeOperations.first(where: { $0.kind == .catalogFetch }) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Updating catalog…")
                    Spacer()
                    Button("Cancel") { Task { await store.operationHost.cancel(id: activeOperation.id) } }
                        .accessibilityIdentifier("v2.settings.update-catalog-cancel")
                }
            } else {
                HStack {
                    Button("Update Catalog") { Task { await store.startUpdate() } }
                        .disabled(!extendedCatalogEnabled)
                        .accessibilityIdentifier("v2.settings.update-catalog")
                    Text(catalogStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorMessage = store.lastErrorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(AstroTokens.Color.critical)
            }
            Text("This research has made use of the SIMBAD database and the VizieR catalogue access tool, CDS, Strasbourg, France.")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.settings.extended-catalog-attribution")
        }
    }

    private var catalogStatusText: String {
        guard let count = store.cachedTargetCount, let fetchedAt = store.lastFetchedAt else {
            return "Not downloaded yet — Planning uses the built-in 217-object catalog."
        }
        return "\(count) cached targets, updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// Runs the extended-catalog download through `OperationHost` (progress +
/// cooperative cancel) and persists the result via `CatalogCache` -- the
/// "download once, then work offline" contract `CatalogFetcher`'s own doc
/// comment describes. `cache`/`fetcherFactory` are injectable purely for
/// tests; production callers get the real Application-Support-backed cache
/// and `URLSession`-backed fetcher.
@MainActor
@Observable
final class ExtendedCatalogUpdateStore {
    let operationHost = OperationHost(center: OperationCenter())
    private(set) var lastFetchedAt: Date?
    private(set) var cachedTargetCount: Int?
    private(set) var lastErrorMessage: String?

    private let cache: CatalogCache
    private let fetcherFactory: @Sendable () -> CatalogFetcher

    init(
        cache: CatalogCache = ExtendedCatalogUpdateStore.productionCache(),
        fetcherFactory: @escaping @Sendable () -> CatalogFetcher = { CatalogFetcher() }
    ) {
        self.cache = cache
        self.fetcherFactory = fetcherFactory
    }

    /// `init` stays silent: SwiftUI re-evaluates a `@State` default expression
    /// on every view construction, so reading the cache file there would mean
    /// disk I/O once per render -- the same shape as the freezes this module
    /// spent five builds chasing. Views call this from `.task` instead.
    private var isActivated = false

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        reloadCachedSummary()
    }

    /// First-launch behaviour: with the catalog enabled (the default) and
    /// nothing cached yet, fetch it once so the planner opens on the wide
    /// catalog instead of the built-in 217.
    func startUpdateIfNeeded(isEnabled: Bool) async {
        activate()
        guard isEnabled, cachedTargetCount == nil, lastErrorMessage == nil else { return }
        await startUpdate()
    }

    private static func productionCache() -> CatalogCache {
        let fileURL = (try? CatalogCache.productionFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("extended-catalog-fallback.json")
        return CatalogCache(fileURL: fileURL)
    }

    func reloadCachedSummary() {
        guard let payload = cache.load() else {
            lastFetchedAt = nil
            cachedTargetCount = nil
            return
        }
        lastFetchedAt = payload.fetchedAt
        cachedTargetCount = payload.targets.count
    }

    func startUpdate() async {
        lastErrorMessage = nil
        let fetcher = fetcherFactory()
        let cache = self.cache
        _ = await operationHost.run(kind: .catalogFetch, title: "Updating catalog", cancellation: .cooperative) { [weak self] in
            do {
                let targets = try await fetcher.fetchAll(isCancelled: { Task.isCancelled })
                try Task.checkCancellation()
                let payload = CatalogCachePayload(fetchedAt: Date(), targets: targets)
                try cache.save(payload)
                await self?.reloadCachedSummary()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await self?.recordError(error)
                throw error
            }
        }
    }

    private func recordError(_ error: Error) {
        lastErrorMessage = "Could not update the catalog: \(error.localizedDescription). The built-in catalog is unaffected."
    }
}

private struct EquipmentEvaluationSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var manufacturer = ""
    @State private var model = ""
    @State private var passband = EquipmentFilterPassband.unknown
    @State private var errorMessage: String?
    @State private var selectedFilterID: UUID?
    /// V2 UI/UX audit (2026-08-14) section 5: "Remove Filter" and "Remove
    /// Selected" used to call `store.removeFilter` immediately, with no
    /// confirmation and no undo, while every other destructive path in V2
    /// (quarantine's typed token, conversion's undo `confirmationDialog`) is
    /// gated. Both actions now only stage a pending removal here; the
    /// dialog below names the filter and is the only place that actually
    /// calls `removeFilter`.
    @State private var pendingFilterRemoval: EquipmentFilter?
    /// Mirrors `SettingsStore.sortOrder`. The table needs a `Binding`, but
    /// the actual re-sort happens in the store's own `filters` (see
    /// `PlanningView.sortOrder`'s own doc comment for why that split
    /// exists).
    @State private var sortOrder: [KeyPathComparator<EquipmentFilter>] = [
        KeyPathComparator(\EquipmentFilter.manufacturer, order: .forward),
        KeyPathComparator(\EquipmentFilter.model, order: .forward),
    ]

    var body: some View {
        Form {
            Section("Filters") {
                if store.filters.isEmpty { Text("No filters added yet.").foregroundStyle(.secondary) }
                Table(store.filters, selection: $selectedFilterID, sortOrder: $sortOrder) {
                    TableColumn("Filter", value: \EquipmentFilter.manufacturer) { filter in
                        Text([filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " "))
                    }
                    TableColumn("Passband", value: \EquipmentFilter.passband.title) { filter in Text(filter.passband.title) }
                }
                .onChange(of: sortOrder) { _, newValue in store.setSortOrder(newValue) }
                // A `maxHeight` cap, not a `minHeight` floor: this table sits
                // in a `Form` `Section`, not a `ScrollView`, so it is not the
                // ScrollView-nesting shape the freeze diagnosis (build 20017)
                // describes -- but capping it still keeps a long
                // user-managed filter list from pushing the rest of the
                // settings tab off screen.
                .frame(maxHeight: 220)
                .contextMenu(forSelectionType: UUID.self) { filterIDs in
                    if let id = filterIDs.first, let filter = store.filters.first(where: { $0.id == id }) {
                        Button("Remove Filter…", role: .destructive) { pendingFilterRemoval = filter }
                    }
                }
                .accessibilityIdentifier("v2.settings.filters-table")
                Button("Remove Selected…", role: .destructive) {
                    if let selectedFilterID, let filter = store.filters.first(where: { $0.id == selectedFilterID }) {
                        pendingFilterRemoval = filter
                    }
                }
                .disabled(selectedFilterID == nil)
            }
            .confirmationDialog(
                pendingFilterRemoval.map { removalTitle(for: $0) } ?? "Remove this filter?",
                isPresented: Binding(
                    get: { pendingFilterRemoval != nil },
                    set: { isPresented in if !isPresented { pendingFilterRemoval = nil } }
                )
            ) {
                Button("Remove Filter", role: .destructive) {
                    if let pendingFilterRemoval { store.removeFilter(id: pendingFilterRemoval.id) }
                    pendingFilterRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingFilterRemoval = nil }
            } message: {
                Text("This removes the saved equipment filter from your inventory. This cannot be undone.")
            }
            Section("Add filter") {
                TextField("Manufacturer, e.g. SVBONY", text: $manufacturer)
                TextField("Model, e.g. SV220", text: $model)
                Picker("Passband", selection: $passband) {
                    ForEach(EquipmentFilterPassband.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(AstroTokens.Color.critical) }
                Button("Add Filter") {
                    do {
                        _ = try store.createFilter(manufacturer: manufacturer, model: model, passband: passband)
                        manufacturer = ""; model = ""; passband = .unknown; errorMessage = nil
                    } catch { errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.formStyle(.grouped)
    }

    private func removalTitle(for filter: EquipmentFilter) -> String {
        let name = [filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " ")
        return "Remove \"\(name)\"?"
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
                Text("The extended target catalog (Planning tab, on by default) downloads once from SIMBAD/VizieR and then works offline. Only catalogue queries leave this Mac -- never library contents, paths or file names. Turn it off in Planning settings to stay fully offline: \"This research has made use of the SIMBAD database and the VizieR catalogue access tool, CDS, Strasbourg, France.\"")
                    .font(.caption).foregroundStyle(.secondary)
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
                    if copied { Label("Copied", systemImage: "checkmark").foregroundStyle(AstroTokens.Color.ok) }
                }
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(AstroTokens.Color.critical)
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
