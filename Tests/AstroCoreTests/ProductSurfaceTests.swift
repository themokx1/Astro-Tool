import Foundation
import Testing

@Suite("ProductSurface") struct ProductSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func sharedProductStyleOwnsSpacingCardsAndEmptyStates() throws {
        let style = try source("Sources/AstroToolApp/Views/ProductStyle.swift")
        #expect(style.contains("enum ProductMetrics"))
        #expect(style.contains("struct ProductCard"))
        #expect(style.contains("struct ProductEmptyState"))
        #expect(style.contains("accessibilityLabel"))
        #expect(style.contains("accessibilityReduceMotion"))
    }

    @Test func settingsUseANativeSidebarInsteadOfAnOverloadedTabStrip() throws {
        let settings = try source("Sources/AstroToolApp/Views/SettingsWindow.swift")
        #expect(settings.contains("NavigationSplitView"))
        #expect(settings.contains("List(selection:"))
        #expect(!settings.contains("TabView(selection:"))
        for category in ["Általános", "Könyvtár", "Helyszínek", "Felszerelések", "Szűrők", "Minőség", "Adatvédelem és támogatás"] {
            #expect(settings.contains(category), Comment(rawValue: category))
        }
    }

    @Test func mainShellUsesBalancedNativeNavigationAndSharedCards() throws {
        let shell = try source("Sources/AstroToolApp/Views/MainShellView.swift")
        let shared = try source("Sources/AstroToolApp/Views/SharedComponents.swift")
        #expect(shell.contains("navigationSplitViewStyle(.balanced)"))
        #expect(shared.contains("ProductCard"))
    }

    @Test func navigationChoicesAreRestoredWithoutStoringLibraryData() throws {
        let state = try source("Sources/AstroToolApp/AppState.swift")
        #expect(state.contains("lastPageKey"))
        #expect(state.contains("lastSettingsTabKey"))
        #expect(state.contains("persistentIdentifier"))
        #expect(state.contains("restoreNavigationPreferences"))
    }
}
