import SwiftUI
import Foundation
import AstroMobileDomain

@main
struct AstroToolMobileApp: App {
    private let store: MobileLibraryStore
    private let fixtureMode: String?
    private let fixtureRoot: URL?
    private let securityScope: MobileSecurityScopedAccess
    @State private var stagedPackageURL: URL?
    @State private var intakeError: MobileIntakeError?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--astrotool-mobile-ui-fixture"), arguments.indices.contains(index + 1) {
            fixtureMode = arguments[index + 1]
        } else {
            fixtureMode = nil
        }
        let fixture = MobileLaunchFixture.make(mode: fixtureMode)
        store = fixture.store
        fixtureRoot = fixture.root
        securityScope = MobileSecurityScopedAccess()
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, stagedPackageURL: $stagedPackageURL, intakeError: $intakeError, fixtureMode: fixtureMode, fixtureQRPayload: launchQRPayload, fixtureRoot: fixtureRoot)
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
        Task {
            let accessed = securityScope.start(url)
            do {
                // A false scope result is not a proof that the URL cannot be
                // read. The store still attempts its app-owned copy; only a
                // true result receives the balanced stop call.
                _ = try await securityScope.perform(at: url, acquired: accessed) {
                    try await store.receive(source: url)
                }
                let current = await store.stagedPackageURL
                await MainActor.run { stagedPackageURL = current; intakeError = nil }
            } catch {
                let current = await store.stagedPackageURL
                await MainActor.run {
                    stagedPackageURL = current
                    intakeError = accessed ? .copyFailed : .securityScopeUnavailable
                }
            }
        }
    }
}

private enum MobileLaunchFixture {
    struct Result {
        let store: MobileLibraryStore
        let root: URL?
    }

    static func make(mode: String?) -> Result {
        guard mode == "imported" else { return Result(store: MobileLibraryStore(), root: nil) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AstroToolMobileUIFixture-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        let active = root.appendingPathComponent("active", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create the imported mobile UI fixture: \(error)")
        }
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
        do {
            try MobileJSON.encoder.encode(snapshot).write(to: active.appendingPathComponent("snapshot.json"), options: .atomic)
        } catch {
            fatalError("Could not write the imported mobile UI fixture: \(error)")
        }
        return Result(store: MobileLibraryStore(applicationSupportURL: root), root: root)
    }
}
