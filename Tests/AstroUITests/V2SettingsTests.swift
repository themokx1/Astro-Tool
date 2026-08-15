@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
struct V2SettingsTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("V2 support can preview, copy and save privacy-safe diagnostics")
    func supportDiagnosticsSurface() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(source.contains("SupportDiagnostics"))
        #expect(source.contains("Generate Diagnostics"))
        #expect(source.contains("Copy Diagnostics"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("v2.settings.diagnostics"))
        #expect(source.contains("v2.settings.support.save"))
        #expect(source.contains("NSSavePanel"))
    }

    @Test("Support exposes documentation, support, source and privacy links plus a version/OS/architecture row")
    func supportLinksAndVersionSurface() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(source.contains("v2.settings.support.links"))
        #expect(source.contains("ProductInfo.documentationURL"))
        #expect(source.contains("ProductInfo.supportURL"))
        #expect(source.contains("ProductInfo.sourceURL"))
        #expect(source.contains("ProductInfo.privacyURL"))
        #expect(source.contains("ProductInfo.displayVersion"))
        #expect(source.contains("ProcessInfo.processInfo.operatingSystemVersionString"))
        #expect(source.contains("SupportDiagnostics.currentArchitecture"))
    }

    @Test("Generated diagnostics report the live schema version and non-zero library counts, and never the fixture's own paths or names")
    func diagnosticsReflectLiveLibraryState() async throws {
        // `LibraryDiagnosticsQuery` deliberately takes an *already-open*
        // `MetadataStore` rather than opening its own -- `MetadataStore`'s
        // confined-open path is meant to have a single owner at a time, and
        // in production that owner is `ProjectsStore.metadataStore` via
        // `AppModel.currentMetadataStore`. `MetadataStore.temporary()`
        // mirrors that single-owner shape here.
        let metadata = try MetadataStore.temporary()
        try await metadata.save(ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elephant's Trunk Secret Target", phase: .collecting))
        try await metadata.save(NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "UTC"))

        let fileManager = FileManager.default
        let indexDirectory = fileManager.temporaryDirectory.appendingPathComponent("AstroTool-V2SettingsTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: indexDirectory) }
        let indexDatabase = indexDirectory.appendingPathComponent("index.sqlite")
        let indexDB = try SQLiteDB(path: indexDatabase.path)
        try indexDB.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,estimator_version INTEGER,PRIMARY KEY(camera,gain,offset));
        INSERT INTO sensor_profile VALUES('ZWO ASI2600MC Pro',100,50,500.2,1.4,0.003,-10,0.76,1786147200,40,2);
        """)

        let snapshot = try #require(await LibraryDiagnosticsQuery.snapshot(metadata: metadata, indexDatabase: indexDatabase))

        #expect(snapshot.schemaVersion == MetadataSchema.currentVersion)
        #expect(snapshot.projectCount == 1)
        #expect(snapshot.nightCount == 1)
        #expect(snapshot.sensorProfileCount == 1)

        let diagnostics = SupportDiagnostics(
            databaseSchemaVersion: snapshot.schemaVersion,
            libraryConnected: true,
            targetCount: snapshot.projectCount,
            sessionCount: snapshot.nightCount,
            filterProfileCount: 1,
            sensorProfileCount: snapshot.sensorProfileCount,
            weatherEnabled: false,
            recentOperations: []
        )
        let payload = diagnostics.plainText

        #expect(!payload.contains("Elephant's Trunk Secret Target"))
        #expect(!payload.contains("IC 1396"))
        #expect(!payload.contains(indexDirectory.path))
        #expect(!payload.contains(metadata.databaseURL.path))
    }

    @Test("An empty library still reports its live schema version with zero counts, never crashing")
    func diagnosticsOnAFreshLibraryReportZeroCounts() async throws {
        let metadata = try MetadataStore.temporary()
        let fileManager = FileManager.default
        let indexDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: indexDirectory) }

        let snapshot = await LibraryDiagnosticsQuery.snapshot(
            metadata: metadata, indexDatabase: indexDirectory.appendingPathComponent("index.sqlite")
        )

        #expect(snapshot?.schemaVersion == MetadataSchema.currentVersion)
        #expect(snapshot?.projectCount == 0)
        #expect(snapshot?.nightCount == 0)
        #expect(snapshot?.sensorProfileCount == 0)
    }

    @Test("Writing a diagnostics snapshot to a file round-trips its exact plain-text content")
    func fileWriterRoundTrips() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.txt")
        let diagnostics = SupportDiagnostics(
            databaseSchemaVersion: 5, libraryConnected: true, targetCount: 3, sessionCount: 4,
            filterProfileCount: 1, sensorProfileCount: 1, weatherEnabled: false, recentOperations: []
        )

        try SupportDiagnosticsFileWriter.write(diagnostics, to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == diagnostics.plainText)
    }

    @Test("The Planning tab's baseline preferences are wired to PlanningStore, not disclosed as a no-op")
    func planningPreferencesAreWiredNotDisclosedAsANoOp() throws {
        let settingsSource = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(!settingsSource.contains("Not yet applied to planning calculations"))
        #expect(settingsSource.contains("PlanningStore.referenceHoursKey"))

        let planningStoreSource = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningStore.swift"))
        #expect(planningStoreSource.contains("v2.planning.referenceHours"))
        #expect(planningStoreSource.contains("referenceFocalRatio"))
        #expect(planningStoreSource.contains("referenceSurfaceBrightness"))
    }

    @Test("Recent Libraries are listed with a switch action routed through AppModel")
    func recentLibrariesSurface() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(source.contains("v2.settings.recent-libraries"))
        #expect(source.contains("appModel.recentLibraries"))
        #expect(source.contains("appModel.requestLibrarySwitch"))
    }

    @Test("scanOnOpen actually gates whether the last library is restored and re-indexed at launch")
    func scanOnOpenGatesAutomaticRestoreAtLaunch() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(source.contains("@AppStorage(\"v2.library.scanOnOpen\")"))
        #expect(source.contains("else if scanOnOpen"))
        // V2 UI/UX audit section 2.2: the raw, unrouted `restoreSavedLibrary()`
        // used to leave the launch-time scan invisible (no toolbar progress,
        // no Cancel) -- it now goes through `operationHost`, exactly like a
        // manual rescan already does (`LibraryLaunchScanTests` covers the
        // behavior itself).
        #expect(source.contains("restoreSavedLibrary(through: operationHost)"))
    }

    @Test("showGuidance actually gates guidance captions in Home and Settings")
    func showGuidanceGatesCaptionsInHomeAndSettings() throws {
        let settingsSource = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(settingsSource.contains("if showGuidance"))

        let homeSource = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"))
        #expect(homeSource.contains("@AppStorage(\"v2.general.showGuidance\")"))
        #expect(homeSource.contains("if showGuidance"))
        #expect(homeSource.contains("v2.home.guidance-caption"))
    }

    @Test("A filter created in settings is immediately available to inline selectors")
    func sharedFilterInventory() throws {
        let suite = "AstroTool-V2SettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        let filter = try store.createFilter(manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        #expect(store.filters == [filter])
        #expect(SettingsStore(defaults: defaults).filters == [filter])
        #expect(SeriesFilterChoices(settings: store).filters.contains(filter))
    }

    @Test("Removing a saved equipment filter requires confirmation, like every other destructive V2 path")
    func filterRemovalRequiresConfirmation() throws {
        // V2 UI/UX audit (2026-08-14) section 5: "Remove Filter" (context
        // menu, role: .destructive) and "Remove Selected" both used to call
        // `store.removeFilter` immediately -- no confirmation, no undo --
        // while every other destructive path in V2 (quarantine's typed
        // token, conversion's undo `confirmationDialog`) is gated. Both
        // buttons must now only stage a pending removal; the actual
        // `store.removeFilter` call must happen inside a
        // `.confirmationDialog`.
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains(".confirmationDialog("), "filter removal must be gated behind a confirmation dialog")

        guard let dialogStart = source.range(of: ".confirmationDialog(") else {
            Issue.record("no confirmationDialog found")
            return
        }
        let dialogBody = String(source[dialogStart.lowerBound...].prefix(600))
        #expect(dialogBody.contains("store.removeFilter"), "the confirmation dialog's own action is where removeFilter must actually be called")

        // Neither destructive button may call removeFilter directly from
        // its own action closure -- that would skip the dialog entirely.
        #expect(!source.contains(#"Button("Remove Filter", role: .destructive) { store.removeFilter(id: id) }"#))
        #expect(!source.contains("if let selectedFilterID { store.removeFilter(id: selectedFilterID) }"))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Blank or duplicate filters are rejected without changing inventory")
    func filterValidation() throws {
        let suite = "AstroTool-V2SettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        _ = try store.createFilter(manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        #expect(throws: SettingsStoreError.self) { try store.createFilter(manufacturer: "", model: "", passband: .unknown) }
        #expect(throws: SettingsStoreError.self) { try store.createFilter(manufacturer: "svbony", model: "sv220", passband: .dualBand) }
        #expect(store.filters.count == 1)
    }

    // MARK: - Extended target catalog (wave-5 Task 5)
    //
    // Shipped opt-in/default-off; the owner then asked for it on by default
    // with a first-launch download, since the built-in 217 objects are far too
    // narrow to plan from. The default is therefore ON — but because that
    // means the app reaches the network on first run, the privacy copy has to
    // say so plainly and the switch-off has to stay one click away.

    @Test("The extended-catalog toggle defaults to ON and the privacy copy admits the network use")
    func extendedCatalogDefaultsToOnAndSaysSo() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains("@AppStorage(\"v2.settings.extended-catalog\") private var extendedCatalogEnabled = true"))
        // The user must be told it is on by default and how to turn it off.
        #expect(source.contains("on by default"))
        #expect(source.contains("Turn it off"))
    }

    @Test("The catalog is fetched once on first launch, not on every render")
    func extendedCatalogFetchesOnceOnFirstLaunch() throws {
        let settings = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        // A guarded, explicit entry point rather than work in `init` — the
        // store is held in a `@State` default expression, which SwiftUI
        // re-evaluates on every view construction.
        #expect(settings.contains("func startUpdateIfNeeded(isEnabled: Bool) async"))
        #expect(settings.contains("guard isEnabled, cachedTargetCount == nil"))
        #expect(!settings.contains("        reloadCachedSummary()\n    }\n\n    private static func productionCache"))

        let planning = try contents("Sources/AstroUI/Features/Planning/PlanningView.swift")
        #expect(planning.contains("startUpdateIfNeeded(isEnabled: extendedCatalogEnabled)"))
    }

    @Test("Settings states plainly that only catalogue names/coordinates leave the machine, and carries the required SIMBAD/VizieR attribution")
    func extendedCatalogSurfaceAndAttribution() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains("v2.settings.extended-catalog"))
        #expect(source.contains("v2.settings.update-catalog"))
        #expect(source.contains("never your library's files, paths, targets, or notes"))
        #expect(source.contains("This research has made use of the SIMBAD database and the VizieR catalogue access tool, CDS, Strasbourg, France."))
    }

    @Test("The Update Catalog action is disabled while the toggle is off")
    func updateCatalogButtonDisabledWhenToggleOff() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains(".disabled(!extendedCatalogEnabled)"))
    }

    @Test("The catalog update runs through OperationHost with cooperative cancellation")
    func updateCatalogRunsThroughOperationHost() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains("operationHost.run(kind: .catalogFetch"))
        #expect(source.contains("cancellation: .cooperative"))
        #expect(source.contains("v2.settings.update-catalog-cancel"))
    }

    // MARK: - Language preference (localization plan Task 1)

    @Test("The General tab offers a language picker with the three AppLanguage cases and an honest restart notice")
    func languagePickerSurface() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains("v2.settings.language"))
        #expect(source.contains("AppLanguage.allCases"))
        // It must not claim the change is instantaneous -- `Bundle.main`'s
        // preferred localization is fixed for the process's lifetime, so
        // only a restart actually picks up a new language.
        #expect(!source.contains("takes effect immediately"))
        #expect(source.contains("restart"))
    }

    @Test("Picking a language actually applies the AppLanguage override, not just updates local state")
    func languagePickerAppliesTheOverride() throws {
        let source = try contents("Sources/AstroUI/Settings/V2SettingsView.swift")
        #expect(source.contains(".apply("))
    }

    @Test("ExtendedCatalogUpdateStore reflects a saved cache and updates it after a fixture-driven fetch, never the network")
    func extendedCatalogUpdateStoreReflectsCacheAndFetches() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-ExtendedCatalogTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extended-catalog-v1.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = CatalogCache(fileURL: cacheURL)

        let store = ExtendedCatalogUpdateStore(
            cache: cache,
            fetcherFactory: {
                CatalogFetcher(transport: { url in
                    // `fetchAll()` queries all six sources; the SIMBAD
                    // (Abell planetary nebulae) request must get valid JSON
                    // back, everything else can share the one Sharpless-
                    // shaped fixture (only `.sharpless` actually parses a
                    // row out of it -- the rest legitimately yield zero,
                    // which is fine for this plumbing test).
                    if url.host?.contains("simbad") == true {
                        return Data(#"{"data":[]}"#.utf8)
                    }
                    return Data("""
                    Sh2	_RAJ2000	_DEJ2000	Diam
                     	deg	deg	arcmin
                    ----	----------	----------	----
                       1	239.713380	-26.120461	 150
                    """.utf8)
                })
            }
        )

        #expect(store.cachedTargetCount == nil)
        #expect(store.lastFetchedAt == nil)

        await store.startUpdate()
        // OperationHost's own `run` starts the work on a detached task and
        // returns as soon as it's registered -- give it a moment to finish
        // before asserting on its outcome (matching `OperationHostTests`'
        // own `waitUntil` pattern, inlined here to avoid a cross-module
        // dependency on that test helper).
        for _ in 0..<50 where store.cachedTargetCount == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(store.cachedTargetCount == 1)
        #expect(store.lastFetchedAt != nil)
        #expect(cache.load()?.targets.first?.designation == "Sh2-1")
    }
}
