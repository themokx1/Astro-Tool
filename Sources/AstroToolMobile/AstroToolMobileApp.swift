import SwiftUI
import Foundation
import AstroMobileDomain

@main
struct AstroToolMobileApp: App {
    private let store: MobileLibraryStore
    private let fixtureMode: String?
    @State private var stagedPackageURL: URL?
    @State private var intakeMessage: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--astrotool-mobile-ui-fixture"), arguments.indices.contains(index + 1) {
            fixtureMode = arguments[index + 1]
        } else {
            fixtureMode = nil
        }
        store = MobileLaunchFixture.makeStore(mode: fixtureMode)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, stagedPackageURL: $stagedPackageURL, intakeMessage: $intakeMessage, fixtureMode: fixtureMode, fixtureQRPayload: launchQRPayload)
                .onOpenURL { url in
                    receive(url)
                }
        }
    }

    private var launchQRPayload: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--astrotool-mobile-qr-payload"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func receive(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try await store.receive(source: url)
                let current = await store.stagedPackageURL
                await MainActor.run { stagedPackageURL = current; intakeMessage = nil }
            } catch {
                let current = await store.stagedPackageURL
                await MainActor.run {
                    stagedPackageURL = current
                    intakeMessage = accessed ? "AstroTool could not copy that mobile package safely. Send it from your Mac again and try once more." : "AstroTool could not open that package. In Files, try sharing it with AstroTool again."
                }
            }
        }
    }
}

private enum MobileLaunchFixture {
    static func makeStore(mode: String?) -> MobileLibraryStore {
        guard mode == "imported" else { return MobileLibraryStore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AstroToolMobileUIFixture-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        let active = root.appendingPathComponent("active", isDirectory: true)
        try? FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let projectID = UUID(), nightID = UUID(), briefingID = UUID()
        let noteID = "fixture-note"
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [MobileProject(id: projectID, displayName: "M31", catalogID: "M31", phase: "ready", integrationSeconds: 0, goalHours: nil)],
            nights: [MobileNight(id: nightID, localDate: "2026-08-23", timeZoneID: "Europe/Budapest")], captures: [],
            briefings: [MobileBriefing(id: briefingID, revision: 1, savedAt: Date(timeIntervalSince1970: 1_700_000_001), nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
            notes: [MobileNote(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "", baseRevision: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_002), isEditableOnPhone: true)]
        )
        try? MobileJSON.encoder.encode(snapshot).write(to: active.appendingPathComponent("snapshot.json"), options: .atomic)
        return MobileLibraryStore(applicationSupportURL: root)
    }
}
