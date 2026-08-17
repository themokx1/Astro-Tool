import AstroApplication
import Foundation
import SwiftUI

/// One card per problem KIND, not per finding -- `ArchiveTaskQuery` already
/// rolled up thousands of individual findings into at most six tasks, and
/// this view turns each into a single actionable card. The old library-health
/// table listed every finding as its own row with a "Next step" column that
/// was a static label; every card here carries a real button instead, and
/// `ArchiveTaskQuery`'s own doc comment gates that a task with no executable
/// action never reaches this view at all.
struct ArchiveTaskCard: View {
    let task: ArchiveTask
    let onAction: (ArchiveTaskAction) -> Void
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AstroTokens.Spacing.section) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(headlineValue)
                        .font(.system(size: 23, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(task.severity == .error
                            ? AstroTokens.Color.critical : AstroTokens.Color.accent)
                    Text(title).astroSectionTitle()
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(task.evidencePaths, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button(actionTitle) { onAction(task.action) }
                .buttonStyle(.borderedProminent)
                .tint(task.severity == .error
                    ? AstroTokens.Color.critical : AstroTokens.Color.accent)
                .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue).action")
        }
        .padding(AstroTokens.Spacing.standard)
        // Task 6 (2026-08-17, Liquid Glass): the literal "kártya" (card) the
        // plan's own example sentence names -- it floats now, via true
        // glass rather than the former flat `surface` fill. Its own content
        // is a headline, a sentence, and a handful of evidence paths, never
        // a `Table`/`List`, so it carries none of that gate's restrictions.
        // An error card keeps its distinct identity through a red glass
        // tint rather than the former stroked-red border.
        .glassEffect(cardGlass, in: ConcentricRectangle())
        .contextMenu { Button("Mark as Acknowledged…", action: onAcknowledge) }
        .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue)")
    }

    private var cardGlass: Glass {
        task.severity == .error
            ? .regular.tint(AstroTokens.Color.critical.opacity(0.18))
            : .regular
    }

    // `.reclaim` severity is a byte count the user can win back;
    // everything else is a count of files that need a look.
    private var headlineValue: String {
        task.severity == .reclaim
            ? Self.formatBytes(task.bytes)
            : task.affectedFileCount.formatted()
    }

    // wave 2: move to AstroFormat
    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // Localization trap (see this file's header + the plan's own warning):
    // a `switch` over `task.kind` that returns `String` infers `String` on
    // every literal branch and NEVER localizes -- `Text(String)` resolves to
    // the verbatim `StringProtocol` overload, not the `LocalizedStringKey`
    // one, so the Hungarian build would silently keep showing English
    // forever. This is the exact defect `MetricCard.title` was fixed for.
    // The type must be spelled out explicitly on every one of these three
    // properties, or a ternary/`??` inside a branch can silently widen the
    // inferred type back to `String`.
    //
    // Task 3 (wave 3): the switch itself now lives in `ArchiveTaskPresentation`,
    // shared with `ArchiveTaskDetailView`'s own `navigationTitle` and the
    // breadcrumb label, so the card and its own "view all" destination can
    // never show two different names for the same kind.
    private var title: LocalizedStringKey { ArchiveTaskPresentation.title(for: task.kind) }

    private var explanation: LocalizedStringKey {
        switch task.kind {
        case .intermediateFiles:
            "Intermediate output from stacking — regenerable from your raw frames. Your light frames are not touched."
        case .duplicateContent:
            "Files whose exact contents already exist elsewhere. You choose which copy stays."
        case .misplacedCalibration:
            "These files sit in a calibration folder but are not calibration frames, so this night's matching is silently wrong."
        case .brokenNames:
            "A nested session tree, an unfilled template name, or a duplicated catalog prefix."
        case .corruption:
            // The only card whose finding may mean data is already lost, and
            // the only one for which "restore from a backup copy" is true
            // advice -- see `ArchiveTaskKind.corruption`'s doc comment.
            "A file's contents changed while its size and timestamp did not. Restore it from a backup copy."
        case .unverified:
            // Deliberately does NOT say "restore from a backup": an unread
            // or in-place-rewritten file is not proof of loss, and telling
            // someone to restore it would be wrong advice.
            "The last integrity check could not read these files, or found them rewritten in place. This is not proof of loss."
        case .auditNeverRun:
            "I have not looked through this library yet. The check reads only — it never moves or deletes anything."
        }
    }

    // Task 3 (wave 3): worded by what the action ITSELF does, not by kind --
    // "Megjelenítés a Finderben" for 33 items was a false promise (the
    // owner's own words: a single button cannot open 33 items in Finder).
    // Switches on `task.action`, not `task.kind`, so the label always
    // matches what tapping the button actually does: a kind whose card
    // currently has more than one finding says so in the count, a kind with
    // exactly one still says it opens Finder directly.
    private var actionTitle: LocalizedStringKey {
        switch task.action {
        case .previewQuarantine: "Preview Quarantine…"
        case .revealInFinder: "Reveal in Finder"
        case .showFindings: "View \(task.affectedFileCount.formatted()) Files"
        case .runAudit: "Run Check"
        // Gated out before a card ever reaches this view
        // (`ArchiveTaskQueryTests.everyCardIsActionable`) -- reachable here
        // only if that gate regresses, so this string is never actually
        // shown to anyone.
        case .unavailable: "No Action Available"
        }
    }
}
