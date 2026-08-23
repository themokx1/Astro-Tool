import SwiftUI

@main
struct AstroToolMobileApp: App {
    private let store = MobileLibraryStore()
    private let fixtureMode: String?
    @State private var stagedPackageURL: URL?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--astrotool-mobile-ui-fixture"), arguments.indices.contains(index + 1) {
            fixtureMode = arguments[index + 1]
        } else {
            fixtureMode = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, stagedPackageURL: $stagedPackageURL, fixtureMode: fixtureMode, fixtureQRPayload: launchQRPayload)
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
                let staged = try await store.replaceStagedPackage(previous: stagedPackageURL, from: url)
                await MainActor.run { stagedPackageURL = staged }
            } catch {
                await MainActor.run { stagedPackageURL = nil }
            }
        }
    }
}
