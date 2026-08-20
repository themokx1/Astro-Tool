import AstroCore
import Foundation

/// Tiny, additive on-disk state for `ClearSkyTrigger` -- not the index DB (a
/// v8/v12-schema table would be overkill for two fields nobody queries), and
/// not `AstroConfig`/`config.json` either, since this is disposable runtime
/// state the user never edits, not a preference. Lives at
/// `.astro_tool/clear_sky_trigger_state.json`, written through
/// `WriteGuard.writeToolFile` -- the exact same mechanism
/// `AstroConfig.save(using:)` already uses for `config.json`, per the
/// spec's own "a `config.json` mechanizmusával azonos módon" instruction.
public enum ClearSkyTriggerStateStore {
    static let relativePath = "clear_sky_trigger_state.json"

    /// Reads the persisted state, or `ClearSkyTrigger.State()` (nothing
    /// notified yet, no baseline) for a missing or corrupt file -- this is
    /// disposable runtime state, not a user document, so a decode failure is
    /// never worth surfacing as an error; the trigger just starts over from
    /// a clean slate rather than throwing.
    public static func load(from rootURL: URL) -> ClearSkyTrigger.State {
        let url = rootURL.appendingPathComponent(".astro_tool").appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return ClearSkyTrigger.State() }
        return (try? JSONDecoder().decode(ClearSkyTrigger.State.self, from: data)) ?? ClearSkyTrigger.State()
    }

    /// Persists `state` via `writeGuard` -- always under that guard's own
    /// `.astro_tool/`, never anywhere else in the library.
    public static func save(_ state: ClearSkyTrigger.State, using writeGuard: WriteGuard) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try writeGuard.writeToolFile(relativePath: relativePath, data: data)
    }
}
