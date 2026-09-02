import AstroApplication
import SwiftUI

@MainActor
public struct FirstScanSummaryView: View {
    private let snapshot: LibrarySnapshot
    /// The scanned folder's own name -- named in the "found nothing" state,
    /// so the reader can tell at a glance that the wrong folder was picked.
    private let libraryName: String
    private let continueToLibrary: () -> Void
    private let personalize: () -> Void
    /// Back to the folder picker. The primary action of the "found nothing"
    /// state below, which without it would be a dead end: 0 / 0 / 0 under
    /// "Your library is ready" was the single most misleading screen in the
    /// first run (2026-09-02 audit, fix E).
    private let chooseAnotherFolder: () -> Void

    public init(
        snapshot: LibrarySnapshot,
        libraryName: String,
        continueToLibrary: @escaping () -> Void,
        personalize: @escaping () -> Void,
        chooseAnotherFolder: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.libraryName = libraryName
        self.continueToLibrary = continueToLibrary
        self.personalize = personalize
        self.chooseAnotherFolder = chooseAnotherFolder
    }

    /// The scan completed and found no astrophotography at all -- neither a
    /// project folder nor a single frame. `nightCount` is deliberately not
    /// part of this: it counts session-date folder names, which cannot be
    /// non-zero while both of these are zero.
    private var foundNothing: Bool {
        snapshot.frameCount == 0 && snapshot.projectCount == 0
    }

    public var body: some View {
        if foundNothing {
            foundNothingState
        } else {
            readyState
        }
    }

    /// Same eyebrow identifier (`v2.onboarding.summary`) and same primary
    /// action identifier (`v2.onboarding.continue`) as `readyState`, so
    /// existing automation still finds both on either branch.
    private var foundNothingState: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            Label("FIRST SCAN COMPLETE", systemImage: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(AstroTokens.Color.accent)
                .accessibilityIdentifier("v2.onboarding.summary")

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("No astrophotos found in \(libraryName)")
                    .font(.largeTitle.weight(.semibold))
                Text("AstroTool looked for sessions, stacks, and processed folders, and for image files it recognises, and found none. This is usually the wrong folder — pick the one that holds your captures.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Nothing was changed in the folder that was scanned.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Continue anyway", action: continueToLibrary)
                    .accessibilityIdentifier("v2.onboarding.continue")
                Spacer()
                Button("Choose a Different Folder…", action: chooseAnotherFolder)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("v2.onboarding.choose-different-folder")
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private var readyState: some View {
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
                    // W6-E item 3 (live pixel review, real library): this
                    // tile used to say "Nights", the same word the Home
                    // page/sidebar's own Éjszakák count uses for a DIFFERENT
                    // number -- `LibrarySnapshot.nightCount` is
                    // `COUNT(DISTINCT session_date)` raw folder-name
                    // strings (`Database.libraryIndexCounts`), which counts
                    // a run-suffix sibling folder (e.g. "2026-04-06" and
                    // "2026-04-06-2") as two, unlike the deduplicated,
                    // calendar-date `NightRecord` count the Home page shows.
                    // Both numbers are real and neither is wrong for what
                    // it measures; showing them under the same word is what
                    // was wrong (20 vs. 16 on the real library that
                    // prompted this fix). Naming what THIS number actually
                    // counts -- session folders on disk -- removes the
                    // apparent contradiction instead of forcing the two
                    // counts to agree.
                    countTile(snapshot.nightCount, label: "Session Folders", systemImage: "folder.badge.gearshape")
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
