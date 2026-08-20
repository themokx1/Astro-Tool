import Foundation

/// V3 pre-stack program, section 5.1 (Ingest-figyelő): the opt-in toggle's
/// own `UserDefaults` key, following the exact pattern
/// `AppState.autoScanOnMount` already established (a plain boolean,
/// default OFF, no `config.json` involvement -- this is a per-machine UI
/// preference, not library shape).
///
/// This constant is the single source of truth both sides of the toggle
/// share without either one depending on the other: `AstroToolApp.AppState`
/// (Settings ▸ Könyvtár's own toggle) writes it, and `AstroUI.IngestWatcher`
/// (the actual mount-notification watcher) reads it -- `AstroApplication`
/// sits below both in the dependency graph (`AstroCore` <- `AstroApplication`
/// <- `AstroUI` <- `AstroToolApp`), so this is the lowest shared layer that
/// can hold one literal string both can reference instead of two string
/// literals that could silently drift apart.
public enum IngestWatcherSettings {
    public static let enabledDefaultsKey = "ingestWatcherEnabled"
}
