import CryptoKit
import Foundation
import AstroMobileDomain
import AstroMobileTransport

/// The only command boundary the return importer may call. It accepts a
/// closed set of checklist/note batches; it deliberately has no generic
/// execute hook or begin/end lifecycle callbacks.
package struct MobileChangeCommands: Sendable {
    typealias ApplyBatch = @Sendable (MobileChangeDomainBatch) async throws -> MobileChangeDomainBatchResult

    let applyBatch: ApplyBatch
    fileprivate let isConfigured: Bool

    /// Internal test/production seam. The public importer deliberately does
    /// not expose a caller-supplied command factory.
    init(applyBatch: ApplyBatch? = nil) {
        self.isConfigured = applyBatch != nil
        self.applyBatch = applyBatch ?? { _ in throw MobileChangeImportError.configurationMissing }
    }
}

package enum MobileNoteBatchMutationMode: String, Codable, Equatable, Sendable {
    case replace
    case appendFieldNote
}

package enum MobileBriefingBatchMutation: Codable, Equatable, Sendable {
    case checklist(MobileChecklistRevisionCommand)
    case note(MobileNoteRevisionCommand, MobileNoteBatchMutationMode)
}

package struct MobileBriefingChangeBatch: Codable, Equatable, Sendable {
    package let briefingID: UUID
    package let expectedRevision: Int
    package let mutations: [MobileBriefingBatchMutation]

    package init(briefingID: UUID, expectedRevision: Int, mutations: [MobileBriefingBatchMutation]) {
        self.briefingID = briefingID
        self.expectedRevision = expectedRevision
        self.mutations = mutations
    }
}

package struct MobileProjectAnnotationChangeBatch: Codable, Equatable, Sendable {
    package let projectID: UUID
    package let expectedRevision: Int
    package let mutations: [(MobileNoteRevisionCommand, MobileNoteBatchMutationMode)]

    package init(projectID: UUID, expectedRevision: Int, mutations: [(MobileNoteRevisionCommand, MobileNoteBatchMutationMode)]) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.mutations = mutations
    }

    private enum CodingKeys: String, CodingKey { case projectID, expectedRevision, mutations }
    private struct EncodedMutation: Codable, Equatable, Sendable { let command: MobileNoteRevisionCommand; let mode: MobileNoteBatchMutationMode }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        expectedRevision = try values.decode(Int.self, forKey: .expectedRevision)
        mutations = try values.decode([EncodedMutation].self, forKey: .mutations).map { ($0.command, $0.mode) }
    }
    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encode(mutations.map { EncodedMutation(command: $0.0, mode: $0.1) }, forKey: .mutations)
    }
    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID
            && lhs.expectedRevision == rhs.expectedRevision
            && lhs.mutations.elementsEqual(rhs.mutations, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }
}

package enum MobileChangeDomainBatch: Codable, Equatable, Sendable {
    case briefing(MobileBriefingChangeBatch)
    case projectAnnotation(MobileProjectAnnotationChangeBatch)
}

package struct MobileChangeDomainBatchResult: Codable, Equatable, Sendable {
    package let appliedChangeIDs: [UUID]
    package let resultingRevisions: [String: Int]

    package init(appliedChangeIDs: [UUID], resultingRevisions: [String: Int]) {
        self.appliedChangeIDs = appliedChangeIDs.sorted { $0.uuidString < $1.uuidString }
        self.resultingRevisions = resultingRevisions
    }
}

package struct MobileChecklistRevisionCommand: Codable, Equatable, Sendable {
    package let changeID: UUID
    package let deviceID: UUID
    package let briefingID: UUID
    package let itemID: String
    package let phoneBaseRevision: Int
    package let isCompleted: Bool
    package let expectedRevision: Int
    package let resultingRevision: Int
    package let createdAt: Date

    package init(changeID: UUID, deviceID: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), briefingID: UUID, itemID: String, phoneBaseRevision: Int? = nil, isCompleted: Bool, expectedRevision: Int, resultingRevision: Int, createdAt: Date = Date()) {
        self.changeID = changeID
        self.deviceID = deviceID
        self.briefingID = briefingID
        self.itemID = itemID
        self.phoneBaseRevision = phoneBaseRevision ?? expectedRevision
        self.isCompleted = isCompleted
        self.expectedRevision = expectedRevision
        self.resultingRevision = resultingRevision
        self.createdAt = createdAt
    }
}

package struct MobileNoteRevisionCommand: Codable, Equatable, Sendable {
    package let changeID: UUID
    package let deviceID: UUID
    package let noteID: String
    package let ownerID: String
    package let phoneBaseRevision: Int
    package let text: String
    package let expectedRevision: Int
    package let resultingRevision: Int
    package let createdAt: Date

    package init(changeID: UUID, deviceID: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), noteID: String, ownerID: String, phoneBaseRevision: Int? = nil, text: String, expectedRevision: Int, resultingRevision: Int, createdAt: Date) {
        self.changeID = changeID
        self.deviceID = deviceID
        self.noteID = noteID
        self.ownerID = ownerID
        self.phoneBaseRevision = phoneBaseRevision ?? expectedRevision
        self.text = text
        self.expectedRevision = expectedRevision
        self.resultingRevision = resultingRevision
        self.createdAt = createdAt
    }
}

package struct MobileFieldNoteCommand: Codable, Equatable, Sendable {
    package let changeID: UUID
    package let noteID: String
    package let ownerID: String
    package let text: String
    package let createdAt: Date

    package init(changeID: UUID, noteID: String, ownerID: String, text: String, createdAt: Date) {
        self.changeID = changeID
        self.noteID = noteID
        self.ownerID = ownerID
        self.text = text
        self.createdAt = createdAt
    }
}

/// Fingerprints only immutable phone intent. Mac-side compare-and-set and
/// result revisions deliberately do not participate, so a crash retry after
/// later unrelated Mac revisions can still authenticate the original marker.
package enum MobileChangeMarkerFingerprint {
    private struct ChecklistPayload: Codable {
        let kind: String
        let changeID: UUID
        let deviceID: UUID
        let briefingID: UUID
        let itemID: String
        let phoneBaseRevision: Int
        let isCompleted: Bool
        let createdAt: Date
    }

    private struct NotePayload: Codable {
        let kind: String
        let changeID: UUID
        let deviceID: UUID
        let noteID: String
        let ownerID: String
        let phoneBaseRevision: Int
        let text: String
        let createdAt: Date
        let mode: MobileNoteBatchMutationMode
    }

    package static func checklist(_ command: MobileChecklistRevisionCommand) -> String {
        digest(ChecklistPayload(
            kind: "checklist",
            changeID: command.changeID,
            deviceID: command.deviceID,
            briefingID: command.briefingID,
            itemID: command.itemID,
            phoneBaseRevision: command.phoneBaseRevision,
            isCompleted: command.isCompleted,
            createdAt: command.createdAt
        ))
    }

    package static func note(_ command: MobileNoteRevisionCommand, mode: MobileNoteBatchMutationMode) -> String {
        digest(NotePayload(
            kind: "note",
            changeID: command.changeID,
            deviceID: command.deviceID,
            noteID: command.noteID,
            ownerID: command.ownerID,
            phoneBaseRevision: command.phoneBaseRevision,
            text: command.text,
            createdAt: command.createdAt,
            mode: mode
        ))
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoded = (try? MobileJSON.encoder.encode(value)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

public enum MobileChangeResolution: String, Codable, Equatable, Sendable {
    case applyPhone
    case keepMac
    case keepBothAsFieldNote
}

public enum MobileChangeConflictKind: String, Codable, Equatable, Sendable {
    case checklist
    case note
}

public struct MobileChangeConflict: Codable, Equatable, Sendable {
    public let change: MobileChange
    public let kind: MobileChangeConflictKind
    public let targetName: String
    public let macChecklistCompletion: Bool?
    public let phoneChecklistCompletion: Bool?
    public let macText: String?
    public let phoneText: String?
    public let macTimestamp: Date
    public let phoneTimestamp: Date
    public let recommendedResolution: MobileChangeResolution

    public init(
        change: MobileChange,
        kind: MobileChangeConflictKind,
        targetName: String,
        macChecklistCompletion: Bool? = nil,
        phoneChecklistCompletion: Bool? = nil,
        macText: String? = nil,
        phoneText: String? = nil,
        macTimestamp: Date,
        phoneTimestamp: Date,
        recommendedResolution: MobileChangeResolution
    ) {
        self.change = change
        self.kind = kind
        self.targetName = targetName
        self.macChecklistCompletion = macChecklistCompletion
        self.phoneChecklistCompletion = phoneChecklistCompletion
        self.macText = macText
        self.phoneText = phoneText
        self.macTimestamp = macTimestamp
        self.phoneTimestamp = phoneTimestamp
        self.recommendedResolution = recommendedResolution
    }

    public var changeID: UUID { change.mobileChangeID }
}

public enum MobileRejectedChangeReason: String, Codable, Equatable, Sendable {
    case libraryMismatch
    case snapshotMismatch
    case unsupportedSchema
    case malformedChange
    case unknownTarget
    case noTextToImport
    case crossDeviceQueue
    case duplicateChangeID
    case alreadyApplied
    case limitExceeded
}

public struct MobileRejectedChange: Codable, Equatable, Sendable {
    public let changeID: UUID?
    public let reason: MobileRejectedChangeReason
    public let detail: String?

    public init(changeID: UUID?, reason: MobileRejectedChangeReason, detail: String? = nil) {
        self.changeID = changeID
        self.reason = reason
        self.detail = detail
    }
}

public struct MobileChangeImportPreview: Codable, Equatable, Sendable {
    public let applicable: [MobileChange]
    public let conflicts: [MobileChangeConflict]
    public let duplicates: [UUID]
    public let alreadyApplied: [UUID]
    public let superseded: [UUID]
    public let rejected: [MobileRejectedChange]
    public let libraryID: PortableLibraryID
    public let baseSnapshotID: UUID
    public let sourcePackageID: UUID
    public let sourceFingerprint: String

    public init(
        applicable: [MobileChange],
        conflicts: [MobileChangeConflict],
        duplicates: [UUID],
        rejected: [MobileRejectedChange],
        alreadyApplied: [UUID] = [],
        superseded: [UUID] = [],
        libraryID: PortableLibraryID = PortableLibraryID(rawValue: UUID()),
        baseSnapshotID: UUID = UUID(),
        sourcePackageID: UUID = UUID(),
        sourceFingerprint: String = ""
    ) {
        self.applicable = applicable
        self.conflicts = conflicts
        self.duplicates = duplicates
        self.alreadyApplied = alreadyApplied
        self.superseded = superseded
        self.rejected = rejected
        self.libraryID = libraryID
        self.baseSnapshotID = baseSnapshotID
        self.sourcePackageID = sourcePackageID
        self.sourceFingerprint = sourceFingerprint
    }
}

/// A bounded, app-owned acknowledgement summary. It contains no secrets;
/// target-domain records, not this ledger, remain the durable idempotency
/// authority after a mutation has happened.
public struct MobileChangeApplicationRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let libraryID: PortableLibraryID
    public let sourcePackageID: UUID
    public let sourceFingerprint: String
    public let appliedChangeIDs: [UUID]
    public let resolvedChangeIDs: [UUID]
    public let resultingRevisions: [String: Int]
    public let recordedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        libraryID: PortableLibraryID,
        sourcePackageID: UUID,
        sourceFingerprint: String,
        appliedChangeIDs: [UUID],
        resolvedChangeIDs: [UUID] = [],
        resultingRevisions: [String: Int],
        recordedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.sourcePackageID = sourcePackageID
        self.sourceFingerprint = sourceFingerprint
        let applied = Set(appliedChangeIDs)
        self.appliedChangeIDs = applied.sorted { $0.uuidString < $1.uuidString }
        self.resolvedChangeIDs = Set(resolvedChangeIDs)
            .subtracting(applied)
            .sorted { $0.uuidString < $1.uuidString }
        self.resultingRevisions = resultingRevisions
        self.recordedAt = recordedAt
    }
}

public typealias MobileChangeApplicationReceipt = MobileChangeApplicationRecord

package struct MobileChangeApplicationLedger: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1
    package let schemaVersion: Int
    package let libraryID: PortableLibraryID
    package let records: [MobileChangeApplicationRecord]
    package let appliedChangeIDs: [UUID]
    package let resolvedChangeIDs: [UUID]
    package let resultingRevisions: [String: Int]

    package init(libraryID: PortableLibraryID, records: [MobileChangeApplicationRecord] = [], appliedChangeIDs: [UUID] = [], resolvedChangeIDs: [UUID] = [], resultingRevisions: [String: Int] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.libraryID = libraryID
        self.records = Array(records.suffix(256))
        let applied = Set(appliedChangeIDs)
        self.appliedChangeIDs = applied.sorted { $0.uuidString < $1.uuidString }
        // A real mutation wins classification over a later "resolved" view
        // of the same change. This keeps acknowledgement classes disjoint and
        // prevents a forward package from naming one ID twice.
        self.resolvedChangeIDs = Set(resolvedChangeIDs)
            .subtracting(applied)
            .sorted { $0.uuidString < $1.uuidString }
        self.resultingRevisions = resultingRevisions
    }
}

public enum MobileChangeImportError: Error, Equatable, Sendable {
    case invalidEnvelope
    case directionMismatch
    case configurationMissing
    case crossDeviceQueue
    case libraryMismatch
    case snapshotMismatch
    case unsupportedSchema
    case limitsExceeded
    case stalePreview
    case finalConfirmationRequired
    case conflictResolutionRequired(UUID)
    case invalidResolution(UUID)
    case commandFailed(UUID)
    case corruptDomainMarkers
    case partialReceipt(MobileChangeApplicationReceipt)
    case receiptFailed
}

package protocol MobileChangeApplicationRecordStore: Sendable {
    func load() throws -> MobileChangeApplicationLedger?
    func save(_ ledger: MobileChangeApplicationLedger) throws
    /// A ledger read-modify-write transaction. Concrete durable stores must
    /// reload while holding their cross-window lock; this default preserves
    /// lightweight fixture compatibility.
    func updateLedger(
        _ mutation: (MobileChangeApplicationLedger?) throws -> MobileChangeApplicationLedger?
    ) throws
}

package extension MobileChangeApplicationRecordStore {
    func updateLedger(
        _ mutation: (MobileChangeApplicationLedger?) throws -> MobileChangeApplicationLedger?
    ) throws {
        if let next = try mutation(load()) { try save(next) }
    }
}

private final class MobileChangeInMemoryRecordStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MobileChangeApplicationLedger?
    func load() throws -> MobileChangeApplicationLedger? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ ledger: MobileChangeApplicationLedger) throws { lock.lock(); value = ledger; lock.unlock() }
}

package final class MobileChangeImporter: @unchecked Sendable {
    package struct Limits: Equatable, Sendable {
        package let maxChanges: Int
        package let maxTextBytes: Int
        package init(maxChanges: Int = 10_000, maxTextBytes: Int = 256 * 1024) {
            self.maxChanges = maxChanges
            self.maxTextBytes = maxTextBytes
        }
    }

    private let commands: MobileChangeCommands
    private let limits: Limits
    private let recordStore: MobileChangeApplicationRecordStore?
    private var ledger: MobileChangeApplicationLedger?
    private let ledgerLoadFailed: Bool

    package func currentAcknowledgementIDs() throws -> [UUID] {
        try reloadLedger()
        if let libraryID = ledger?.libraryID { try validateLedger(expectedLibraryID: libraryID) }
        return (ledger?.appliedChangeIDs ?? []) + (ledger?.resolvedChangeIDs ?? [])
    }

    /// Prunes only acknowledgement IDs proven delivered to the phone by a
    /// later authenticated return package based on the exact forward snapshot
    /// that carried them. Domain-side idempotency markers remain authoritative
    /// for replay protection.
    func acknowledgePhoneEvidence(_ acknowledgedIDs: Set<UUID>) throws {
        guard !acknowledgedIDs.isEmpty, let recordStore else { return }
        do {
            var updated: MobileChangeApplicationLedger?
            try recordStore.updateLedger { ledger in
                guard let ledger else { return nil }
                let next = MobileChangeApplicationLedger(
                    libraryID: ledger.libraryID,
                    records: ledger.records.map { record in
                        MobileChangeApplicationRecord(
                            libraryID: record.libraryID,
                            sourcePackageID: record.sourcePackageID,
                            sourceFingerprint: record.sourceFingerprint,
                            appliedChangeIDs: record.appliedChangeIDs.filter { !acknowledgedIDs.contains($0) },
                            resolvedChangeIDs: record.resolvedChangeIDs.filter { !acknowledgedIDs.contains($0) },
                            resultingRevisions: record.resultingRevisions.filter { key, _ in
                                UUID(uuidString: key).map { !acknowledgedIDs.contains($0) } ?? false
                            },
                            recordedAt: record.recordedAt
                        )
                    }.filter { !$0.appliedChangeIDs.isEmpty || !$0.resolvedChangeIDs.isEmpty },
                    appliedChangeIDs: ledger.appliedChangeIDs.filter { !acknowledgedIDs.contains($0) },
                    resolvedChangeIDs: ledger.resolvedChangeIDs.filter { !acknowledgedIDs.contains($0) },
                    resultingRevisions: ledger.resultingRevisions.filter { key, _ in
                        UUID(uuidString: key).map { !acknowledgedIDs.contains($0) } ?? false
                    }
                )
                updated = next
                return next
            }
            self.ledger = updated
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    /// A non-mutating importer suitable for preview-only callers. Production
    /// mutation is available solely through `production(rootURL:recordStore:)`.
    package convenience init(
        limits: Limits = .init(),
        recordStore: MobileChangeApplicationRecordStore? = nil
    ) {
        self.init(commands: .init(), limits: limits, recordStore: recordStore)
    }

    init(
        commands: MobileChangeCommands = .init(),
        limits: Limits = .init(),
        recordStore: MobileChangeApplicationRecordStore? = nil,
        existingRecord: MobileChangeApplicationRecord? = nil
    ) {
        self.commands = commands
        self.limits = limits
        self.recordStore = recordStore ?? (commands.isConfigured ? MobileChangeInMemoryRecordStore() : nil)
        if let existingRecord {
            self.ledger = MobileChangeApplicationLedger(libraryID: existingRecord.libraryID, records: [existingRecord], appliedChangeIDs: existingRecord.appliedChangeIDs, resolvedChangeIDs: existingRecord.resolvedChangeIDs, resultingRevisions: existingRecord.resultingRevisions)
            self.ledgerLoadFailed = false
        } else {
            do {
                let loaded = try self.recordStore?.load()
                if let loaded, loaded.schemaVersion != MobileChangeApplicationLedger.currentSchemaVersion {
                    throw MobileChangeImportError.receiptFailed
                }
                self.ledger = loaded
                self.ledgerLoadFailed = false
            }
            catch { self.ledger = nil; self.ledgerLoadFailed = true }
        }
    }

    /// Constructs the sole mutating importer used by the Mac application.
    /// Its command boundary is fixed to the domain store rooted at `rootURL`;
    /// outside clients cannot inject arbitrary mutation closures.
    package static func production(
        rootURL: URL,
        limits: Limits = .init(),
        recordStore: MobileChangeApplicationRecordStore? = nil
    ) throws -> MobileChangeImporter {
        MobileChangeImporter(
            commands: try MobileChangeCommands.production(rootURL: rootURL),
            limits: limits,
            recordStore: recordStore
        )
    }

    /// Production entry point. The caller has no route to supply a raw
    /// envelope, manifest identifier, or fingerprint: all are derived from a
    /// return capability minted by `MobilePackageService`.
    package func preview(
        authenticatedReturn: MobileAuthenticatedReturnPackage,
        expectedLibraryID: PortableLibraryID,
        expectedBaseSnapshotID: UUID? = nil,
        currentSnapshot: MobileLibrarySnapshot,
        appliedChangeIDs: Set<UUID> = []
    ) throws -> MobileChangeImportPreview {
        let envelope = MobilePackageEnvelope(
            purpose: .returnChanges,
            snapshot: authenticatedReturn.baseSnapshot,
            baseSnapshotID: authenticatedReturn.baseSnapshotID,
            changes: authenticatedReturn.changes,
            acknowledgedChangeIDs: []
        )
        return try preview(
            envelope: envelope,
            expectedLibraryID: expectedLibraryID,
            expectedBaseSnapshotID: expectedBaseSnapshotID,
            currentSnapshot: currentSnapshot,
            sourcePackageID: authenticatedReturn.packageID,
            appliedChangeIDs: appliedChangeIDs
        )
    }

    /// Test-only raw seam. Production callers must use
    /// `preview(authenticatedReturn:...)`.
    func preview(
        envelope: MobilePackageEnvelope,
        expectedLibraryID: PortableLibraryID,
        expectedBaseSnapshotID: UUID? = nil,
        currentSnapshot: MobileLibrarySnapshot,
        sourcePackageID: UUID,
        appliedChangeIDs: Set<UUID> = []
    ) throws -> MobileChangeImportPreview {
        try reloadLedger()
        guard !ledgerLoadFailed else { throw MobileChangeImportError.receiptFailed }
        try validateLedger(expectedLibraryID: expectedLibraryID)
        guard let base = envelope.snapshot else { throw MobileChangeImportError.invalidEnvelope }
        guard envelope.purpose == .returnChanges,
              envelope.baseSnapshotID == base.snapshotID,
              envelope.acknowledgedChangeIDs.isEmpty else { throw MobileChangeImportError.directionMismatch }
        guard base.libraryID == expectedLibraryID, currentSnapshot.libraryID == expectedLibraryID else { throw MobileChangeImportError.libraryMismatch }
        guard base.libraryID == currentSnapshot.libraryID else { throw MobileChangeImportError.snapshotMismatch }
        if let expectedBaseSnapshotID, base.snapshotID != expectedBaseSnapshotID { throw MobileChangeImportError.snapshotMismatch }
        guard base.schemaVersion == MobileLibrarySnapshot.currentSchemaVersion else { throw MobileChangeImportError.unsupportedSchema }
        guard envelope.acknowledgedChangeIDs.isEmpty else { throw MobileChangeImportError.invalidEnvelope }
        guard envelope.changes.count <= limits.maxChanges else { throw MobileChangeImportError.limitsExceeded }
        let devices = Set(envelope.changes.map(\.mobileDeviceID))
        guard devices.count <= 1 else { throw MobileChangeImportError.crossDeviceQueue }

        let fingerprint = Self.fingerprint(envelope)
        let persistedIDs = Set((ledger?.appliedChangeIDs ?? []) + (ledger?.resolvedChangeIDs ?? []))
        let allApplied = appliedChangeIDs.union(persistedIDs)
        let effectivePackageID = sourcePackageID
        var applicable: [MobileChange] = []
        var conflicts: [MobileChangeConflict] = []
        var duplicates: [UUID] = []
        var alreadyApplied: [UUID] = []
        var superseded: [UUID] = []
        var rejected: [MobileRejectedChange] = []
        var seen = Set<UUID>()
        var uniqueChanges: [MobileChange] = []
        var occurrences: [UUID: Int] = [:]
        for change in envelope.changes {
            let id = change.mobileChangeID
            occurrences[id, default: 0] += 1
            guard seen.insert(id).inserted else { continue }
            uniqueChanges.append(change)
        }
        let collisionIDs = Set(occurrences.compactMap { $0.value > 1 ? $0.key : nil })
        duplicates = Array(collisionIDs)
        // A duplicated ID has no authoritative payload. Remove every one of
        // those records before chronological supersession so an ambiguous
        // later entry cannot suppress a valid earlier value for the target.
        let chronologyCandidates = uniqueChanges.filter { !collisionIDs.contains($0.mobileChangeID) }
        var latestByTarget: [String: MobileChange] = [:]
        for change in chronologyCandidates {
            let key = change.mobileTargetKey
            if let existing = latestByTarget[key] {
                let newer = change.mobileCreatedAt > existing.mobileCreatedAt || (change.mobileCreatedAt == existing.mobileCreatedAt && change.mobileChangeID.uuidString > existing.mobileChangeID.uuidString)
                if newer { superseded.append(existing.mobileChangeID); latestByTarget[key] = change }
                else { superseded.append(change.mobileChangeID) }
            } else { latestByTarget[key] = change }
        }
        let selectedIDs = Set(latestByTarget.values.map(\.mobileChangeID))

        for change in chronologyCandidates where selectedIDs.contains(change.mobileChangeID) {
            let id = change.mobileChangeID
            if allApplied.contains(id) {
                alreadyApplied.append(id)
                continue
            }
            guard Self.isValid(change: change, maxTextBytes: limits.maxTextBytes) else {
                rejected.append(.init(changeID: id, reason: .malformedChange, detail: "The change record is incomplete."))
                continue
            }

            switch change {
            case .checklistCompletion(let phone):
                guard let briefing = currentSnapshot.briefings.first(where: { $0.id == phone.briefingID }),
                      let item = briefing.checklist.flatMap(\.items).first(where: { $0.id == phone.itemID }) else {
                    rejected.append(.init(changeID: id, reason: .unknownTarget, detail: "The checklist item is no longer available."))
                    continue
                }
                if item.baseRevision == phone.baseRevision {
                    applicable.append(change)
                } else {
                    conflicts.append(MobileChangeConflict(
                        change: change, kind: .checklist, targetName: item.title,
                        macChecklistCompletion: item.isCompleted, phoneChecklistCompletion: phone.isCompleted,
                        macTimestamp: briefing.savedAt, phoneTimestamp: phone.createdAt,
                        recommendedResolution: .applyPhone
                    ))
                }
            case .noteRevision(let phone):
                guard let note = currentSnapshot.notes.first(where: { $0.id == phone.noteID }), note.ownerID == phone.ownerID, note.isEditableOnPhone else {
                    rejected.append(.init(changeID: id, reason: .unknownTarget, detail: "The note is no longer available."))
                    continue
                }
                guard !phone.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    rejected.append(.init(changeID: id, reason: .noTextToImport, detail: "No text to import."))
                    continue
                }
                if note.baseRevision == phone.baseRevision {
                    applicable.append(change)
                } else {
                    conflicts.append(MobileChangeConflict(
                        change: change, kind: .note, targetName: note.scope == .briefing ? "Briefing note" : note.scope == .project ? "Project note" : "Night note",
                        macText: note.text, phoneText: phone.text,
                        macTimestamp: note.updatedAt, phoneTimestamp: phone.createdAt,
                        recommendedResolution: .keepBothAsFieldNote
                    ))
                }
            }
        }

        applicable = applicable.filter { selectedIDs.contains($0.mobileChangeID) }
        conflicts = conflicts.filter { selectedIDs.contains($0.changeID) }
        applicable.sort { $0.mobileCreatedAt == $1.mobileCreatedAt ? $0.mobileChangeID.uuidString < $1.mobileChangeID.uuidString : $0.mobileCreatedAt < $1.mobileCreatedAt }
        conflicts.sort { $0.phoneTimestamp == $1.phoneTimestamp ? $0.changeID.uuidString < $1.changeID.uuidString : $0.phoneTimestamp < $1.phoneTimestamp }
        duplicates.sort { $0.uuidString < $1.uuidString }
        alreadyApplied.sort { $0.uuidString < $1.uuidString }
        superseded.sort { $0.uuidString < $1.uuidString }
        rejected.sort { ($0.changeID?.uuidString ?? "") < ($1.changeID?.uuidString ?? "") }
        return MobileChangeImportPreview(
            applicable: applicable, conflicts: conflicts, duplicates: duplicates,
            rejected: rejected, alreadyApplied: alreadyApplied, superseded: superseded, libraryID: expectedLibraryID,
            baseSnapshotID: base.snapshotID, sourcePackageID: effectivePackageID,
            sourceFingerprint: fingerprint
        )
    }

    /// Production apply entry point. It repeats capability-derived validation
    /// immediately before any typed domain command runs.
    package func apply(
        preview: MobileChangeImportPreview,
        authenticatedReturn: MobileAuthenticatedReturnPackage,
        currentSnapshot: MobileLibrarySnapshot,
        resolutions: [UUID: MobileChangeResolution],
        confirmed: Bool
    ) async throws -> MobileChangeApplicationReceipt {
        let envelope = MobilePackageEnvelope(
            purpose: .returnChanges,
            snapshot: authenticatedReturn.baseSnapshot,
            baseSnapshotID: authenticatedReturn.baseSnapshotID,
            changes: authenticatedReturn.changes,
            acknowledgedChangeIDs: []
        )
        guard preview.sourcePackageID == authenticatedReturn.packageID else {
            throw MobileChangeImportError.stalePreview
        }
        return try await apply(
            preview: preview,
            envelope: envelope,
            currentSnapshot: currentSnapshot,
            resolutions: resolutions,
            confirmed: confirmed
        )
    }

    /// Test-only raw seam. Production callers must use
    /// `apply(authenticatedReturn:...)`.
    func apply(
        preview: MobileChangeImportPreview,
        envelope: MobilePackageEnvelope,
        currentSnapshot: MobileLibrarySnapshot,
        resolutions: [UUID: MobileChangeResolution],
        confirmed: Bool
    ) async throws -> MobileChangeApplicationReceipt {
        guard confirmed else { throw MobileChangeImportError.finalConfirmationRequired }
        guard commands.isConfigured, recordStore != nil else { throw MobileChangeImportError.configurationMissing }
        try reloadLedger()
        guard let base = envelope.snapshot,
              envelope.purpose == .returnChanges,
              envelope.baseSnapshotID == base.snapshotID,
              envelope.acknowledgedChangeIDs.isEmpty,
              base.libraryID == currentSnapshot.libraryID,
              preview.libraryID == currentSnapshot.libraryID,
              preview.baseSnapshotID == base.snapshotID,
              preview.sourceFingerprint == Self.fingerprint(envelope) else {
            throw MobileChangeImportError.stalePreview
        }
        let refreshed = try self.preview(envelope: envelope, expectedLibraryID: currentSnapshot.libraryID, expectedBaseSnapshotID: preview.baseSnapshotID, currentSnapshot: currentSnapshot, sourcePackageID: preview.sourcePackageID)
        guard refreshed == preview else { throw MobileChangeImportError.stalePreview }

        let existingAcknowledgements = Set((ledger?.appliedChangeIDs ?? []) + (ledger?.resolvedChangeIDs ?? []))
        for conflict in refreshed.conflicts where resolutions[conflict.changeID] == nil {
            throw MobileChangeImportError.conflictResolutionRequired(conflict.changeID)
        }

        var selected = refreshed.applicable.map { PendingMutation(change: $0, resolution: .applyPhone) }
        var resolved = refreshed.superseded
        for conflict in refreshed.conflicts {
            let resolution = resolutions[conflict.changeID]!
            if resolution == .keepMac {
                resolved.append(conflict.changeID)
            } else {
                guard conflict.kind == .note || resolution != .keepBothAsFieldNote else {
                    throw MobileChangeImportError.invalidResolution(conflict.changeID)
                }
                selected.append(PendingMutation(change: conflict.change, resolution: resolution))
            }
        }
        selected.sort { lhs, rhs in
            lhs.change.mobileCreatedAt == rhs.change.mobileCreatedAt
                ? lhs.change.mobileChangeID.uuidString < rhs.change.mobileChangeID.uuidString
                : lhs.change.mobileCreatedAt < rhs.change.mobileCreatedAt
        }
        resolved = Array(Set(resolved)).sorted { $0.uuidString < $1.uuidString }
        let selectedIDs = Set(selected.map { $0.change.mobileChangeID })
        resolved.removeAll { selectedIDs.contains($0) }
        guard existingAcknowledgements.union(selectedIDs).union(resolved).count <= 10_000 else {
            throw MobileChangeImportError.limitsExceeded
        }

        let batches = try Self.batches(for: selected, snapshot: currentSnapshot)
        // Validate final receipt size before a domain batch mutates its owning
        // store. A receipt write can still fail afterwards, but the target's
        // own atomic mobile IDs make a retry a no-op rather than a duplicate.
        let anticipatedResultingRevisions = Dictionary(uniqueKeysWithValues: batches.flatMap { batch in
            Self.changeIDs(in: batch).map { ($0.uuidString, Self.expectedRevision(after: batch)) }
        })
        let tentative = MobileChangeApplicationLedger(
            libraryID: preview.libraryID,
            records: (ledger?.records ?? []) + [MobileChangeApplicationRecord(
                libraryID: preview.libraryID,
                sourcePackageID: preview.sourcePackageID,
                sourceFingerprint: preview.sourceFingerprint,
                appliedChangeIDs: Array(selectedIDs),
                resolvedChangeIDs: resolved,
                resultingRevisions: anticipatedResultingRevisions
            )],
            appliedChangeIDs: (ledger?.appliedChangeIDs ?? []) + Array(selectedIDs),
            resolvedChangeIDs: (ledger?.resolvedChangeIDs ?? []) + resolved,
            resultingRevisions: (ledger?.resultingRevisions ?? [:]).merging(anticipatedResultingRevisions) { _, new in new }
        )
        guard let encoded = try? MobileJSON.encoder.encode(tentative), encoded.count <= 1_048_576 else {
            throw MobileChangeImportError.limitsExceeded
        }

        var applied: [UUID] = []
        var resulting: [String: Int] = [:]
        do {
            for batch in batches {
                let expectedIDs = Set(Self.changeIDs(in: batch))
                let result = try await commands.applyBatch(batch)
                guard Set(result.appliedChangeIDs).isSuperset(of: expectedIDs) else {
                    throw MobileChangeImportError.commandFailed(expectedIDs.first ?? UUID())
                }
                applied.append(contentsOf: expectedIDs)
                resulting.merge(result.resultingRevisions) { _, new in new }
            }
        } catch let error as MobileChangeImportError {
            if !applied.isEmpty {
                let partial = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resolvedChangeIDs: [], resultingRevisions: resulting)
                throw MobileChangeImportError.partialReceipt(partial)
            }
            throw error
        } catch {
            if !applied.isEmpty {
                let partial = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resolvedChangeIDs: [], resultingRevisions: resulting)
                throw MobileChangeImportError.partialReceipt(partial)
            }
            throw MobileChangeImportError.commandFailed(envelope.changes.first?.mobileChangeID ?? UUID())
        }

        let receipt = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resolvedChangeIDs: resolved, resultingRevisions: resulting)
        do {
            var finalLedger: MobileChangeApplicationLedger?
            try recordStore?.updateLedger { latest in
                let persisted = latest ?? MobileChangeApplicationLedger(libraryID: preview.libraryID)
                guard persisted.libraryID == preview.libraryID else { throw MobileChangeImportError.receiptFailed }
                let next = MobileChangeApplicationLedger(
                    libraryID: preview.libraryID,
                    records: persisted.records.filter { $0.sourcePackageID != preview.sourcePackageID } + [receipt],
                    appliedChangeIDs: persisted.appliedChangeIDs + applied,
                    resolvedChangeIDs: persisted.resolvedChangeIDs + resolved,
                    resultingRevisions: persisted.resultingRevisions.merging(resulting) { _, new in new }
                )
                guard let encoded = try? MobileJSON.encoder.encode(next), encoded.count <= 1_048_576 else {
                    throw MobileChangeImportError.limitsExceeded
                }
                finalLedger = next
                return next
            }
            ledger = finalLedger
        } catch {
            // Domain records already carry their own idempotency marker. The
            // caller gets an honest partial receipt and can safely retry.
            guard !applied.isEmpty else { throw MobileChangeImportError.receiptFailed }
            throw MobileChangeImportError.partialReceipt(MobileChangeApplicationRecord(
                libraryID: receipt.libraryID,
                sourcePackageID: receipt.sourcePackageID,
                sourceFingerprint: receipt.sourceFingerprint,
                appliedChangeIDs: receipt.appliedChangeIDs,
                resolvedChangeIDs: [],
                resultingRevisions: receipt.resultingRevisions,
                recordedAt: receipt.recordedAt
            ))
        }
        return receipt
    }

    private func reloadLedger() throws {
        guard let recordStore else { return }
        do {
            let loaded = try recordStore.load()
            if let loaded, loaded.schemaVersion != MobileChangeApplicationLedger.currentSchemaVersion {
                throw MobileChangeImportError.receiptFailed
            }
            ledger = loaded
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    private struct PendingMutation: Sendable {
        let change: MobileChange
        let resolution: MobileChangeResolution
    }

    private static func batches(for selected: [PendingMutation], snapshot: MobileLibrarySnapshot) throws -> [MobileChangeDomainBatch] {
        enum Owner: Hashable { case briefing(UUID); case project(UUID) }
        var briefingMutations: [UUID: [MobileBriefingBatchMutation]] = [:]
        var projectMutations: [UUID: [(MobileNoteRevisionCommand, MobileNoteBatchMutationMode)]] = [:]
        // A batch is atomic per owner, so global chronology is represented by
        // each owner's *last effective* phone change.  For A1, B1, A2 this
        // correctly executes B before A (rather than preserving A's first
        // appearance), while still keeping A1/A2 in one revision.
        var ownerLastEffectiveChange: [Owner: MobileChange] = [:]
        for pending in selected {
            switch pending.change {
            case .checklistCompletion(let value):
                guard let briefing = snapshot.briefings.first(where: { $0.id == value.briefingID }) else { throw MobileChangeImportError.stalePreview }
                ownerLastEffectiveChange[.briefing(value.briefingID)] = pending.change
                briefingMutations[value.briefingID, default: []].append(.checklist(.init(changeID: value.changeID, deviceID: value.deviceID, briefingID: value.briefingID, itemID: value.itemID, phoneBaseRevision: value.baseRevision, isCompleted: value.isCompleted, expectedRevision: briefing.revision, resultingRevision: briefing.revision + 1, createdAt: value.createdAt)))
            case .noteRevision(let value):
                guard let note = snapshot.notes.first(where: { $0.id == value.noteID }) else { throw MobileChangeImportError.stalePreview }
                let mode: MobileNoteBatchMutationMode = pending.resolution == .keepBothAsFieldNote ? .appendFieldNote : .replace
                if note.scope == .briefing {
                    guard let briefingID = UUID(uuidString: note.ownerID), let briefing = snapshot.briefings.first(where: { $0.id == briefingID }) else { throw MobileChangeImportError.stalePreview }
                    ownerLastEffectiveChange[.briefing(briefingID)] = pending.change
                    briefingMutations[briefingID, default: []].append(.note(.init(changeID: value.changeID, deviceID: value.deviceID, noteID: value.noteID, ownerID: value.ownerID, phoneBaseRevision: value.baseRevision, text: value.text, expectedRevision: briefing.revision, resultingRevision: briefing.revision + 1, createdAt: value.createdAt), mode))
                } else if note.scope == .project, let projectID = UUID(uuidString: note.ownerID) {
                    ownerLastEffectiveChange[.project(projectID)] = pending.change
                    projectMutations[projectID, default: []].append((.init(changeID: value.changeID, deviceID: value.deviceID, noteID: value.noteID, ownerID: value.ownerID, phoneBaseRevision: value.baseRevision, text: value.text, expectedRevision: note.baseRevision, resultingRevision: note.baseRevision + 1, createdAt: value.createdAt), mode))
                } else { throw MobileChangeImportError.stalePreview }
            }
        }
        var batches: [MobileChangeDomainBatch] = []
        let ownerOrder = ownerLastEffectiveChange.keys.sorted { lhs, rhs in
            guard let left = ownerLastEffectiveChange[lhs], let right = ownerLastEffectiveChange[rhs] else { return false }
            if left.mobileCreatedAt != right.mobileCreatedAt { return left.mobileCreatedAt < right.mobileCreatedAt }
            if left.mobileChangeID != right.mobileChangeID { return left.mobileChangeID.uuidString < right.mobileChangeID.uuidString }
            return Self.ownerSortKey(lhs) < Self.ownerSortKey(rhs)
        }
        for owner in ownerOrder {
            switch owner {
            case .briefing(let id):
                guard let briefing = snapshot.briefings.first(where: { $0.id == id }), let mutations = briefingMutations[id] else { throw MobileChangeImportError.stalePreview }
                batches.append(.briefing(.init(briefingID: id, expectedRevision: briefing.revision, mutations: mutations)))
            case .project(let id):
                guard let note = snapshot.notes.first(where: { $0.scope == .project && UUID(uuidString: $0.ownerID) == id }), let mutations = projectMutations[id] else { throw MobileChangeImportError.stalePreview }
                batches.append(.projectAnnotation(.init(projectID: id, expectedRevision: note.baseRevision, mutations: mutations)))
            }
        }
        return batches
    }

    private static func ownerSortKey(_ owner: Any) -> String {
        String(describing: owner)
    }

    private static func changeIDs(in batch: MobileChangeDomainBatch) -> [UUID] {
        switch batch {
        case .briefing(let batch):
            return batch.mutations.map { mutation in
                switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
            }
        case .projectAnnotation(let batch): return batch.mutations.map { $0.0.changeID }
        }
    }

    private static func expectedRevision(after batch: MobileChangeDomainBatch) -> Int {
        switch batch {
        case .briefing(let batch): return batch.expectedRevision + 1
        case .projectAnnotation(let batch): return batch.expectedRevision + 1
        }
    }

    private static func isValid(change: MobileChange, maxTextBytes: Int) -> Bool {
        switch change {
        case .checklistCompletion(let value):
            return value.baseRevision >= 0 && !value.itemID.isEmpty && value.itemID.utf8.count <= maxTextBytes && value.createdAt.timeIntervalSince1970.isFinite
        case .noteRevision(let value):
            return value.baseRevision >= 0 && !value.noteID.isEmpty && !value.ownerID.isEmpty && value.noteID.utf8.count <= maxTextBytes && value.ownerID.utf8.count <= maxTextBytes && value.text.utf8.count <= maxTextBytes && value.createdAt.timeIntervalSince1970.isFinite
        }
    }

    private func validateLedger(expectedLibraryID: PortableLibraryID) throws {
        guard let ledger else { return }
        let applied = Set(ledger.appliedChangeIDs)
        let resolved = Set(ledger.resolvedChangeIDs)
        let recordPackageIDs = ledger.records.map(\.sourcePackageID)
        guard ledger.schemaVersion == MobileChangeApplicationLedger.currentSchemaVersion,
              ledger.libraryID == expectedLibraryID,
              applied.count == ledger.appliedChangeIDs.count,
              resolved.count == ledger.resolvedChangeIDs.count,
              applied.isDisjoint(with: resolved),
              applied.union(resolved).count <= 10_000,
              ledger.records.count <= 256,
              Set(recordPackageIDs).count == recordPackageIDs.count,
              Self.validRevisionMap(ledger.resultingRevisions, allowedIDs: applied),
              ledger.records.allSatisfy({ record in
                  let recordApplied = Set(record.appliedChangeIDs)
                  let recordResolved = Set(record.resolvedChangeIDs)
                  return record.schemaVersion == MobileChangeApplicationRecord.currentSchemaVersion
                      && record.libraryID == expectedLibraryID
                      && !record.sourceFingerprint.isEmpty
                      && recordApplied.count == record.appliedChangeIDs.count
                      && recordResolved.count == record.resolvedChangeIDs.count
                      && recordApplied.isDisjoint(with: recordResolved)
                      && recordApplied.isSubset(of: applied)
                      && recordResolved.isSubset(of: resolved)
                      && Self.validRevisionMap(record.resultingRevisions, allowedIDs: recordApplied)
              })
        else { throw MobileChangeImportError.receiptFailed }
    }

    private static func validRevisionMap(_ values: [String: Int], allowedIDs: Set<UUID>) -> Bool {
        values.allSatisfy { key, revision in
            guard let id = UUID(uuidString: key) else { return false }
            return allowedIDs.contains(id) && revision >= 0 && revision <= 1_000_000_000
        }
    }

    private static func revisions(in snapshot: MobileLibrarySnapshot) -> [String: Int] {
        var values: [String: Int] = [:]
        for briefing in snapshot.briefings {
            for item in briefing.checklist.flatMap(\.items) { values["checklist:\(briefing.id.uuidString):\(item.id)"] = item.baseRevision }
        }
        for note in snapshot.notes { values["note:\(note.id)"] = note.baseRevision }
        return values
    }

    private static func fingerprint(_ envelope: MobilePackageEnvelope) -> String {
        guard let data = try? MobileJSON.encoder.encode(envelope) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension MobileChange {
    var mobileChangeID: UUID {
        switch self {
        case .checklistCompletion(let value): value.changeID
        case .noteRevision(let value): value.changeID
        }
    }

    var mobileDeviceID: UUID {
        switch self {
        case .checklistCompletion(let value): value.deviceID
        case .noteRevision(let value): value.deviceID
        }
    }

    var mobileCreatedAt: Date {
        switch self {
        case .checklistCompletion(let value): value.createdAt
        case .noteRevision(let value): value.createdAt
        }
    }

    var mobileTargetKey: String {
        switch self {
        case .checklistCompletion(let value): "checklist:\(value.briefingID.uuidString):\(value.itemID)"
        case .noteRevision(let value): "note:\(value.noteID)"
        }
    }
}
