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
    /// timezone handling or reformatting. This is CAMERA-LOCAL wall-clock
    /// time, not UTC -- see `dateTakenOffset` and `ExifDateConversion`.
    public var dateTaken: String?
    /// Exif `OffsetTimeOriginal` -- the UTC offset the camera was set to
    /// when `dateTaken` was recorded, e.g. `"+02:00"`. Only a handful of
    /// bodies write this tag at all (most DSLRs never did; some
    /// mirrorless/phone cameras do), so it's usually `nil` -- callers that
    /// need an absolute instant from `dateTaken` fall back to
    /// `TimeZone.current` when this is `nil` (see `ExifDateConversion`).
    public var dateTakenOffset: String?
    /// Exif `ExposureTime`, in seconds. DSLR (e.g. Canon CR3) lights have no
    /// FITS `EXPTIME` -- this is where their exposure length actually lives,
    /// and it's what lets them contribute to integration-time stats instead
    /// of landing in the `"unknown"` exposure bucket.
    public var exposureSeconds: Double?
    /// Exif `ISOSpeedRatings`, first value when the tag holds more than one.
    public var iso: Int?
    /// Exif `FNumber` -- the aperture, e.g. `2.8` for f/2.8. `nil` for a lens
    /// that doesn't report it (or a body with no lens metadata at all).
    /// Added for the card-import wizard's Classify step (W4-1b): alongside
    /// `exposureSeconds`/`iso` it's the third value a photographer actually
    /// reads off a group of CR3 files to decide what they are.
    public var apertureFNumber: Double?

    public init(
        focalLengthMM: Double? = nil,
        cameraModel: String? = nil,
        dateTaken: String? = nil,
        dateTakenOffset: String? = nil,
        exposureSeconds: Double? = nil,
        iso: Int? = nil,
        apertureFNumber: Double? = nil
    ) {
        self.focalLengthMM = focalLengthMM
        self.cameraModel = cameraModel
        self.dateTaken = dateTaken
        self.dateTakenOffset = dateTakenOffset
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.apertureFNumber = apertureFNumber
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
        // Only meaningful alongside `ExifDateTimeOriginal` -- there's no
        // equivalent offset tag for the TIFF `DateTime` fallback above, so
        // this stays nil whenever `dateTaken` itself came from TIFF instead
        // of Exif.
        let dateTakenOffset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let exposureSeconds = exif?[kCGImagePropertyExifExposureTime] as? Double
        // ISOSpeedRatings is Exif's array-valued tag (some cameras record
        // more than one rating) -- ImageIO surfaces it as an NSNumber array;
        // only the first value is meaningful for our purposes.
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let apertureFNumber = exif?[kCGImagePropertyExifFNumber] as? Double

        return ImageMeta(
            focalLengthMM: focalLength,
            cameraModel: cameraModel,
            dateTaken: dateTaken,
            dateTakenOffset: dateTakenOffset,
            exposureSeconds: exposureSeconds,
            iso: iso,
            apertureFNumber: apertureFNumber
        )
    }
}
