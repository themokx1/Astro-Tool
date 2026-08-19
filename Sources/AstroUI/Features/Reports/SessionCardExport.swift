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
