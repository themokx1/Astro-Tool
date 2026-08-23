import SwiftUI

@main
struct AstroToolMobileApp: App {
    private let store = MobileLibraryStore()
    @State private var stagedPackageURL: URL?

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, stagedPackageURL: $stagedPackageURL, fixtureQRPayload: launchQRPayload)
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
                if let previous = stagedPackageURL {
                    await store.discardStagedPackage(at: previous)
                    await MainActor.run { stagedPackageURL = nil }
                }
                let staged = try await store.stagePackage(from: url)
                await MainActor.run { stagedPackageURL = staged }
            } catch {
                await MainActor.run { stagedPackageURL = nil }
            }
        }
    }
}
