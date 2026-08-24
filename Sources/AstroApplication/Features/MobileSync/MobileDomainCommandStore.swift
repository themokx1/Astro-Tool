import Foundation
import Darwin
import AstroMobileDomain

/// The production bridge for the three deliberately narrow mobile domains.
/// Every mutation is keyed by the phone change ID and written atomically, so
/// a command retry after a receipt interruption is a no-op for that change.
/// Internal fixture seam; the public application cannot obtain mutation
/// commands from it. Real return application is built by
/// `MobileChangeImporter.production` below.
final class MobileDomainCommandStore: @unchecked Sendable {
    private struct ChecklistValue: Codable, Sendable {
        var revision: Int
        var isCompleted: Bool
        var changeIDs: [UUID]
    }
    private struct NoteValue: Codable, Sendable {
        var revision: Int
        var text: String
        var changeIDs: [UUID]
    }
    private struct FieldNoteValue: Codable, Sendable {
        let changeID: UUID
        let noteID: String
        let ownerID: String
        let text: String
        let createdAt: Date
    }
    private struct State: Codable, Sendable {
        var schemaVersion: Int = 1
        var checklist: [String: ChecklistValue] = [:]
        var notes: [String: NoteValue] = [:]
        var fieldNotes: [FieldNoteValue] = []
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var state: State

    init(rootURL: URL) throws {
        let directory = rootURL.appendingPathComponent(".astro-tool", isDirectory: true)
        fileURL = directory.appendingPathComponent("mobile-domain-commands.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                state = try MobileJSON.decoder.decode(State.self, from: Data(contentsOf: fileURL))
                guard state.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            } catch let error as MobileChangeImportError {
                throw error
            } catch {
                throw MobileChangeImportError.receiptFailed
            }
        } else {
            state = State()
        }
    }

    func commands() -> MobileChangeCommands {
        .init(applyBatch: { [self] batch in try apply(batch) })
    }

    private func apply(_ batch: MobileChangeDomainBatch) throws -> MobileChangeDomainBatchResult {
        switch batch {
        case .briefing(let batch):
            var revisions: [String: Int] = [:]
            var ids: [UUID] = []
            for mutation in batch.mutations {
                switch mutation {
                case .checklist(let command):
                    guard let revision = try saveChecklist(command) else { throw MobileChangeImportError.commandFailed(command.changeID) }
                    ids.append(command.changeID); revisions[command.changeID.uuidString] = revision
                case .note(let command, let mode):
                    let revision: Int?
                    switch mode {
                    case .replace: revision = try saveNote(command)
                    case .appendFieldNote: revision = try addFieldNote(.init(changeID: command.changeID, noteID: command.noteID, ownerID: command.ownerID, text: command.text, createdAt: command.createdAt))
                    }
                    ids.append(command.changeID); revisions[command.changeID.uuidString] = revision ?? batch.expectedRevision + 1
                }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: revisions)
        case .projectAnnotation(let batch):
            var revisions: [String: Int] = [:]
            var ids: [UUID] = []
            for (command, mode) in batch.mutations {
                let revision: Int?
                switch mode {
                case .replace: revision = try saveNote(command)
                case .appendFieldNote: revision = try addFieldNote(.init(changeID: command.changeID, noteID: command.noteID, ownerID: command.ownerID, text: command.text, createdAt: command.createdAt))
                }
                ids.append(command.changeID); revisions[command.changeID.uuidString] = revision ?? batch.expectedRevision + 1
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: revisions)
        }
    }

    private func saveChecklist(_ command: MobileChecklistRevisionCommand) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(command.briefingID.uuidString):\(command.itemID)"
        if let existing = state.checklist[key], existing.changeIDs.contains(command.changeID) { return existing.revision }
        var value = state.checklist[key] ?? .init(revision: command.expectedRevision, isCompleted: false, changeIDs: [])
        guard value.revision == command.expectedRevision else { throw MobileChangeImportError.commandFailed(command.changeID) }
        value.revision = command.resultingRevision
        value.isCompleted = command.isCompleted
        value.changeIDs.append(command.changeID)
        var proposed = state
        proposed.checklist[key] = value
        try persist(proposed)
        state = proposed
        return value.revision
    }

    private func saveNote(_ command: MobileNoteRevisionCommand) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let existing = state.notes[command.noteID], existing.changeIDs.contains(command.changeID) { return existing.revision }
        var value = state.notes[command.noteID] ?? .init(revision: command.expectedRevision, text: "", changeIDs: [])
        guard value.revision == command.expectedRevision else { throw MobileChangeImportError.commandFailed(command.changeID) }
        value.revision = command.resultingRevision
        value.text = command.text
        value.changeIDs.append(command.changeID)
        var proposed = state
        proposed.notes[command.noteID] = value
        try persist(proposed)
        state = proposed
        return value.revision
    }

    private func addFieldNote(_ command: MobileFieldNoteCommand) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !state.fieldNotes.contains(where: { $0.changeID == command.changeID }) else { return nil }
        var proposed = state
        proposed.fieldNotes.append(.init(changeID: command.changeID, noteID: command.noteID, ownerID: command.ownerID, text: command.text, createdAt: command.createdAt))
        try persist(proposed)
        state = proposed
        return nil
    }

    private func persist(_ value: State) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try MobileJSON.encoder.encode(value)
            guard data.count <= 1_048_576 else { throw MobileChangeImportError.limitsExceeded }
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }
}

extension MobileChangeCommands {
    static func production(rootURL: URL) throws -> MobileChangeCommands {
        let paths = try AppStoragePaths.production(
            libraryID: LibraryIdentity(rootURL: rootURL),
            libraryRoot: rootURL
        )
        let metadataStore = try MetadataStore(storagePaths: paths)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let bridge = try MobileMacDomainCommandBridge(rootURL: rootURL, metadataStore: metadataStore, briefingStore: briefingStore)
        return .init(applyBatch: { batch in try await bridge.apply(batch) })
    }
}

/// Production commands write the same stores read by
/// `MobileSyncStore.metadataSnapshotProvider`: briefing revisions and the
/// metadata project's annotation table. The JSON helper above remains a
/// fixture seam only; it is never selected by the production factory.
private actor MobileMacDomainCommandBridge {
    private let metadataStore: MetadataStore
    private let briefingStore: NightBriefingRevisionStore
    private let rootLockURL: URL

    init(rootURL: URL, metadataStore: MetadataStore, briefingStore: NightBriefingRevisionStore) throws {
        self.metadataStore = metadataStore
        self.briefingStore = briefingStore
        self.rootLockURL = rootURL.appendingPathComponent(".astro-tool/mobile-domain-authority.lock")
    }

    func apply(_ batch: MobileChangeDomainBatch) async throws -> MobileChangeDomainBatchResult {
        try await withRootMutationLock {
            try await validateGlobalMarkers(for: batch)
            switch batch {
            case .briefing(let briefing): return try await apply(briefing)
            case .projectAnnotation(let project): return try await metadataStore.applyMobileProjectAnnotationBatch(project)
            }
        }
    }

    private func apply(_ batch: MobileBriefingChangeBatch) async throws -> MobileChangeDomainBatchResult {
        let requestedIDs = batch.mutations.map { mutation in
            switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
        }
        guard Set(requestedIDs).count == requestedIDs.count,
              var draft = try await briefingStore.latest(id: batch.briefingID) else {
            throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
        }
        let existingIDs = Set(draft.mobileChangeIDs)
        let ownerID = "briefing:\(batch.briefingID.uuidString.lowercased())"
        let requestedMarkers = batch.mutations.map {
            Self.marker(for: $0, ownerID: ownerID, resultingRevision: batch.expectedRevision + 1)
        }
        let existingMarkers = try Self.validatedMarkers(
            draft.mobileChangeMarkers,
            ids: draft.mobileChangeIDs,
            ownerID: ownerID,
            maximumRevision: draft.revision
        )
        guard requestedMarkers.allSatisfy({ marker in
                  existingMarkers[marker.changeID].map { $0.ownerID == marker.ownerID && $0.payloadFingerprint == marker.payloadFingerprint } ?? true
              })
        else { throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID()) }
        if Set(requestedIDs).isSubset(of: existingIDs) {
            return .init(
                appliedChangeIDs: requestedIDs,
                resultingRevisions: Dictionary(uniqueKeysWithValues: requestedIDs.compactMap { id in
                    existingMarkers[id].map { (id.uuidString, $0.resultingRevision) }
                })
            )
        }
        guard draft.revision == batch.expectedRevision,
              draft.mobileChangeIDs.count + requestedIDs.filter({ !existingIDs.contains($0) }).count <= 10_000 else {
            throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
        }
        var savedAt = draft.savedAt
        for mutation in batch.mutations where !existingIDs.contains(Self.changeID(mutation)) {
            switch mutation {
            case .checklist(let command):
                guard let sectionIndex = draft.checklist.firstIndex(where: { $0.items.contains { $0.id == command.itemID } }),
                      let itemIndex = draft.checklist[sectionIndex].items.firstIndex(where: { $0.id == command.itemID }) else { throw MobileChangeImportError.commandFailed(command.changeID) }
                draft.checklist[sectionIndex].items[itemIndex].isCompleted = command.isCompleted
                savedAt = max(savedAt, command.createdAt)
            case .note(let command, let mode):
                switch mode {
                case .replace: draft.notes = command.text
                case .appendFieldNote:
                    draft.notes += "\n\n— Phone field note —\n" + command.createdAt.formatted(date: .abbreviated, time: .shortened) + "\n" + command.text
                }
                savedAt = max(savedAt, command.createdAt)
            }
        }
        // Per-mutation text is already bounded by `Limits.maxTextBytes`, but
        // `.appendFieldNote` accumulates onto `draft.notes` across up to
        // 10,000 phone changes, so the resulting string needs its own cap.
        // This must run before any durable write below.
        guard draft.notes.utf8.count <= MobileChangeImporter.Limits.maxAccumulatedNotesBytes else {
            throw MobileChangeImportError.limitsExceeded
        }
        draft.savedAt = savedAt
        draft.mobileChangeIDs = Array(existingIDs.union(requestedIDs)).sorted { $0.uuidString < $1.uuidString }
        draft.mobileChangeMarkers += requestedMarkers.filter { existingMarkers[$0.changeID] == nil }
        do {
            let saved = try await briefingStore.saveIfLatestRecordingMobileEvidence(draft, expectedRevision: batch.expectedRevision)
            return .init(appliedChangeIDs: requestedIDs, resultingRevisions: Dictionary(uniqueKeysWithValues: requestedIDs.map { ($0.uuidString, saved.revision) }))
        } catch NightBriefingRevisionStoreError.revisionAlreadyExists {
            // A second sync window may have won the filename race after this
            // bridge read the draft. Re-read once: an identical return batch
            // is an idempotent success, while any other concurrent Mac edit
            // remains a compare-and-set failure.
            guard let latest = try await briefingStore.latest(id: batch.briefingID) else {
                throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
            }
            let latestMarkers = try Self.validatedMarkers(
                latest.mobileChangeMarkers,
                ids: latest.mobileChangeIDs,
                ownerID: ownerID,
                maximumRevision: latest.revision
            )
            guard requestedMarkers.allSatisfy({ marker in
                latestMarkers[marker.changeID].map {
                    $0.ownerID == marker.ownerID && $0.payloadFingerprint == marker.payloadFingerprint
                } ?? false
            }) else {
                throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
            }
            return .init(
                appliedChangeIDs: requestedIDs,
                resultingRevisions: Dictionary(uniqueKeysWithValues: requestedIDs.compactMap { id in
                    latestMarkers[id].map { (id.uuidString, $0.resultingRevision) }
                })
            )
        }
    }

    private static func changeID(_ mutation: MobileBriefingBatchMutation) -> UUID {
        switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
    }

    private func validateGlobalMarkers(for batch: MobileChangeDomainBatch) async throws {
        let requested: [MobileChangeMarker]
        switch batch {
        case .briefing(let briefing):
            let ownerID = "briefing:\(briefing.briefingID.uuidString.lowercased())"
            requested = briefing.mutations.map { Self.marker(for: $0, ownerID: ownerID, resultingRevision: briefing.expectedRevision + 1) }
        case .projectAnnotation(let project):
            let ownerID = "project:\(project.projectID.uuidString.lowercased())"
            requested = project.mutations.map { command, mode in
                Self.marker(for: command, mode: mode, ownerID: ownerID, resultingRevision: project.expectedRevision + 1)
            }
        }
        let briefs = try await briefingStore.latestRevisions()
        var briefingMarkers: [MobileChangeMarker] = []
        for draft in briefs {
            let ownerID = "briefing:\(draft.id.uuidString.lowercased())"
            let markers = try Self.validatedMarkers(
                draft.mobileChangeMarkers,
                ids: draft.mobileChangeIDs,
                ownerID: ownerID,
                maximumRevision: draft.revision
            )
            briefingMarkers.append(contentsOf: markers.values)
        }
        let projectMarkers = try await metadataStore.allProjectAnnotationMarkers()
        let all = briefingMarkers + projectMarkers
        guard Dictionary(grouping: all, by: \.changeID).values.allSatisfy({ $0.count == 1 }) else {
            throw MobileChangeImportError.corruptDomainMarkers
        }
        for marker in requested {
            let matches = all.filter { $0.changeID == marker.changeID }
            guard matches.allSatisfy({ $0.ownerID == marker.ownerID && $0.payloadFingerprint == marker.payloadFingerprint }) else {
                throw MobileChangeImportError.commandFailed(marker.changeID)
            }
        }
    }

    private static func marker(for mutation: MobileBriefingBatchMutation, ownerID: String, resultingRevision: Int) -> MobileChangeMarker {
        let changeID = changeID(mutation)
        let fingerprint: String
        switch mutation {
        case .checklist(let command): fingerprint = MobileChangeMarkerFingerprint.checklist(command)
        case .note(let command, let mode): fingerprint = MobileChangeMarkerFingerprint.note(command, mode: mode)
        }
        return MobileChangeMarker(
            changeID: changeID,
            ownerID: ownerID,
            payloadFingerprint: fingerprint,
            resultingRevision: resultingRevision
        )
    }

    private static func marker(for command: MobileNoteRevisionCommand, mode: MobileNoteBatchMutationMode, ownerID: String, resultingRevision: Int) -> MobileChangeMarker {
        return MobileChangeMarker(
            changeID: command.changeID,
            ownerID: ownerID,
            payloadFingerprint: MobileChangeMarkerFingerprint.note(command, mode: mode),
            resultingRevision: resultingRevision
        )
    }

    private static func validatedMarkers(
        _ markers: [MobileChangeMarker],
        ids: [UUID],
        ownerID: String,
        maximumRevision: Int
    ) throws -> [UUID: MobileChangeMarker] {
        let markerIDs = markers.map(\.changeID)
        guard Set(ids).count == ids.count,
              Set(markerIDs).count == markerIDs.count,
              Set(ids) == Set(markerIDs),
              markers.allSatisfy({
                  $0.ownerID == ownerID
                      && $0.payloadFingerprint.count == 64
                      && $0.payloadFingerprint.allSatisfy(\.isHexDigit)
                      && $0.resultingRevision >= 0
                      && $0.resultingRevision <= maximumRevision
              }) else {
            throw MobileChangeImportError.corruptDomainMarkers
        }
        return Dictionary(markers.map { ($0.changeID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func withRootMutationLock<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            try FileManager.default.createDirectory(
                at: rootLockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
        let descriptor = Darwin.open(rootLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MobileChangeImportError.receiptFailed }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw MobileChangeImportError.receiptFailed
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try await operation()
    }
}
