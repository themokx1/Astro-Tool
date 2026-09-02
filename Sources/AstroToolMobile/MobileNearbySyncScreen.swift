import SwiftUI
import Foundation

/// The nearby-sync screen (spec §4.1/§4.3): the local-network explanation
/// and start button, the pairing-code confirmation, the in-progress states,
/// and the finished/failed outcomes. Presentation only — every action it
/// offers is a plain closure the caller supplies. It never touches storage
/// itself: the session that drives the actual exchange, and the two
/// `MobileLibraryStore` routes an incoming or outgoing plan goes through,
/// live in the caller (`MobileRootView.swift`), which maps its own session
/// state into the plain `MobileNearbySyncUIState` this view renders (also
/// declared in `MobileRootView.swift`) — so this file needs no dependency
/// on the underlying session module at all.
struct MobileNearbySyncScreen: View {
    let state: MobileNearbySyncUIState
    let onStart: () -> Void
    let onConfirmCode: () -> Void
    let onRejectCode: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onForgetAndRetry: () -> Void
    let onOpenSettings: () -> Void
    let onUseAirDropInstead: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch state {
                case .idle:
                    startView
                case .searching:
                    progressView(String(localized: "Looking for your Mac…"), identifier: "v5.mobile.nearby.searching")
                case .connecting:
                    progressView(String(localized: "Connecting…"), identifier: "v5.mobile.nearby.connecting")
                case .pairingCode(let code):
                    codeView(code)
                case .receiving:
                    progressView(String(localized: "Receiving the plan from your Mac…"), identifier: "v5.mobile.nearby.receiving")
                case .staged:
                    progressView(String(localized: "Checking the plan…"), identifier: "v5.mobile.nearby.staged")
                case .sendingReturn:
                    progressView(String(localized: "Sending your checklist and notes…"), identifier: "v5.mobile.nearby.sending-return")
                case .finished:
                    finishedView
                case .failed(let failure):
                    failedView(failure)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .navigationTitle("Connect to my Mac")
            .toolbar {
                if isCancellable {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .accessibilityIdentifier("v5.mobile.nearby.cancel")
                    }
                }
            }
        }
        .accessibilityIdentifier("v5.mobile.nearby.screen")
    }

    private var isCancellable: Bool {
        switch state {
        case .finished, .failed: return false
        default: return true
        }
    }

    private var startView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "wifi")
                .font(.system(size: 42))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Connect to my Mac")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("The local network permission is used only to hand data between your own AstroTool apps.")
                .font(.body)
                .accessibilityIdentifier("v5.mobile.nearby.explanation")
            Text("Open iPhone Sync on your Mac first, then look for it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Look for my Mac", action: onStart)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile.nearby.start")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressView(_ message: String, identifier: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier(identifier)
    }

    private func codeView(_ code: String) -> some View {
        VStack(spacing: 20) {
            Text("Check that both screens show the same code")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .accessibilityIdentifier("v5.mobile.nearby.code")
            HStack(spacing: 16) {
                Button("Not a match", role: .destructive, action: onRejectCode)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("v5.mobile.nearby.reject-code")
                Button("Codes match", action: onConfirmCode)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v5.mobile.nearby.confirm-code")
            }
        }
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Label("Your Mac is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(uiColor: .systemGreen))
                .font(.title3.weight(.semibold))
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile.nearby.done")
        }
        .accessibilityIdentifier("v5.mobile.nearby.finished")
    }

    private func failedView(_ failure: MobileNearbySyncUIFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message(for: failure))
                .font(.body)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("v5.mobile.nearby.failure-message")
            if failure == .peerNotFound {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("v5.mobile.nearby.open-settings")
            }
            if case .identityChanged = failure {
                Button("Forget this Mac and pair again", action: onForgetAndRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v5.mobile.nearby.forget-and-retry")
            } else {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v5.mobile.nearby.retry")
            }
            Button("Send with AirDrop instead", action: onUseAirDropInstead)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("v5.mobile.nearby.use-airdrop")
        }
        .accessibilityIdentifier("v5.mobile.nearby.failed")
    }

    private func message(for failure: MobileNearbySyncUIFailure) -> String {
        switch failure {
        case .peerNotFound:
            return String(localized: "AstroTool could not find your Mac on this network. Check that Local Network access is allowed for AstroTool in Settings, and that iPhone Sync is open on your Mac.")
        case .pairingRejected:
            return String(localized: "The code was not confirmed on both devices. Nothing was sent or received.")
        case .identityChanged:
            return String(localized: "This Mac no longer matches what this iPhone already trusts. This usually means the Mac was reinstalled or replaced. If you did not expect that, stop here and check your Mac. Otherwise, forget it and pair again — you'll see the six-digit code once more.")
        case .transferFailed:
            return String(localized: "The connection was lost before the sync finished. Nothing changed on either device.")
        case .importFailed:
            return String(localized: "The plan from your Mac could not be brought in safely. Your current plan on this iPhone is unchanged.")
        case .timeout:
            return String(localized: "This took too long and was stopped. Nothing changed on either device.")
        case .cancelled:
            return String(localized: "The connection was stopped.")
        }
    }
}
