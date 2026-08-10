import Foundation

/// The broad camera category used to describe a saved imaging setup.
///
/// The category is intentionally descriptive in this release: field of view
/// depends on the physical sensor dimensions and focal length, not on whether
/// the camera is modified. Keeping the distinction in the profile makes the
/// setup unambiguous to the photographer and leaves a sound input for future
/// target/filter suitability advice.
public enum CameraKind: String, Codable, CaseIterable, Equatable, Sendable {
    case unspecified
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

/// Domain-level validation failures shared by config/UI callers.
public enum ImagingSetupValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyCameraName
    case unspecifiedCameraKind
    case invalidSensorSize
    case invalidFocalRange
    case defaultFocalLengthOutsideRange
    case invalidFNumber
    case invalidRelativeEfficiency
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
    /// Working focal ratio used by the integration-reference planner. Older
    /// saved setups decode to f/5, the app-wide reference default.
    public var fNumber: Double
    /// Relative throughput/QE multiplier. `1` means reference efficiency;
    /// values below one require proportionally more integration.
    public var relativeEfficiency: Double
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
        fNumber: Double = 5,
        relativeEfficiency: Double = 1,
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
        self.fNumber = fNumber
        self.relativeEfficiency = relativeEfficiency
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cameraName, cameraKind, sensorWidthMM, sensorHeightMM
        case focalLengthMinMM, focalLengthMaxMM, defaultFocalLengthMM
        case fNumber, relativeEfficiency, isDefault
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cameraName = try container.decode(String.self, forKey: .cameraName)
        cameraKind = try container.decode(CameraKind.self, forKey: .cameraKind)
        sensorWidthMM = try container.decode(Double.self, forKey: .sensorWidthMM)
        sensorHeightMM = try container.decode(Double.self, forKey: .sensorHeightMM)
        focalLengthMinMM = try container.decode(Double.self, forKey: .focalLengthMinMM)
        focalLengthMaxMM = try container.decode(Double.self, forKey: .focalLengthMaxMM)
        defaultFocalLengthMM = try container.decode(Double.self, forKey: .defaultFocalLengthMM)
        fNumber = try container.decodeIfPresent(Double.self, forKey: .fNumber) ?? 5
        relativeEfficiency = try container.decodeIfPresent(Double.self, forKey: .relativeEfficiency) ?? 1
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    public var isZoom: Bool {
        guard focalLengthMinMM.isFinite, focalLengthMaxMM.isFinite,
              focalLengthMinMM > 0, focalLengthMaxMM >= focalLengthMinMM
        else { return false }
        return focalLengthMaxMM - focalLengthMinMM > 0.000_001
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImagingSetupValidationError.emptyName
        }
        guard !cameraName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImagingSetupValidationError.emptyCameraName
        }
        guard cameraKind != .unspecified else {
            throw ImagingSetupValidationError.unspecifiedCameraKind
        }
        guard sensorWidthMM.isFinite, sensorHeightMM.isFinite,
              sensorWidthMM > 0, sensorHeightMM > 0 else {
            throw ImagingSetupValidationError.invalidSensorSize
        }
        guard focalLengthMinMM.isFinite, focalLengthMaxMM.isFinite,
              focalLengthMinMM > 0, focalLengthMaxMM >= focalLengthMinMM else {
            throw ImagingSetupValidationError.invalidFocalRange
        }
        guard defaultFocalLengthMM.isFinite,
              defaultFocalLengthMM >= focalLengthMinMM,
              defaultFocalLengthMM <= focalLengthMaxMM else {
            throw ImagingSetupValidationError.defaultFocalLengthOutsideRange
        }
        guard fNumber.isFinite, fNumber > 0 else {
            throw ImagingSetupValidationError.invalidFNumber
        }
        guard relativeEfficiency.isFinite, relativeEfficiency > 0 else {
            throw ImagingSetupValidationError.invalidRelativeEfficiency
        }
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
        guard sensorWidthMM.isFinite, sensorHeightMM.isFinite,
              sensorWidthMM > 0, sensorHeightMM > 0,
              focalLengthMinMM.isFinite, focalLengthMaxMM.isFinite,
              defaultFocalLengthMM.isFinite, focalLengthMM.isFinite,
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
