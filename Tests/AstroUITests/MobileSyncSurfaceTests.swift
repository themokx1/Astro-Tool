import Foundation
import Testing

@Suite("V5 Mac mobile sync surface")
struct MobileSyncSurfaceTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("The native surface has the pinned entry points, rail, and safety promise")
    func pinnedSurface() throws {
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncView.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"), encoding: .utf8)
        let rootView = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        for identifier in ["v5.mobile-sync.open", "v5.mobile-sync.safety", "v5.mobile-sync.export", "v5.mobile-sync.import", "v5.mobile-sync.confirm-identity", "v5.mobile-sync.confirm-summary", "v5.mobile-sync.cancel", "v5.mobile-sync.qr", "v5.mobile-sync.error.retry"] {
            #expect(store.contains(identifier) || view.contains(identifier) || settings.contains(identifier) || rootView.contains(identifier))
        }
        #expect(view.contains("Original photos are not transferred. iPhone cannot modify files in the image library."))
        #expect(view.contains("Original photos stay on this Mac."))
        #expect(view.contains("Mac"))
        #expect(view.contains("sealed package"))
        #expect(view.contains("iPhone"))
        #expect(view.contains("fileExporter"))
        #expect(view.contains("fileImporter"))
        #expect(view.contains("configuration.existingFile"), "Replace requests must be rejected before SwiftUI writes a placeholder")
        #expect(view.contains("interactiveDismissDisabled"))
        #expect(view.contains("SecureField"))
        #expect(view.contains("clearIncomingSelection"))
        #expect(view.contains("case .discarding"))
        #expect(view.contains("Finishing safely"))
        #expect(view.contains(".astroMobile"))
        let visibleCopy = view
            .split(separator: "\n")
            .filter { $0.contains("Text(") || $0.contains("Label(") || $0.contains("Button(") }
            .joined(separator: "\n")
        #expect(!visibleCopy.localizedCaseInsensitiveContains("schema"))
        #expect(!visibleCopy.localizedCaseInsensitiveContains("manifest"))
        #expect(!visibleCopy.localizedCaseInsensitiveContains("symmetric key"))
        #expect(!visibleCopy.localizedCaseInsensitiveContains("payload"))
        #expect(!visibleCopy.localizedCaseInsensitiveContains("staging"))
    }

    @Test("Briefing export surfaces remain and iPhone sync is adjacent")
    func briefingExportsRemain() throws {
        let briefing = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Briefing/NightBriefingView.swift"), encoding: .utf8)
        #expect(briefing.contains("v2.briefing.export.pdf"))
        #expect(briefing.contains("v2.briefing.export.pdf-png"))
        #expect(briefing.contains("v2.briefing.export.png"))
        #expect(briefing.contains("v5.mobile-sync.open"))
        #expect(briefing.contains("Send to iPhone") || briefing.contains("Küldés iPhone-ra"))
        #expect(briefing.contains("snapshotProvider"), "Briefing entry must receive the live metadata provider")
    }

    @Test("Root, settings, and briefing share the live metadata provider")
    func liveProviderIsThreaded() throws {
        let rootView = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"), encoding: .utf8)
        #expect(rootView.contains("mobileSnapshotProvider"))
        #expect(settings.contains("metadataSnapshotProvider"))
        #expect(rootView.contains("snapshotProvider: mobileSnapshotProvider"))
    }

    @Test("Settings uses the human-facing iPhone Sync name")
    func settingsEntryIsHumanFacing() throws {
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("iPhone Sync"))
        #expect(settings.contains("iPhone szinkron"))
        #expect(!settings.contains("transport"))
    }

    @Test("Incoming package identity uses a responsive full-value layout")
    func incomingPackageIdentityIsResponsive() throws {
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncView.swift"), encoding: .utf8)
        #expect(view.contains("v5.mobile-sync.package-id"))
        #expect(view.contains("ViewThatFits(in: .horizontal)"))
        #expect(view.contains("textSelection(.enabled)"))
        #expect(view.contains("monospaced"))
        #expect(view.contains("Package ID"))
    }

    @Test("production surface exposes only the root coordinator boundary")
    func returnAuthoritySurfaceIsClosed() throws {
        let importer = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/MobileSync/MobileChangeImporter.swift"), encoding: .utf8)
        let sent = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/MobileSync/MobileSentSnapshotStore.swift"), encoding: .utf8)
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/MobileSync/MobileReturnApplicationCoordinator.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift"), encoding: .utf8)

        #expect(importer.contains("package final class MobileChangeImporter"))
        #expect(!importer.contains("public final class MobileChangeImporter"))
        #expect(sent.contains("package final class MobileSentSnapshotIdentityStore"))
        #expect(!sent.contains("public final class MobileSentSnapshotIdentityStore"))
        #expect(coordinator.contains("public actor MobileReturnApplicationCoordinator"))
        #expect(coordinator.contains("public init(rootURL: URL)"))
        #expect(!coordinator.contains("public static func production"))
        #expect(store.contains("productionMode: true"))
        #expect(store.contains("package init("))
        #expect(!store.contains("public typealias PackageAuthenticatedReturn"))
    }

    @Test("The nearby sync surface has the pinned identifiers, the safety sentence, and one retry action")
    func nearbySyncSurfaceIsPinned() throws {
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncView.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift"), encoding: .utf8)

        for identifier in ["v5.nearby.start", "v5.nearby.state", "v5.nearby.code", "v5.nearby.confirm", "v5.nearby.reject", "v5.nearby.retry"] {
            #expect(view.contains(identifier), "missing accessibility identifier \(identifier)")
        }
        // Exactly one retry action per spec §4.3 -- pinned by count, not just
        // presence, so a second retry button added elsewhere would fail this.
        let retryOccurrences = view.components(separatedBy: "v5.nearby.retry").count - 1
        #expect(retryOccurrences == 1)

        #expect(view.contains("The local network permission is used only to hand data between your own AstroTool apps."))
        #expect(view.contains("Sync with iPhone directly"))

        // The nearby coordinator is fed the store's OWN `returnCoordinator`
        // instance (not one it builds itself) -- see NearbySyncCoordinator's
        // doc comment for why a separate instance would break `apply`/
        // `discard` against the live in-memory session.
        #expect(store.contains("localReturnCoordinator.publishForwardSnapshot"))
        #expect(store.contains("localReturnCoordinator.preview"))
        // The production coordinator init taking only rootURL/displayName is
        // never used by the store directly -- it wires the injectable seam
        // instead, so this call site would only ever appear in a comment.
        #expect(!store.contains("NearbySyncCoordinator(rootURL:"))
    }

    // MARK: - Fix 1: peer-identity-changed recovery (permanent dead end)

    @Test("Mac's identityChanged failure offers a dedicated forget-and-retry recovery action")
    func macIdentityChangedOffersForgetAndRetry() throws {
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncView.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/MobileSync/MobileSyncStore.swift"), encoding: .utf8)
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/AstroApplication/Features/MobileSync/NearbySyncCoordinator.swift"), encoding: .utf8)

        #expect(view.contains("v5.nearby.forget-and-retry"))
        #expect(view.contains("Forget this iPhone and pair again"))
        #expect(store.contains("func forgetNearbyPeerAndRetry()"))
        #expect(store.contains("case .failed(.identityChanged(let deviceID))"))
        // The failure carries the offending peer's deviceID (not just a bare
        // "it changed" signal) so the recovery action knows exactly which
        // trusted peer to remove.
        #expect(coordinator.contains("case identityChanged(deviceID: UUID)"))
        #expect(coordinator.contains("func forgetPeer(deviceID: UUID) throws"))
        #expect(coordinator.contains("func trustedPeerDisplayName(deviceID: UUID) -> String?"))
    }

    @Test("iPhone Sync settings lists trusted peers with a per-peer forget action")
    func settingsListsPairedDevicesWithForget() throws {
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("Forget paired devices"))
        #expect(settings.contains("removeTrustedPeer(deviceID:"))
        #expect(settings.contains("trustedPeers()"))
    }

    @Test("iPhone's own identityChanged screen offers the mirrored forget-and-retry action")
    func iPhoneIdentityChangedOffersForgetAndRetry() throws {
        let screen = try String(contentsOf: root.appendingPathComponent("Sources/AstroToolMobile/MobileNearbySyncScreen.swift"), encoding: .utf8)
        let rootView = try String(contentsOf: root.appendingPathComponent("Sources/AstroToolMobile/MobileRootView.swift"), encoding: .utf8)
        let session = try String(contentsOf: root.appendingPathComponent("Sources/AstroMobileTransport/NearbyPhoneSyncSession.swift"), encoding: .utf8)

        #expect(screen.contains("v5.mobile.nearby.forget-and-retry"))
        #expect(screen.contains("Forget this Mac and pair again"))
        #expect(rootView.contains("func forgetNearbySyncPeerAndRetry()"))
        #expect(rootView.contains("case identityChanged(deviceID: UUID)"))
        #expect(session.contains("func forgetPeer(deviceID: UUID) throws"))
    }

    // MARK: - Fix 2: backgrounding mid nearby-sync must not dangle

    @Test("Backgrounding mid nearby-sync cancels the session instead of leaving it running unbounded")
    func scenePhaseChangeCancelsNearbySync() throws {
        let rootView = try String(contentsOf: root.appendingPathComponent("Sources/AstroToolMobile/MobileRootView.swift"), encoding: .utf8)
        let screen = try String(contentsOf: root.appendingPathComponent("Sources/AstroToolMobile/MobileNearbySyncScreen.swift"), encoding: .utf8)

        guard let sceneHandlerRange = rootView.range(of: ".onChange(of: scenePhase)") else {
            Issue.record("scenePhase onChange handler not found in MobileRootView.swift")
            return
        }
        // Only look within the `phase != .active` branch that already
        // cancels the scanner/import/export paths (bounded by the next
        // `.sheet(` call site, which starts well past that branch).
        guard let branchEnd = rootView.range(of: ".sheet(isPresented: $showingScanner", range: sceneHandlerRange.upperBound..<rootView.endIndex) else {
            Issue.record("could not bound the scenePhase != .active branch")
            return
        }
        let branch = String(rootView[sceneHandlerRange.upperBound..<branchEnd.lowerBound])
        #expect(branch.contains("cancelReturnExport()"))
        #expect(branch.contains("cancelNearbySyncDueToBackgrounding()"))

        #expect(rootView.contains("case backgrounded"))
        #expect(screen.contains("Sync stopped because the app went to the background"))
    }
}
