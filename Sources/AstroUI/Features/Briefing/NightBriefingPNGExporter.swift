import AppKit
import CoreGraphics
import Foundation
import PDFKit

public enum NightBriefingPNGExportError: Error, Equatable, Sendable {
    case invalidPDF
    case pageUnavailable(Int)
    case bitmapCreationFailed(Int)
    case encodingFailed(Int)
}

public struct NightBriefingPNGExporter: Sendable {
    public init() {}

    public func pages(from pdf: Data, dpi: CGFloat = 144) throws -> [Data] {
        guard let document = PDFDocument(data: pdf), document.pageCount > 0 else {
            throw NightBriefingPNGExportError.invalidPDF
        }
        let scale = dpi / 72
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw NightBriefingPNGExportError.pageUnavailable(index)
            }
            let bounds = page.bounds(for: .mediaBox)
            let width = Int((bounds.width * scale).rounded())
            let height = Int((bounds.height * scale).rounded())
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw NightBriefingPNGExportError.bitmapCreationFailed(index)
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            guard let image = context.makeImage() else {
                throw NightBriefingPNGExportError.bitmapCreationFailed(index)
            }
            let representation = NSBitmapImageRep(cgImage: image)
            representation.size = bounds.size
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw NightBriefingPNGExportError.encodingFailed(index)
            }
            return png
        }
    }
}
