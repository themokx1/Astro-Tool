import Foundation

/// V3 pre-stack program section 5.5 ("Derült-trigger"): the pure trend
/// decision behind the "tell me when it clears tonight" notification. This
/// enum has NO knowledge of `WeatherService`, `UNUserNotificationCenter`, or
/// the filesystem -- every input is a plain value the caller
/// (`ClearSkyTriggerCheckRunner`, the thin notification layer) already
/// resolved, and every output is a plain value too. Same "extract the pure
/// decision, test it directly" shape `PreflightChecklist.build`/
/// `HomeStore.cloudOutlook` already use elsewhere in this app -- the
/// house rule this feature was built under ("Trend/threshold logic must be a
/// pure, tested engine; the notification layer thin").
///
/// The decision matrix (`evaluate(...)`'s doc comment below has the exact
/// gate order):
/// - not authorized -> never fires, no matter what the weather says.
/// - already notified tonight -> never fires twice for the same calendar
///   night (pinned in `State.lastNotifiedDayKey`).
/// - before `checkHourLocal` -> this tick only records a baseline; it can
///   never be the "real" afternoon check the spec describes.
/// - at/after `checkHourLocal` with no same-day baseline yet -> also just
///   records a baseline (honest: there is nothing to compare against, so
///   claiming "it just cleared up" would be unearned).
/// - baseline was cloudy, now clear -> fires. This is the one positive case.
/// - baseline was already clear, now clear -> skips (nothing new to say;
///   this is what already fired, or will fire, once its own baseline was
///   first seen cloudy some earlier day -- see `alreadyClearEarlier`).
/// - still cloudy either way -> skips.
public enum ClearSkyTrigger {
    /// Whether the system currently lets this app show a notification --
    /// this engine's own stand-in for `UNAuthorizationStatus`, collapsing
    /// `.provisional`/`.ephemeral` into `.authorized` (both already let a
    /// notification through) so this pure engine never has to
    /// `import UserNotifications` itself.
    public enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
    }

    /// One resolved measurement of "tonight's" forecast cloud cover, tagged
    /// with the local calendar day it was taken on (and speaks about) --
    /// this is what keeps a measurement from one calendar day from ever
    /// being compared against a different night's.
    public struct Measurement: Codable, Equatable, Sendable {
        public let dayKey: String
        public let cloudPercent: Double

        public init(dayKey: String, cloudPercent: Double) {
            self.dayKey = dayKey
            self.cloudPercent = cloudPercent
        }
    }

    /// Persisted, additive state (see `ClearSkyTriggerStateStore`) -- the
    /// "earlier (e.g. noon) measurement" the spec calls for, plus the
    /// one-per-night notification pin. A stale `earlierMeasurement` (from a
    /// calendar day other than the one being evaluated) is pruned by
    /// `evaluate` itself before it can ever be compared against tonight.
    public struct State: Codable, Equatable, Sendable {
        public var earlierMeasurement: Measurement?
        public var lastNotifiedDayKey: String?

        public init(earlierMeasurement: Measurement? = nil, lastNotifiedDayKey: String? = nil) {
            self.earlierMeasurement = earlierMeasurement
            self.lastNotifiedDayKey = lastNotifiedDayKey
        }
    }

    public enum Reason: Equatable, Sendable {
        /// Notification permission isn't `.authorized` -- honest silence,
        /// never a repeated system permission prompt.
        case notAuthorized
        /// This calendar night already had its one notification.
        case alreadyNotifiedTonight
        /// `now`'s local hour is before `checkHourLocal` -- baseline-only.
        case beforeCheckWindow
        /// The afternoon window arrived, but there is no same-day baseline
        /// to compare against yet -- this tick becomes the new baseline.
        case noBaselineYet
        /// Tonight's forecast is still cloudy.
        case stillCloudy
        /// Tonight's forecast was already clear at the earlier measurement
        /// too -- nothing NEW to report.
        case alreadyClearEarlier
    }

    public enum Decision: Equatable, Sendable {
        case fire
        case skip(Reason)
    }

    public struct Result: Equatable, Sendable {
        public let decision: Decision
        public let nextState: State

        public init(decision: Decision, nextState: State) {
            self.decision = decision
            self.nextState = nextState
        }
    }

    /// The one decision point. `now`/`calendar` are both injected so tests
    /// never depend on the real wall clock or the test machine's own time
    /// zone -- production callers pass `Date()`/`Calendar.current`.
    ///
    /// - Parameters:
    ///   - checkHourLocal: `AstroConfig.NotificationRule.checkHourLocal` --
    ///     the local hour of day the "real" afternoon check is allowed to
    ///     fire at.
    ///   - cloudyThresholdPercent: `ClearNightOutlook.cloudyThresholdPercent`
    ///     -- the SAME single constant every other "is it cloudy tonight?"
    ///     read in this app already uses, never a copy of its own.
    ///   - currentCloudPercent: tonight's forecast mean cloud-cover percent,
    ///     already resolved by the caller (e.g.
    ///     `WeatherService`'s `DailySummary.meanPercent` for tonight's key).
    public static func evaluate(
        now: Date,
        calendar: Calendar,
        checkHourLocal: Int,
        cloudyThresholdPercent: Double,
        currentCloudPercent: Double,
        authorization: Authorization,
        state: State
    ) -> Result {
        let dayKey = Self.dayKey(for: now, calendar: calendar)

        guard authorization == .authorized else {
            return Result(decision: .skip(.notAuthorized), nextState: state)
        }
        guard state.lastNotifiedDayKey != dayKey else {
            return Result(decision: .skip(.alreadyNotifiedTonight), nextState: state)
        }

        // A baseline from any earlier calendar day never applies to tonight.
        var state = state
        if state.earlierMeasurement?.dayKey != dayKey {
            state.earlierMeasurement = nil
        }

        let hour = calendar.component(.hour, from: now)
        guard hour >= checkHourLocal else {
            if state.earlierMeasurement == nil {
                state.earlierMeasurement = Measurement(dayKey: dayKey, cloudPercent: currentCloudPercent)
            }
            return Result(decision: .skip(.beforeCheckWindow), nextState: state)
        }

        guard let earlier = state.earlierMeasurement else {
            state.earlierMeasurement = Measurement(dayKey: dayKey, cloudPercent: currentCloudPercent)
            return Result(decision: .skip(.noBaselineYet), nextState: state)
        }

        let isClearNow = currentCloudPercent <= cloudyThresholdPercent
        guard isClearNow else {
            return Result(decision: .skip(.stillCloudy), nextState: state)
        }
        let wasClearEarlier = earlier.cloudPercent <= cloudyThresholdPercent
        guard !wasClearEarlier else {
            return Result(decision: .skip(.alreadyClearEarlier), nextState: state)
        }

        state.lastNotifiedDayKey = dayKey
        return Result(decision: .fire, nextState: state)
    }

    /// `"yyyy-MM-dd"`-shaped, but built from `calendar`'s own date
    /// components rather than a `DateFormatter` -- this engine takes no
    /// dependency on `WeatherService`'s own formatter (a pure engine should
    /// not need to know that type exists), and every caller already passes a
    /// `calendar` set to the same time zone `WeatherService.isoDateFormatter`
    /// itself uses in production (`TimeZone.current`), so the two stay in
    /// practical agreement without either depending on the other.
    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
