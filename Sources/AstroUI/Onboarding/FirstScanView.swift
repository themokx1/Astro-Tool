import SwiftUI

@MainActor
public struct FirstScanView: View {
    private let libraryName: String
    private let progress: Double?
    private let cancel: () -> Void

    public init(
        libraryName: String,
        progress: Double?,
        cancel: @escaping () -> Void
    ) {
        self.libraryName = libraryName
        self.progress = progress
        self.cancel = cancel
    }

    public var body: some View {
        VStack(spacing: AstroTokens.Spacing.spacious) {
            if let progress {
                VStack(spacing: AstroTokens.Spacing.compact) {
                    ProgressView(value: progress, total: 1)
                        .frame(maxWidth: 360)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }

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
