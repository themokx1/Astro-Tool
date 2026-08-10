import AppKit
import AstroCore
import QuickLookThumbnailing
import SwiftUI

/// The file extensions QuickLook has no stock macOS plugin for, and which
/// `FITSImageRenderer` knows how to turn into a preview instead -- shared by
/// `ThumbnailCell`'s thumbnail fallback (R10-B1) and `FrameReviewSheet`'s
/// large-preview loader, so the two decide "is this a FITS frame" the exact
/// same way. `.fz` (Rice-compressed) is included here even though the
/// renderer itself always returns `nil` for it -- that's a deliberate "we
/// tried, this layout isn't supported" `nil`, not a reason to skip the
/// attempt, and it still needs to fall through to the ordinary placeholder
/// afterward exactly like every other unsupported case.
let fitsFallbackExtensions: Set<String> = ["fits", "fit", "fz"]

/// Quick Look invokes its completion handler on an implementation-owned
/// response queue. Keeping that callback inside `ThumbnailCell` made Swift
/// 6 inherit the SwiftUI view's main-actor isolation for the closure, then
/// trap at runtime when Quick Look called it off the main queue. This bridge
/// is deliberately outside the view and explicitly nonisolated: it transports
/// only immutable `CGImage`, never AppKit/SwiftUI state.
enum QuickLookThumbnailBridge {
    nonisolated static func cgImage(url: URL, size: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.cgImage)
            }
        }
    }
}

/// R9-T6/B7: a small thumbnail view for one file on disk, via
/// `QLThumbnailGenerator` (64×64 generation size, downscaled to fit a
/// 28pt-tall table row). Cached in-memory keyed by `path + mtime` (an
/// `NSCache`, process-lifetime, no disk persistence) so re-scrolling a
/// table never re-generates the same thumbnail twice in one session.
///
/// R10-B1: stock macOS has no FITS QuickLook plugin, so QuickLook alone
/// used to fail for the vast majority of frames this app manages -- that
/// case now falls back to `FITSImageRenderer` (debayer + MTF autostretch)
/// run off the main thread, so a light/dark/flat/bias frame gets a REAL
/// preview instead of a generic icon. `.fz` (Rice-compressed) and any other
/// layout the renderer doesn't support still come back `nil` from it, same
/// as a genuinely corrupt file -- both fall through to the plain
/// placeholder rather than showing an error. A DSS-exported
/// `.tif`/`.jpg`/`.png` stack, or a Canon `.cr3`, never reaches the FITS
/// fallback at all -- QuickLook already thumbnails those on its own, same
/// as before this change.
struct ThumbnailCell: View {
    let url: URL
    var size: CGFloat = 28

    @State private var image: NSImage?
    @State private var attempted = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if attempted {
                // D26: generation finished and came up empty (e.g. a FITS
                // file with no QuickLook plugin installed) -- the generic
                // placeholder icon, distinct from still-loading below.
                Image(systemName: "photo")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .opacity(0.35)
            } else {
                // D26: `attempted` used to be set but never read -- a
                // loading row looked identical to a row that will never
                // have a thumbnail. `ProgressView` here, the icon above,
                // once `load()`'s callback actually reports back.
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        image = nil
        attempted = false
        let cacheKey = Self.cacheKey(for: url)
        if let cached = ThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            attempted = true
            return
        }

        if let qlImage = await Self.generateQuickLookThumbnail(url: url, size: size) {
            attempted = true
            ThumbnailCache.shared.set(qlImage, for: cacheKey)
            image = qlImage
            return
        }

        // R10-B1: QuickLook came up empty -- for a FITS/FIT/.fz file (never
        // any other extension), try `FITSImageRenderer` before giving up.
        // `size` is the cell's POINT size; the retina request above already
        // asked QuickLook for `size * scale(2)` pixels, so the renderer is
        // asked for the same pixel budget for a visually consistent result.
        if fitsFallbackExtensions.contains(url.pathExtension.lowercased()) {
            let pixelDimension = Int((size * 2).rounded())
            if let fitsImage = await Self.renderFITSThumbnail(url: url, maxDimension: pixelDimension) {
                attempted = true
                ThumbnailCache.shared.set(fitsImage, for: cacheKey)
                image = fitsImage
                return
            }
        }

        // D26: generation finished and came up empty either way (no
        // QuickLook plugin AND either not a FITS file or the renderer
        // itself declined this layout/.fz) -- `attempted` alone drives the
        // generic placeholder icon below, same as before this fallback
        // existed.
        attempted = true
    }

    /// Runs one `QLThumbnailGenerator` request, returning `nil` on any
    /// failure/no-representation outcome (never throws) -- the sole
    /// QuickLook call site, unchanged in BEHAVIOR from before R10-B1's FITS
    /// fallback was added, just extracted so `load()` can fall through to
    /// the FITS path in between the two of its steps.
    private static func generateQuickLookThumbnail(url: URL, size: CGFloat) async -> NSImage? {
        let cgImage = await QuickLookThumbnailBridge.cgImage(url: url, size: size)
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Renders a FITS/FIT/.fz frame's primary HDU into a small `NSImage` via
    /// `FITSImageRenderer`. The detached worker returns only the immutable,
    /// Sendable `CGImage`; AppKit object creation stays on the main actor.
    /// `nil` for anything it
    /// declines to render (`.fz`, unsupported `BITPIX`/`NAXIS`) or a
    /// genuinely corrupt file (`try?` swallows `FITSImageRenderer`'s thrown
    /// `AstroError.corruptFITS` the same "never surface an error, just show
    /// the placeholder" way a QuickLook failure already didn't either).
    private static func renderFITSThumbnail(url: URL, maxDimension: Int) async -> NSImage? {
        let cgImage = await Task.detached(priority: .utility) {
            try? FITSImageRenderer.render(url: url, maxDimension: maxDimension)
        }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// `"<path>|<mtime>"` -- the mtime component means a file that's been
    /// overwritten (e.g. a re-run stack export) gets a fresh thumbnail
    /// rather than showing a stale cached one indefinitely. Falls back to
    /// the bare path when the file's modification date can't be read (e.g.
    /// it's momentarily missing) -- a slightly weaker cache key, not a
    /// crash.
    private static func cacheKey(for url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        guard let mtime else { return url.path }
        return "\(url.path)|\(mtime)"
    }
}

/// Process-lifetime in-memory thumbnail cache, keyed by `ThumbnailCell`'s
/// own `"path|mtime"` string -- deliberately no disk persistence or custom
/// eviction beyond `NSCache`'s own memory-pressure behavior, since even a
/// large stacks table's worth of small bitmaps for one session is cheap to
/// hold in memory.
@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}
