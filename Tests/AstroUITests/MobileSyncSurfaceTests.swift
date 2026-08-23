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
}
