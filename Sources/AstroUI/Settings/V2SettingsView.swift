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
            ImagingSetupsSettingsView(appModel: appModel).tabItem { Label("Imaging Setups", systemImage: "camera.on.rectangle") }
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
    /// V2 UI/UX audit -- same cross-scene rebuild pattern
    /// `ImagingSetupsSettingsView`/`LocationSettingsView` already use:
    /// `SessionResiduePatternsStore` reads `AppModel.currentLibraryRootURL`
    /// only at construction, so this view rebuilds it on `.onChange` rather
    /// than relying on a live binding across the two separate scenes.
    @State private var patternsStore: SessionResiduePatternsStore
    @State private var newSessionResiduePattern = ""

    init(appModel: AppModel) {
        self.appModel = appModel
        _patternsStore = State(initialValue: SessionResiduePatternsStore(rootURL: appModel.currentLibraryRootURL))
    }

    var body: some View {
        Form {
            Section("Library behavior") {
                Toggle("Refresh the external index when opening a library", isOn: $scanOnOpen)
                Label("Metadata and indexes live outside the image library.", systemImage: "internaldrive")
                // W6-D fix: a ternary of two string literals infers as
                // plain `String`, not `LocalizedStringKey` -- `Text(_:)`
                // then resolves to its verbatim `StringProtocol` overload no
                // matter what `hu.lproj` says, same defect class
                // `LocalizationCoverageTests
                // .saveTargetLocalizesDespiteTernary` already pins down for
                // `PlanningView`'s Save/Saved button.
                Text(LocalizedStringKey(
                    scanOnOpen
                        ? "AstroTool restores and re-indexes your last library automatically at launch."
                        : "AstroTool waits for you to choose a library at launch; it will not reopen the last one automatically."
                ))
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
                // W6-D fix: same ternary-of-two-literals trap as the
                // `Text(...)` above -- `Label`'s title picked its own
                // verbatim `StringProtocol` overload for the identical
                // reason.
                Label(
                    LocalizedStringKey(
                        enableWriteOperations
                            ? "Approved operations (quarantine apply, calibration linking) may now write to your library."
                            : "Image folders are read-only unless you explicitly approve a physical operation."
                    ),
                    systemImage: "lock.shield"
                )
                Text("Every write still requires its own separate confirmation — this only unlocks the option.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library rules") {
                if !patternsStore.hasLibraryOpen {
                    Label("Open a library first, using Choose Image Library… on Home.", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(patternsStore.patterns.enumerated()), id: \.offset) { index, pattern in
                        HStack {
                            Text(pattern)
                            Spacer()
                            Button {
                                patternsStore.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Pattern, e.g. starless*", text: $newSessionResiduePattern)
                            .onSubmit(addSessionResiduePattern)
                            .accessibilityIdentifier("v2.settings.library-rules.new-pattern")
                        Button(action: addSessionResiduePattern) {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("v2.settings.library-rules.add")
                    }
                    if let lastError = patternsStore.lastError {
                        Text(lastError.errorDescription ?? "").foregroundStyle(AstroTokens.Color.critical)
                    }
                    HStack {
                        Button("Restore Defaults") { patternsStore.restoreDefaults() }
                            .accessibilityIdentifier("v2.settings.library-rules.restore-defaults")
                        Spacer()
                        if let saveMessage = patternsStore.saveMessage {
                            Text(saveMessage).foregroundStyle(AstroTokens.Color.ok)
                        }
                    }
                    Text("These patterns only count as processing residue inside the sessions area -- the same names (e.g. starless, result_...) are kept stack variants under stacks/processed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("v2.settings.library-rules")
        }.formStyle(.grouped)
        .onChange(of: appModel.currentLibraryRootURL) { _, newRootURL in
            // Settings is a separate scene (see `LocationSettingsView`'s own
            // doc comment): rebuilding the store is the only way this tab
            // notices a library opening or switching afterward.
            patternsStore = SessionResiduePatternsStore(rootURL: newRootURL)
        }
    }

    private func addSessionResiduePattern() {
        guard patternsStore.add(newSessionResiduePattern) else { return }
        newSessionResiduePattern = ""
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
                    // Wave W6-A section C: this used to just NAME "a library"
                    // with no way to open one FROM here. A "Choose Library…"
                    // button here cannot cleanly reach one, though: this view
                    // lives inside `AstroToolApp`'s own separate `Settings { }`
                    // scene (see `AstroToolApp.swift`), never a child of the
                    // `WindowGroup` that owns `V2RootView` -- the same
                    // cross-scene boundary `ExtendedCatalogSettingsSection`'s
                    // own doc comment documents for `OperationHost`. The real
                    // "choose a library" action (`V2RootView.presentOnboarding`)
                    // is local `@State` on that OTHER window (it presents
                    // `LibraryWelcomeView` as a sheet there), with no
                    // cross-scene trigger this scene could call. So this names
                    // the button the user actually has -- Home's own
                    // `emptyLibrary.chooseLibrary` button -- instead of
                    // offering a second one that cannot exist here.
                    Label("Open a library first, using Choose Image Library… on Home.", systemImage: "externaldrive.badge.xmark")
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

    // W2-10 (2026-08-17): this used to return a plain `String`, which routes
    // `Text(effectiveSourceCaption(...))` to its verbatim `StringProtocol`
    // overload and never translates -- same defect class as `HealthView`'s
    // `rawValue.capitalized` leak, just shaped as a `switch`-returning
    // function rather than a computed property. `LocalizedStringKey`
    // entries hand-added to hu.lproj (invisible to the extraction script for
    // the same reason every other switch-returned key in this codebase is).
    private func effectiveSourceCaption(_ source: SiteSettingsStore.EffectiveSiteSource) -> LocalizedStringKey {
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
/// never anything about the user's own library).
///
/// W3-12 (orphan `OperationHost` cleanup): this used to drive its own private
/// `OperationHost`/`OperationCenter` pair, reasoning that Settings is built
/// inside `AstroToolApp`'s separate `Settings { }` scene (see
/// `AstroToolApp.swift`), never a child of the `WindowGroup` that owns
/// `V2RootView`'s `OperationHost`, so there was no shared instance to borrow.
/// True, but that `OperationHost` was carrying dead weight: `OperationHost
/// .run` always queues a success/failure toast, and the `Settings { }` scene
/// mounts no `ToastOverlay` anywhere to ever render one -- every toast this
/// store ever produced was created, sat in `toasts` unread, and vanished
/// with the store itself. Nothing was actually SILENT (this section's own
/// inline "Updating catalog…"/Cancel row and `lastErrorMessage` line already
/// said everything a toast would have), so mounting a `ToastOverlay` here
/// just to give those toasts an audience would be solving a problem that
/// does not exist, in a scene where every other section (`LocationSettingsView`
/// 's save/error line, `EquipmentEvaluationSettingsView`'s `errorMessage`,
/// `IntegrationsSupportSettingsView`'s `saveErrorMessage`) already reports
/// through plain inline `@State`, never a toast. Removing the host instead
/// keeps this section on the SAME convention as its five siblings in this
/// file, with the exact same user-visible progress/cancel/error surface as
/// before -- just backed by a local `Task` this store now owns directly
/// instead of borrowing `OperationHost`'s machinery for a scene it was never
/// built for.
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

            if store.isUpdating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Updating catalog…")
                    Spacer()
                    Button("Cancel") { store.cancelUpdate() }
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

    // W2-10 (2026-08-17): same fix as `effectiveSourceCaption` above -- a
    // plain `String` never translates through `Text(catalogStatusText)`.
    // The extended target catalog is this settings screen's own SEARCH
    // feature (it downloads SIMBAD/VizieR's target catalog so Planning can
    // look targets up offline), which is why its status line was one of the
    // two leaks reported for this file. Hand-added to hu.lproj: the
    // interpolated branch's placeholders follow `scripts/extract
    // -localizable-strings.swift`'s own inference (`Int` -> `%lld`,
    // `.formatted(` -> `%@`), the same convention already used for every
    // other hand-added interpolated key in that file.
    private var catalogStatusText: LocalizedStringKey {
        guard let count = store.cachedTargetCount, let fetchedAt = store.lastFetchedAt else {
            return "Not downloaded yet — Planning uses the built-in 217-object catalog."
        }
        return "\(count) cached targets, updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// Runs the extended-catalog download (progress + cooperative cancel) and
/// persists the result via `CatalogCache` -- the "download once, then work
/// offline" contract `CatalogFetcher`'s own doc comment describes.
/// `cache`/`fetcherFactory` are injectable purely for tests; production
/// callers get the real Application-Support-backed cache and
/// `URLSession`-backed fetcher.
///
/// W3-12: used to route through a private `OperationHost`/`OperationCenter`
/// pair for exactly this progress/cancel/error surface -- see
/// `ExtendedCatalogSettingsSection`'s own doc comment for why that host was
/// dead weight in this scene (no `ToastOverlay` ever mounted to read its
/// toasts) and was removed in favor of the plain `isUpdating`/
/// `lastErrorMessage` shape every other Settings section already uses.
/// `runningTask` reimplements only the one piece `OperationHost` was
/// actually earning its keep for here -- cooperative cancellation of the
/// in-flight fetch.
@MainActor
@Observable
final class ExtendedCatalogUpdateStore {
    private(set) var isUpdating = false
    private(set) var lastFetchedAt: Date?
    private(set) var cachedTargetCount: Int?
    private(set) var lastErrorMessage: String?

    private let cache: CatalogCache
    private let fetcherFactory: @Sendable () -> CatalogFetcher
    private var runningTask: Task<Void, Never>?

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
        guard runningTask == nil else { return }
        lastErrorMessage = nil
        isUpdating = true
        let fetcher = fetcherFactory()
        let cache = self.cache
        let task = Task { [weak self] in
            do {
                let targets = try await fetcher.fetchAll(isCancelled: { Task.isCancelled })
                try Task.checkCancellation()
                let payload = CatalogCachePayload(fetchedAt: Date(), targets: targets)
                try cache.save(payload)
                await self?.finishUpdate { $0.reloadCachedSummary() }
            } catch is CancellationError {
                await self?.finishUpdate { _ in }
            } catch {
                await self?.finishUpdate { $0.recordError(error) }
            }
        }
        runningTask = task
        await task.value
    }

    /// Requests cooperative cancellation of an in-flight `startUpdate()` --
    /// `CatalogFetcher.fetchAll`'s own `isCancelled` closure checks
    /// `Task.isCancelled`, so this is the same cooperative shape
    /// `OperationHost.cancel(id:)` used before, just against the one task
    /// this store owns directly instead of one registered with a shared
    /// center.
    func cancelUpdate() {
        runningTask?.cancel()
    }

    private func finishUpdate(_ apply: (ExtendedCatalogUpdateStore) -> Void) {
        apply(self)
        isUpdating = false
        runningTask = nil
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
                    // Task 5b (2026-08-17): `passband.title` stays `String`
                    // (see `EquipmentFilterPassband.title`'s own doc comment)
                    // because `TableColumn(value:)` needs a `Comparable` sort
                    // key, which `LocalizedStringKey` isn't -- wrapped as
                    // `LocalizedStringKey` only for the cell's own `Text`.
                    TableColumn("Passband", value: \EquipmentFilter.passband.title) { filter in Text(LocalizedStringKey(filter.passband.title)) }
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
                TextField("Manufacturer, e.g. Optolong", text: $manufacturer)
                TextField("Model, e.g. L-eXtreme", text: $model)
                Picker("Passband", selection: $passband) {
                    ForEach(EquipmentFilterPassband.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
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

    // W2-10 (2026-08-17): same String-never-translates defect as
    // `effectiveSourceCaption`/`catalogStatusText` above, for the equipment
    // filter list's own confirmation dialog title. `name` is genuine DATA
    // (a filter's manufacturer/model), interpolated into the sentence rather
    // than through it, matching every other hand-added interpolated key in
    // this codebase.
    private func removalTitle(for filter: EquipmentFilter) -> LocalizedStringKey {
        let name = [filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " ")
        return "Remove \"\(name)\"?"
    }
}

/// V2 UI/UX audit: the imaging-setup CRUD V2's default shell never had. V1's
/// `EquipmentSettingsView` (`Sources/AstroToolApp`) has always been able to
/// add/edit/delete `AstroConfig.imagingSetups`, but V1's UI is unreachable
/// from the default V2 shell -- so an owner using V2 exclusively had no way
/// at all to tell Planning about their real camera/optics combinations, only
/// the three hardcoded `PlanningStore.defaultSetups` samples. Same
/// cross-scene rebuild pattern `LocationSettingsView` above already uses:
/// `EquipmentSetupsStore` reads `AppModel.currentLibraryRootURL` only at
/// construction, so this view rebuilds the store on `.onChange` rather than
/// relying on a live binding across the two separate scenes.
private struct ImagingSetupsSettingsView: View {
    let appModel: AppModel
    @State private var store: EquipmentSetupsStore
    @State private var selectedSetupID: String?
    @State private var isAddingSetup = false
    @State private var editingSetup: ImagingSetupProfile?
    @State private var pendingDeletion: ImagingSetupProfile?

    init(appModel: AppModel) {
        self.appModel = appModel
        _store = State(initialValue: EquipmentSetupsStore(rootURL: appModel.currentLibraryRootURL))
    }

    var body: some View {
        Form {
            if !store.hasLibraryOpen {
                Section {
                    Label("Open a library first, using Choose Image Library… on Home.", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("v2.settings.equipment-setups.no-library")
            } else {
                Section("Saved imaging setups") {
                    if store.setups.isEmpty {
                        Text("No imaging setups saved yet. Add your camera and optics so Planning can frame targets for your real gear.")
                            .foregroundStyle(.secondary)
                    } else {
                        Table(store.setups, selection: $selectedSetupID) {
                            TableColumn("Name") { setup in
                                HStack(spacing: 4) {
                                    Text(setup.name)
                                    if setup.isDefault {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(AstroTokens.Color.attention)
                                            .accessibilityLabel(Text("Default"))
                                    }
                                }
                            }
                            TableColumn("Camera") { setup in Text(setup.cameraName) }
                            TableColumn("Focal length") { setup in focalLengthText(setup) }
                        }
                        .frame(maxHeight: 220)
                        .accessibilityIdentifier("v2.settings.equipment-setups.table")
                    }
                    HStack {
                        Button("Add Setup…") { isAddingSetup = true }
                            .accessibilityIdentifier("v2.settings.equipment-setups.add")
                        Button("Edit…") {
                            if let setup = selectedSetup { editingSetup = setup }
                        }
                        .disabled(selectedSetup == nil)
                        Button("Delete…", role: .destructive) {
                            if let setup = selectedSetup { pendingDeletion = setup }
                        }
                        .disabled(selectedSetup == nil)
                    }
                    if let saveMessage = store.saveMessage {
                        Text(saveMessage).foregroundStyle(AstroTokens.Color.ok)
                    }
                    Text("Planning uses these to frame targets for your real camera and optics -- the setup marked default opens first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAddingSetup) {
            ImagingSetupEditorView(store: store, original: nil)
        }
        .sheet(item: $editingSetup) { setup in
            ImagingSetupEditorView(store: store, original: setup)
        }
        .confirmationDialog(
            pendingDeletion.map { deletionTitle(for: $0) } ?? "Delete this setup?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in if !isPresented { pendingDeletion = nil } }
            )
        ) {
            Button("Delete Setup", role: .destructive) {
                if let pendingDeletion { store.delete(id: pendingDeletion.id) }
                selectedSetupID = nil
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Planning falls back to another saved setup, or to its built-in defaults if none remain. This cannot be undone.")
        }
        .onChange(of: appModel.currentLibraryRootURL) { _, newRootURL in
            // Settings is a separate scene (see `LocationSettingsView`'s own
            // doc comment): rebuilding the store is the only way this tab
            // notices a library opening or switching afterward.
            store = EquipmentSetupsStore(rootURL: newRootURL)
            selectedSetupID = nil
        }
        .accessibilityIdentifier("v2.settings.equipment-setups")
    }

    private var selectedSetup: ImagingSetupProfile? {
        guard let selectedSetupID else { return nil }
        return store.setups.first { $0.id == selectedSetupID }
    }

    private func focalLengthText(_ setup: ImagingSetupProfile) -> Text {
        setup.isZoom
            ? Text("\(setup.focalLengthMinMM, format: .number)–\(setup.focalLengthMaxMM, format: .number) mm")
            : Text("\(setup.focalLengthMinMM, format: .number) mm")
    }

    // W2-10-style fix (see `effectiveSourceCaption`/`removalTitle` above in
    // this file): a plain `String` default in the `??` below would infer the
    // WHOLE expression as `String`, never translating through
    // `confirmationDialog`'s title. `LocalizedStringKey`'s own interpolation
    // takes the setup's name as genuine DATA, matching `removalTitle`'s own
    // shape exactly; hand-added to hu.lproj for the same reason (the
    // extraction script cannot see a switch/function-returned key).
    private func deletionTitle(for setup: ImagingSetupProfile) -> LocalizedStringKey {
        "Delete \"\(setup.name)\"?"
    }
}

/// The add/edit sheet for one `ImagingSetupProfile` -- shared by both
/// `ImagingSetupsSettingsView`'s "Add Setup…" and "Edit…" actions, keyed by
/// whether `original` is `nil`. All numeric fields bind directly to `Double`
/// via `TextField(_, value:, format: .number)` (the same pattern
/// `PlanningSettingsView`'s reference-baseline fields already use), so this
/// view does no manual text parsing of its own -- domain validation is
/// entirely `ImagingSetupProfile.validate()`'s, surfaced through
/// `EquipmentSetupsStore.lastError`.
private struct ImagingSetupEditorView: View {
    let store: EquipmentSetupsStore
    let original: ImagingSetupProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImagingSetupDraft

    init(store: EquipmentSetupsStore, original: ImagingSetupProfile?) {
        self.store = store
        self.original = original
        _draft = State(initialValue: original.map(ImagingSetupDraft.init(profile:)) ?? ImagingSetupDraft())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Setup") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("v2.settings.equipment-setups.editor.name")
                    TextField("Camera", text: $draft.cameraName)
                    Picker("Camera kind", selection: $draft.cameraKind) {
                        ForEach(CameraKind.allCases, id: \.self) { kind in
                            Text(kind.settingsLabel).tag(kind)
                        }
                    }
                    Toggle("Default setup", isOn: $draft.isDefault)
                }
                Section("Sensor") {
                    LabeledContent("Width") { TextField("mm", value: $draft.sensorWidthMM, format: .number).frame(width: 90) }
                    LabeledContent("Height") { TextField("mm", value: $draft.sensorHeightMM, format: .number).frame(width: 90) }
                }
                Section("Optics") {
                    Toggle("Zoom / variable focal length", isOn: $draft.isZoom)
                    if draft.isZoom {
                        LabeledContent("Minimum focal length") { TextField("mm", value: $draft.focalLengthMinMM, format: .number).frame(width: 90) }
                        LabeledContent("Maximum focal length") { TextField("mm", value: $draft.focalLengthMaxMM, format: .number).frame(width: 90) }
                        LabeledContent("Default focal length") { TextField("mm", value: $draft.defaultFocalLengthMM, format: .number).frame(width: 90) }
                    } else {
                        LabeledContent("Focal length") { TextField("mm", value: $draft.focalLengthMinMM, format: .number).frame(width: 90) }
                    }
                    LabeledContent("F-number") { TextField("f/", value: $draft.fNumber, format: .number).frame(width: 90) }
                    LabeledContent("Relative system efficiency") { TextField("1.0", value: $draft.relativeEfficiency, format: .number).frame(width: 90) }
                    Text("Used for Planning's integration-time estimate; 1.0 = reference.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Default filter (optional)") {
                    Picker("Passband", selection: $draft.defaultFilterSignalMode) {
                        ForEach(SignalMode.allCases, id: \.self) { mode in
                            Text(LocalizedStringKey(mode.settingsLabel)).tag(mode)
                        }
                    }
                    TextField("Filter name, e.g. L-eXtreme", text: $draft.defaultFilterName)
                    Text("Used when a frame from this setup's camera has no FITS FILTER header, capture group, or capture-slug name to fall back on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let lastError = store.lastError {
                    Text(errorMessage(for: lastError))
                        .foregroundStyle(AstroTokens.Color.critical)
                        .accessibilityIdentifier("v2.settings.equipment-setups.editor.error")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if store.save(draft.makeProfile()) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("v2.settings.equipment-setups.editor.save")
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .accessibilityIdentifier("v2.settings.equipment-setups.editor")
    }

    private func errorMessage(for error: EquipmentSetupsStore.EquipmentSetupsError) -> LocalizedStringKey {
        switch error {
        case .noLibraryOpen: "Open a library before managing imaging setups."
        case .duplicateName: "Another saved setup already has this name."
        case .saveFailed: "Could not save this setup. Try again."
        case .validation(let validationError): validationMessage(validationError)
        }
    }

    // Hand-added to hu.lproj (see `effectiveSourceCaption`'s own doc comment
    // above for why a switch-returned `LocalizedStringKey` needs that): the
    // shared `ImagingSetupValidationError` surfaced as localized, human text
    // rather than its raw case name.
    private func validationMessage(_ error: ImagingSetupValidationError) -> LocalizedStringKey {
        switch error {
        case .emptyName: "Every setup needs a name."
        case .emptyCameraName: "Enter the camera name for every setup."
        case .unspecifiedCameraKind: "Choose a camera kind for every setup."
        case .invalidSensorSize: "Sensor width and height must be positive numbers."
        case .invalidFocalRange: "Focal length must be positive, and the minimum cannot exceed the maximum."
        case .defaultFocalLengthOutsideRange: "The default focal length must fall within the zoom range."
        case .invalidFNumber: "The f-number must be a positive number."
        case .invalidRelativeEfficiency: "Relative system efficiency must be a positive number (1.0 = reference)."
        }
    }
}

/// Editable draft for one `ImagingSetupProfile` -- `isZoom` is a plain
/// stored toggle here (unlike `ImagingSetupProfile.isZoom`, which is
/// DERIVED from the min/max focal length actually being different) so a
/// fixed-optic setup being edited can be told apart from a one-off zoom
/// whose min happens to equal its max, and so the "Zoom" toggle has
/// something stable to bind to while the user is still typing the range.
private struct ImagingSetupDraft {
    var id: String
    var name: String
    var cameraName: String
    var cameraKind: CameraKind
    var sensorWidthMM: Double
    var sensorHeightMM: Double
    var isZoom: Bool
    var focalLengthMinMM: Double
    var focalLengthMaxMM: Double
    var defaultFocalLengthMM: Double
    var fNumber: Double
    var relativeEfficiency: Double
    var isDefault: Bool
    var defaultFilterSignalMode: SignalMode
    var defaultFilterName: String

    init() {
        id = UUID().uuidString
        name = ""
        cameraName = ""
        cameraKind = .unspecified
        sensorWidthMM = 23.5
        sensorHeightMM = 15.6
        isZoom = false
        focalLengthMinMM = 50
        focalLengthMaxMM = 50
        defaultFocalLengthMM = 50
        fNumber = 5
        relativeEfficiency = 1
        isDefault = false
        defaultFilterSignalMode = .unknown
        defaultFilterName = ""
    }

    init(profile: ImagingSetupProfile) {
        id = profile.id
        name = profile.name
        cameraName = profile.cameraName
        cameraKind = profile.cameraKind
        sensorWidthMM = profile.sensorWidthMM
        sensorHeightMM = profile.sensorHeightMM
        isZoom = profile.isZoom
        focalLengthMinMM = profile.focalLengthMinMM
        focalLengthMaxMM = profile.isZoom ? profile.focalLengthMaxMM : profile.focalLengthMinMM
        defaultFocalLengthMM = profile.isZoom ? profile.defaultFocalLengthMM : profile.focalLengthMinMM
        fNumber = profile.fNumber
        relativeEfficiency = profile.relativeEfficiency
        isDefault = profile.isDefault
        defaultFilterSignalMode = profile.defaultFilterSignalMode
        defaultFilterName = profile.defaultFilterName ?? ""
    }

    func makeProfile() -> ImagingSetupProfile {
        let minFocal = focalLengthMinMM
        let maxFocal = isZoom ? focalLengthMaxMM : minFocal
        let defaultFocal = isZoom ? defaultFocalLengthMM : minFocal
        let trimmedFilterName = defaultFilterName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImagingSetupProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraName: cameraName.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraKind: cameraKind,
            sensorWidthMM: sensorWidthMM, sensorHeightMM: sensorHeightMM,
            focalLengthMinMM: minFocal, focalLengthMaxMM: maxFocal, defaultFocalLengthMM: defaultFocal,
            fNumber: fNumber, relativeEfficiency: relativeEfficiency, isDefault: isDefault,
            defaultFilterSignalMode: defaultFilterSignalMode,
            defaultFilterName: trimmedFilterName.isEmpty ? nil : trimmedFilterName
        )
    }
}

private extension CameraKind {
    // Hand-added to hu.lproj (see `effectiveSourceCaption`'s own doc comment
    // above): a switch-returned `LocalizedStringKey` is invisible to
    // `scripts/extract-localizable-strings.swift`'s literal-argument scan.
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .unspecified: "Choose a kind"
        case .dedicatedAstro: "Dedicated astro camera"
        case .unmodifiedColor: "Unmodified color"
        case .modifiedColor: "Astro-modified color"
        case .monochrome: "Monochrome"
        }
    }
}

private extension SignalMode {
    // Task 5b (`EquipmentFilterPassband.title`'s own doc comment): stays
    // `String`-returning so this reuses the SAME hu.lproj entries that type
    // already established for the four shared cases ("Broadband",
    // "Dual-band", "Narrowband", "Not specified") -- wrapped as
    // `LocalizedStringKey` only at the `Text(...)` call site above.
    var settingsLabel: String {
        switch self {
        case .broadband: "Broadband"
        case .dualBand: "Dual-band"
        case .narrowband: "Narrowband"
        case .lrgb: "LRGB"
        case .luminance: "Luminance"
        case .unfiltered: "Unfiltered"
        case .other: "Other"
        case .unknown: "Not specified"
        }
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

/// W5-4 item 3: `IntegrationsSupportSettingsView.generateDiagnostics()` used
/// to hardcode the `weatherEnabled` snapshot field to `false` regardless of
/// whether the user had actually turned Open-Meteo weather on -- even though
/// `config.weather.enabled` is live product behavior everywhere else in V2
/// (`HomeStore.productionWeather`, `NightsStore`, `PlanningStore` all gate
/// their own weather fetch on this exact same value). Reads the SAME
/// `<library-root>/.astro_tool/config.json` those call sites read, so a
/// toggle flipped from either V1's or V2's Settings is reflected here too.
/// `nil` root (no library open) or a config that fails to load/parse both
/// report `false`, same honest default `AstroConfig()`'s own `WeatherRule()`
/// already uses -- never a crash, never a guess.
enum SupportDiagnosticsWeatherState {
    static func weatherEnabled(libraryRootURL: URL?) -> Bool {
        guard let libraryRootURL else { return false }
        let configURL = libraryRootURL.appendingPathComponent(".astro_tool/config.json")
        let config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        return config.weather.enabled
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
                // W6-D fix: `LabeledContent(_:value:)`'s `value:` parameter
                // is plain `String`-typed -- the content-closure initializer
                // instead gives the value a real `Text("...")`, which
                // resolves through the `LocalizedStringKey` overload.
                LabeledContent("Diagnostics") { Text("Privacy-safe and local") }
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
                weatherEnabled: SupportDiagnosticsWeatherState.weatherEnabled(libraryRootURL: rootURL),
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
