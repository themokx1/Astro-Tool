import AppKit
import AstroCore
import QuickLookThumbnailing
import SwiftUI

/// Quick Look invokes its completion handler on an implementation-owned
/// response queue. Keeping that callback inline in `FrameThumbnailCell`
/// makes Swift 6 inherit the SwiftUI view's main-actor isolation for the
/// closure, then trap at runtime when Quick Look calls it off the main
/// queue -- mirrors V1's own `QuickLookThumbnailBridge`
/// (`Sources/AstroToolApp/Views/ThumbnailCell.swift`). This bridge is
/// deliberately outside the view and explicitly nonisolated: it transports
/// only an immutable `CGImage`, never AppKit/SwiftUI state.
enum FrameThumbnailBridge {
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

/// A small async thumbnail for one library frame, via `QLThumbnailGenerator`
/// with a `FITSImageRenderer` fallback for FITS/FIT files (which stock
/// macOS has no QuickLook plugin for) -- a native V2 port of V1's
/// `ThumbnailCell`. Read-only: resolves `relativePath` against `rootURL`
/// with the same containment check `ResultsView.resultURL` already applies,
/// and refuses to generate anything for a path that escapes the library
/// root or doesn't exist on disk.
public struct FrameThumbnailCell: View {
    let rootURL: URL
    let relativePath: String
    var size: CGFloat = 28

    @State private var image: NSImage?
    @State private var attempted = false

    public init(rootURL: URL, relativePath: String, size: CGFloat = 28) {
        self.rootURL = rootURL
        self.relativePath = relativePath
        self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if attempted {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .opacity(0.35)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(rootURL.path)|\(relativePath)") { await load() }
        .accessibilityIdentifier("v2.frame.thumbnail")
    }

    @MainActor
    private func load() async {
        image = nil
        attempted = false

        guard let url = Self.resolvedURL(rootURL: rootURL, relativePath: relativePath) else {
            attempted = true
            return
        }

        let cacheKey = Self.cacheKey(for: url)
        if let cached = FrameThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            attempted = true
            return
        }

        if let qlImage = await Self.generateQuickLookThumbnail(url: url, size: size) {
            attempted = true
            FrameThumbnailCache.shared.set(qlImage, for: cacheKey)
            image = qlImage
            return
        }

        if astroUIFITSFallbackExtensions.contains(url.pathExtension.lowercased()) {
            let pixelDimension = Int((size * 2).rounded())
            if let fitsImage = await Self.renderFITSThumbnail(url: url, maxDimension: pixelDimension) {
                attempted = true
                FrameThumbnailCache.shared.set(fitsImage, for: cacheKey)
                image = fitsImage
                return
            }
        }

        attempted = true
    }

    /// Resolves `relativePath` against `rootURL`, refusing anything that
    /// escapes the library root or doesn't exist on disk -- the same
    /// containment rule `ResultsView.resultURL` already applies to result
    /// files. Shared with `FrameBlinkReview`'s own large-preview loader and
    /// the QuickLook spacebar action, so every caller resolves a frame path
    /// the exact same way.
    static func resolvedURL(rootURL: URL, relativePath: String) -> URL? {
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func generateQuickLookThumbnail(url: URL, size: CGFloat) async -> NSImage? {
        let cgImage = await FrameThumbnailBridge.cgImage(url: url, size: size)
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Renders a FITS/FIT/.fz frame's primary HDU into a small `NSImage` via
    /// `FITSImageRenderer`. The detached worker returns only the immutable,
    /// Sendable `CGImage`; AppKit object creation stays on the main actor.
    /// `nil` for anything it declines to render (`.fz`, unsupported
    /// `BITPIX`/`NAXIS`) or a genuinely corrupt file.
    private static func renderFITSThumbnail(url: URL, maxDimension: Int) async -> NSImage? {
        let cgImage = await Task.detached(priority: .utility) {
            try? FITSImageRenderer.render(url: url, maxDimension: maxDimension)
        }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// `"<path>|<mtime>"` -- a file that's been overwritten (e.g. a re-run
    /// stack export) gets a fresh thumbnail rather than showing a stale
    /// cached one indefinitely. Falls back to the bare path when the
    /// modification date can't be read.
    private static func cacheKey(for url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        guard let mtime else { return url.path }
        return "\(url.path)|\(mtime)"
    }
}

/// Process-lifetime in-memory thumbnail cache, keyed by `FrameThumbnailCell`'s
/// own `"path|mtime"` string -- an `NSCache` with no disk persistence or
/// custom eviction beyond `NSCache`'s own memory-pressure behavior, mirroring
/// V1's `ThumbnailCache`. Memory-capped implicitly: `NSCache` evicts under
/// system memory pressure, so a long session never grows this unbounded.
@MainActor
final class FrameThumbnailCache {
    static let shared = FrameThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func set(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}
