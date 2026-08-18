import AppKit
import AstroApplication
import AstroCore
import SwiftUI

/// Pure navigation/verdict state for the blink-review sheet, decoupled from
/// image loading and from `ReviewStore` itself so it can be unit-tested with
/// a plain array of `FrameDecisionRecord` and a fake verdict closure --
/// mirrors V1 `FrameReviewSheet`'s own `index`/`recordVerdict` behavior:
/// `←`/`→` never go out of bounds, `a`/`x` (accept/reject) write the verdict
/// then auto-advance, `u` (clear) writes `undecided` but deliberately stays
/// put (a fix-a-mistake action, not "I've judged this, move on").
@MainActor
@Observable
public final class FrameBlinkReviewStore {
    /// Writes one frame's verdict through to storage (`ReviewStore.setVerdict`
    /// in production). Thrown errors are captured into `errorMessage` and
    /// the blink position does NOT advance -- a failed write should stay
    /// visible to the user, not silently skip past.
    public typealias VerdictHandler = @Sendable (_ relativePath: String, _ verdict: FrameVerdict) async throws -> Void

    public private(set) var decisions: [FrameDecisionRecord]
    public private(set) var index: Int
    public private(set) var errorMessage: String?

    private let verdictHandler: VerdictHandler

    public init(
        decisions: [FrameDecisionRecord],
        initialRelativePath: String? = nil,
        verdictHandler: @escaping VerdictHandler
    ) {
        self.decisions = decisions
        self.verdictHandler = verdictHandler
        if let initialRelativePath,
           let found = decisions.firstIndex(where: { $0.relativePath == initialRelativePath }) {
            self.index = found
        } else {
            self.index = 0
        }
    }

    public var currentFrame: FrameDecisionRecord? {
        decisions.indices.contains(index) ? decisions[index] : nil
    }

    public var canGoPrevious: Bool { index > 0 }
    public var canGoNext: Bool { decisions.indices.contains(index + 1) }

    public var positionText: String {
        decisions.isEmpty ? "0 / 0" : "\(index + 1) / \(decisions.count)"
    }

    public func goPrevious() {
        guard canGoPrevious else { return }
        index -= 1
    }

    public func goNext() {
        guard canGoNext else { return }
        index += 1
    }

    public func accept() async { await recordVerdict(.accepted) }
    public func reject() async { await recordVerdict(.rejected) }
    public func clearVerdict() async { await recordVerdict(.undecided) }

    /// Pushes a freshly-loaded decisions list (e.g. after `ReviewStore`'s own
    /// snapshot refreshed elsewhere) while keeping the blink position on the
    /// SAME frame whenever it still exists in the new list -- a verdict
    /// write must never silently reshuffle the frame the user is currently
    /// looking at. Falls back to clamping the index into range when the
    /// current frame is genuinely gone (e.g. its capture-group filter no
    /// longer includes it).
    public func refresh(decisions: [FrameDecisionRecord]) {
        let currentPath = currentFrame?.relativePath
        self.decisions = decisions
        if let currentPath, let found = decisions.firstIndex(where: { $0.relativePath == currentPath }) {
            index = found
        } else {
            index = min(index, max(decisions.count - 1, 0))
        }
    }

    private func recordVerdict(_ verdict: FrameVerdict) async {
        guard let frame = currentFrame else { return }
        errorMessage = nil
        do {
            try await verdictHandler(frame.relativePath, verdict)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if verdict != .undecided {
            goNext()
        }
    }
}

/// The file extensions QuickLook has no stock macOS plugin for, and which
/// `FITSImageRenderer` knows how to turn into a preview instead -- shared by
/// `FrameThumbnailCell` and this sheet's own large-preview loader, mirroring
/// V1's `fitsFallbackExtensions` (`Sources/AstroToolApp/Views/ThumbnailCell.swift`).
let astroUIFITSFallbackExtensions: Set<String> = ["fits", "fit", "fz"]

/// The "blink review" sheet -- R10-B1's V1 human-eyeball backstop, ported to
/// V2: a large image preview with `←`/`→` navigation and `a`/`x`/`u` verdict
/// shortcuts, plus a measured-quality metric bar (score/FWHM/roundness/
/// percentile) alongside each frame. Every verdict written here goes through
/// `store`'s own `verdictHandler` (`ReviewStore.setVerdict` in production),
/// the same call the frame table's context menu already uses -- a rejection
/// made here takes effect the next time this series is stacked, with no
/// extra step.
public struct FrameBlinkReview: View {
    @Bindable var store: FrameBlinkReviewStore
    let rootURL: URL
    let qualityLookup: (String) -> FrameQualityMetrics?
    let dismiss: () -> Void

    @State private var image: NSImage?
    @State private var isLoadingImage = false
    @State private var previewCache: [String: NSImage] = [:]
    @State private var cacheOrder: [String] = []
    private let cacheCapacity = 12
    private static let previewMaxDimension = 1600

    public init(
        store: FrameBlinkReviewStore,
        rootURL: URL,
        qualityLookup: @escaping (String) -> FrameQualityMetrics?,
        dismiss: @escaping () -> Void
    ) {
        self.store = store
        self.rootURL = rootURL
        self.qualityLookup = qualityLookup
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        .task(id: store.currentFrame?.relativePath) { await loadCurrent() }
        .accessibilityIdentifier("v2.review.blink-sheet")
    }

    // MARK: - Header (filename, position, metric bar, verdict chip)

    private var header: some View {
        HStack(spacing: 16) {
            if let frame = store.currentFrame {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: frame.relativePath).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(store.positionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                let quality = qualityLookup(frame.relativePath)
                statTile("Score", Self.formatted(quality?.score, fractionDigits: 2))
                statTile("FWHM", Self.formatted(quality?.fwhm, fractionDigits: 2))
                statTile("Roundness", Self.formatted(quality?.roundness, fractionDigits: 2))
                statTile("Percentile", quality?.libraryPercentile.map { "\($0.percentile)" } ?? "—")

                if quality?.isOutlier == true {
                    Label("Outlier", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(AstroTokens.Color.attention)
                }

                verdictChip(frame.verdict)
            } else {
                Text("No frame to display").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .accessibilityIdentifier("v2.review.blink-header")
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.subheadline).monospacedDigit().bold()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func verdictChip(_ verdict: FrameVerdict) -> some View {
        switch verdict {
        case .accepted:
            Label("Accepted", systemImage: "checkmark.circle.fill").foregroundStyle(AstroTokens.Color.ok)
        case .rejected:
            Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(AstroTokens.Color.critical)
        case .undecided:
            Label("Undecided", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private static func formatted(_ value: Double?, fractionDigits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            // W5-3 (owner pixel review, 2026-08-18): this stage's backdrop
            // must read as a darkened mat behind the image in BOTH
            // appearances. The former fill, `AstroTokens.Color.edge.opacity
            // (0.08)`, inverted that in dark mode -- `edge` is deliberately
            // LIGHTER than `ground`/`surface` there (a hairline needs to
            // read against a near-black backdrop), so the same 8% wash that
            // dims the stage in light appearance BRIGHTENS it in dark,
            // exactly backwards from a photo mat. `AstroTokens.Color.recess`
            // is the token actually built to read darker in both
            // appearances, but it is gated to only ever be painted by
            // `astroRecessedSurface(_:)`
            // (`V2PolishSurfaceTests.surfaceTokensAreOnlyPaintedByTheSharedTreatment`),
            // and that modifier rounds its corners -- wrong for this
            // full-bleed stage, which spans edge-to-edge between two
            // `Divider`s (see `astroRecessedSurface`'s own "When NOT to use
            // it" note, which names this exact view). A bare `Color.black`
            // would need the same two-appearance honesty every other
            // structural token here carries and is banned in `Features/`
            // for exactly that reason (`noInlineColorsInFeatureViews`), so
            // this reaches for the same appearance-aware factory
            // (`AstroTokens.Color.dynamic`) every token in `AstroTokens.swift`
            // is itself built from, pinned to true black in both appearances
            // -- a fill that can only ever darken, never invert.
            Rectangle().fill(AstroTokens.Color.dynamic(dark: 0x000000, light: 0x000000).opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if isLoadingImage {
                ProgressView("Loading…")
            } else if store.currentFrame != nil {
                ContentUnavailableView(
                    "No preview available",
                    systemImage: "photo",
                    description: Text("The file is missing, or is an unsupported format.")
                )
            }
        }
        .frame(minHeight: 380, maxHeight: .infinity)
    }

    // MARK: - Footer (navigation, verdict actions, close)

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.goPrevious()
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!store.canGoPrevious)

            Button {
                store.goNext()
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!store.canGoNext)

            Divider().frame(height: 20)

            Button("Accept") { Task { await store.accept() } }
                .keyboardShortcut("a", modifiers: [])
                .disabled(store.currentFrame == nil)

            Button("Reject") { Task { await store.reject() } }
                .keyboardShortcut("x", modifiers: [])
                .disabled(store.currentFrame == nil)

            Button("Clear Decision") { Task { await store.clearVerdict() } }
                .keyboardShortcut("u", modifiers: [])
                .disabled(store.currentFrame == nil)

            if let errorMessage = store.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(AstroTokens.Color.critical)
            }

            Spacer()

            Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Preview loading (cached, with neighbor preload)

    @MainActor
    private func loadCurrent() async {
        guard let frame = store.currentFrame,
              let url = FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: frame.relativePath) else {
            image = nil
            isLoadingImage = false
            return
        }

        if let cached = previewCache[frame.relativePath] {
            image = cached
            isLoadingImage = false
        } else {
            image = nil
            isLoadingImage = true
            let loaded = await Self.renderPreview(url: url, maxDimension: Self.previewMaxDimension)
            if let loaded { remember(loaded, for: frame.relativePath) }
            guard !Task.isCancelled else { return }
            image = loaded
            isLoadingImage = false
        }

        preloadNeighbors()
    }

    @MainActor
    private func preloadNeighbors() {
        let neighborIndices = [store.index - 1, store.index + 1]
        for neighbor in neighborIndices where store.decisions.indices.contains(neighbor) {
            let relativePath = store.decisions[neighbor].relativePath
            guard previewCache[relativePath] == nil,
                  let url = FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: relativePath) else { continue }
            Task {
                let loaded = await Self.renderPreview(url: url, maxDimension: Self.previewMaxDimension)
                if let loaded { remember(loaded, for: relativePath) }
            }
        }
    }

    @MainActor
    private func remember(_ image: NSImage, for relativePath: String) {
        guard previewCache[relativePath] == nil else { return }
        previewCache[relativePath] = image
        cacheOrder.append(relativePath)
        if cacheOrder.count > cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            previewCache.removeValue(forKey: evicted)
        }
    }

    /// Loads one frame's large preview without moving a non-Sendable AppKit
    /// object across the detached-task boundary -- mirrors V1
    /// `FrameReviewSheet.renderPreview`: FITS/FIT/.fz workers return a
    /// `CGImage` from `FITSImageRenderer`; every other extension (a
    /// DSS-exported `.tif`/`.jpg`/`.png` stack, a Canon `.cr3`) returns its
    /// `Data`. `NSImage` creation stays on the main actor. `nil` on any
    /// failure (missing file, corrupt/unsupported FITS layout).
    private static func renderPreview(url: URL, maxDimension: Int) async -> NSImage? {
        if astroUIFITSFallbackExtensions.contains(url.pathExtension.lowercased()) {
            let cgImage = await Task.detached(priority: .userInitiated) {
                try? FITSImageRenderer.render(url: url, maxDimension: maxDimension)
            }.value
            guard let cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data else { return nil }
        return NSImage(data: data)
    }
}
