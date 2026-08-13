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
        #expect(source.contains("restoreSavedLibrary()"))
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
}
