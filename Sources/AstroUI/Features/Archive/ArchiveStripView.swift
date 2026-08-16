import AstroApplication
import Foundation
import SwiftUI

/// Pure layout maths for the archive strip, kept separate from the view so
/// it can be tested without rendering: a 1px-wide segment is unclickable and
/// unreadable, so anything under `residualThreshold` of the archive merges
/// into a single residual segment rather than being drawn as a sliver.
struct ArchiveStripLayout {
    static let residualThreshold = 0.005

    struct Segment: Equatable {
        let archiveClass: ArchiveClass?
        let fraction: Double
        let bytes: Int64
        let fileCount: Int
        var isResidual: Bool { archiveClass == nil }
    }

    let segments: [Segment]

    init(slices: [ArchiveSlice]) {
        let total = slices.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { segments = []; return }
        var kept: [Segment] = []
        var residualFraction = 0.0
        var residualBytes: Int64 = 0
        var residualFileCount = 0
        for slice in slices {
            let fraction = Double(slice.bytes) / Double(total)
            if fraction >= Self.residualThreshold {
                kept.append(Segment(
                    archiveClass: slice.archiveClass, fraction: fraction,
                    bytes: slice.bytes, fileCount: slice.fileCount
                ))
            } else {
                residualFraction += fraction
                residualBytes += slice.bytes
                residualFileCount += slice.fileCount
            }
        }
        if residualFraction > 0 {
            kept.append(Segment(
                archiveClass: nil, fraction: residualFraction,
                bytes: residualBytes, fileCount: residualFileCount
            ))
        }
        segments = kept
    }
}

struct ArchiveStripView: View {
    let slices: [ArchiveSlice]
    let reclaimableBytes: Int64
    let totalBytes: Int64
    let selectedClass: ArchiveClass?
    let onSelect: (ArchiveClass?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stored, computed once in `init` -- not a computed getter. `body` may
    /// run many times per layout pass, and this codebase's freeze history is
    /// entirely "work that ran in a getter on the body path".
    private let layout: ArchiveStripLayout

    init(
        slices: [ArchiveSlice], reclaimableBytes: Int64, totalBytes: Int64,
        selectedClass: ArchiveClass?, onSelect: @escaping (ArchiveClass?) -> Void
    ) {
        self.slices = slices
        self.reclaimableBytes = reclaimableBytes
        self.totalBytes = totalBytes
        self.selectedClass = selectedClass
        self.onSelect = onSelect
        self.layout = ArchiveStripLayout(slices: slices)
    }

    private var reclaimFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(reclaimableBytes) / Double(totalBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment, width: proxy.size.width)
                    }
                }
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Capsule()
                .fill(AstroTokens.Color.hairline)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(AstroTokens.Color.danger)
                            .frame(width: proxy.size.width * reclaimFraction)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.45), value: reclaimFraction)
                .help(reclaimHelpText)
                .accessibilityIdentifier("v2.archive.reclaim-rail")
                .accessibilityLabel("Reclaimable space")
                .accessibilityValue(reclaimHelpText)
        }
    }

    private var reclaimHelpText: String {
        let percent = (reclaimFraction * 100).formatted(.number.precision(.fractionLength(0...1)))
        let bytes = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
        return "\(bytes) reclaimable, \(percent)% of the archive"
    }

    @ViewBuilder
    private func segmentView(_ segment: ArchiveStripLayout.Segment, width: CGFloat) -> some View {
        let isDimmed = selectedClass != nil && selectedClass != segment.archiveClass
        let identifier = segment.archiveClass?.rawValue ?? "residual"
        let name = segment.archiveClass?.displayName ?? "Other"
        let detail = "\(ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file)) · \(segment.fileCount.formatted()) files"
        Rectangle()
            .fill(segment.archiveClass.map(ArchivePalette.color(for:)) ?? AstroTokens.Color.hairline)
            .opacity(isDimmed ? 0.35 : 1)
            .frame(width: max(0, width * segment.fraction))
            .onTapGesture { onSelect(segment.archiveClass) }
            .help("\(name) · \(detail)")
            .accessibilityLabel(name)
            .accessibilityValue(detail)
            .accessibilityIdentifier("v2.archive.strip.\(identifier)")
    }
}

private extension ArchiveClass {
    /// English display names for the strip and its tooltips/accessibility
    /// text -- `ArchiveTargetRow.displayName`'s doc comment already
    /// established this UI stays English (V2 UI/UX audit pattern P1), so
    /// this deliberately does not localize.
    var displayName: String {
        switch self {
        case .light: "Light frames"
        case .stack: "Stacks"
        case .processed: "Processed"
        case .calibration: "Calibration"
        case .unclassified: "Unclassified"
        }
    }
}
