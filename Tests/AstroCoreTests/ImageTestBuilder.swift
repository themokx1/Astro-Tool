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
    dateTimeOriginal: String? = "2026:01:15 20:30:00",
    tiffDateTime: String? = nil,
    offsetTimeOriginal: String? = nil,
    exposureSeconds: Double? = nil,
    iso: Int? = nil,
    apertureFNumber: Double? = nil
) throws {
    try writeTestImage(
        to: url,
        utType: UTType.tiff,
        focalLengthMM: focalLengthMM,
        cameraModel: cameraModel,
        dateTimeOriginal: dateTimeOriginal,
        tiffDateTime: tiffDateTime,
        offsetTimeOriginal: offsetTimeOriginal,
        exposureSeconds: exposureSeconds,
        iso: iso,
        apertureFNumber: apertureFNumber
    )
}

/// Same round-trip as `writeTestTIFF`, through the JPEG codec instead --
/// used by `ScannerTests` to confirm `LibraryScanner.captureMeta` now
/// introspects `.jpg`/`.jpeg` the same way it already did `.tif`.
func writeTestJPEG(
    to url: URL,
    focalLengthMM: Double = 50.0,
    cameraModel: String = "Canon EOS R6",
    dateTimeOriginal: String? = "2026:01:15 20:30:00",
    tiffDateTime: String? = nil,
    offsetTimeOriginal: String? = nil,
    exposureSeconds: Double? = nil,
    iso: Int? = nil,
    apertureFNumber: Double? = nil
) throws {
    try writeTestImage(
        to: url,
        utType: UTType.jpeg,
        focalLengthMM: focalLengthMM,
        cameraModel: cameraModel,
        dateTimeOriginal: dateTimeOriginal,
        tiffDateTime: tiffDateTime,
        offsetTimeOriginal: offsetTimeOriginal,
        exposureSeconds: exposureSeconds,
        iso: iso,
        apertureFNumber: apertureFNumber
    )
}

private func writeTestImage(
    to url: URL,
    utType: UTType,
    focalLengthMM: Double,
    cameraModel: String,
    dateTimeOriginal: String?,
    tiffDateTime: String?,
    offsetTimeOriginal: String?,
    exposureSeconds: Double?,
    iso: Int?,
    apertureFNumber: Double?
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
        Issue.record("failed to create CGContext for test image")
        return
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        Issue.record("failed to create CGImage for test image")
        return
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
        Issue.record("failed to create CGImageDestination")
        return
    }

    var exifDict: [CFString: Any] = [
        kCGImagePropertyExifFocalLength: focalLengthMM,
    ]
    if let dateTimeOriginal {
        exifDict[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal
    }
    if let offsetTimeOriginal {
        exifDict[kCGImagePropertyExifOffsetTimeOriginal] = offsetTimeOriginal
    }
    if let exposureSeconds {
        exifDict[kCGImagePropertyExifExposureTime] = exposureSeconds
    }
    if let iso {
        exifDict[kCGImagePropertyExifISOSpeedRatings] = [iso]
    }
    if let apertureFNumber {
        exifDict[kCGImagePropertyExifFNumber] = apertureFNumber
    }
    var tiffDict: [CFString: Any] = [
        kCGImagePropertyTIFFModel: cameraModel,
    ]
    if let tiffDateTime {
        tiffDict[kCGImagePropertyTIFFDateTime] = tiffDateTime
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exifDict,
        kCGImagePropertyTIFFDictionary: tiffDict,
    ]

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination), "CGImageDestinationFinalize should succeed")
}
