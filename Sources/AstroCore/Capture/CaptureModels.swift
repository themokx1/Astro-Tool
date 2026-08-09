import Foundation

/// Physical sensor/color interpretation. This is deliberately independent
/// from `SignalMode`: an OSC camera can capture either broadband or filtered
/// dual-band data.
public enum SensorMode: String, Codable, Sendable, CaseIterable {
    case osc
    case mono
    case unknown

    public var displayNameHU: String {
        switch self {
        case .osc: return "OSC"
        case .mono: return "Monokróm"
        case .unknown: return "Ismeretlen szenzor"
        }
    }
}

/// Spectral intent/passband of a capture, kept separate from sensor type.
public enum SignalMode: String, Codable, Sendable, CaseIterable {
    case broadband
    case dualBand = "dual_band"
    case narrowband
    case lrgb
    case luminance
    case unfiltered
    case other
    case unknown

    public var displayNameHU: String {
        switch self {
        case .broadband: return "Szélessáv"
        case .dualBand: return "Dual-band"
        case .narrowband: return "Keskenysáv"
        case .lrgb: return "LRGB"
        case .luminance: return "Luminancia"
        case .unfiltered: return "Szűrő nélkül"
        case .other: return "Egyéb fénysáv"
        case .unknown: return "Ismeretlen fénysáv"
        }
    }
}

/// Where one resolved capture metadata value came from. UI surfaces this so
/// a user can distinguish an actual FITS value from a manual or inferred one.
public enum CaptureMetadataOrigin: String, Codable, Sendable, CaseIterable {
    case manualOverride = "manual_override"
    case captureGroup = "capture_group"
    case fitsHeader = "fits_header"
    case pathInference = "path_inference"
    case unknown

    public var displayNameHU: String {
        switch self {
        case .manualOverride: return "Kézi felülírás"
        case .captureGroup: return "Gyűjtésből"
        case .fitsHeader: return "FITS fejlécből"
        case .pathInference: return "Következtetett"
        case .unknown: return "Ismeretlen"
        }
    }
}

/// One first-class capture group below a target/date session.
public struct CaptureGroupRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var target: String
    public var sessionDate: String
    public var slug: String
    public var displayName: String
    public var sensorMode: SensorMode
    public var signalMode: SignalMode
    public var filterManufacturer: String?
    public var filterModel: String?
    public var filterName: String?
    public var notes: String?
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: Int64? = nil,
        target: String,
        sessionDate: String,
        slug: String,
        displayName: String,
        sensorMode: SensorMode = .unknown,
        signalMode: SignalMode = .unknown,
        filterManufacturer: String? = nil,
        filterModel: String? = nil,
        filterName: String? = nil,
        notes: String? = nil,
        createdAt: Double = 0,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.target = target
        self.sessionDate = sessionDate
        self.slug = slug
        self.displayName = displayName
        self.sensorMode = sensorMode
        self.signalMode = signalMode
        self.filterManufacturer = filterManufacturer
        self.filterModel = filterModel
        self.filterName = filterName
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Compact, unambiguous label for dense tables and chips.
    public var quickLabel: String {
        var parts = [sensorMode.displayNameHU, signalMode.displayNameHU]
        if let filterLabel { parts.append(filterLabel) }
        return parts.joined(separator: " · ")
    }

    public var filterLabel: String? {
        let manufacturer = filterManufacturer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = filterModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = filterName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let makeAndModel = [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
        if !makeAndModel.isEmpty, !name.isEmpty, name.caseInsensitiveCompare(makeAndModel) != .orderedSame {
            return "\(makeAndModel) \(name)"
        }
        if !makeAndModel.isEmpty { return makeAndModel }
        return name.isEmpty ? nil : name
    }
}

/// A directory prefix mapped to one capture group. Canonical groups normally
/// have one source per frame role, while legacy sessions can map `lights_osc`
/// without moving anything.
public struct CaptureSourceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var captureGroupID: Int64
    public var relativePath: String
    public var role: FrameRole

    public init(id: Int64? = nil, captureGroupID: Int64, relativePath: String, role: FrameRole) {
        self.id = id
        self.captureGroupID = captureGroupID
        self.relativePath = relativePath
        self.role = role
    }
}

/// Optional per-file assignment and overrides. Assigning a single file to a
/// group is enough for the common case; overrides cover exceptional frames
/// without changing their raw FITS headers.
public struct FileCaptureAssignmentRecord: Codable, Equatable, Sendable {
    public var fileID: Int64
    public var captureGroupID: Int64
    public var sensorModeOverride: SensorMode?
    public var signalModeOverride: SignalMode?
    public var filterManufacturerOverride: String?
    public var filterModelOverride: String?
    public var filterNameOverride: String?
    public var assignmentSource: String
    public var assignedAt: Double

    public init(
        fileID: Int64,
        captureGroupID: Int64,
        sensorModeOverride: SensorMode? = nil,
        signalModeOverride: SignalMode? = nil,
        filterManufacturerOverride: String? = nil,
        filterModelOverride: String? = nil,
        filterNameOverride: String? = nil,
        assignmentSource: String = "app",
        assignedAt: Double = 0
    ) {
        self.fileID = fileID
        self.captureGroupID = captureGroupID
        self.sensorModeOverride = sensorModeOverride
        self.signalModeOverride = signalModeOverride
        self.filterManufacturerOverride = filterManufacturerOverride
        self.filterModelOverride = filterModelOverride
        self.filterNameOverride = filterNameOverride
        self.assignmentSource = assignmentSource
        self.assignedAt = assignedAt
    }
}

/// Fully resolved metadata used by stats, quality, reports, and UI.
public struct ResolvedCaptureMetadata: Codable, Equatable, Sendable {
    public var groupID: Int64?
    public var slug: String?
    public var displayName: String?
    public var sensorMode: SensorMode
    public var signalMode: SignalMode
    public var filterManufacturer: String?
    public var filterModel: String?
    public var filterName: String?
    public var sensorOrigin: CaptureMetadataOrigin
    public var signalOrigin: CaptureMetadataOrigin
    public var filterOrigin: CaptureMetadataOrigin
    public var conflicts: [String]

    public init(
        groupID: Int64? = nil,
        slug: String? = nil,
        displayName: String? = nil,
        sensorMode: SensorMode = .unknown,
        signalMode: SignalMode = .unknown,
        filterManufacturer: String? = nil,
        filterModel: String? = nil,
        filterName: String? = nil,
        sensorOrigin: CaptureMetadataOrigin = .unknown,
        signalOrigin: CaptureMetadataOrigin = .unknown,
        filterOrigin: CaptureMetadataOrigin = .unknown,
        conflicts: [String] = []
    ) {
        self.groupID = groupID
        self.slug = slug
        self.displayName = displayName
        self.sensorMode = sensorMode
        self.signalMode = signalMode
        self.filterManufacturer = filterManufacturer
        self.filterModel = filterModel
        self.filterName = filterName
        self.sensorOrigin = sensorOrigin
        self.signalOrigin = signalOrigin
        self.filterOrigin = filterOrigin
        self.conflicts = conflicts
    }

    public var hasConflict: Bool { !conflicts.isEmpty }
}
