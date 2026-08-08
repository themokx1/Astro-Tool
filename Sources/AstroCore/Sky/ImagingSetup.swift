import Foundation

/// The broad camera category used to describe a saved imaging setup.
///
/// The category is intentionally descriptive in this release: field of view
/// depends on the physical sensor dimensions and focal length, not on whether
/// the camera is modified. Keeping the distinction in the profile makes the
/// setup unambiguous to the photographer and leaves a sound input for future
/// target/filter suitability advice.
public enum CameraKind: String, Codable, CaseIterable, Equatable, Sendable {
    case dedicatedAstro
    case unmodifiedColor
    case modifiedColor
    case monochrome
}

/// A concrete rectangular field of view in degrees.
public struct SetupFieldOfView: Equatable, Sendable {
    public var widthDeg: Double
    public var heightDeg: Double

    public init(widthDeg: Double, heightDeg: Double) {
        self.widthDeg = widthDeg
        self.heightDeg = heightDeg
    }
}

/// One user-defined camera + lens/telescope combination for planning.
///
/// Physical sensor dimensions are persisted instead of a crop factor: they
/// directly determine both axes of the field of view and work for arbitrary
/// dedicated astronomy sensors as well as DSLR/mirrorless formats. A fixed
/// optic stores the same minimum/maximum/default focal length; a zoom stores
/// its real range plus the preferred initial planning focal length.
public struct ImagingSetupProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var cameraName: String
    public var cameraKind: CameraKind
    public var sensorWidthMM: Double
    public var sensorHeightMM: Double
    public var focalLengthMinMM: Double
    public var focalLengthMaxMM: Double
    public var defaultFocalLengthMM: Double
    public var isDefault: Bool

    public init(
        id: String,
        name: String,
        cameraName: String,
        cameraKind: CameraKind,
        sensorWidthMM: Double,
        sensorHeightMM: Double,
        focalLengthMinMM: Double,
        focalLengthMaxMM: Double,
        defaultFocalLengthMM: Double,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.cameraName = cameraName
        self.cameraKind = cameraKind
        self.sensorWidthMM = sensorWidthMM
        self.sensorHeightMM = sensorHeightMM
        self.focalLengthMinMM = focalLengthMinMM
        self.focalLengthMaxMM = focalLengthMaxMM
        self.defaultFocalLengthMM = defaultFocalLengthMM
        self.isDefault = isDefault
    }

    public var isZoom: Bool {
        abs(focalLengthMaxMM - focalLengthMinMM) > 0.000_001
    }

    /// Returns a planning focal length constrained to this setup's usable
    /// range. A missing proposal means the profile's configured default.
    public func clampedFocalLengthMM(_ proposed: Double?) -> Double {
        min(max(proposed ?? defaultFocalLengthMM, focalLengthMinMM), focalLengthMaxMM)
    }

    /// Computes the rectilinear FOV using `2 × atan(sensor / 2f)` per axis.
    /// Invalid hand-edited profile values yield `nil`, never a fabricated FOV.
    public func fieldOfView(at proposed: Double? = nil) -> SetupFieldOfView? {
        let focalLengthMM = clampedFocalLengthMM(proposed)
        guard sensorWidthMM > 0,
              sensorHeightMM > 0,
              focalLengthMinMM > 0,
              focalLengthMaxMM >= focalLengthMinMM,
              defaultFocalLengthMM >= focalLengthMinMM,
              defaultFocalLengthMM <= focalLengthMaxMM,
              focalLengthMM > 0
        else { return nil }

        let widthDeg = 2 * atan(sensorWidthMM / (2 * focalLengthMM)) * 180 / .pi
        let heightDeg = 2 * atan(sensorHeightMM / (2 * focalLengthMM)) * 180 / .pi
        return SetupFieldOfView(widthDeg: widthDeg, heightDeg: heightDeg)
    }

    /// Picks the explicit default, defensively falling back to the first
    /// profile when a hand-edited config has no default marker.
    public static func defaultSetup(in setups: [ImagingSetupProfile]) -> ImagingSetupProfile? {
        setups.first(where: \.isDefault) ?? setups.first
    }
}
