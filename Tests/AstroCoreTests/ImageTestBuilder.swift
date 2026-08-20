import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing

/// Shared TIFF-with-metadata builder used by `ImageMetaReaderTests` and
/// `ScannerTests`: writes a tiny 2x2 TIFF at `url` with the given Exif focal
/// length, TIFF camera model, and Exif `DateTimeOriginal`, via
/// `CGImageDestination` — the same ImageIO stack `ImageMetaReader` reads
/// with, so this is a genuine round-trip rather than a hand-rolled byte
/// fixture.
func writeTestTIFF(
    to url: URL,
    focalLengthMM: Double = 50.0,
    cameraModel: String = "Canon EOS R6",
    dateTimeOriginal: String = "2026:01:15 20:30:00",
    exposureSeconds: Double? = nil,
    iso: Int? = nil,
    apertureFNumber: Double? = nil
) throws {
    let width = 2
    let height = 2
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        Issue.record("failed to create CGContext for test TIFF")
        return
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        Issue.record("failed to create CGImage for test TIFF")
        return
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
        Issue.record("failed to create CGImageDestination")
        return
    }

    var exifDict: [CFString: Any] = [
        kCGImagePropertyExifFocalLength: focalLengthMM,
        kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
    ]
    if let exposureSeconds {
        exifDict[kCGImagePropertyExifExposureTime] = exposureSeconds
    }
    if let iso {
        exifDict[kCGImagePropertyExifISOSpeedRatings] = [iso]
    }
    if let apertureFNumber {
        exifDict[kCGImagePropertyExifFNumber] = apertureFNumber
    }
    let tiffDict: [CFString: Any] = [
        kCGImagePropertyTIFFModel: cameraModel,
    ]
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exifDict,
        kCGImagePropertyTIFFDictionary: tiffDict,
    ]

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination), "CGImageDestinationFinalize should succeed")
}
