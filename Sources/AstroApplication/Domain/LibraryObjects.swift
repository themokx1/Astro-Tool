import Foundation

/// A mobile idempotency marker is self-authenticating domain metadata: the
/// change ID is bound to its owning record, normalized command payload, and
/// resulting revision in the same durable write as the user-visible change.
/// Bare IDs are deliberately insufficient for replay authorization.
public struct MobileChangeMarker: Codable, Equatable, Hashable, Sendable {
    public let changeID: UUID
    public let ownerID: String
    public let payloadFingerprint: String
    public let resultingRevision: Int

    public init(changeID: UUID, ownerID: String, payloadFingerprint: String, resultingRevision: Int) {
        self.changeID = changeID
        self.ownerID = ownerID
        self.payloadFingerprint = payloadFingerprint
        self.resultingRevision = resultingRevision
    }
}

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

public struct ProjectAnnotationRecord: Codable, Equatable, Hashable, Sendable {
    public let projectID: UUID
    public let integrationGoalHours: Double?
    public let notes: String
    public let updatedAt: Date
    public let revision: Int
    /// Durable idempotency markers for mobile-originated annotation edits.
    /// They live in the same SQLite row as the edited text/revision.
    public let mobileChangeIDs: [UUID]
    public let mobileChangeMarkers: [MobileChangeMarker]

    public init(projectID: UUID, integrationGoalHours: Double?, notes: String, updatedAt: Date, revision: Int = 0, mobileChangeIDs: [UUID] = [], mobileChangeMarkers: [MobileChangeMarker] = []) {
        self.projectID = projectID
        self.integrationGoalHours = integrationGoalHours
        self.notes = notes
        self.updatedAt = updatedAt
        self.revision = revision
        self.mobileChangeMarkers = mobileChangeMarkers.sorted { $0.changeID.uuidString < $1.changeID.uuidString }
        self.mobileChangeIDs = Array(Set(mobileChangeIDs).union(mobileChangeMarkers.map(\.changeID))).sorted { $0.uuidString < $1.uuidString }
    }

    private enum CodingKeys: String, CodingKey { case projectID, integrationGoalHours, notes, updatedAt, revision, mobileChangeIDs, mobileChangeMarkers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        integrationGoalHours = try c.decodeIfPresent(Double.self, forKey: .integrationGoalHours)
        notes = try c.decode(String.self, forKey: .notes)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        mobileChangeIDs = Array(Set(try c.decodeIfPresent([UUID].self, forKey: .mobileChangeIDs) ?? [])).sorted { $0.uuidString < $1.uuidString }
        mobileChangeMarkers = (try c.decodeIfPresent([MobileChangeMarker].self, forKey: .mobileChangeMarkers) ?? []).sorted { $0.changeID.uuidString < $1.changeID.uuidString }
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

public struct FrameDecisionRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
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

/// One acknowledged finding group -- "rendben van, ismerem, nem hiba" -- keyed
/// by `MetadataStore.ackKey(category:groupKey:)`, the same deterministic
/// `"\(category)|\(groupKey)"` format V1's `Database.ackKey` used, so a V1
/// import lands in the same keyspace as a native V2 ack.
public struct AuditAcknowledgementRecord: Codable, Equatable, Hashable, Sendable {
    public let ackKey: String
    public let category: String
    public let groupKey: String
    public let ackedAt: Date
    public let note: String?

    public init(ackKey: String, category: String, groupKey: String, ackedAt: Date, note: String?) {
        self.ackKey = ackKey
        self.category = category
        self.groupKey = groupKey
        self.ackedAt = ackedAt
        self.note = note
    }
}

/// One completed audit run's headline facts -- when it ran, how many
/// findings it produced, and every finding group's key (for a later run to
/// diff against, mirroring V1 `AuditDiff`'s new/resolved comparison).
public struct AuditRunRecord: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let ranAt: Date
    public let findingCount: Int
    public let groupKeys: [String]

    public init(id: UUID, ranAt: Date, findingCount: Int, groupKeys: [String]) {
        self.id = id
        self.ranAt = ranAt
        self.findingCount = findingCount
        self.groupKeys = groupKeys
    }
}

/// The result of comparing the two most recent `AuditRunRecord`s (V1
/// `AuditDiff` semantics): a group key is "new" when it fires in the latest
/// run but not the previous one, "resolved" the other way around.
public struct AuditRunDiff: Equatable, Sendable {
    public let newGroupKeys: [String]
    public let resolvedGroupKeys: [String]

    public init(newGroupKeys: [String], resolvedGroupKeys: [String]) {
        self.newGroupKeys = newGroupKeys
        self.resolvedGroupKeys = resolvedGroupKeys
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
