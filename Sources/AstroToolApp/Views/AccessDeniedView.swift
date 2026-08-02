import AppKit
import SwiftUI

/// Full-screen replacement for the tab UI when the configured root can't be
/// read at all -- either a TCC permission problem or an unmounted external
/// volume. Shown in place of `TabView`, not as an overlay on top of it.
struct AccessDeniedView: View {
    let status: RootStatus
    let onRetry: () -> Void

    private var isNotMounted: Bool { status == .notMounted }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isNotMounted ? "externaldrive.badge.xmark" : "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text(isNotMounted ? "A kötet nincs csatlakoztatva" : "Hozzáférés megtagadva")
                .font(.title)
                .bold()

            if isNotMounted {
                Text("A könyvtár gyökere egy külső köteten van, ami jelenleg nincs csatlakoztatva.\nCsatlakoztasd a kötetet a Finderben, majd próbáld újra.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lépések a hozzáférés megadásához:")
                        .bold()
                    Text("1. Rendszerbeállítások → Adatvédelem és biztonság → Teljes lemezhozzáférés")
                    Text("2. Engedélyezd a hozzáférést ennek az alkalmazásnak")
                    Text("3. Indítsd újra az alkalmazást")
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if !isNotMounted {
                    Button("Adatvédelmi beállítások megnyitása") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Újrapróbálás") { onRetry() }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
