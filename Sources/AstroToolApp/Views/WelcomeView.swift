import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LegacyMigrationView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Korábbi AstroTool telepítés található")
                    .font(.largeTitle.bold())
                Text("Átveheted a korábbi képkönyvtár-kapcsolatot és az ismert, biztonságos beállításokat. A régi beállítások és a képfájlok változatlanok maradnak.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
            HStack(spacing: 12) {
                Button("Tiszta indítás") { appState.declineLegacyMigration() }
                Button("Korábbi beállítások átvétele") { appState.acceptLegacyMigration() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Csak a könyvtárengedély, a legutóbbi könyvtárak és általános felületi beállítások vehetők át. Ismeretlen vagy érzékeny kulcsot az AstroTool nem másol.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// First-run screen (R9-T1, spec A.9): replaces the WHOLE window when there
/// is no saved root bookmark at all -- `RootView` shows this instead of
/// `NavigationSplitView`, same "full-screen replacement, not an overlay"
/// convention as `AccessDeniedView`. Once a root is chosen (button, drop, or
/// a resolved bookmark on a later launch), `AppState.rootStatus` moves past
/// `.noRoot` and `RootView` swaps to `FirstScanView` or the normal shell.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @State private var showStructureHelp = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear, Color.indigo.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Az égbolt-adatbázisod, végre egyben.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Az AstroTool rendszerezi az éjszakáidat, ellenőrzi a minőséget, és megmutatja a következő értelmes lépést.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 650)
                }

                HStack(alignment: .top, spacing: 12) {
                    promise(
                        "A képeid helyben maradnak",
                        detail: "Nincs fiók, felhő vagy háttérben futó feltöltés.",
                        symbol: "lock.shield"
                    )
                    promise(
                        "Te választod a könyvtárat",
                        detail: "Csak az általad kiválasztott könyvtárhoz fér hozzá.",
                        symbol: "folder.badge.plus"
                    )
                    promise(
                        "Biztonságos első lépés",
                        detail: "Az első beolvasás nem töröl és nem mozgat.",
                        symbol: "checkmark.shield"
                    )
                }
                .frame(maxWidth: 760)

                VStack(spacing: 12) {
                    Button("Képkönyvtár kiválasztása…") { appState.chooseRoot() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Képkönyvtár kiválasztása")

                    Button("Milyen mappastruktúrát vár?") { showStructureHelp = true }
                        .buttonStyle(.link)
                }

                Text("Tipp: egy mappát ide is húzhatsz.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Képkönyvtár mappája ide húzható")

                if let lastError = appState.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .accessibilityLabel("Hiba: \(lastError)")
                }
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3, antialiased: true)
                    .padding(16)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $showStructureHelp) {
            FolderStructureHelpSheet()
        }
    }

    private func promise(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.separator.opacity(0.45)))
    }

    /// Accepts a single dropped folder anywhere on the window and selects it
    /// as the root, same as "Képkönyvtár kiválasztása…" would.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                appState.selectRoot(at: url)
            }
        }
        return true
    }
}
