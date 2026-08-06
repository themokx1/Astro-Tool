import AppKit
import QuickLookThumbnailing
import SwiftUI

/// R9-T6/B7: a small thumbnail view for one file on disk, via
/// `QLThumbnailGenerator` (64×64 generation size, downscaled to fit a
/// 28pt-tall table row). Cached in-memory keyed by `path + mtime` (an
/// `NSCache`, process-lifetime, no disk persistence) so re-scrolling a
/// table never re-generates the same thumbnail twice in one session. A FITS
/// file usually fails to thumbnail -- stock macOS has no FITS QuickLook
/// plugin -- that's expected and falls back to a generic placeholder icon
/// rather than showing an error; a DSS-exported `.tif`/`.jpg`/`.png` stack
/// DOES thumbnail.
struct ThumbnailCell: View {
    let url: URL
    var size: CGFloat = 28

    @State private var image: NSImage?
    @State private var attempted = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .opacity(0.35)
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
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: 2,
            representationTypes: .thumbnail
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                // Extracted immediately, outside the actor-hop below: the
                // callback itself runs on an arbitrary queue, and
                // `QLThumbnailRepresentation` isn't `Sendable` -- only the
                // plain `NSImage` it hands out crosses into the `@MainActor`
                // closure.
                let nsImage = thumbnail?.nsImage
                Task { @MainActor in
                    self.attempted = true
                    if let nsImage {
                        ThumbnailCache.shared.set(nsImage, for: cacheKey)
                        self.image = nsImage
                    }
                    continuation.resume()
                }
            }
        }
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
