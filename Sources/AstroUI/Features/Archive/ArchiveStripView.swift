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

    /// Task 10 prerequisite (the fourth instance of this wave's own
    /// localization trap): a `String`-typed accessor over user-facing
    /// prose is invisible to `scripts/extract-localizable-strings.swift`
    /// and resolves `.help`/`.accessibilityValue` through `Text`'s verbatim
    /// `StringProtocol` overload instead of the `LocalizedStringKey` one --
    /// the Hungarian build would silently keep showing this sentence in
    /// English forever. `Text` (not `String`) is required, exactly like
    /// `detailText(for:)` just below already does for the per-segment
    /// tooltip.
    private var reclaimHelpText: Text {
        // Named `percentText`/`bytesText`, not the bare `percent`/`bytes` --
        // the extraction script's placeholder-type inference indexes EVERY
        // `let name: Type` declaration across all of `Sources/` by name, and
        // both bare names are declared as numeric types elsewhere in this
        // codebase (`ArchiveTask.bytes: Int64`, `TonightPage.percent:
        // Double`); a same-named local here (itself a `String`, with no
        // type annotation to register a conflicting entry) would have been
        // misclassified as `%lld`/`%lf` instead of the `%@` these two
        // already-formatted strings actually need.
        let percentText = (reclaimFraction * 100).formatted(.number.precision(.fractionLength(0...1)))
        let bytesText = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
        return Text("\(bytesText) reclaimable, \(percentText)% of the archive")
    }

    @ViewBuilder
    private func segmentView(_ segment: ArchiveStripLayout.Segment, width: CGFloat) -> some View {
        let isDimmed = selectedClass != nil && selectedClass != segment.archiveClass
        let identifier = segment.archiveClass?.rawValue ?? "residual"
        let nameText = Text(segment.archiveClass?.displayName ?? "Other")
        let detailText = detailText(for: segment)
        Rectangle()
            .fill(segment.archiveClass.map(ArchivePalette.color(for:)) ?? AstroTokens.Color.hairline)
            .opacity(isDimmed ? 0.35 : 1)
            .frame(width: max(0, width * segment.fraction))
            .onTapGesture { onSelect(segment.archiveClass) }
            .help(nameText + Text(verbatim: " · ") + detailText)
            .accessibilityLabel(nameText)
            .accessibilityValue(detailText)
            .accessibilityIdentifier("v2.archive.strip.\(identifier)")
    }

    /// Two localizable pieces composed with `Text`'s `+` operator, not one
    /// concatenated `String` -- `.help(...)` and `.accessibilityLabel(...)`
    /// both accept `Text`, so this stays translatable end to end instead of
    /// baking the byte count and file count into a verbatim string.
    private func detailText(for segment: ArchiveStripLayout.Segment) -> Text {
        Text("\(ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file)) · \(segment.fileCount.formatted()) files")
    }
}

private extension ArchiveClass {
    /// The strip's segment names and tooltip text. This is user-facing
    /// vocabulary ("Processed", "Unclassified", "Calibration" are ordinary
    /// words), not a catalog designation -- unlike
    /// `ArchiveTargetRow.displayName`, which renders a literal catalog
    /// string (e.g. "NGC 7000") that has no Hungarian form to translate to.
    /// `LocalizedStringKey` (not `String`) is required here: a `String`-typed
    /// switch is invisible to `scripts/extract-localizable-strings.swift` and
    /// to SwiftUI's own localization resolution, so it silently renders
    /// English forever -- the same defect `MetricCard.title` was fixed for.
    var displayName: LocalizedStringKey {
        switch self {
        case .light: "Light frames"
        case .stack: "Stacks"
        case .processed: "Processed"
        case .calibration: "Calibration"
        case .unclassified: "Unclassified"
        }
    }
}
