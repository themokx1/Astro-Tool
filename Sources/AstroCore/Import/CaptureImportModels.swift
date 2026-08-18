import Foundation

/// Where `DiscoveredCaptureFile.captureDate` came from -- the wizard's
/// destination step shows this next to the date it prefilled, per the
/// owner's brief ("date default from the files' own capture dates -- FITS
/// DATE-OBS or file dates, say which you used").
public enum CaptureDateSource: Equatable, Sendable {
    /// The FITS header's own `DATE-OBS` card.
    case fitsDateObs
    /// The CR3's Exif `DateTimeOriginal` (or TIFF `DateTime`).
    case exifDateTaken
    /// Neither header nor Exif had a usable date -- the file's own content
    /// modification date on the source volume.
    case fileModificationDate
}

/// One capture file found on the source volume/folder by
/// `CaptureImportScanner.scan`, before it has been placed anywhere in the
/// library. Never touches the library itself -- everything here describes
/// the file where it currently sits on the card.
public struct DiscoveredCaptureFile: Equatable, Sendable, Identifiable {
    /// The file's own absolute path doubles as a stable identity: two scans
    /// of the same source never produce two different files at the same
    /// path, and a path is what every UI selection/override keys off of.
    public var id: String { sourceURL.path }

    public let sourceURL: URL
    /// Path relative to the scanned source root, for display -- e.g.
    /// `DCIM/100EOS_R/IMG_0042.CR3` rather than the volume's full absolute
    /// path.
    public let relativeSourcePath: String
    public let fileName: String
    public let ext: String
    /// `"fits"` or `"raw"` -- `LibraryScanner.fitsExtensions`/
    /// `.rawExtensions`' own two kinds; nothing else is a capture file for
    /// this wizard's purposes.
    public let kind: String
    public let sizeBytes: Int64
    /// `nil` means "unclassified" -- the file's role could not be determined
    /// from its own content (no FITS `IMAGETYP`, or a `.cr3` with no
    /// equivalent header at all). Never a guess; the wizard's Classify step
    /// surfaces this explicitly for the user to resolve or exclude.
    public var proposedRole: FrameRole?
    public let captureDate: String?
    public let captureDateSource: CaptureDateSource?
    /// The SAME instant `captureDate` was truncated from (`DATE-OBS`/Exif
    /// `DateTimeOriginal`/file modification date, in that preference order --
    /// see `CaptureImportScanner.classify`), kept at full precision. Owner
    /// feedback W4-1b: "csoportosítani is kell ezeket a képeket, amik egymás
    /// utána készültek interval-ban" -- burst grouping
    /// (`CaptureBurstGrouper`) needs seconds, not just a day string, to tell
    /// "these were shot ninety seconds apart" from "these were shot ten
    /// hours apart on the same calendar day". Always present (the file
    /// modification date fallback never fails to produce SOME `Date`), so
    /// every discovered file has a place in the sort order grouping needs.
    public let captureInstant: Date
    /// Exif `ExposureTime` in seconds -- `nil` for FITS (which has its own
    /// `EXPTIME` header, read separately by whatever consumes the FITS
    /// header directly; this field exists for the wizard's Classify step,
    /// which needs it uniformly across CR3 groups). See `CaptureFileGroup`
    /// for how a group's files' values are summarized.
    public let exposureSeconds: Double?
    /// Exif `ISOSpeedRatings`, first value.
    public let iso: Int?
    /// Exif `FNumber` -- the aperture.
    public let apertureFNumber: Double?

    public init(
        sourceURL: URL,
        relativeSourcePath: String,
        fileName: String,
        ext: String,
        kind: String,
        sizeBytes: Int64,
        proposedRole: FrameRole?,
        captureDate: String?,
        captureDateSource: CaptureDateSource?,
        captureInstant: Date = Date(timeIntervalSince1970: 0),
        exposureSeconds: Double? = nil,
        iso: Int? = nil,
        apertureFNumber: Double? = nil
    ) {
        self.sourceURL = sourceURL
        self.relativeSourcePath = relativeSourcePath
        self.fileName = fileName
        self.ext = ext
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.proposedRole = proposedRole
        self.captureDate = captureDate
        self.captureDateSource = captureDateSource
        self.captureInstant = captureInstant
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.apertureFNumber = apertureFNumber
    }
}
