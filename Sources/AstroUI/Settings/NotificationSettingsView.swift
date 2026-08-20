import AstroApplication
import AstroCore
import Foundation
import Observation
import SwiftUI

/// V3 pre-stack program section 5.5 ("Derült-trigger"): reads/writes
/// `AstroConfig.notification` at `<library-root>/.astro_tool/config.json` --
/// same cross-scene rebuild pattern `SiteSettingsStore`/`EquipmentSetupsStore`
/// already use (Settings is a separate scene from the window that owns
/// `AppModel.currentLibraryRootURL`, so this store only reads that URL at
/// construction; `NotificationSettingsView` rebuilds it on
/// `.onChange(of: appModel.currentLibraryRootURL)`).
@MainActor
@Observable
public final class NotificationSettingsStore {
    public private(set) var hasLibraryOpen: Bool
    public private(set) var enabled: Bool
    public private(set) var authorization: ClearSkyTrigger.Authorization
    public private(set) var saveMessage: String?
    public private(set) var errorMessage: String?

    private let rootURL: URL?
    private let scheduler: UserNotificationScheduler

    public init(rootURL: URL?, scheduler: UserNotificationScheduler = .shared) {
        self.rootURL = rootURL
        self.scheduler = scheduler
        hasLibraryOpen = rootURL != nil
        authorization = .notDetermined
        if let rootURL {
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            let config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            enabled = config.notification.enabled
        } else {
            enabled = false
        }
    }

    /// Reads the current OS permission state -- never prompts. Called on
    /// first appearance and whenever the library changes, so a toggle that
    /// was already on from a previous session shows its REAL, current
    /// authorization state (e.g. the user may have revoked it in System
    /// Settings since) rather than a stale guess.
    public func refreshAuthorization() async {
        authorization = await scheduler.authorizationStatus()
    }

    /// Flips the toggle and persists it to `config.json`. Turning it ON is
    /// the one, single moment this feature is allowed to ask macOS for
    /// notification permission -- never at first app launch, per the spec's
    /// own "az engedélykérés UX-időzítése kritikus (ne az első indításkor
    /// kérjen, hanem amikor a felhasználó tényleg bekapcsolja a funkciót)".
    /// `UserNotificationScheduler.requestAuthorizationIfNeeded()` itself only
    /// actually prompts when the OS status is still `.notDetermined`, so
    /// turning this on again after a `.denied` answer never re-prompts -- the
    /// toggle just keeps honestly reporting `.denied` until the user fixes it
    /// in System Settings themselves.
    public func setEnabled(_ newValue: Bool) async {
        guard let rootURL else { return }
        errorMessage = nil
        saveMessage = nil
        do {
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            config.notification.enabled = newValue
            try config.save(using: WriteGuard(root: rootURL))
            enabled = newValue
            saveMessage = NSLocalizedString(
                "Saved.", bundle: .main, comment: "Notification settings save confirmation"
            )
        } catch {
            errorMessage = NSLocalizedString(
                "Could not save this setting. Try again.",
                bundle: .main,
                comment: "Notification settings save failure"
            )
            return
        }
        if newValue {
            authorization = await scheduler.requestAuthorizationIfNeeded()
        }
    }
}

/// Settings ▸ Notifications -- the one user-facing surface for the
/// "Derült-trigger" feature. Honest, up front, about the V3.0 in-process
/// limitation (no daemon/launch-agent: this only ever runs while AstroTool
/// itself is open), and never hides a `.denied` OS answer behind a
/// still-on-looking toggle.
struct NotificationSettingsView: View {
    let appModel: AppModel
    @State private var store: NotificationSettingsStore

    init(appModel: AppModel) {
        self.appModel = appModel
        _store = State(initialValue: NotificationSettingsStore(rootURL: appModel.currentLibraryRootURL))
    }

    var body: some View {
        Form {
            if !store.hasLibraryOpen {
                Section {
                    Label("Open a library first, using Choose Image Library… on Home.", systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("v2.settings.notifications.no-library")
            } else {
                Section("Clear-sky notification") {
                    Toggle(
                        "Tell me when it clears up tonight",
                        isOn: Binding(
                            get: { store.enabled },
                            set: { newValue in Task { await store.setEnabled(newValue) } }
                        )
                    )
                    .accessibilityIdentifier("v2.settings.notifications.enabled")

                    Text(
                        "Checks the afternoon forecast while AstroTool is open, and -- if it clears up for tonight -- shows a notification with the pre-flight status and a suggested target. This only runs while the app is open: if you quit before the afternoon check window, you will not get a notification tonight."
                    )
                    .font(.caption).foregroundStyle(.secondary)

                    authorizationStatusView
                }
                .accessibilityIdentifier("v2.settings.notifications.section")

                if let saveMessage = store.saveMessage {
                    Text(saveMessage).foregroundStyle(AstroTokens.Color.ok)
                }
                if let errorMessage = store.errorMessage {
                    Text(errorMessage).foregroundStyle(AstroTokens.Color.critical)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await store.refreshAuthorization()
        }
        .onChange(of: appModel.currentLibraryRootURL) { _, newRootURL in
            // Settings is a separate scene (see `SiteSettingsStore`'s own doc
            // comment): rebuilding the store is the only way this tab
            // notices a library opening or switching afterward.
            store = NotificationSettingsStore(rootURL: newRootURL)
            Task { await store.refreshAuthorization() }
        }
        .accessibilityIdentifier("v2.settings.notifications")
    }

    @ViewBuilder
    private var authorizationStatusView: some View {
        switch store.authorization {
        case .authorized:
            Label("Notifications are allowed.", systemImage: "checkmark.circle")
                .foregroundStyle(AstroTokens.Color.ok)
                .accessibilityIdentifier("v2.settings.notifications.authorization")
        case .denied:
            Label(
                "Notifications are blocked for AstroTool. Allow them in System Settings ▸ Notifications.",
                systemImage: "bell.slash"
            )
            .foregroundStyle(AstroTokens.Color.attention)
            .accessibilityIdentifier("v2.settings.notifications.authorization")
        case .notDetermined:
            if store.enabled {
                Label("Waiting for permission…", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.settings.notifications.authorization")
            }
        }
    }
}
