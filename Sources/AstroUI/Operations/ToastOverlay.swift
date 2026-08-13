import AstroApplication
import SwiftUI

/// The V2 global toast layer -- a top-trailing stack of recent operation
/// outcomes, floating above whichever page happens to be on screen. Mirrors
/// the V1 `ToastOverlay` (see `Sources/AstroToolApp/Views/ToastOverlay.swift`)
/// but reads from `OperationHost` instead of `AppState`, since V2 routes all
/// background work through `OperationHost.run(kind:title:work:)` rather than
/// V1's `beginOperation`/`endOperation` pair.
///
/// Also owns the toast layer's only timer: `OperationHost.expireToasts(now:)`
/// is a pure function of a caller-supplied `Date`, so this view is what
/// actually drives real-time expiry, keeping the store itself trivially
/// testable with a synthetic clock.
public struct ToastOverlay: View {
    @Environment(OperationHost.self) private var operationHost

    public init() {}

    public var body: some View {
        VStack(alignment: .trailing, spacing: AstroTokens.Spacing.compact) {
            ForEach(operationHost.toasts) { toast in
                ToastCapsule(toast: toast) {
                    operationHost.dismissToast(id: toast.id)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, AstroTokens.Spacing.compact)
        .padding(.trailing, AstroTokens.Spacing.compact)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: operationHost.toasts.count)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                operationHost.expireToasts(now: Date())
            }
        }
    }
}

private struct ToastCapsule: View {
    let toast: OperationHost.Toast
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .firstTextBaseline, spacing: AstroTokens.Spacing.compact) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(toast.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Click to dismiss")
        .accessibilityIdentifier("v2.toast-layer.toast")
    }

    private var iconName: String {
        switch toast.level {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.level {
        case .success: .green
        case .failure: .red
        case .info: AstroTokens.Color.spectralBlue
        }
    }
}
