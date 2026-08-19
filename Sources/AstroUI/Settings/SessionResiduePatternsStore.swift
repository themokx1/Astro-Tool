import AstroApplication
import AstroCore
import Foundation
import Observation

/// The last piece of the V2 UI/UX audit before v2.0.0: 3b8aeb0 added
/// `AstroConfig.sessionResiduePatterns` (session-area-scoped residue
/// patterns -- filenames like `starless*`/`starmask*`/`*graxpert*`/
/// `result_*` that only count as processing residue INSIDE the `sessions/`
/// area, because the identical vocabulary is a kept stack variant under
/// `stacks/`/`processed/`; see `ResidueMatcher.category`'s own doc comment
/// in `Sources/AstroCore/Audit/Rules.swift`) with an editable pattern-list
/// UI -- but that editor landed in V1's `LibraryRulesSettingsView`
/// (`Sources/AstroToolApp`), which the default V2 shell can never reach. A
/// V2-only owner therefore had no way at all to see, add to, or roll back
/// this list -- only the four engine defaults, or hand-editing
/// `<library-root>/.astro_tool/config.json` outside the app.
///
/// Writes go through the exact same `AstroConfig.save(using:)` -> `WriteGuard`
/// path every other V2 Settings tab already uses -- `configLoader`/
/// `configSaver` default straight to `SiteSettingsStore`'s own production
/// implementations rather than a second, parallel one, so there is only ever
/// one canonical way anything in V2 Settings reads or writes `config.json`.
/// Same shape as `EquipmentSetupsStore` (the freshest precedent for this
/// exact "V1 has it, V2's default shell can't reach it" gap): a `rootURL:
/// URL?` that is `nil` exactly when no library is open, honest
/// `noLibraryOpen` refusal from every mutating method in that state, and a
/// `lastError`/`saveMessage` pair the view surfaces directly.
///
/// Unlike `EquipmentSetupsStore`'s `[ImagingSetupProfile]` (each entry has
/// its own stable `id`), a session-residue pattern is a bare `String` with
/// no identity of its own -- `remove(at:)` therefore addresses entries by
/// their position in `patterns`, matching how the view renders them (a
/// `ForEach` over `patterns.enumerated()`).
@MainActor
@Observable
public final class SessionResiduePatternsStore {
    public enum SessionResiduePatternsError: LocalizedError, Equatable {
        case noLibraryOpen
        case emptyPattern
        case duplicatePattern
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noLibraryOpen: "Open a library before editing library rules."
            case .emptyPattern: "Enter a pattern before adding it."
            case .duplicatePattern: "This pattern is already in the list."
            case .saveFailed(let message): "Could not save: \(message)"
            }
        }
    }

    public private(set) var patterns: [String] = []
    public private(set) var lastError: SessionResiduePatternsError?
    public private(set) var saveMessage: String?

    public let rootURL: URL?
    private let configLoader: @Sendable (URL) -> AstroConfig
    private let configSaver: @Sendable (AstroConfig, URL) throws -> Void

    public init(
        rootURL: URL?,
        configLoader: @escaping @Sendable (URL) -> AstroConfig = SiteSettingsStore.productionConfigLoader,
        configSaver: @escaping @Sendable (AstroConfig, URL) throws -> Void = SiteSettingsStore.productionConfigSaver
    ) {
        self.rootURL = rootURL
        self.configLoader = configLoader
        self.configSaver = configSaver
        if let rootURL {
            patterns = configLoader(rootURL).sessionResiduePatterns
        }
    }

    public var hasLibraryOpen: Bool { rootURL != nil }

    /// Adds a trimmed, non-empty, non-duplicate (case-insensitive) pattern.
    /// Matches `GlobMatcher`'s own case-insensitive comparison
    /// (`Sources/AstroCore/Audit/Rules.swift`), so "Unique_*" and
    /// "unique_*" are treated as the same rule they would actually behave
    /// as at scan time -- keeping both would be a silent, confusing no-op
    /// duplicate rather than a real second rule.
    @discardableResult
    public func add(_ pattern: String) -> Bool {
        lastError = nil
        saveMessage = nil
        guard let rootURL else {
            lastError = .noLibraryOpen
            return false
        }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = .emptyPattern
            return false
        }
        let isDuplicate = patterns.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !isDuplicate else {
            lastError = .duplicatePattern
            return false
        }

        var updated = patterns
        updated.append(trimmed)
        guard persist(updated, rootURL: rootURL) else { return false }
        saveMessage = "Saved."
        return true
    }

    /// Removes the pattern at `index`. An out-of-range index is a quiet
    /// no-op that still reports success -- by the time this runs the view
    /// has already resolved a specific row to remove, so the only way the
    /// index could be stale is a harmless double-invocation, the same
    /// tolerance `EquipmentSetupsStore.delete(id:)` gives an unknown id.
    @discardableResult
    public func remove(at index: Int) -> Bool {
        lastError = nil
        saveMessage = nil
        guard let rootURL else {
            lastError = .noLibraryOpen
            return false
        }
        guard patterns.indices.contains(index) else { return true }

        var updated = patterns
        updated.remove(at: index)
        guard persist(updated, rootURL: rootURL) else { return false }
        saveMessage = "Saved."
        return true
    }

    /// Resets the list to the engine's own `AstroConfig()` defaults
    /// (`starless*`, `starmask*`, `*graxpert*`, `result_*`) and persists
    /// immediately -- a single, low-stakes list reset, so this deliberately
    /// carries no confirmation dialog of its own (unlike
    /// `ImagingSetupsSettingsView`'s per-setup delete, which destroys a
    /// whole hand-built profile).
    @discardableResult
    public func restoreDefaults() -> Bool {
        lastError = nil
        saveMessage = nil
        guard let rootURL else {
            lastError = .noLibraryOpen
            return false
        }
        guard persist(AstroConfig().sessionResiduePatterns, rootURL: rootURL) else { return false }
        saveMessage = "Restored defaults."
        return true
    }

    private func persist(_ updated: [String], rootURL: URL) -> Bool {
        var config = configLoader(rootURL)
        config.sessionResiduePatterns = updated
        do {
            try configSaver(config, rootURL)
            patterns = updated
            return true
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            return false
        }
    }
}
