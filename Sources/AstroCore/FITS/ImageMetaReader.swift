import Foundation
import ImageIO
import CoreGraphics

/// Best-effort image metadata pulled from a CR3/TIFF/JPEG via ImageIO. All
/// fields are optional since not every camera/tool writes every tag, and
/// `ImageMetaReader.read` itself returns `nil` rather than a mostly-empty
/// value when the file can't be opened as an image at all.
public struct ImageMeta: Equatable, Sendable {
    public var focalLengthMM: Double?
    public var cameraModel: String?
    /// Exif `DateTimeOriginal` (or TIFF `DateTime` as a fallback), verbatim
    /// as ImageIO reports it (Exif's `"yyyy:MM:dd HH:mm:ss"` form) — no
    /// timezone handling or reformatting.
    public var dateTaken: String?
    /// Exif `ExposureTime`, in seconds. DSLR (e.g. Canon CR3) lights have no
    /// FITS `EXPTIME` -- this is where their exposure length actually lives,
    /// and it's what lets them contribute to integration-time stats instead
    /// of landing in the `"unknown"` exposure bucket.
    public var exposureSeconds: Double?
    /// Exif `ISOSpeedRatings`, first value when the tag holds more than one.
    public var iso: Int?

    public init(
        focalLengthMM: Double? = nil,
        cameraModel: String? = nil,
        dateTaken: String? = nil,
        exposureSeconds: Double? = nil,
        iso: Int? = nil
    ) {
        self.focalLengthMM = focalLengthMM
        self.cameraModel = cameraModel
        self.dateTaken = dateTaken
        self.exposureSeconds = exposureSeconds
        self.iso = iso
    }
}

/// Reads camera/lens metadata from image files ImageIO understands: TIFF and
/// JPEG directly, and CR3 (Canon's ISO-BMFF-based raw format) via ImageIO's
/// built-in RAW codec on macOS. There's no CR3 test fixture here — ImageIO
/// doesn't expose a CR3 encoder to generate one — so CR3 support is
/// best-effort, verified only by the TIFF path exercising the same
/// Exif/TIFF dictionary lookups CR3 files populate.
public enum ImageMetaReader {
    /// Reads `url` via ImageIO. Returns `nil` when the file doesn't exist or
    /// ImageIO can't parse it as an image (never throws); returns an
    /// `ImageMeta` with whichever fields were present otherwise — a
    /// successfully-opened image with no matching Exif/TIFF tags still
    /// yields a (mostly-nil) `ImageMeta`, not `nil`.
    public static func read(url: URL) -> ImageMeta? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        let cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        let dateTaken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let exposureSeconds = exif?[kCGImagePropertyExifExposureTime] as? Double
        // ISOSpeedRatings is Exif's array-valued tag (some cameras record
        // more than one rating) -- ImageIO surfaces it as an NSNumber array;
        // only the first value is meaningful for our purposes.
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue

        return ImageMeta(
            focalLengthMM: focalLength,
            cameraModel: cameraModel,
            dateTaken: dateTaken,
            exposureSeconds: exposureSeconds,
            iso: iso
        )
    }
}
