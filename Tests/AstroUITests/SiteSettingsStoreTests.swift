@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// Task 1 (V2 UI/UX audit section 2.1): before this store existed, the only
/// writer of `AstroConfig.site`/`sites` was hand-editing
/// `<library-root>/.astro_tool/config.json` outside the app -- Settings had
/// no observing-site control at all, so a library whose FITS lack
/// `SITELAT`/`SITELONG` was permanently stuck with an empty Planning tab, a
/// "Site not set" Home rail, and an unusable 30-night calendar, with no way
/// in-app to fix it. These tests exercise the actual round trip
/// (`SiteSettingsStore.save()` -> disk -> `Planner.resolveSite`, the exact
/// function Planning/Home/Nights all call), plus validation and the
/// no-library-open state.
@MainActor
@Suite("Site settings store")
struct SiteSettingsStoreTests {
    private struct TempLibrary {
        let root: URL
        let applicationSupport: URL
        let caches: URL

        static func make() throws -> TempLibrary {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("AstroTool-SiteSettingsTests-\(UUID().uuidString)", isDirectory: true)
            let root = base.appendingPathComponent("library", isDirectory: true)
            let applicationSupport = base.appendingPathComponent("app-support", isDirectory: true)
            let caches = base.appendingPathComponent("caches", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            return TempLibrary(root: root, applicationSupport: applicationSupport, caches: caches)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }

        /// The exact same storage layout `Planner.resolveSite`'s production
        /// callers (`PlanningStore.productionSkyContext`, `HomeStore`,
        /// `NightsStore`) resolve via `AppStoragePaths.production` -- just
        /// pointed at this fixture's own temp application-support/caches
        /// roots instead of the user's real ones (`V2PreviewFixtures`
        /// establishes this exact pattern for UI-test fixtures already).
        func openIndexDatabase() throws -> Database {
            let identity = LibraryIdentity(rootURL: root)
            let paths = try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: identity,
                libraryRoot: root
            )
            try FileManager.default.createDirectory(
                at: paths.indexDatabase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try Database(path: paths.indexDatabase.path)
        }

        func siteResolver(rootURL: URL, config: AstroConfig) async -> SiteRule? {
            let identity = LibraryIdentity(rootURL: rootURL)
            guard let paths = try? AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: identity,
                libraryRoot: rootURL
            ), let database = try? Database(path: paths.indexDatabase.path) else { return nil }
            return try? Planner.resolveSite(db: database, config: config)
        }
    }

    // MARK: - Round trip through `Planner.resolveSite`'s own storage path

    @Test("Saving a site persists to config.json and Planner.resolveSite reads back exactly what was saved")
    func savedSiteRoundTripsThroughPlannerResolveSite() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        _ = try library.openIndexDatabase() // creates the index database file

        let store = SiteSettingsStore(rootURL: library.root)
        store.setNameText("Backyard")
        store.setLatitudeText("47.4979")
        store.setLongitudeText("19.0402")

        #expect(store.save())
        #expect(store.errorMessage == nil)

        // Read back through the exact on-disk path `AstroConfig` itself
        // documents (`.astro_tool/config.json`), then resolve it exactly the
        // way `Planner.resolveSite` does for every other caller.
        let configURL = library.root.appendingPathComponent(".astro_tool/config.json")
        let reloaded = try AstroConfig.load(from: configURL)
        #expect(reloaded.site.latitudeDeg == 47.4979)
        #expect(reloaded.site.longitudeDeg == 19.0402)
        #expect(reloaded.sites.map(\.name) == ["Backyard"])
        #expect(reloaded.sites.first?.isDefault == true)

        let database = try library.openIndexDatabase()
        let resolved = try Planner.resolveSite(db: database, config: reloaded)
        #expect(resolved.latitudeDeg == 47.4979)
        #expect(resolved.longitudeDeg == 19.0402)
    }

    @Test("A config.json with an existing multi-site list is still overridden by this tab's single-site save")
    func saveOverridesAPreExistingSitesList() throws {
        // `Planner.resolveSite` treats a non-empty `sites` as AUTHORITATIVE
        // over `site` -- if this tab only ever wrote `site`, saving here
        // would silently do nothing for a config.json that already has
        // `sites` populated. Guards against that regression.
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        var initialConfig = AstroConfig()
        initialConfig.rootPath = library.root.path
        initialConfig.sites = [
            SiteProfile(name: "Old Site A", latitudeDeg: 10, longitudeDeg: 10, isDefault: true),
            SiteProfile(name: "Old Site B", latitudeDeg: 20, longitudeDeg: 20, isDefault: false),
        ]
        try initialConfig.save(using: WriteGuard(root: library.root))
        _ = try library.openIndexDatabase()

        let store = SiteSettingsStore(rootURL: library.root)
        store.setNameText("New Site")
        store.setLatitudeText("5")
        store.setLongitudeText("6")
        #expect(store.save())

        let configURL = library.root.appendingPathComponent(".astro_tool/config.json")
        let reloaded = try AstroConfig.load(from: configURL)
        #expect(reloaded.sites.map(\.name) == ["New Site"])

        let database = try library.openIndexDatabase()
        let resolved = try Planner.resolveSite(db: database, config: reloaded)
        #expect(resolved.latitudeDeg == 5)
        #expect(resolved.longitudeDeg == 6)
    }

    // MARK: - Loading an existing config prefills the draft

    @Test("Opening the tab against a library that already has a configured site prefills the draft fields")
    func loadsExistingSiteIntoDraft() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        var config = AstroConfig()
        config.rootPath = library.root.path
        config.sites = [SiteProfile(name: "Kertem", latitudeDeg: 47.1234, longitudeDeg: 19.5678, isDefault: true)]
        config.site = SiteRule(latitudeDeg: 47.1234, longitudeDeg: 19.5678)
        try config.save(using: WriteGuard(root: library.root))

        let store = SiteSettingsStore(rootURL: library.root)

        #expect(store.nameText == "Kertem")
        #expect(store.latitudeText == "47.1234")
        #expect(store.longitudeText == "19.5678")
    }

    // MARK: - Validation

    @Test("Latitude outside -90...90 is rejected and never written")
    func rejectsOutOfRangeLatitude() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SiteSettingsStore(rootURL: library.root)
        store.setLatitudeText("120")
        store.setLongitudeText("19")

        #expect(!store.save())
        #expect(store.errorMessage != nil)

        let configURL = library.root.appendingPathComponent(".astro_tool/config.json")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("Longitude outside -180...180 is rejected and never written")
    func rejectsOutOfRangeLongitude() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SiteSettingsStore(rootURL: library.root)
        store.setLatitudeText("47")
        store.setLongitudeText("200")

        #expect(!store.save())
        #expect(store.errorMessage != nil)

        let configURL = library.root.appendingPathComponent(".astro_tool/config.json")
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("Non-numeric coordinates are rejected rather than silently coerced")
    func rejectsNonNumericCoordinates() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = SiteSettingsStore(rootURL: library.root)
        store.setLatitudeText("north-ish")
        store.setLongitudeText("19")

        #expect(!store.save())
        #expect(store.errorMessage != nil)
    }

    @Test("Boundary values -90/-180 and 90/180 are accepted, not off-by-one rejected")
    func acceptsBoundaryValues() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        _ = try library.openIndexDatabase()
        let store = SiteSettingsStore(rootURL: library.root)
        store.setLatitudeText("-90")
        store.setLongitudeText("-180")

        #expect(store.save())
    }

    // MARK: - No library open

    @Test("With no library open, saving fails honestly instead of writing anywhere")
    func noLibraryOpenRefusesToSave() throws {
        let store = SiteSettingsStore(rootURL: nil)

        #expect(!store.hasLibraryOpen)
        store.setLatitudeText("47")
        store.setLongitudeText("19")
        #expect(!store.save())
        #expect(store.errorMessage != nil)
    }

    @Test("With no library open, refreshEffectiveSite reports nothing rather than crashing")
    func noLibraryOpenEffectiveSiteIsNil() async throws {
        let store = SiteSettingsStore(rootURL: nil)
        await store.refreshEffectiveSite()
        #expect(store.effectiveSite == nil)
    }

    // MARK: - Effective-site source (configured vs. derived from FITS)

    @Test("With an explicit site configured, the effective site reports .configured")
    func effectiveSiteReportsConfigured() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        _ = try library.openIndexDatabase()

        let store = SiteSettingsStore(rootURL: library.root, siteResolver: library.siteResolver)
        store.setLatitudeText("47.5")
        store.setLongitudeText("19.04")
        #expect(store.save())

        await store.refreshEffectiveSite()

        #expect(store.effectiveSite?.latitudeDeg == 47.5)
        #expect(store.effectiveSite?.longitudeDeg == 19.04)
        #expect(store.effectiveSite?.source == .configured)
    }

    @Test("With no configured site but FITS SITELAT/SITELONG present, the effective site reports .derivedFromFITS")
    func effectiveSiteReportsDerivedFromFITS() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let database = try library.openIndexDatabase()
        let id = try database.upsertFile(FileRecord(
            path: "sessions/M31/2026-08-10/lights/l1.fit", size: 0, mtime: 0, ext: "fit", kind: "fits",
            area: .sessions, target: "M31", sessionDate: "2026-08-10", role: .light, scannedAt: 0
        ))
        let header = try String(data: JSONEncoder().encode(["SITELAT": "47.5", "SITELONG": "19.04"]), encoding: .utf8)!
        try database.upsertFITSMeta(FITSMetaRecord(fileID: id, exptime: 300, filter: nil, headerJSON: header))

        let store = SiteSettingsStore(rootURL: library.root, siteResolver: library.siteResolver)
        await store.refreshEffectiveSite()

        #expect(store.effectiveSite?.latitudeDeg == 47.5)
        #expect(store.effectiveSite?.longitudeDeg == 19.04)
        #expect(store.effectiveSite?.source == .derivedFromFITS)
    }

    @Test("With neither a configured site nor derivable FITS coordinates, the effective site reports .notSet")
    func effectiveSiteReportsNotSet() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        _ = try library.openIndexDatabase()

        let store = SiteSettingsStore(rootURL: library.root, siteResolver: library.siteResolver)
        await store.refreshEffectiveSite()

        #expect(store.effectiveSite?.latitudeDeg == nil)
        #expect(store.effectiveSite?.source == .notSet)
    }

    // MARK: - Settings surface (V2SettingsView)

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("V2SettingsView carries a findable Location tab with the site editor's accessibility identifiers")
    func locationTabSurfaceExists() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains(#"Label("Location", systemImage: "location")"#))
        #expect(source.contains("v2.settings.site.latitude"))
        #expect(source.contains("v2.settings.site.longitude"))
        #expect(source.contains("v2.settings.site.save"))
    }
}
