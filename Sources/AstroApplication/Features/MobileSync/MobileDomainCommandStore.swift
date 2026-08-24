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
        let key = "(command.briefingID.uuidString):(command.itemID)"
        if let existing = state.checklist[key], existing.changeIDs.contains(command.changeID) { return existing.revision }
        var value = state.checklist[key] ?? .init(revision: command.expectedRevision, isCompleted: false, changeIDs: [])
        guard value.revision == command.expectedRevision else { throw MobileChangeImportError.commandFailed(command.changeID) }
        value.revision = command.resultingRevision
        value.isCompleted = command.isCompleted
        value.changeIDs.append(command.changeID)
        state.checklist[key] = value
        try persist()
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
        state.notes[command.noteID] = value
        try persist()
        return value.revision
    }

    private func addFieldNote(_ command: MobileFieldNoteCommand) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !state.fieldNotes.contains(where: { $0.changeID == command.changeID }) else { return nil }
        state.fieldNotes.append(.init(changeID: command.changeID, noteID: command.noteID, ownerID: command.ownerID, text: command.text, createdAt: command.createdAt))
        try persist()
        return nil
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try MobileJSON.encoder.encode(state)
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
        try MobileDomainCommandStore(rootURL: rootURL).commands()
    }
}
