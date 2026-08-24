import CryptoKit
import Foundation
import AstroMobileDomain

/// The only commands the Mac return importer may call.  The closures are
/// intentionally typed to the two editable mobile domains; only these
/// allowlisted records can cross the boundary.
public struct MobileChangeCommands: Sendable {
    public typealias SaveChecklist = @Sendable (MobileChecklistRevisionCommand) throws -> Int?
    public typealias SaveNote = @Sendable (MobileNoteRevisionCommand) throws -> Int?
    public typealias AddFieldNote = @Sendable (MobileFieldNoteCommand) throws -> Int?

    public let saveChecklist: SaveChecklist
    public let saveNote: SaveNote
    public let addFieldNote: AddFieldNote
    fileprivate let isConfigured: Bool

    public init(
        saveChecklist: SaveChecklist? = nil,
        saveNote: SaveNote? = nil,
        addFieldNote: AddFieldNote? = nil
    ) {
        self.isConfigured = saveChecklist != nil && saveNote != nil && addFieldNote != nil
        self.saveChecklist = saveChecklist ?? { _ in throw MobileChangeImportError.configurationMissing }
        self.saveNote = saveNote ?? { _ in throw MobileChangeImportError.configurationMissing }
        self.addFieldNote = addFieldNote ?? { _ in throw MobileChangeImportError.configurationMissing }
    }
}

public struct MobileChecklistRevisionCommand: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let briefingID: UUID
    public let itemID: String
    public let isCompleted: Bool
    public let expectedRevision: Int
    public let resultingRevision: Int

    public init(changeID: UUID, briefingID: UUID, itemID: String, isCompleted: Bool, expectedRevision: Int, resultingRevision: Int) {
        self.changeID = changeID
        self.briefingID = briefingID
        self.itemID = itemID
        self.isCompleted = isCompleted
        self.expectedRevision = expectedRevision
        self.resultingRevision = resultingRevision
    }
}

public struct MobileNoteRevisionCommand: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let noteID: String
    public let ownerID: String
    public let text: String
    public let expectedRevision: Int
    public let resultingRevision: Int
    public let createdAt: Date

    public init(changeID: UUID, noteID: String, ownerID: String, text: String, expectedRevision: Int, resultingRevision: Int, createdAt: Date) {
        self.changeID = changeID
        self.noteID = noteID
        self.ownerID = ownerID
        self.text = text
        self.expectedRevision = expectedRevision
        self.resultingRevision = resultingRevision
        self.createdAt = createdAt
    }
}

public struct MobileFieldNoteCommand: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let noteID: String
    public let ownerID: String
    public let text: String
    public let createdAt: Date

    public init(changeID: UUID, noteID: String, ownerID: String, text: String, createdAt: Date) {
        self.changeID = changeID
        self.noteID = noteID
        self.ownerID = ownerID
        self.text = text
        self.createdAt = createdAt
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

/// A bounded, app-owned record.  It contains no secrets and is the durable
/// idempotency key for a return package after relaunch.
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
        self.appliedChangeIDs = appliedChangeIDs.sorted { $0.uuidString < $1.uuidString }
        self.resolvedChangeIDs = resolvedChangeIDs.sorted { $0.uuidString < $1.uuidString }
        self.resultingRevisions = resultingRevisions
        self.recordedAt = recordedAt
    }
}

public typealias MobileChangeApplicationReceipt = MobileChangeApplicationRecord

public struct MobileChangeApplicationLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let libraryID: PortableLibraryID
    public let records: [MobileChangeApplicationRecord]
    public let appliedChangeIDs: [UUID]
    public let resolvedChangeIDs: [UUID]
    public let resultingRevisions: [String: Int]

    public init(libraryID: PortableLibraryID, records: [MobileChangeApplicationRecord] = [], appliedChangeIDs: [UUID] = [], resolvedChangeIDs: [UUID] = [], resultingRevisions: [String: Int] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.libraryID = libraryID
        self.records = records
        self.appliedChangeIDs = Array(Set(appliedChangeIDs)).sorted { $0.uuidString < $1.uuidString }
        self.resolvedChangeIDs = Array(Set(resolvedChangeIDs)).sorted { $0.uuidString < $1.uuidString }
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
    case partialReceipt(MobileChangeApplicationReceipt)
    case receiptFailed
}

public protocol MobileChangeApplicationRecordStore: Sendable {
    func load() throws -> MobileChangeApplicationLedger?
    func save(_ ledger: MobileChangeApplicationLedger) throws
}

private final class MobileChangeInMemoryRecordStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MobileChangeApplicationLedger?
    func load() throws -> MobileChangeApplicationLedger? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ ledger: MobileChangeApplicationLedger) throws { lock.lock(); value = ledger; lock.unlock() }
}

public final class MobileChangeImporter: @unchecked Sendable {
    public struct Limits: Equatable, Sendable {
        public let maxChanges: Int
        public let maxTextBytes: Int
        public init(maxChanges: Int = 10_000, maxTextBytes: Int = 256 * 1024) {
            self.maxChanges = maxChanges
            self.maxTextBytes = maxTextBytes
        }
    }

    private let commands: MobileChangeCommands
    private let limits: Limits
    private let recordStore: MobileChangeApplicationRecordStore?
    private var ledger: MobileChangeApplicationLedger?
    private let ledgerLoadFailed: Bool

    public var acknowledgementIDs: [UUID] {
        (ledger?.appliedChangeIDs ?? []) + (ledger?.resolvedChangeIDs ?? [])
    }

    public init(
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

    public func preview(
        envelope: MobilePackageEnvelope,
        expectedLibraryID: PortableLibraryID,
        expectedBaseSnapshotID: UUID? = nil,
        currentSnapshot: MobileLibrarySnapshot,
        sourcePackageID: UUID,
        appliedChangeIDs: Set<UUID> = []
    ) throws -> MobileChangeImportPreview {
        guard !ledgerLoadFailed else { throw MobileChangeImportError.receiptFailed }
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

        for change in envelope.changes {
            let id = change.mobileChangeID
            guard seen.insert(id).inserted else { duplicates.append(id); continue }
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

        let allCandidates = applicable + conflicts.map(\.change)
        var latestByTarget: [String: (MobileChange, Bool)] = [:]
        for candidate in allCandidates {
            let key = candidate.mobileTargetKey
            let isConflict = conflicts.contains { $0.changeID == candidate.mobileChangeID }
            if let existing = latestByTarget[key] {
                let newer = candidate.mobileCreatedAt > existing.0.mobileCreatedAt || (candidate.mobileCreatedAt == existing.0.mobileCreatedAt && candidate.mobileChangeID.uuidString > existing.0.mobileChangeID.uuidString)
                if newer { superseded.append(existing.0.mobileChangeID); latestByTarget[key] = (candidate, isConflict) }
                else { superseded.append(candidate.mobileChangeID) }
            } else { latestByTarget[key] = (candidate, isConflict) }
        }
        let chosenIDs = Set(latestByTarget.values.map { $0.0.mobileChangeID })
        applicable = applicable.filter { chosenIDs.contains($0.mobileChangeID) }
        conflicts = conflicts.filter { chosenIDs.contains($0.changeID) }
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

    public func apply(
        preview: MobileChangeImportPreview,
        envelope: MobilePackageEnvelope,
        currentSnapshot: MobileLibrarySnapshot,
        resolutions: [UUID: MobileChangeResolution],
        confirmed: Bool
    ) throws -> MobileChangeApplicationReceipt {
        guard confirmed else { throw MobileChangeImportError.finalConfirmationRequired }
        guard commands.isConfigured, recordStore != nil else { throw MobileChangeImportError.configurationMissing }
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

        let applicable = refreshed.applicable
        let conflicts = refreshed.conflicts
        for conflict in conflicts where resolutions[conflict.changeID] == nil {
            throw MobileChangeImportError.conflictResolutionRequired(conflict.changeID)
        }

        var applied: [UUID] = []
        var resolved: [UUID] = []
        var resulting: [String: Int] = [:]
        var skipped: [UUID] = []
        var currentRevisionByTarget = Self.revisions(in: currentSnapshot)

        func persist(_ id: UUID, resultingRevision: Int) throws {
            applied.append(id)
            resulting[id.uuidString] = resultingRevision
            let next = MobileChangeApplicationRecord(
                libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID,
                sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied,
                resolvedChangeIDs: resolved, resultingRevisions: resulting
            )
            do {
                let prior = ledger
                let nextLedger = MobileChangeApplicationLedger(
                    libraryID: preview.libraryID,
                    records: (prior?.records ?? []).filter { $0.sourcePackageID != preview.sourcePackageID } + [next],
                    appliedChangeIDs: (prior?.appliedChangeIDs ?? []) + applied,
                    resolvedChangeIDs: (prior?.resolvedChangeIDs ?? []) + resolved,
                    resultingRevisions: (prior?.resultingRevisions ?? [:]).merging(resulting) { _, new in new }
                )
                try recordStore?.save(nextLedger)
                ledger = nextLedger
            } catch {
                throw MobileChangeImportError.receiptFailed
            }
        }

        do {
            for change in applicable {
                try apply(change, resolution: .applyPhone, currentRevisionByTarget: &currentRevisionByTarget, persist: persist)
            }
            for conflict in conflicts {
                let resolution = resolutions[conflict.changeID]!
                switch resolution {
                case .keepMac:
                    skipped.append(conflict.changeID)
                    resolved.append(conflict.changeID)
                case .applyPhone, .keepBothAsFieldNote:
                    guard conflict.kind == .note || resolution != .keepBothAsFieldNote else { throw MobileChangeImportError.invalidResolution(conflict.changeID) }
                    try apply(conflict.change, resolution: resolution, currentRevisionByTarget: &currentRevisionByTarget, persist: persist)
                }
            }
        } catch let error as MobileChangeImportError {
            if case .partialReceipt = error { throw error }
            if case .receiptFailed = error { throw error }
            if !applied.isEmpty {
                let partial = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resultingRevisions: resulting)
                throw MobileChangeImportError.partialReceipt(partial)
            }
            throw error
        } catch {
            if !applied.isEmpty {
                let partial = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resultingRevisions: resulting)
                throw MobileChangeImportError.partialReceipt(partial)
            }
            throw MobileChangeImportError.commandFailed(envelope.changes.first?.mobileChangeID ?? UUID())
        }

        for id in refreshed.superseded where !applied.contains(id) && !resolved.contains(id) {
            applied.append(id)
            resulting[id.uuidString] = currentRevisionByTarget.values.max() ?? 0
        }
        if !refreshed.superseded.isEmpty || !resolved.isEmpty {
            let final = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resolvedChangeIDs: resolved, resultingRevisions: resulting)
            let prior = ledger
            let finalLedger = MobileChangeApplicationLedger(libraryID: preview.libraryID, records: (prior?.records ?? []).filter { $0.sourcePackageID != preview.sourcePackageID } + [final], appliedChangeIDs: (prior?.appliedChangeIDs ?? []) + applied, resolvedChangeIDs: (prior?.resolvedChangeIDs ?? []) + resolved, resultingRevisions: (prior?.resultingRevisions ?? [:]).merging(resulting) { _, new in new })
            do { try recordStore?.save(finalLedger); ledger = finalLedger } catch { throw MobileChangeImportError.receiptFailed }
        }

        let receipt = MobileChangeApplicationRecord(libraryID: preview.libraryID, sourcePackageID: preview.sourcePackageID, sourceFingerprint: preview.sourceFingerprint, appliedChangeIDs: applied, resolvedChangeIDs: resolved, resultingRevisions: resulting)
        return receipt
    }

    private func apply(
        _ change: MobileChange,
        resolution: MobileChangeResolution,
        currentRevisionByTarget: inout [String: Int],
        persist: (UUID, Int) throws -> Void
    ) throws {
        switch change {
        case .checklistCompletion(let value):
            guard resolution != .keepBothAsFieldNote else { throw MobileChangeImportError.invalidResolution(value.changeID) }
            let key = "checklist:\(value.briefingID.uuidString):\(value.itemID)"
            let expected = currentRevisionByTarget[key, default: value.baseRevision]
            let next: Int
            do {
                guard let resulting = try commands.saveChecklist(.init(changeID: value.changeID, briefingID: value.briefingID, itemID: value.itemID, isCompleted: value.isCompleted, expectedRevision: expected, resultingRevision: expected + 1)) else {
                    throw MobileChangeImportError.commandFailed(value.changeID)
                }
                next = resulting
            } catch {
                throw MobileChangeImportError.commandFailed(value.changeID)
            }
            currentRevisionByTarget[key] = next
            try persist(value.changeID, next)
        case .noteRevision(let value):
            let key = "note:\(value.noteID)"
            let expected = currentRevisionByTarget[key, default: value.baseRevision]
            switch resolution {
            case .keepMac:
                return
            case .applyPhone:
                let next: Int
                do {
                    guard let resulting = try commands.saveNote(.init(changeID: value.changeID, noteID: value.noteID, ownerID: value.ownerID, text: value.text, expectedRevision: expected, resultingRevision: expected + 1, createdAt: value.createdAt)) else {
                        throw MobileChangeImportError.commandFailed(value.changeID)
                    }
                    next = resulting
                } catch {
                    throw MobileChangeImportError.commandFailed(value.changeID)
                }
                currentRevisionByTarget[key] = next
                try persist(value.changeID, next)
            case .keepBothAsFieldNote:
                do {
                    _ = try commands.addFieldNote(.init(changeID: value.changeID, noteID: value.noteID, ownerID: value.ownerID, text: value.text, createdAt: value.createdAt))
                } catch {
                    throw MobileChangeImportError.commandFailed(value.changeID)
                }
                try persist(value.changeID, expected)
            }
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
