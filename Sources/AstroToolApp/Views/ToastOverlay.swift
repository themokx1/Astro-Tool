import SwiftUI

/// R10-A5: the global toast feedback layer -- top-right stacked capsules
/// showing the last few operation outcomes, regardless of which page
/// happens to be on screen. Rendered from `MainShellView` via
/// `.overlay(alignment: .topTrailing)`, so it floats above the whole window
/// (sidebar + detail) rather than living inside any one page's own view
/// hierarchy -- an error page A triggers is still visible after the user has
/// already moved on to page B.
///
/// Complements, never replaces: `AppState.lastError`'s existing inline
/// displays (8 view surfaces) and the toolbar clock icon's activity-log
/// popover both stay exactly as they were. See `AppState.pushToast`'s doc
/// comment for the "why" -- errors used to be invisible everywhere except
/// those 8 surfaces, and success feedback was a `progressText` toolbar
/// caption that vanished the moment the next operation started.
struct ToastOverlay: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(appState.toasts) { toast in
                ToastCapsule(toast: toast) {
                    appState.dismissToast(id: toast.id)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: appState.toasts.count)
    }
}

/// One toast bubble -- icon (kind-colored) + message, clickable to dismiss
/// early. A large-corner-radius `RoundedRectangle` rather than a literal
/// SwiftUI `Capsule` shape: "capsule" here means the familiar rounded-pill
/// toast look, but messages can wrap to a couple of lines (a long export
/// filename, a longer error), and a true `Capsule` looks wrong once its
/// content isn't a single line.
private struct ToastCapsule: View {
    let toast: AppState.Toast
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Kattintásra eltűnik")
    }

    private var iconName: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.kind {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}
