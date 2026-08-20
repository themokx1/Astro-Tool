import AstroApplication
import Foundation
import SwiftUI

/// One row per target, its byte composition drawn as a miniature of
/// `ArchiveStripView` above it -- same segment colors
/// (`AstroTokens.Color.forArchiveClass`), same residual-merging layout maths
/// (`ArchiveStripLayout`), so the two read as one visual language rather than
/// two unrelated bar charts.
///
/// Unlike the strip, a row's bar is not normalized to its OWN total: it is
/// normalized to the LARGEST target in the map (`maxTargetBytes`), so a
/// row's bar length is directly comparable to every other row's at a glance.
/// That is why this view takes `maxTargetBytes` as a parameter instead of
/// computing it -- a single row has no way to know the largest target on its
/// own, and rows must all agree on the same scale.
struct ArchiveTargetRowView: View {
    let row: ArchiveTargetRow
    let maxTargetBytes: Int64
    let onRevealInFinder: () -> Void
    let onPreviewQuarantine: () -> Void

    /// Stored, computed once in `init` -- same reasoning as
    /// `ArchiveStripView.layout`: never recompute a segment layout in a
    /// getter on the body path.
    private let layout: ArchiveStripLayout

    init(
        row: ArchiveTargetRow, maxTargetBytes: Int64,
        onRevealInFinder: @escaping () -> Void,
        onPreviewQuarantine: @escaping () -> Void
    ) {
        self.row = row
        self.maxTargetBytes = maxTargetBytes
        self.onRevealInFinder = onRevealInFinder
        self.onPreviewQuarantine = onPreviewQuarantine
        self.layout = ArchiveStripLayout(slices: row.slices)
    }

    /// This row's share of the largest target's bytes -- the factor the bar
    /// block scales its full width by. `maxTargetBytes <= 0` means there is
    /// no meaningful largest target (an empty map), so the bar stays empty
    /// rather than dividing by zero.
    private var targetFraction: Double {
        guard maxTargetBytes > 0 else { return 0 }
        return min(1, Double(row.totalBytes) / Double(maxTargetBytes))
    }

    var body: some View {
        HStack(alignment: .center, spacing: AstroTokens.Spacing.standard) {
            nameBlock
                .frame(width: 210, alignment: .leading)
            barBlock
                .frame(maxWidth: .infinity)
            valueBlock
                .frame(width: 92, alignment: .trailing)
            // W6-E item 7 (live pixel review): "Preview Quarantine for This
            // Target…" used to be reachable ONLY through the right-click
            // context menu, with no visible affordance on the row itself.
            // Same row-actions convention as `ProjectWorkspaceView`'s
            // `nightActionMenu`/`seriesActionMenu` ("one set, not two"): the
            // same `rowActions` builder backs both this menu and the
            // context menu below.
            Menu {
                rowActions
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
            .accessibilityIdentifier("v2.archive.target.\(row.id).actions")
        }
        .padding(.vertical, AstroTokens.Spacing.compact / 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRevealInFinder)
        .contextMenu { rowActions }
        .accessibilityIdentifier("v2.archive.target.\(row.id)")
    }

    /// The ONE place this row's action set is declared -- both the visible
    /// ellipsis menu and the right-click context menu build from this same
    /// function.
    @ViewBuilder
    private var rowActions: some View {
        Button("Reveal in Finder", action: onRevealInFinder)
        Button("Preview Quarantine for This Target…", action: onPreviewQuarantine)
    }

    @ViewBuilder
    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let name = row.displayName {
                Text(name) // verbatim: catalog designation, not translatable
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Not tied to a target") // LocalizedStringKey, translatable
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            Text("\(row.nightCount) nights · \(row.fileCount) files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var barBlock: some View {
        GeometryReader { proxy in
            let scaledWidth = proxy.size.width * targetFraction
            HStack(spacing: 1.5) {
                ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.archiveClass.map(AstroTokens.Color.forArchiveClass) ?? AstroTokens.Color.edge)
                        .frame(width: max(0, scaledWidth * segment.fraction))
                }
            }
            .frame(width: max(0, scaledWidth), alignment: .leading)
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var valueBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(ByteCountFormatter.string(fromByteCount: row.totalBytes, countStyle: .file))
                .font(.callout.monospacedDigit())
            if row.reclaimableBytes > 0 {
                Text("−\(ByteCountFormatter.string(fromByteCount: row.reclaimableBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AstroTokens.Color.critical)
            }
        }
    }
}
