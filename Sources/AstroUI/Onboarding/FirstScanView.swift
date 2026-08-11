import SwiftUI

@MainActor
public struct FirstScanView: View {
    private let libraryName: String
    private let cancel: () -> Void

    public init(libraryName: String, cancel: @escaping () -> Void) {
        self.libraryName = libraryName
        self.cancel = cancel
    }

    public var body: some View {
        VStack(spacing: AstroTokens.Spacing.spacious) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: AstroTokens.Spacing.compact) {
                Text("Reading \(libraryName)")
                    .font(.title.weight(.semibold))
                Text("AstroTool is building a read-only index. Files stay where they are, and the index is kept outside the image library.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            Label("Scanning locally", systemImage: "externaldrive.badge.magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(AstroTokens.Color.spectralBlue)

            Button("Cancel Scan", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
