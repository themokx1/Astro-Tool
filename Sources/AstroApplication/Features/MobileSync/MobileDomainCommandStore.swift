import Foundation
import AstroMobileDomain

/// The production bridge for the three deliberately narrow mobile domains.
/// Every mutation is keyed by the phone change ID and written atomically, so
/// a command retry after a receipt interruption is a no-op for that change.
public final class MobileDomainCommandStore: @unchecked Sendable {
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

    public init(rootURL: URL) throws {
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

    public func commands() -> MobileChangeCommands {
        .init(
            saveChecklist: { [self] command in try saveChecklist(command) },
            saveNote: { [self] command in try saveNote(command) },
            addFieldNote: { [self] command in try addFieldNote(command) }
        )
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

public extension MobileChangeCommands {
    static func production(rootURL: URL) throws -> MobileChangeCommands {
        let paths = try AppStoragePaths.production(
            libraryID: LibraryIdentity(rootURL: rootURL),
            libraryRoot: rootURL
        )
        let metadataStore = try MetadataStore(storagePaths: paths)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let bridge = MobileMacDomainCommandBridge(metadataStore: metadataStore, briefingStore: briefingStore)
        return .init(
            saveChecklist: { command in try await bridge.saveChecklist(command) },
            saveNote: { command in try await bridge.saveNote(command) },
            addFieldNote: { command in try await bridge.addFieldNote(command) }
        )
    }
}

/// Production commands write the same stores read by
/// `MobileSyncStore.metadataSnapshotProvider`: briefing revisions and the
/// metadata project's annotation table. The JSON helper above remains a
/// fixture seam only; it is never selected by the production factory.
private final class MobileMacDomainCommandBridge: @unchecked Sendable {
    private let metadataStore: MetadataStore
    private let briefingStore: NightBriefingRevisionStore

    init(metadataStore: MetadataStore, briefingStore: NightBriefingRevisionStore) {
        self.metadataStore = metadataStore
        self.briefingStore = briefingStore
    }

    func saveChecklist(_ command: MobileChecklistRevisionCommand) async throws -> Int? {
        guard var draft = try await briefingStore.latest(id: command.briefingID), draft.revision == command.expectedRevision else {
            throw MobileChangeImportError.commandFailed(command.changeID)
        }
        guard let sectionIndex = draft.checklist.firstIndex(where: { $0.items.contains { $0.id == command.itemID } }),
              let itemIndex = draft.checklist[sectionIndex].items.firstIndex(where: { $0.id == command.itemID }) else {
            throw MobileChangeImportError.commandFailed(command.changeID)
        }
        draft.checklist[sectionIndex].items[itemIndex].isCompleted = command.isCompleted
        let saved = try await briefingStore.save(draft)
        return saved.revision
    }

    func saveNote(_ command: MobileNoteRevisionCommand) async throws -> Int? {
        if let briefingID = Self.briefingID(from: command.noteID) {
            guard var draft = try await briefingStore.latest(id: briefingID), draft.revision == command.expectedRevision else {
                throw MobileChangeImportError.commandFailed(command.changeID)
            }
            draft.notes = command.text
            let saved = try await briefingStore.save(draft)
            return saved.revision
        }
        guard let projectID = UUID(uuidString: command.ownerID),
              let annotation = try await metadataStore.projectAnnotation(projectID: projectID) else {
            throw MobileChangeImportError.commandFailed(command.changeID)
        }
        try await metadataStore.save(ProjectAnnotationRecord(
            projectID: annotation.projectID,
            integrationGoalHours: annotation.integrationGoalHours,
            notes: command.text,
            updatedAt: command.createdAt
        ))
        return command.resultingRevision
    }

    func addFieldNote(_ command: MobileFieldNoteCommand) async throws -> Int? {
        let separator = "\n\n— Phone field note —\n"
        if let briefingID = Self.briefingID(from: command.noteID) {
            guard var draft = try await briefingStore.latest(id: briefingID) else {
                throw MobileChangeImportError.commandFailed(command.changeID)
            }
            draft.notes += separator + command.text
            _ = try await briefingStore.save(draft)
            return nil
        }
        guard let projectID = UUID(uuidString: command.ownerID),
              let annotation = try await metadataStore.projectAnnotation(projectID: projectID) else {
            throw MobileChangeImportError.commandFailed(command.changeID)
        }
        try await metadataStore.save(ProjectAnnotationRecord(
            projectID: annotation.projectID,
            integrationGoalHours: annotation.integrationGoalHours,
            notes: annotation.notes + separator + command.text,
            updatedAt: command.createdAt
        ))
        return nil
    }

    private static func briefingID(from noteID: String) -> UUID? {
        guard noteID.hasPrefix("briefing-") else { return nil }
        return UUID(uuidString: String(noteID.dropFirst("briefing-".count)))
    }
}
