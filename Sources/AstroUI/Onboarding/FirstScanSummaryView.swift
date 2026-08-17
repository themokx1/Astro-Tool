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
                .foregroundStyle(AstroTokens.Color.accent)
                .accessibilityIdentifier("v2.onboarding.summary")

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Your library is ready")
                    .font(.largeTitle.weight(.semibold))
                Text("AstroTool found these items without changing the image library.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // W2-10 (2026-08-17, Liquid Glass): three static count tiles on a
            // one-time marketing screen -- title, hero number, no Table/List
            // -- exactly `MetricCard`'s own shape, so they get real glass
            // like it rather than the hand-rolled `.regularMaterial` panel
            // this used to draw. `GlassEffectContainer` groups the three so
            // they merge/morph as one region instead of each computing its
            // own independent glass pass.
            GlassEffectContainer {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    countTile(snapshot.projectCount, label: "Projects", systemImage: "folder")
                    countTile(snapshot.nightCount, label: "Nights", systemImage: "moon.stars")
                    countTile(snapshot.frameCount, label: "Frames", systemImage: "photo.stack")
                }
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
                    .accessibilityIdentifier("v2.onboarding.continue")
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    // W2-10: `label` used to be a plain `String`, which routes
    // `Label(label, systemImage:)` to its verbatim `StringProtocol` overload
    // instead of the translating `LocalizedStringKey` one -- "Projects",
    // "Nights", "Frames" stayed English on a Hungarian first-scan screen.
    // Same defect class as `MetricCard.title` (`WorkspaceComponents.swift`),
    // fixed the same way.
    private func countTile(_ count: Int, label: LocalizedStringKey, systemImage: String) -> some View {
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
        // `ConcentricRectangle` (no explicit radius) matches whichever
        // container this tile ends up in, the same way `MetricCard` and
        // `ArchiveTaskCard` already do -- see this file's own call site
        // comment for why this became glass instead of staying a hand-rolled
        // `.regularMaterial` card.
        .glassEffect(.regular, in: ConcentricRectangle())
    }
}
