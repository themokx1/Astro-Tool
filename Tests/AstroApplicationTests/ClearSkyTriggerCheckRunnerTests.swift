import AstroApplication
import AstroCore
import Foundation
import Testing

/// `ClearSkyTriggerCheckRunner.check` is the thin glue between config, the
/// real site/weather/plan resolution, and the pure `ClearSkyTrigger` engine.
/// These tests only exercise its two honest, fully-offline early exits --
/// disabled in Settings, and no site configured/derivable -- since anything
/// past site resolution needs a live network fetch (`WeatherService`), which
/// is out of scope for a deterministic unit suite (the spec's own
/// "app-nem-fut szcenárió... nem tesztelhető unit szinten" allowance covers
/// this exact boundary: the DECISION logic is unit tested in
/// `ClearSkyTriggerTests`, the live integration is not). What matters here
/// is the house rule these two paths exist to satisfy: "quiet if the site is
/// unconfigured (honest empty state)".
@Suite("Clear-sky trigger check runner (V3 5.5)")
struct ClearSkyTriggerCheckRunnerTests {
    private struct TempLibrary {
        let root: URL
        let applicationSupport: URL
        let caches: URL

        static func make() throws -> TempLibrary {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("clear-sky-runner-tests-\(UUID().uuidString)", isDirectory: true)
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

        /// The same injectable-`AppStoragePaths` seam `SiteSettingsStoreTests`
        /// already establishes -- points storage at this fixture's own temp
        /// roots instead of the user's real Application Support/Caches, and
        /// creates the index DB's own parent directory up front so
        /// `Database(path:)` can open (and initialize) a brand-new, empty
        /// index there.
        func storagePaths(identity: LibraryIdentity, libraryRoot: URL) throws -> AppStoragePaths {
            let paths = try AppStoragePaths(
                applicationSupport: applicationSupport, caches: caches, libraryID: identity, libraryRoot: libraryRoot
            )
            try FileManager.default.createDirectory(
                at: paths.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            return paths
        }
    }

    @Test("Notifications disabled in Settings: quiet, never even resolves a site")
    func disabledIsQuiet() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }

        var config = AstroConfig()
        config.notification.enabled = false
        try config.save(using: WriteGuard(root: library.root))

        let outcome = await ClearSkyTriggerCheckRunner.check(
            rootURL: library.root,
            storagePaths: { try library.storagePaths(identity: $0, libraryRoot: $1) }
        )

        #expect(outcome == .disabled)
    }

    @Test("Enabled but no site configured and nothing scanned yet: honest empty state, never a guess")
    func noSiteIsHonestlyQuiet() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }

        var config = AstroConfig()
        config.notification.enabled = true
        // No `config.site`/`config.sites`, and the freshly-created index DB
        // has zero scanned lights -- `Planner.resolveSite` has nothing to
        // derive a coordinate from at all.
        try config.save(using: WriteGuard(root: library.root))

        let outcome = await ClearSkyTriggerCheckRunner.check(
            rootURL: library.root,
            storagePaths: { try library.storagePaths(identity: $0, libraryRoot: $1) }
        )

        #expect(outcome == .noSite)
    }

    @Test("An unconfigured library never writes trigger state -- nothing to dedupe, nothing to prune later")
    func noSiteNeverPersistsState() async throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }

        var config = AstroConfig()
        config.notification.enabled = true
        try config.save(using: WriteGuard(root: library.root))

        _ = await ClearSkyTriggerCheckRunner.check(
            rootURL: library.root,
            storagePaths: { try library.storagePaths(identity: $0, libraryRoot: $1) }
        )

        let stateFile = library.root.appendingPathComponent(".astro_tool/clear_sky_trigger_state.json")
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
    }

    /// `check` is `async` and `public`, and its only caller lives in another
    /// module (`AstroUI.ClearSkyTriggerLoop`) -- exactly the cross-module
    /// shape `AsyncContextSizeGateTests` exists to catch. A default argument
    /// on such a function is emitted into every client translation unit as a
    /// `linkonce_odr` copy, and Swift 6.3.3 sizes those copies differently
    /// from the declaring module's, which corrupts the task allocator once
    /// the linker pairs a large body with a small size record. This is a
    /// source-text check (this repo's "surface test" convention) that the
    /// declaration keeps the `Optional`-parameter/resolve-in-body shape the
    /// rest of the codebase now uses, since the binary gate only notices
    /// after an unrelated edit re-rolls the linker's dice.
    @Test("check() takes no defaulted arguments -- every injection point is Optional and resolved in the body")
    func checkDeclaresNoDefaultArguments() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AstroApplication/Notifications/ClearSkyTriggerCheckRunner.swift"),
            encoding: .utf8
        )
        let signature = try #require(
            source.components(separatedBy: "public static func check(").dropFirst().first?
                .components(separatedBy: ") async").first
        )
        for parameter in ["scheduler", "storagePaths", "now", "calendar"] {
            #expect(
                signature.contains("\(parameter): ") && signature.contains("? = nil"),
                "\(parameter) must be an Optional parameter resolved inside check()'s body"
            )
        }
        #expect(!signature.contains("= {"), "no closure default argument may cross the module boundary")
        #expect(!signature.contains("= .shared"))
        #expect(!signature.contains("= Date()"))
        #expect(!signature.contains("= .current"))
    }
}
