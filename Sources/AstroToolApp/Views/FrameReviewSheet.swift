import AppKit
import AstroCore
import SwiftUI

/// The "Átnézés" (frame-review / "blink") sheet -- R10-B1. Machine z-scores
/// (`Rater.rate`'s `isOutlier`) can't see a satellite trail, a plane, thin
/// cloud, or a tracking blip; this is the human-eyeball backstop. Lets the
/// user step through a target's frames -- in EXACTLY the order/filter the
/// Quality table is currently showing, since the caller hands in
/// `filteredFrameScores` already sorted -- and record a manual accept/
/// reject verdict per frame (`A`/`X`), or clear one (`U`), with instant
/// keyboard-driven navigation (`←`/`→`). Every verdict recorded here writes
/// straight to `user_verdicts` (source `"app"`, via
/// `AppState.setFrameVerdict`) -- the same table `StackList.select` already
/// hard-drops `accepted == false` frames from regardless of score, so a
/// rejection made here takes effect the next time this target is stacked,
/// with no extra step.
struct FrameReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// The exact order to blink through -- the Quality table's current
    /// sort column + date filter, already applied by the caller
    /// (`QualitySegment` passes `rows.map(\.frameScore)`). This sheet never
    /// re-sorts or re-filters it.
    let frames: [FrameScore]

    @State private var index = 0
    @State private var image: NSImage?
    @State private var isLoadingImage = false

    /// Small cache of already-rendered previews, keyed by path -- large
    /// enough to hold the current frame plus a few frames of back-and-forth
    /// browsing without re-decoding, but capped (`cacheCapacity`) so a long
    /// blink session can't grow this to hold a whole night's worth of
    /// 1600px bitmaps. `cacheOrder` tracks insertion order for the eviction
    /// below -- oldest-inserted goes first, a plain FIFO rather than a true
    /// LRU (true LRU would need to bump an entry's position on every HIT,
    /// not just insertion; not worth the bookkeeping at this size).
    @State private var previewCache: [String: NSImage] = [:]
    @State private var cacheOrder: [String] = []
    private let cacheCapacity = 12

    /// Review previews render considerably larger than the table's own
    /// 22pt thumbnails -- big enough to actually judge a trail/cloud/focus
    /// issue by eye.
    private static let previewMaxDimension = 1600

    private var currentFrame: FrameScore? {
        frames.indices.contains(index) ? frames[index] : nil
    }

    private var tally: (accepted: Int, rejected: Int, none: Int) {
        var accepted = 0, rejected = 0, none = 0
        for frame in frames {
            switch appState.frameVerdicts[frame.path] {
            case .some(true): accepted += 1
            case .some(false): rejected += 1
            case .none: none += 1
            }
        }
        return (accepted, rejected, none)
    }

    private var tallyText: String {
        let t = tally
        return "Elfogadva: \(t.accepted) · Elvetve: \(t.rejected) · Döntés nélkül: \(t.none)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        // Mirrors `ThumbnailCell`'s own `.task(id: url)` convention: SwiftUI
        // cancels the in-flight task for the OLD index and starts a fresh
        // one whenever `index` changes, which `loadCurrent()`'s own
        // `Task.isCancelled` check (after its one `await`) relies on to
        // never apply a now-stale render to `image`.
        .task(id: index) { await loadCurrent() }
        // Esc closes: standard `.sheet` behavior on macOS, nothing to wire.
    }

    // MARK: - Header (filename, index, score/FWHM/stars, outlier, verdict)

    private var header: some View {
        HStack(spacing: 16) {
            if let frame = currentFrame {
                VStack(alignment: .leading, spacing: 2) {
                    Text((frame.path as NSString).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(index + 1) / \(frames.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                statTile("Pontszám", String(format: "%.2f", frame.score))
                // Parenthesized: `fwhm`/`starCount` are non-Optional on
                // `StarMetrics` itself, so `metrics?.fwhm.map { … }` would
                // try to resolve `.map` against a plain `Double` mid-chain
                // (a compile error) -- the parens force the `metrics?.fwhm`
                // optional chain to resolve to a concrete `Double?` FIRST.
                statTile("FWHM", (frame.metrics?.fwhm).map { String(format: "%.2f", $0) } ?? "-")
                statTile("Csillagok", (frame.metrics?.starCount).map(String.init) ?? "-")

                if frame.isOutlier {
                    Text("⚠️ Kiugró").font(.callout).foregroundStyle(.red)
                }

                verdictChip(appState.frameVerdicts[frame.path])
            } else {
                Text("Nincs megjeleníthető keret").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.subheadline).monospacedDigit().bold()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func verdictChip(_ verdict: Bool?) -> some View {
        switch verdict {
        case .some(true):
            Label("Elfogadva", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(false):
            Label("Elvetve", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .none:
            Label("Döntés nélkül", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if isLoadingImage {
                ProgressView("Betöltés…")
            } else if currentFrame != nil {
                ContentUnavailableView(
                    "Nincs előnézet",
                    systemImage: "photo",
                    description: Text("A fájl hiányzik, vagy nem támogatott formátumú.")
                )
            }
        }
        .frame(minHeight: 380, maxHeight: .infinity)
    }

    // MARK: - Footer (navigation, verdict actions, tally, close)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    goPrevious()
                } label: {
                    Label("Előző", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)

                Button {
                    goNext()
                } label: {
                    Label("Következő", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!frames.indices.contains(index + 1))

                Divider().frame(height: 20)

                Button("Elfogadás") { recordVerdict(true) }
                    .keyboardShortcut("a", modifiers: [])
                    .disabled(currentFrame == nil)

                Button("Elvetés") { recordVerdict(false) }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(currentFrame == nil)

                Button("Döntés törlése") { recordVerdict(nil) }
                    .keyboardShortcut("u", modifiers: [])
                    .disabled(currentFrame == nil)

                Spacer()

                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(tallyText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Navigation + verdict actions

    private func goPrevious() {
        guard index > 0 else { return }
        index -= 1
    }

    private func goNext() {
        guard frames.indices.contains(index + 1) else { return }
        index += 1
    }

    /// Records `accepted` (or clears the verdict, when `nil`) for the
    /// CURRENT frame, then auto-advances -- but only after an actual
    /// accept/reject decision, never after a clear: clearing is a
    /// fix-a-mistake action ("undo"), not "I've judged this frame, move
    /// on", so it deliberately leaves the sheet right where it is.
    private func recordVerdict(_ accepted: Bool?) {
        guard let frame = currentFrame else { return }
        appState.setFrameVerdict(path: frame.path, accepted: accepted)
        if accepted != nil {
            goNext()
        }
    }

    // MARK: - Preview loading (cached, with neighbor preload)

    @MainActor
    private func loadCurrent() async {
        guard let frame = currentFrame else {
            image = nil
            isLoadingImage = false
            return
        }

        if let cached = previewCache[frame.path] {
            image = cached
            isLoadingImage = false
        } else {
            image = nil
            isLoadingImage = true
            let path = frame.path
            let rootPath = appState.config.rootPath
            let loaded = await Self.renderPreview(path: path, rootPath: rootPath, maxDimension: Self.previewMaxDimension)
            // Cache unconditionally (even if this exact task has since been
            // superseded by a newer index) -- still useful the next time
            // the user blinks back to this frame. Only the UI-facing
            // `image`/`isLoadingImage` below need the cancellation guard.
            if let loaded { remember(loaded, for: path) }
            guard !Task.isCancelled else { return }
            image = loaded
            isLoadingImage = false
        }

        // IMPORTANT UX (spec): the sheet must feel instant -- warm the
        // cache for both neighbors now, so the NEXT step (the overwhelmingly
        // likely next action) almost always hits the cache above instead of
        // waiting on a fresh render.
        preloadNeighbors()
    }

    @MainActor
    private func preloadNeighbors() {
        let rootPath = appState.config.rootPath
        for neighbor in [index - 1, index + 1] where frames.indices.contains(neighbor) {
            let path = frames[neighbor].path
            guard previewCache[path] == nil else { continue }
            Task {
                let loaded = await Self.renderPreview(path: path, rootPath: rootPath, maxDimension: Self.previewMaxDimension)
                if let loaded { remember(loaded, for: path) }
            }
        }
    }

    @MainActor
    private func remember(_ image: NSImage, for path: String) {
        guard previewCache[path] == nil else { return }
        previewCache[path] = image
        cacheOrder.append(path)
        if cacheOrder.count > cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            previewCache.removeValue(forKey: evicted)
        }
    }

    /// Renders one frame's large preview off the main thread. FITS/FIT/.fz
    /// go through `FITSImageRenderer` -- the same fallback `ThumbnailCell`
    /// uses for the table's own small thumbnails, just at review size
    /// rather than thumbnail size; every other extension (a DSS-exported
    /// `.tif`/`.jpg`/`.png` stack, a Canon `.cr3`) falls back to plain
    /// `NSImage(contentsOf:)`, which already decodes those natively without
    /// any FITS involvement. `nil` on any failure (missing file,
    /// corrupt/unsupported FITS layout) -- the caller shows an empty-state
    /// message rather than a raw error for one bad preview.
    private static func renderPreview(path: String, rootPath: String, maxDimension: Int) async -> NSImage? {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(path)
        if fitsFallbackExtensions.contains(url.pathExtension.lowercased()) {
            return await Task.detached(priority: .userInitiated) {
                guard let cgImage = try? FITSImageRenderer.render(url: url, maxDimension: maxDimension) else {
                    return nil
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
        }
        return await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }
}
