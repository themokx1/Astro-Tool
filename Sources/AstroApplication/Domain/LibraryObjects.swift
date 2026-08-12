import Foundation

public enum ProjectWorkflowPhase: String, CaseIterable, Codable, Sendable {
    case planned
    case collecting
    case processing
    case complete
    case archived
}

public struct ProjectRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let catalogID: String
    public let displayName: String
    public let phase: ProjectWorkflowPhase

    public init(id: UUID, catalogID: String, displayName: String, phase: ProjectWorkflowPhase) {
        self.id = id
        self.catalogID = catalogID
        self.displayName = displayName
        self.phase = phase
    }
}

public struct NightRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let localDate: String
    public let timeZoneID: String

    public init(id: UUID, localDate: String, timeZoneID: String) {
        self.id = id
        self.localDate = localDate
        self.timeZoneID = timeZoneID
    }
}

public enum SeriesSensorMode: String, CaseIterable, Codable, Sendable {
    case osc
    case mono
    case dslr
    case unknown
}

public enum SeriesPassband: String, CaseIterable, Codable, Sendable {
    case broadband
    case dualBand = "dual_band"
    case narrowband
    case lrgb
    case luminance
    case unfiltered
    case other
    case unknown
}

public struct SeriesRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let nightID: UUID
    public let setupID: String?
    public let setupDescriptor: String
    public let sensorMode: SeriesSensorMode
    public let passband: SeriesPassband
    public let exposureSeconds: Double
    public let filterName: String?
    public let filterID: String?
    public let gain: Double?
    public let offset: Double?
    public let binning: String

    public init(
        id: UUID,
        projectID: UUID,
        nightID: UUID,
        setupID: String?,
        setupDescriptor: String,
        sensorMode: SeriesSensorMode,
        passband: SeriesPassband,
        exposureSeconds: Double,
        filterName: String?,
        filterID: String?,
        gain: Double?,
        offset: Double?,
        binning: String
    ) {
        self.id = id
        self.projectID = projectID
        self.nightID = nightID
        self.setupID = setupID
        self.setupDescriptor = setupDescriptor
        self.sensorMode = sensorMode
        self.passband = passband
        self.exposureSeconds = exposureSeconds
        self.filterName = filterName
        self.filterID = filterID
        self.gain = gain
        self.offset = offset
        self.binning = binning
    }
}

public enum FrameVerdict: String, CaseIterable, Codable, Sendable {
    case undecided
    case accepted
    case rejected
}

public struct FrameDecisionRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let seriesID: UUID
    public let relativePath: String
    public let verdict: FrameVerdict
    public let logicallyExcluded: Bool

    public init(
        id: UUID,
        seriesID: UUID,
        relativePath: String,
        verdict: FrameVerdict,
        logicallyExcluded: Bool
    ) {
        self.id = id
        self.seriesID = seriesID
        self.relativePath = relativePath
        self.verdict = verdict
        self.logicallyExcluded = logicallyExcluded
    }
}

public enum ResultKind: String, CaseIterable, Codable, Sendable {
    case stack
    case processingVariant = "processing_variant"
}

public enum ResultRole: String, CaseIterable, Codable, Sendable {
    case intermediate
    case starless
    case mask
    case final
}

public struct ResultRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let parentResultID: UUID?
    public let kind: ResultKind
    public let role: ResultRole
    public let relativePath: String?
    public let createdAt: Date
    public let softwareName: String?
    public let softwareVersion: String?

    public init(
        id: UUID,
        projectID: UUID,
        parentResultID: UUID?,
        kind: ResultKind,
        role: ResultRole,
        relativePath: String?,
        createdAt: Date,
        softwareName: String?,
        softwareVersion: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.parentResultID = parentResultID
        self.kind = kind
        self.role = role
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.softwareName = softwareName
        self.softwareVersion = softwareVersion
    }
}

public enum LineageSourceKind: String, CaseIterable, Codable, Sendable {
    case series
    case frame
    case result
}

public struct LineageEdgeRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let resultID: UUID
    public let sourceKind: LineageSourceKind
    public let sourceID: UUID

    public init(id: UUID, resultID: UUID, sourceKind: LineageSourceKind, sourceID: UUID) {
        self.id = id
        self.resultID = resultID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
    }
}

public enum ReviewStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case complete
}

public struct ReviewStateRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let seriesID: UUID
    public let status: ReviewStatus
    public let updatedAt: Date

    public init(id: UUID, seriesID: UUID, status: ReviewStatus, updatedAt: Date) {
        self.id = id
        self.seriesID = seriesID
        self.status = status
        self.updatedAt = updatedAt
    }
}

public enum MutationJournalStatus: String, CaseIterable, Codable, Sendable {
    case planned
    case applying
    case applied
    case rollingBack = "rolling_back"
    case rolledBack = "rolled_back"
    case failed
}

public struct MutationJournalRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let status: MutationJournalStatus
    public let createdAt: Date
    public let payloadJSON: String

    public init(
        id: UUID,
        operationID: UUID,
        status: MutationJournalStatus,
        createdAt: Date,
        payloadJSON: String
    ) {
        self.id = id
        self.operationID = operationID
        self.status = status
        self.createdAt = createdAt
        self.payloadJSON = payloadJSON
    }
}

/// Human-authored V1 facts staged for lossless V2 reconciliation. Scanner
/// caches and integer V1 identities are deliberately excluded.
public enum LegacyImportKind: String, CaseIterable, Codable, Sendable {
    case tag
    case sessionNote = "session_note"
    case frameVerdict = "frame_verdict"
    case filterProfile = "filter_profile"
    case captureGroup = "capture_group"
    case captureSource = "capture_source"
    case captureAssignment = "capture_assignment"
    case acknowledgement
    case userConfiguration = "user_configuration"
    case conversionReceipt = "conversion_receipt"
    case quarantineReceipt = "quarantine_receipt"
    case legacySensorMeasurement = "legacy_sensor_measurement"
}

public struct LegacyImportRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let sourceKey: String
    public let kind: LegacyImportKind
    public let payloadJSON: String

    public init(id: UUID, sourceKey: String, kind: LegacyImportKind, payloadJSON: String) {
        self.id = id
        self.sourceKey = sourceKey
        self.kind = kind
        self.payloadJSON = payloadJSON
    }
}
