import Foundation
import UserNotifications

/// The seam between `UserNotificationScheduler` and the real
/// `UNUserNotificationCenter` -- exists so tests never have to touch the
/// actual system notification center, which needs a signed, running app
/// with a notification entitlement and cannot run headlessly under
/// `swift test`. `SystemNotificationCenter` is the only production
/// conformance; test doubles conform to exercise
/// `UserNotificationScheduler`'s own (thin) request/dedupe logic in
/// isolation.
public protocol NotificationCenterProviding: Sendable {
    /// Prompts the user for notification permission. Only ever called by
    /// `UserNotificationScheduler.requestAuthorizationIfNeeded()` when the
    /// current status is `.notDetermined` -- see that method's own doc
    /// comment for why this type itself never needs to guard against a
    /// repeated system prompt.
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> ClearSkyTrigger.Authorization
    func deliver(identifier: String, title: String, body: String) async throws
}

/// Production `NotificationCenterProviding`, backed by the real
/// `UNUserNotificationCenter.current()`.
public struct SystemNotificationCenter: NotificationCenterProviding {
    public init() {}

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func authorizationStatus() async -> ClearSkyTrigger.Authorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    public func deliver(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Thin wrapper around `NotificationCenterProviding` -- every DECISION
/// (whether tonight's forecast warrants a notification at all) is made by
/// the pure `ClearSkyTrigger` engine; this actor only ever executes what
/// `ClearSkyTriggerCheckRunner` tells it to, plus the one piece of
/// permission bookkeeping (`requestAuthorizationIfNeeded()`) that is
/// genuinely this layer's own job.
public actor UserNotificationScheduler {
    /// Production singleton, matching `WeatherService.shared`'s own shape --
    /// one real notification center for the whole process.
    public static let shared = UserNotificationScheduler(center: SystemNotificationCenter())

    private let center: NotificationCenterProviding

    public init(center: NotificationCenterProviding) {
        self.center = center
    }

    /// Requests authorization if (and only if) the OS has not been asked
    /// before. `.denied`/`.authorized` are both already-decided answers --
    /// re-requesting on `.denied` would be a silent no-op anyway (the OS
    /// itself refuses to re-prompt once denied), so this never spams the
    /// user with a rejected permission dialog. Callers (the Settings
    /// toggle's own store) are responsible for only calling this at the one
    /// honest moment the spec allows: when the user explicitly turns the
    /// feature on, never at first app launch.
    @discardableResult
    public func requestAuthorizationIfNeeded() async -> ClearSkyTrigger.Authorization {
        let current = await center.authorizationStatus()
        guard current == .notDetermined else { return current }
        _ = try? await center.requestAuthorization()
        return await center.authorizationStatus()
    }

    public func authorizationStatus() async -> ClearSkyTrigger.Authorization {
        await center.authorizationStatus()
    }

    /// Delivers one clear-sky notification for the night keyed by `dayKey`.
    /// The identifier is keyed by night so that if this were ever called
    /// twice for the same night (it should not be -- `ClearSkyTrigger`'s own
    /// dedupe pin is the actual guarantee), the second delivery would
    /// *replace* the first rather than stacking a second banner. Failure to
    /// deliver is swallowed here (there is nothing actionable to do with a
    /// system delivery error at this layer, and the feature's own honest
    /// posture is "quietly skip", not "crash the periodic check loop").
    public func deliverClearSkyNotification(dayKey: String, content: ClearSkyNotificationContent.Content) async {
        try? await center.deliver(
            identifier: "clear-sky-trigger-\(dayKey)",
            title: content.title,
            body: content.body
        )
    }
}
