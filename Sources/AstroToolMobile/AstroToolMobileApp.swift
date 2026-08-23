import SwiftUI

@main
struct AstroToolMobileApp: App {
    private let store = MobileLibraryStore()
    @State private var stagedPackageURL: URL?

    var body: some Scene {
        WindowGroup {
            MobileRootView(store: store, stagedPackageURL: $stagedPackageURL)
                .onOpenURL { url in
                    receive(url)
                }
        }
    }

    private func receive(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let staged = try await store.stagePackage(from: url)
                await MainActor.run { stagedPackageURL = staged }
            } catch {
                await MainActor.run { stagedPackageURL = nil }
            }
        }
    }
}
