import SwiftUI

/// A non-technical map of the AstroTool hierarchy. File-system paths are
/// deliberately absent; the surrounding onboarding offers those separately.
public struct LibraryMapView: View {
    private struct Node: Identifiable {
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let symbol: String
        var id: String { symbol }
    }

    private let nodes: [Node] = [
        Node(title: "Library", detail: "The home of everything AstroTool follows", symbol: "books.vertical"),
        Node(title: "Project", detail: "One object you collect over time", symbol: "sparkles.rectangle.stack"),
        Node(title: "Night", detail: "What happened on one date", symbol: "moon.stars"),
        Node(title: "Capture", detail: "Frames made with the same setup", symbol: "camera.aperture"),
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    ZStack {
                        Circle().fill(AstroTokens.Color.accent.opacity(0.14))
                        Image(systemName: node.symbol).foregroundStyle(AstroTokens.Color.accent)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title).font(.headline)
                        Text(node.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index < nodes.count - 1 {
                        Image(systemName: "chevron.down").foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: AstroTokens.Spacing.compact) {
                role("Light", symbol: "star")
                role("Flat", symbol: "circle.lefthalf.filled")
                role("Dark", symbol: "moon.fill")
                role("Bias", symbol: "waveform.path")
            }
        }
        .astroRaisedSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v3.onboarding.library-map")
    }

    private func role(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AstroTokens.Color.recess, in: Capsule())
    }
}
