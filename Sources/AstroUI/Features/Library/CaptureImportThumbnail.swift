import AppKit
import AstroCore
import SwiftUI

/// One capture-file group's representative thumbnail, for the card-import
/// wizard's Classify step (W4-1b owner feedback: "ebből az ablakból, honnan
/// kéne nekem tudni, hogy valami light vagy dark vagy flat?" -- from this
/// window, how am I supposed to know whether something is a light, dark, or
/// flat? -- a dark/bias thumbnail is visibly black, a flat is uniform
/// gray/white, a light shows stars).
///
/// Reuses `FrameThumbnailCell`'s own QuickLook-generator/cache/FITS-fallback
/// pipeline (`FrameThumbnailCell.generateQuickLookThumbnail`/
/// `.renderFITSThumbnail`/`.cacheKey`, and the shared `FrameThumbnailCache`)
/// rather than standing up a second one -- ONLY the URL resolution differs:
/// `FrameThumbnailCell` resolves a `rootURL`+`relativePath` pair against the
/// library with a containment check (the file lives inside a tracked
/// library tree); this thumbnails an absolute source-card URL the scanner
/// already read directly (the file lives on a card that isn't part of the
/// library at all yet, so there is no root to contain it against -- the
/// path came from `CaptureImportScanner.scan`, not from user-typed text).
struct CaptureImportGroupThumbnail: View {
    let sourceURL: URL
    var size: CGFloat = 40

    @State private var image: NSImage?
    @State private var attempted = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if attempted {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .opacity(0.35)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        // `.task(id:)` is its own generation guard, same as
        // `FrameThumbnailCell`'s own body: SwiftUI cancels the in-flight
        // `load()` whenever `sourceURL` changes (a group row scrolled out
        // and a different one recycled the same view identity) before
        // starting a new one, so a slow QuickLook/FITS render for a
        // previous group can never land on the wrong row.
        .task(id: sourceURL) { await load() }
        .accessibilityIdentifier("v2.capture-import.group-thumbnail.\(sourceURL.lastPathComponent)")
    }

    @MainActor
    private func load() async {
        image = nil
        attempted = false

        let cacheKey = FrameThumbnailCell.cacheKey(for: sourceURL)
        if let cached = FrameThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            attempted = true
            return
        }

        if let qlImage = await FrameThumbnailCell.generateQuickLookThumbnail(url: sourceURL, size: size) {
            attempted = true
            FrameThumbnailCache.shared.set(qlImage, for: cacheKey)
            image = qlImage
            return
        }

        if astroUIFITSFallbackExtensions.contains(sourceURL.pathExtension.lowercased()) {
            let pixelDimension = Int((size * 2).rounded())
            if let fitsImage = await FrameThumbnailCell.renderFITSThumbnail(url: sourceURL, maxDimension: pixelDimension) {
                attempted = true
                FrameThumbnailCache.shared.set(fitsImage, for: cacheKey)
                image = fitsImage
                return
            }
        }

        attempted = true
    }
}
