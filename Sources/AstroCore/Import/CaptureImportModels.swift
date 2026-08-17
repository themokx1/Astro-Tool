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

    public init(
        sourceURL: URL,
        relativeSourcePath: String,
        fileName: String,
        ext: String,
        kind: String,
        sizeBytes: Int64,
        proposedRole: FrameRole?,
        captureDate: String?,
        captureDateSource: CaptureDateSource?
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
    }
}
