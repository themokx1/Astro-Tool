@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// V3 pre-stack program section 5.5 ("Derült-trigger"): `NotificationSettingsStore`
/// is the ONE place Settings ▸ Notifications reads/writes
/// `AstroConfig.notification` and decides when it is honestly allowed to ask
/// macOS for notification permission. `FakeNotificationCenter` stands in for
/// the real `UNUserNotificationCenter` (unusable headlessly), matching
/// `UserNotificationSchedulerTests`' own seam.
private actor FakeNotificationCenter: NotificationCenterProviding {
    private(set) var requestAuthorizationCallCount = 0
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

    func deliver(identifier: String, title: String, body: String) async throws {}
}

@MainActor
@Suite("Notification settings store (V3 5.5)")
struct NotificationSettingsStoreTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("No library open: honestly reports no library, and never touches disk")
    func noLibraryOpenIsHonest() {
        let store = NotificationSettingsStore(rootURL: nil, scheduler: UserNotificationScheduler(center: FakeNotificationCenter(status: .notDetermined)))
        #expect(!store.hasLibraryOpen)
        #expect(!store.enabled)
    }

    @Test("A library whose config.json already enables notifications loads that state, not a hardcoded default")
    func loadsExistingEnabledState() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AstroConfig()
        config.notification.enabled = true
        try config.save(using: WriteGuard(root: root))

        let store = NotificationSettingsStore(rootURL: root, scheduler: UserNotificationScheduler(center: FakeNotificationCenter(status: .notDetermined)))
        #expect(store.hasLibraryOpen)
        #expect(store.enabled)
    }

    @Test("Turning the toggle on persists to config.json and requests authorization exactly once")
    func enablingPersistsAndRequestsAuthorization() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fake = FakeNotificationCenter(status: .notDetermined)
        let store = NotificationSettingsStore(rootURL: root, scheduler: UserNotificationScheduler(center: fake))

        await store.setEnabled(true)

        #expect(store.enabled)
        #expect(store.authorization == .authorized)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 1)

        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        let persisted = try AstroConfig.load(from: configURL)
        #expect(persisted.notification.enabled)
    }

    @Test("Turning the toggle off persists, but never requests authorization")
    func disablingNeverRequestsAuthorization() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AstroConfig()
        config.notification.enabled = true
        try config.save(using: WriteGuard(root: root))

        let fake = FakeNotificationCenter(status: .authorized)
        let store = NotificationSettingsStore(rootURL: root, scheduler: UserNotificationScheduler(center: fake))

        await store.setEnabled(false)

        #expect(!store.enabled)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 0)

        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        let persisted = try AstroConfig.load(from: configURL)
        #expect(!persisted.notification.enabled)
    }

    @Test("An already-denied permission is never re-prompted, even when the user re-enables the toggle")
    func reEnablingAfterDenialNeverReprompts() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fake = FakeNotificationCenter(status: .denied)
        let store = NotificationSettingsStore(rootURL: root, scheduler: UserNotificationScheduler(center: fake))

        await store.setEnabled(true)

        #expect(store.authorization == .denied)
        let callCount = await fake.requestAuthorizationCallCount
        #expect(callCount == 0)
    }
}
