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
                            ? AstroTokens.Color.danger : AstroTokens.Color.spectralBlue)
                    Text(title).font(.system(.title3, weight: .semibold))
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
                    ? AstroTokens.Color.danger : AstroTokens.Color.spectralBlue)
                .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue).action")
        }
        .padding(AstroTokens.Spacing.standard)
        .background(AstroTokens.Color.elevatedGraphite, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(task.severity == .error
                    ? AstroTokens.Color.danger.opacity(0.34) : AstroTokens.Color.hairline, lineWidth: 1)
        }
        .contextMenu { Button("Mark as Acknowledged…", action: onAcknowledge) }
        .accessibilityIdentifier("v2.archive.task.\(task.kind.rawValue)")
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
    private var title: LocalizedStringKey {
        switch task.kind {
        case .intermediateFiles: "Stacking leftovers"
        case .duplicateContent: "Byte-identical copies"
        case .misplacedCalibration: "Calibration in the wrong folder"
        case .brokenNames: "Folder names that break scanning"
        case .corruption: "Checksum mismatch"
        case .unverified: "Could not be confirmed"
        case .auditNeverRun: "Not checked yet"
        }
    }

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

    private var actionTitle: LocalizedStringKey {
        switch task.kind {
        case .intermediateFiles: "Preview Quarantine…"
        case .duplicateContent: "Compare Copies…"
        case .misplacedCalibration, .brokenNames, .corruption, .unverified: "Reveal in Finder"
        case .auditNeverRun: "Run Check"
        }
    }
}
