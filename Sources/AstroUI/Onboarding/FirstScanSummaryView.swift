import AstroApplication
import SwiftUI

@MainActor
public struct FirstScanSummaryView: View {
    private let snapshot: LibrarySnapshot
    private let continueToLibrary: () -> Void
    private let personalize: () -> Void

    public init(
        snapshot: LibrarySnapshot,
        continueToLibrary: @escaping () -> Void,
        personalize: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.continueToLibrary = continueToLibrary
        self.personalize = personalize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            Label("FIRST SCAN COMPLETE", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(AstroTokens.Color.spectralBlue)

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Your library is ready")
                    .font(.largeTitle.weight(.semibold))
                Text("AstroTool found these items without changing the image library.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: AstroTokens.Spacing.standard) {
                countTile(snapshot.projectCount, label: "Projects", systemImage: "folder")
                countTile(snapshot.nightCount, label: "Nights", systemImage: "moon.stars")
                countTile(snapshot.frameCount, label: "Frames", systemImage: "photo.stack")
            }

            Text("Personalization is optional. Location, equipment, filters, and quality preferences can all be set up later.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Personalize…", action: personalize)
                Spacer()
                Button("Continue to Library", action: continueToLibrary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private func countTile(_ count: Int, label: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Label(label, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(count, format: .number)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AstroTokens.Spacing.standard)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(AstroTokens.Color.hairline, lineWidth: 1)
        }
    }
}
