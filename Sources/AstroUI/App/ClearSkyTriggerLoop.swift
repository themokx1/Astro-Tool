import AstroApplication
import Foundation

/// V3 pre-stack program section 5.5 ("Derült-trigger"): the ONE place this
/// app starts the in-process periodic "has it cleared up for tonight?"
/// check. Per the spec's own "In-process korlátozás -- kimondva": V3.0 ships
/// no daemon/launch-agent, so this only ever runs while `AstroToolApp`'s own
/// `WindowGroup` content is alive (see `AstroToolApp.swift`'s `.task`
/// attached to `V2RootView`) -- closing the app's last window ends it,
/// honestly, exactly as `NotificationSettingsView`'s own copy says.
///
/// `ClearSkyTriggerCheckRunner.check` itself is cheap to call when the
/// feature is disabled or unconfigured (an early, honest return before any
/// DB/network work) -- so this loop makes no attempt to only run while
/// `config.notification.enabled`; the runner's own first guard already
/// covers that far more simply than duplicating config-reading here.
public enum ClearSkyTriggerLoop {
    /// How often this polls while a window is open. Coarser than 5.6's own
    /// file-watch poll interval (a different feature, different cadence
    /// need) -- `ClearSkyTrigger.evaluate` is keyed by calendar day and one
    /// configured check hour, so anything finer than this buys nothing but
    /// repeated `Planner.plan`/calibration-coverage work against the real
    /// library database for no behavioral difference.
    public static let pollIntervalSeconds: UInt64 = 30 * 60

    /// Runs until the surrounding `Task` is cancelled (i.e. for as long as
    /// the window this `.task` is attached to exists) -- `currentRootURL` is
    /// read fresh on every tick rather than captured once, so a library
    /// switch mid-session is picked up without restarting this loop.
    public static func runWhileActive(currentRootURL: @escaping @Sendable () -> URL?) async {
        while !Task.isCancelled {
            if let rootURL = currentRootURL() {
                _ = await ClearSkyTriggerCheckRunner.check(rootURL: rootURL)
            }
            try? await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
        }
    }
}
