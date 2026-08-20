import AstroApplication
import Foundation
import Testing

/// `UserNotificationScheduler` is deliberately thin -- every actual decision
/// lives in `ClearSkyTrigger`. This suite only pins the two things that ARE
/// this layer's own job: never re-prompting once the OS has already decided
/// (`.denied`/`.authorized`), and delivering exactly the content it was
/// given under a night-keyed identifier. `FakeNotificationCenter` stands in
/// for the real `UNUserNotificationCenter` (unusable headlessly in
/// `swift test`) via `NotificationCenterProviding`.
private actor FakeNotificationCenter: NotificationCenterProviding {
    private(set) var requestAuthorizationCallCount = 0
    private(set) var deliveries: [(identifier: String, title: String, body: String)] = []
    var status: ClearSkyTrigger.Authorization
    var requestResult = true

    init(status: ClearSkyTrigger.Authorization) {
        self.status = status
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        status = requestResult ? .authorized : .denied
        return requestResult
    }

    func authorizationStatus() async -> ClearSkyTrigger.Authorization {
        status
    }

    func deliver(identifier: String, title: String, body: String) async throws {
        deliveries.append((identifier, title, body))
    }
}

@Suite("User notification scheduler (V3 5.5)")
struct UserNotificationSchedulerTests {
    @Test("Not-determined status actually asks the OS for permission")
    func notDeterminedRequestsPermission() async {
        let fake = FakeNotificationCenter(status: .notDetermined)
        let scheduler = UserNotificationScheduler(center: fake)

        let result = await scheduler.requestAuthorizationIfNeeded()

        #expect(result == .authorized)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 1)
    }

    @Test("An already-denied status is never re-prompted")
    func deniedNeverReprompts() async {
        let fake = FakeNotificationCenter(status: .denied)
        let scheduler = UserNotificationScheduler(center: fake)

        let result = await scheduler.requestAuthorizationIfNeeded()

        #expect(result == .denied)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 0)
    }

    @Test("An already-authorized status is never re-prompted either")
    func authorizedNeverReprompts() async {
        let fake = FakeNotificationCenter(status: .authorized)
        let scheduler = UserNotificationScheduler(center: fake)

        let result = await scheduler.requestAuthorizationIfNeeded()

        #expect(result == .authorized)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 0)
    }

    @Test("Delivering a clear-sky notification keys the identifier by night and passes the content through untouched")
    func deliversKeyedByNight() async {
        let fake = FakeNotificationCenter(status: .authorized)
        let scheduler = UserNotificationScheduler(center: fake)
        let content = ClearSkyNotificationContent.Content(title: "T", body: "B")

        await scheduler.deliverClearSkyNotification(dayKey: "2026-08-20", content: content)

        let deliveries = await fake.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.identifier == "clear-sky-trigger-2026-08-20")
        #expect(deliveries.first?.title == "T")
        #expect(deliveries.first?.body == "B")
    }
}
