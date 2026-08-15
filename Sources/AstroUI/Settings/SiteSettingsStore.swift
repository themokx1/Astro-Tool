import AstroApplication
import AstroCore
import Foundation
import Observation

/// Task 1 (V2 UI/UX audit section 2.1): the observing-site editor Settings
/// never had. `PlanningView`'s `.noSite` empty state, `HomeView`'s "Site not
/// set" night-context rail, and `NightsView`'s 30-night calendar empty state
/// all send the user to Settings for this -- but until now nothing there
/// could write `AstroConfig.site`/`sites` at all. The only way in was
/// hand-editing `<library-root>/.astro_tool/config.json` outside the app.
///
/// Writes go through the exact same `AstroConfig.save(using:)` -> `WriteGuard`
/// path every other Settings tab already uses, and -- crucially -- populate
/// BOTH the legacy single-site `config.site` AND the newer named
/// `config.sites` list, because `Planner.resolveSite` treats a non-empty
/// `sites` as AUTHORITATIVE over `site` (see that method's own doc comment):
/// writing only `site` would silently do nothing for a config.json that
/// already has `sites` populated (e.g. from an existing multi-site
/// configuration). This tab is deliberately a SINGLE-site editor -- saving
/// always replaces `sites` with exactly the one entry being edited here,
/// which becomes that library's sole/default site.
@MainActor
@Observable
public final class SiteSettingsStore {
    public enum EffectiveSiteSource: Equatable, Sendable {
        /// `AstroConfig.site`/`sites` explicitly names this coordinate.
        case configured
        /// No explicit configuration; derived from the library's own scanned
        /// `SITELAT`/`SITELONG` FITS headers (`Planner.resolveSite`'s
        /// FITS-median fallback, `TargetCoordinates.medianSite`).
        case derivedFromFITS
        /// Neither configured nor derivable from the library -- nothing to
        /// plan against.
        case notSet
    }

    /// What `Planner.resolveSite` -- the exact function Planning/Home/Nights
    /// all call -- actually resolves right now, so this tab can show an
    /// honest "what's in effect" read-out instead of only echoing the
    /// editable draft fields back.
    public struct EffectiveSite: Equatable, Sendable {
        public let latitudeDeg: Double?
        public let longitudeDeg: Double?
        public let source: EffectiveSiteSource

        public init(latitudeDeg: Double?, longitudeDeg: Double?, source: EffectiveSiteSource) {
            self.latitudeDeg = latitudeDeg
            self.longitudeDeg = longitudeDeg
            self.source = source
        }
    }

    public enum SiteSettingsError: LocalizedError, Equatable {
        case noLibraryOpen
        case invalidCoordinates
        case latitudeOutOfRange
        case longitudeOutOfRange

        public var errorDescription: String? {
            switch self {
            case .noLibraryOpen: "Open a library before setting an observing site."
            case .invalidCoordinates: "Enter a numeric latitude and longitude."
            case .latitudeOutOfRange: "Latitude must be between -90 and 90."
            case .longitudeOutOfRange: "Longitude must be between -180 and 180."
            }
        }
    }

    public private(set) var latitudeText = ""
    public private(set) var longitudeText = ""
    public private(set) var nameText = ""
    public private(set) var effectiveSite: EffectiveSite?
    public private(set) var errorMessage: String?
    public private(set) var saveMessage: String?
    public private(set) var isRefreshing = false

    public let rootURL: URL?
    private let configLoader: @Sendable (URL) -> AstroConfig
    private let configSaver: @Sendable (AstroConfig, URL) throws -> Void
    private let siteResolver: @Sendable (URL, AstroConfig) async -> SiteRule?

    public init(
        rootURL: URL?,
        configLoader: @escaping @Sendable (URL) -> AstroConfig = SiteSettingsStore.productionConfigLoader,
        configSaver: @escaping @Sendable (AstroConfig, URL) throws -> Void = SiteSettingsStore.productionConfigSaver,
        siteResolver: @escaping @Sendable (URL, AstroConfig) async -> SiteRule? = SiteSettingsStore.productionSiteResolver
    ) {
        self.rootURL = rootURL
        self.configLoader = configLoader
        self.configSaver = configSaver
        self.siteResolver = siteResolver
        if let rootURL {
            loadDraft(from: configLoader(rootURL))
        }
    }

    public var hasLibraryOpen: Bool { rootURL != nil }

    public func setLatitudeText(_ text: String) {
        latitudeText = text
        saveMessage = nil
    }

    public func setLongitudeText(_ text: String) {
        longitudeText = text
        saveMessage = nil
    }

    public func setNameText(_ text: String) {
        nameText = text
        saveMessage = nil
    }

    /// Resolves what `Planner.resolveSite` sees for this library right now
    /// -- config-explicit, FITS-derived, or nothing at all.
    public func refreshEffectiveSite() async {
        guard let rootURL else {
            effectiveSite = nil
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let config = configLoader(rootURL)
        guard let resolved = await siteResolver(rootURL, config),
              resolved.latitudeDeg != nil, resolved.longitudeDeg != nil
        else {
            effectiveSite = EffectiveSite(latitudeDeg: nil, longitudeDeg: nil, source: .notSet)
            return
        }
        let source: EffectiveSiteSource = Self.isExplicitlyConfigured(config) ? .configured : .derivedFromFITS
        effectiveSite = EffectiveSite(latitudeDeg: resolved.latitudeDeg, longitudeDeg: resolved.longitudeDeg, source: source)
    }

    /// Validates and persists the draft. Rejects out-of-range/non-numeric
    /// input outright rather than writing it -- `AstroConfig` itself has no
    /// range validation of its own (`SiteRule` accepts any `Double`), so this
    /// tab is the one place that enforces lat -90...90 / lon -180...180.
    @discardableResult
    public func save() -> Bool {
        errorMessage = nil
        saveMessage = nil
        guard let rootURL else {
            errorMessage = SiteSettingsError.noLibraryOpen.errorDescription
            return false
        }
        let trimmedLat = latitudeText.trimmingCharacters(in: .whitespaces)
        let trimmedLon = longitudeText.trimmingCharacters(in: .whitespaces)
        guard let lat = Double(trimmedLat), let lon = Double(trimmedLon) else {
            errorMessage = SiteSettingsError.invalidCoordinates.errorDescription
            return false
        }
        guard (-90...90).contains(lat) else {
            errorMessage = SiteSettingsError.latitudeOutOfRange.errorDescription
            return false
        }
        guard (-180...180).contains(lon) else {
            errorMessage = SiteSettingsError.longitudeOutOfRange.errorDescription
            return false
        }

        var config = configLoader(rootURL)
        config.rootPath = rootURL.path
        config.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let siteName = trimmedName.isEmpty ? "Observing Site" : trimmedName
        config.sites = [SiteProfile(name: siteName, latitudeDeg: lat, longitudeDeg: lon, isDefault: true)]

        do {
            try configSaver(config, rootURL)
            nameText = siteName
            saveMessage = "Saved."
            return true
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
    }

    private func loadDraft(from config: AstroConfig) {
        if let def = SiteProfile.defaultSite(in: config.sites) {
            nameText = def.name
            latitudeText = String(format: "%.4f", def.latitudeDeg)
            longitudeText = String(format: "%.4f", def.longitudeDeg)
        } else if let lat = config.site.latitudeDeg, let lon = config.site.longitudeDeg {
            nameText = ""
            latitudeText = String(format: "%.4f", lat)
            longitudeText = String(format: "%.4f", lon)
        }
    }

    private static func isExplicitlyConfigured(_ config: AstroConfig) -> Bool {
        if !config.sites.isEmpty { return true }
        return config.site.latitudeDeg != nil && config.site.longitudeDeg != nil
    }

    public nonisolated static func productionConfigLoader(rootURL: URL) -> AstroConfig {
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = rootURL.path
        return config
    }

    public nonisolated static func productionConfigSaver(config: AstroConfig, rootURL: URL) throws {
        let writeGuard = WriteGuard(root: rootURL)
        try config.save(using: writeGuard)
    }

    /// The exact same lookup `PlanningStore.productionSkyContext`/
    /// `HomeStore`/`NightsStore` already use: the library's own cache-backed
    /// index database, read through `Planner.resolveSite`.
    public nonisolated static func productionSiteResolver(rootURL: URL, config: AstroConfig) async -> SiteRule? {
        await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            guard let paths = try? AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL),
                  let database = try? Database(path: paths.indexDatabase.path)
            else { return nil }
            return try? Planner.resolveSite(db: database, config: config)
        }.value
    }
}
