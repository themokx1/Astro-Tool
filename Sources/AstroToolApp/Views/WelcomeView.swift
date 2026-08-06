import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        VStack(spacing: 28) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            Text("Üdv az AstroToolban")
                .font(.largeTitle)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                bullet("Végigolvassa a képkönyvtáradat, és megmondja, mi hiányzik.")
                bullet("**Soha nem töröl és nem mozgat semmit** a könyvtáradban.")
                bullet("Minden a te gépeden fut, semmi nem megy ki az internetre.")
            }
            .frame(maxWidth: 460, alignment: .leading)

            VStack(spacing: 10) {
                Button("Képkönyvtár kiválasztása…") { appState.chooseRoot() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Milyen mappastruktúrát vár?") { showStructureHelp = true }
                    .buttonStyle(.link)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(48)
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

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
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
