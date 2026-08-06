import AppKit
import SwiftUI

/// Full-screen replacement for the shell when the configured root can't be
/// read at all -- either a TCC permission problem or an unmounted external
/// volume. Shown in place of `NavigationSplitView`, not as an overlay on top
/// of it.
///
/// B1 fix: BOTH variants offer a way out that doesn't require fixing the
/// CURRENT root (a different folder entirely might be what's actually
/// wanted -- e.g. the bookmarked volume is gone for good). `.notMounted`
/// additionally auto-retries every 5s and reacts as soon as
/// `AppState`'s `NSWorkspace.didMountNotification` observer sees the volume
/// reappear, so plugging in the drive is enough -- no button press needed.
struct AccessDeniedView: View {
    @Environment(AppState.self) private var appState
    let status: RootStatus
    let onRetry: () -> Void

    /// `.notMounted`'s belt on top of `AppState`'s mount-notification
    /// observer's suspenders -- a `Timer` firing while this view is on
    /// screen means the volume also gets picked up even if, for whatever
    /// reason, the OS mount notification didn't fire (e.g. it was already
    /// mounted by the time this screen appeared, just briefly unreadable).
    private let retryTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var isNotMounted: Bool { status == .notMounted }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isNotMounted ? "externaldrive.badge.xmark" : "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text(isNotMounted ? "A kötet nincs csatlakoztatva" : "Hozzáférés megtagadva")
                .font(.title)
                .bold()

            Text(appState.config.rootPath)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .font(.callout)

            if isNotMounted {
                Text("A könyvtár gyökere egy külső köteten van, ami jelenleg nincs csatlakoztatva.\nCsatlakoztasd a kötetet a Finderben -- az app automatikusan folytatja, mihelyt megjelenik.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Vár a kötetre…").foregroundStyle(.secondary)
                }
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
                Button("Másik mappa választása…") { appState.chooseRoot() }
                Button("Mappastruktúra súgó") {
                    NotificationCenter.default.post(name: .showFolderStructureHelp, object: nil)
                }
                .buttonStyle(.link)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(retryTimer) { _ in
            if isNotMounted { onRetry() }
        }
    }
}
