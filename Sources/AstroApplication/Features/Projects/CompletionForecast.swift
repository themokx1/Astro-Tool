import Foundation

/// One resolved "how much longer until this target is done" estimate --
/// the answer behind the Overview tab's "still about N clear nights to
/// go" stat row, expert ideation spec #2 ("még ~3 tiszta éjszaka a
/// célig"). `Equatable`/`Sendable` like every other small `AstroApplication`
/// report model; not `Codable` -- nothing persists this, it is derived
/// fresh on every report load from `ProjectReportQuery.Result`'s own
/// `projectState`/`recentSessionIntegrationSeconds`.
public struct CompletionForecastEstimate: Equatable, Sendable {
    /// Whole clear nights still needed at the observed pace, rounded UP --
    /// a fractional night is still a night you have to go out for. Never
    /// negative, never `0` (see `CompletionForecast.nightsNeeded`'s own doc
    /// for why `remainingSeconds` is already guaranteed positive here).
    /// Capped at `CompletionForecast.maximumDisplayedNights` -- see
    /// `isCapped`.
    public let nightsNeeded: Int
    /// The pace this estimate divided by -- the average of the recent
    /// per-session `integrationSeconds` handed in, exposed so the UI can
    /// show "at your current pace of X h/night" alongside the night count
    /// rather than just the count alone.
    public let paceSecondsPerNight: Double
    /// `true` when the literal computed night count exceeded
    /// `CompletionForecast.maximumDisplayedNights` and `nightsNeeded` was
    /// clamped to that ceiling instead -- the UI reads this to print
    /// "20+ éjszaka" rather than a falsely precise "47 éjszaka" for a
    /// project that is realistically nowhere near done.
    public let isCapped: Bool

    public init(nightsNeeded: Int, paceSecondsPerNight: Double, isCapped: Bool) {
        self.nightsNeeded = nightsNeeded
        self.paceSecondsPerNight = paceSecondsPerNight
        self.isCapped = isCapped
    }
}

/// Pure "am I close to done" forecast, expert ideation spec #2. Reads no
/// database and touches no filesystem -- every input already lives in
/// `ProjectReportQuery.Result` (`projectState.missingSeconds` for
/// `remainingSeconds`, `recentSessionIntegrationSeconds` for
/// `recentSessionSeconds`), so this is a plain, exhaustively testable
/// division-plus-rounding function with its own explicit honesty rails
/// rather than logic folded into the view.
///
/// Deliberately returns `nil` for BOTH of its two "don't forecast" cases
/// (fewer than two recent sessions, and nothing left to reach) rather than
/// a tri-state enum: the two cases render completely differently in the UI
/// (an explicit "not enough data yet" sentence vs. nothing at all, because
/// the goal-met state already has its own "reached" text) and the caller
/// already has to know `remainingSeconds`/`recentSessionSeconds.count`
/// independently to decide which message applies -- see
/// `ProjectWorkspaceView.completionForecastText` for exactly that branch.
public enum CompletionForecast {
    /// Never printed as a bare number past this -- see
    /// `CompletionForecastEstimate.isCapped`.
    public static let maximumDisplayedNights = 20

    /// Never estimates a pace from a single data point -- one session tells
    /// you nothing about a REPEATABLE rate, only that one night happened.
    private static let minimumSessionsForPace = 2

    /// `nil` when `remainingSeconds <= 0` (goal already met -- the UI's own
    /// "reached" text already covers that state, this must not also print a
    /// night count) or when `recentSessionSeconds.count` is under
    /// `minimumSessionsForPace` (not enough history to call anything a
    /// "pace" yet). `nil` again if the resulting pace is non-positive (every
    /// recent session logged 0 usable seconds) -- a zero-or-negative pace
    /// has no finite night count to report, and printing "∞ éjszaka" would
    /// be worse than saying nothing.
    ///
    /// Otherwise: `pace` is the plain arithmetic mean of
    /// `recentSessionSeconds` (typically the last 3-5 sessions for this
    /// target, from `TrendQueries.points` -- the caller decides how many to
    /// hand in), `nightsNeeded` is `ceil(remainingSeconds / pace)` clamped
    /// to `maximumDisplayedNights`.
    public static func nightsNeeded(
        remainingSeconds: Double,
        recentSessionSeconds: [Double]
    ) -> CompletionForecastEstimate? {
        guard remainingSeconds > 0 else { return nil }
        guard recentSessionSeconds.count >= minimumSessionsForPace else { return nil }

        let pace = recentSessionSeconds.reduce(0, +) / Double(recentSessionSeconds.count)
        guard pace > 0 else { return nil }

        let rawNights = (remainingSeconds / pace).rounded(.up)
        let cappedNights = min(rawNights, Double(maximumDisplayedNights))
        return CompletionForecastEstimate(
            nightsNeeded: Int(cappedNights),
            paceSecondsPerNight: pace,
            isCapped: rawNights > Double(maximumDisplayedNights)
        )
    }
}
