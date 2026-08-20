import Foundation

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): the opt-in toggle's
/// and the chosen-folder bookmark's own `UserDefaults` keys, following the
/// exact split `IngestWatcherSettings` (this same directory's sibling
/// feature) already established -- `AstroApplication` sits below both
/// `AstroToolApp` (Settings ▸ Könyvtár's toggle/folder-picker,
/// `AppState.liveNightWatcherEnabled`/`.chooseLiveNightFolder()`) and
/// `AstroUI` (`LiveNightWatcher`, which reads both keys independently) in
/// the dependency graph, so this is the lowest shared layer that can hold
/// these two literal strings once instead of twice.
public enum LiveNightWatcherSettings {
    public static let enabledDefaultsKey = "liveNightWatcherEnabled"
    /// Security-scoped bookmark data for the watched folder (the rig's own
    /// mounted share, or any folder the owner points this at) -- resolved
    /// independently by `AstroUI.LiveNightWatcher` the same way
    /// `AppState`'s own root-folder bookmark is resolved, since a plain
    /// path string would not survive re-launch once App Sandbox is
    /// involved.
    public static let folderBookmarkDefaultsKey = "liveNightWatchFolderBookmark"
}
