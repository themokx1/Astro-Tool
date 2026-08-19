import AppKit
import Foundation

/// The session card's own PNG write path -- split from `NightWorkspaceView`'s
/// `NSSavePanel` call the exact same way `ExportFileWriter`
/// (`Features/Exports/ExportMenu.swift`) splits its own write from the
/// panel: `NSSavePanel.runModal()` cannot run headlessly in a test target,
/// but everything downstream of "the user already chose a URL" can, and
/// should, be tested directly rather than only pinned by a source-text scan.
///
/// A second, binary-`Data` writer rather than a new case on the shared
/// `ExportMenuItem`/`ExportFileWriter` (`Features/Exports/ExportMenu.swift`):
/// that type's `.file` case renders `content: String` for a text export
/// (HTML/CSV/JSON) and interpolates it straight into a toast/alert message
/// on failure -- a PNG's raw bytes have no such string form, so widening a
/// shared, app-wide type's contract to accommodate one binary export would
/// cost every existing caller a now-optional code path for no benefit. This
/// stays a small, feature-local sibling instead.
public enum SessionCardFileWriter {
    public static func write(pngData: Data, to url: URL) throws {
        try pngData.write(to: url, options: .atomic)
    }
}

/// Converts a rendered `NSImage` (from `ImageRenderer(content:).nsImage`) to
/// PNG bytes. Pure aside from the `NSBitmapImageRep` round-trip AppKit
/// requires -- no file I/O, so it is unit-testable without a save panel or a
/// disk write, unlike `SessionCardFileWriter.write` above.
public enum SessionCardImageEncoder {
    /// `nil` only if `image` carries no bitmap-representable raster data at
    /// all (never expected for an `ImageRenderer` snapshot of a fixed-size
    /// SwiftUI view, but honestly propagated rather than force-unwrapped).
    public static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Resolves a session card's representative-frame thumbnail OUTSIDE
/// `SessionCardView`/`FrameThumbnailCell`'s own `.task`-driven async view
/// lifecycle, and never lets that resolution hang the export -- see
/// `SessionCardView.preloadedThumbnail`'s own doc comment for why an
/// in-view async load is the wrong shape for an `ImageRenderer` snapshot at
/// all (the snapshot is synchronous; a still-loading `FrameThumbnailCell`
/// would either lose the race and bake its placeholder `ProgressView` into
/// the PNG, or -- worse -- never resolve before `ImageRenderer` reads its
/// state, producing a blank thumbnail slot indistinguishable from "no path"
/// even when a real image exists).
public enum SessionCardThumbnailLoader {
    /// How long the export flow waits for a thumbnail before giving up and
    /// rendering the card without one -- generous enough for a warm
    /// QuickLook cache hit or a small FITS render, short enough that a
    /// slow/stuck generator (a huge FITS file, a wedged QuickLook daemon)
    /// never makes "Export Session Card…" feel hung.
    public static let defaultTimeout: Duration = .seconds(2)

    /// Races `loader()` against `timeout` and returns whichever finishes
    /// first -- `nil` on timeout, exactly as if `loader()` itself had
    /// returned `nil` (a failed load and a slow load are indistinguishable
    /// to the exported card, which is the point: neither should ever hang
    /// the export or show a placeholder). If `loader()` is the loser and
    /// doesn't itself observe cancellation (this module's own QuickLook/FITS
    /// pipeline doesn't), it keeps running harmlessly in the background and
    /// its result is simply discarded by `SessionCardThumbnailLoadGate`.
    ///
    /// Deliberately NOT `withTaskGroup(of: NSImage?.self)`: `TaskGroup`
    /// requires its `ChildTaskResult` to be `Sendable`, and `NSImage` isn't
    /// (same reason `FrameThumbnailCell.renderFITSThumbnail` only ever
    /// carries a `CGImage`, not an `NSImage`, across its own `Task.detached`
    /// boundary). A manual `CheckedContinuation` race sidesteps that --
    /// `CheckedContinuation` is unconditionally `Sendable` regardless of its
    /// payload type, which is exactly the escape hatch this bridges through.
    public static func load(
        timeout: Duration = defaultTimeout,
        _ loader: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let gate = SessionCardThumbnailLoadGate()
            Task {
                let image = await loader()
                if await gate.claim() {
                    continuation.resume(returning: image)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Resolves one library frame's thumbnail via `FrameThumbnailCell`'s own
    /// cache + QuickLook/FITS-fallback pipeline (`cacheKey`/
    /// `generateQuickLookThumbnail`/`renderFITSThumbnail`) -- reused rather
    /// than reimplemented so a frame thumbnailed once (in the Review
    /// workspace, say) hits the SAME in-memory cache here, and a frame
    /// thumbnailed here is cached for any `FrameThumbnailCell` shown later.
    /// Callers pass this to `load(timeout:_:)` rather than awaiting it
    /// directly, so a slow/stuck generator can't hang the export.
    public static func loadFrameImage(url: URL, size: CGFloat = 220) async -> NSImage? {
        let cacheKey = await FrameThumbnailCell.cacheKey(for: url)
        if let cached = await FrameThumbnailCache.shared.image(for: cacheKey) { return cached }

        if let qlImage = await FrameThumbnailCell.generateQuickLookThumbnail(url: url, size: size) {
            await FrameThumbnailCache.shared.set(qlImage, for: cacheKey)
            return qlImage
        }

        if astroUIFITSFallbackExtensions.contains(url.pathExtension.lowercased()) {
            let pixelDimension = Int((size * 2).rounded())
            if let fitsImage = await FrameThumbnailCell.renderFITSThumbnail(url: url, maxDimension: pixelDimension) {
                await FrameThumbnailCache.shared.set(fitsImage, for: cacheKey)
                return fitsImage
            }
        }

        return nil
    }
}

/// Ensures exactly one of `SessionCardThumbnailLoader.load(timeout:_:)`'s
/// two racing `Task`s ever resumes its `CheckedContinuation` -- resuming a
/// checked continuation twice is a runtime trap, so whichever `Task`
/// finishes second must be a silent no-op rather than a second `resume`
/// call. An `actor` (not a lock) because both racing `Task`s call `claim()`
/// from arbitrary executors; the actor serializes them without any manual
/// synchronization.
private actor SessionCardThumbnailLoadGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
