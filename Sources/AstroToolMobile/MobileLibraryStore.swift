import Darwin
import Foundation
import AstroMobileDomain
import AstroMobileTransport

public enum MobileLibraryStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSnapshot
    case invalidQueue
    case noLibrary
    case invalidPackage
    case libraryMismatch
    case revisionNotMonotonic
    case packageAlreadyConsumed
    case unknownChecklistItem
    case noteNotEditable
    case unknownNote
    case duplicateChange
    case noOpChange
    case persistenceFailed

    public var description: String {
        switch self {
        case .invalidSnapshot: return "The saved mobile library snapshot is not valid."
        case .invalidQueue: return "The saved mobile change queue is not valid."
        case .noLibrary: return "This iPhone does not have an AstroTool library yet."
        case .invalidPackage: return "The mobile package could not be imported."
        case .libraryMismatch: return "This package belongs to another AstroTool library."
        case .revisionNotMonotonic: return "This package is older than the current library."
        case .packageAlreadyConsumed: return "This mobile package has already been imported."
        case .unknownChecklistItem: return "That checklist item is not available."
        case .noteNotEditable: return "That note cannot be edited on iPhone."
        case .unknownNote: return "That note is not available."
        case .duplicateChange: return "That change is already queued."
        case .noOpChange: return "That change would not change anything."
        case .persistenceFailed: return "AstroTool could not save the mobile library safely."
        }
    }
}

public enum MobileLibraryStoreRecoveryState: Equatable, Sendable {
    case ready
    case empty
    case invalidSnapshot
    case invalidQueue
}

/// The iPhone's private, append-only local state. This actor never receives a
/// source photo path and never exposes a generic file operation.
public actor MobileLibraryStore {
    public let applicationSupportURL: URL
    public private(set) var activeSnapshot: MobileLibrarySnapshot?
    public private(set) var queuedChanges: [MobileChange]
    public private(set) var deviceID: UUID
    public private(set) var recoveryState: MobileLibraryStoreRecoveryState

    private let packageService: MobilePackageService
    private let fileManager = FileManager.default
    private var consumedPackageIDs: Set<UUID>

    private var activeDirectory: URL { applicationSupportURL.appendingPathComponent("active", isDirectory: true) }
    private var changesDirectory: URL { applicationSupportURL.appendingPathComponent("changes", isDirectory: true) }
    private var stagingDirectory: URL { applicationSupportURL.appendingPathComponent("import-staging", isDirectory: true) }
    private var receiptsDirectory: URL { applicationSupportURL.appendingPathComponent("receipts", isDirectory: true) }
    private var snapshotURL: URL { activeDirectory.appendingPathComponent("snapshot.json") }
    private var queueURL: URL { changesDirectory.appendingPathComponent("queue.json") }
    private var deviceURL: URL { applicationSupportURL.appendingPathComponent("device-id") }
    private var consumedURL: URL { receiptsDirectory.appendingPathComponent("consumed.json") }

    public init(applicationSupportURL: URL? = nil, packageService: MobilePackageService = MobilePackageService()) {
        self.applicationSupportURL = applicationSupportURL ?? Self.defaultApplicationSupportURL()
        self.packageService = packageService
        self.activeSnapshot = nil
        self.queuedChanges = []
        self.deviceID = UUID()
        self.recoveryState = .empty
        self.consumedPackageIDs = []
        let initial = Self.bootstrap(applicationSupportURL: self.applicationSupportURL, fallbackDeviceID: self.deviceID)
        self.activeSnapshot = initial.snapshot
        self.queuedChanges = initial.queue
        self.deviceID = initial.deviceID
        self.recoveryState = initial.recoveryState
        self.consumedPackageIDs = initial.consumedPackageIDs
    }

    /// Compatibility spelling for callers that use the shorter root label.
    public init(rootURL: URL, packageService: MobilePackageService = MobilePackageService()) {
        self.init(applicationSupportURL: rootURL, packageService: packageService)
    }

    public func reload() { recover() }

    public func stagePackage(from source: URL) throws -> URL {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: source.path), isDirectory(source) else {
            throw MobilePackageError.sourceNotFound
        }
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            guard Set(children.map(\.lastPathComponent)) == [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName] else {
                throw MobilePackageError.malformedPackage
            }
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory != true else { throw MobilePackageError.malformedPackage }
                let target = destination.appendingPathComponent(child.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { throw MobilePackageError.stagingFailed }
                try fileManager.copyItem(at: child, to: target)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw (error as? MobilePackageError) ?? MobilePackageError.stagingFailed
        }
    }

    public func discardStagedPackage(at url: URL) {
        guard url.path.hasPrefix(stagingDirectory.path + "/") else { return }
        try? fileManager.removeItem(at: url)
    }

    public func importPackage(from source: URL, keyPayload: String, removeStagedSource: Bool = false) async throws {
        let key: OneTimePackageKey
        do {
            key = try OneTimePackageKey(scanning: keyPayload)
        } catch {
            if removeStagedSource { discardStagedPackage(at: source) }
            throw error
        }
        try await performImport(from: source, key: key, removeStagedSource: removeStagedSource)
    }

    public func importPackage(from source: URL, key: OneTimePackageKey, removeStagedSource: Bool = false) async throws {
        try await performImport(from: source, key: key, removeStagedSource: removeStagedSource)
    }

    private func performImport(from source: URL, key: OneTimePackageKey, removeStagedSource: Bool) async throws {
        let preview: MobilePackageImportPreview
        do {
            preview = try await packageService.importPreview(from: source, wrapping: key)
        } catch {
            if removeStagedSource { discardStagedPackage(at: source) }
            throw error
        }
        guard !consumedPackageIDs.contains(preview.packageID) else {
            await packageService.discardImportPreview(packageID: preview.packageID)
            if removeStagedSource { discardStagedPackage(at: source) }
            throw MobileLibraryStoreError.packageAlreadyConsumed
        }
        do {
            let envelope = try await packageService.commitImport(packageID: preview.packageID)
            guard let snapshot = envelope.snapshot else { throw MobileLibraryStoreError.invalidPackage }
            try Self.validate(snapshot)
            if let current = activeSnapshot {
                guard current.libraryID == snapshot.libraryID else { throw MobileLibraryStoreError.libraryMismatch }
                guard snapshot.revision > current.revision else { throw MobileLibraryStoreError.revisionNotMonotonic }
            }
            try atomicWrite(snapshot, to: snapshotURL, validate: Self.validate)
            consumedPackageIDs.insert(preview.packageID)
            try atomicWrite(Array(consumedPackageIDs).sorted { $0.uuidString < $1.uuidString }, to: consumedURL) { ids in
                guard Set(ids).count == ids.count else { throw MobileLibraryStoreError.persistenceFailed }
            }
            activeSnapshot = snapshot
            recoveryState = .ready
        } catch {
            if removeStagedSource { discardStagedPackage(at: source) }
            throw error
        }
        if removeStagedSource { discardStagedPackage(at: source) }
    }

    public func editNote(id: String, text: String) throws {
        guard let snapshot = activeSnapshot else { throw MobileLibraryStoreError.noLibrary }
        guard let note = snapshot.notes.first(where: { $0.id == id }) else { throw MobileLibraryStoreError.unknownNote }
        guard note.isEditableOnPhone else { throw MobileLibraryStoreError.noteNotEditable }
        guard note.text != text else { throw MobileLibraryStoreError.noOpChange }
        let change = MobileChange.noteRevision(NoteRevisionChange(
            changeID: UUID(), deviceID: deviceID, noteID: note.id, ownerID: note.ownerID,
            baseRevision: note.baseRevision, text: text, createdAt: Date()
        ))
        try append(change)
    }

    public func toggleChecklistItem(briefingID: UUID, itemID: String, isCompleted: Bool? = nil) throws {
        guard let snapshot = activeSnapshot else { throw MobileLibraryStoreError.noLibrary }
        guard let briefing = snapshot.briefings.first(where: { $0.id == briefingID }),
              let item = briefing.checklist.flatMap(\.items).first(where: { $0.id == itemID }) else {
            throw MobileLibraryStoreError.unknownChecklistItem
        }
        let value = isCompleted ?? !item.isCompleted
        guard value != item.isCompleted else { throw MobileLibraryStoreError.noOpChange }
        let change = MobileChange.checklistCompletion(ChecklistCompletionChange(
            changeID: UUID(), deviceID: deviceID, briefingID: briefingID, itemID: itemID,
            baseRevision: item.baseRevision, isCompleted: value, createdAt: Date()
        ))
        try append(change)
    }

    public func toggleChecklist(briefingID: UUID, itemID: String) throws {
        try toggleChecklistItem(briefingID: briefingID, itemID: itemID)
    }

    private func append(_ change: MobileChange) throws {
        let id: UUID
        switch change {
        case .checklistCompletion(let value): id = value.changeID
        case .noteRevision(let value): id = value.changeID
        }
        guard !queuedChanges.contains(where: { Self.changeID($0) == id }) else { throw MobileLibraryStoreError.duplicateChange }
        var updated = queuedChanges
        updated.append(change)
        do {
            try atomicWrite(updated, to: queueURL) { decoded in
                guard Set(decoded.map(Self.changeID)).count == decoded.count else { throw MobileLibraryStoreError.invalidQueue }
            }
        } catch let error as MobileLibraryStoreError { throw error } catch { throw MobileLibraryStoreError.persistenceFailed }
        queuedChanges = updated
    }

    private func recover() {
        let state = Self.bootstrap(applicationSupportURL: applicationSupportURL, fallbackDeviceID: deviceID)
        activeSnapshot = state.snapshot
        queuedChanges = state.queue
        deviceID = state.deviceID
        recoveryState = state.recoveryState
        consumedPackageIDs = state.consumedPackageIDs
    }

    private struct BootstrapState {
        let snapshot: MobileLibrarySnapshot?
        let queue: [MobileChange]
        let deviceID: UUID
        let recoveryState: MobileLibraryStoreRecoveryState
        let consumedPackageIDs: Set<UUID>
    }

    private static func bootstrap(applicationSupportURL: URL, fallbackDeviceID: UUID) -> BootstrapState {
        let fileManager = FileManager.default
        let activeDirectory = applicationSupportURL.appendingPathComponent("active", isDirectory: true)
        let changesDirectory = applicationSupportURL.appendingPathComponent("changes", isDirectory: true)
        let stagingDirectory = applicationSupportURL.appendingPathComponent("import-staging", isDirectory: true)
        let receiptsDirectory = applicationSupportURL.appendingPathComponent("receipts", isDirectory: true)
        let snapshotURL = activeDirectory.appendingPathComponent("snapshot.json")
        let queueURL = changesDirectory.appendingPathComponent("queue.json")
        let deviceURL = applicationSupportURL.appendingPathComponent("device-id")
        let consumedURL = receiptsDirectory.appendingPathComponent("consumed.json")
        do {
            for url in [applicationSupportURL, activeDirectory, changesDirectory, stagingDirectory, receiptsDirectory] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            var deviceID = fallbackDeviceID
            if fileManager.fileExists(atPath: deviceURL.path), let text = try? String(contentsOf: deviceURL, encoding: .utf8), let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                deviceID = id
            } else if !fileManager.fileExists(atPath: deviceURL.path) {
                try Data(deviceID.uuidString.utf8).write(to: deviceURL, options: .atomic)
            }
            var snapshot: MobileLibrarySnapshot?
            var snapshotError = false
            if fileManager.fileExists(atPath: snapshotURL.path) {
                do {
                    let decoded = try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
                    try validate(decoded)
                    snapshot = decoded
                } catch { snapshotError = true }
            }
            var queue: [MobileChange] = []
            var queueError = false
            if fileManager.fileExists(atPath: queueURL.path) {
                do {
                    let decoded = try MobileJSON.decoder.decode([MobileChange].self, from: Data(contentsOf: queueURL))
                    guard Set(decoded.map(changeID)).count == decoded.count else { throw MobileLibraryStoreError.invalidQueue }
                    queue = decoded
                } catch { queueError = true }
            }
            var consumed: Set<UUID> = []
            if fileManager.fileExists(atPath: consumedURL.path) {
                let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: consumedURL))
                guard Set(ids).count == ids.count else { throw MobileLibraryStoreError.invalidQueue }
                consumed = Set(ids)
            }
            let recovery: MobileLibraryStoreRecoveryState = snapshotError ? .invalidSnapshot : (queueError ? .invalidQueue : (snapshot == nil ? .empty : .ready))
            return BootstrapState(snapshot: snapshot, queue: queue, deviceID: deviceID, recoveryState: recovery, consumedPackageIDs: consumed)
        } catch let error as MobileLibraryStoreError {
            return BootstrapState(snapshot: nil, queue: [], deviceID: fallbackDeviceID, recoveryState: error == .invalidSnapshot ? .invalidSnapshot : .invalidQueue, consumedPackageIDs: [])
        } catch {
            return BootstrapState(snapshot: nil, queue: [], deviceID: fallbackDeviceID, recoveryState: fileManager.fileExists(atPath: snapshotURL.path) ? .invalidSnapshot : .invalidQueue, consumedPackageIDs: [])
        }
    }

    private func ensureDirectories() throws {
        do {
            for url in [applicationSupportURL, activeDirectory, changesDirectory, stagingDirectory, receiptsDirectory] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } catch { throw MobileLibraryStoreError.persistenceFailed }
    }

    private static func validate(_ snapshot: MobileLibrarySnapshot) throws {
        guard snapshot.schemaVersion == MobileLibrarySnapshot.currentSchemaVersion, snapshot.revision >= 0,
              snapshot.createdAt.timeIntervalSince1970.isFinite else { throw MobileLibraryStoreError.invalidSnapshot }
        guard Set(snapshot.projects.map(\.id)).count == snapshot.projects.count,
              Set(snapshot.nights.map(\.id)).count == snapshot.nights.count,
              Set(snapshot.captures.map(\.id)).count == snapshot.captures.count,
              Set(snapshot.briefings.map(\.id)).count == snapshot.briefings.count,
              Set(snapshot.notes.map(\.id)).count == snapshot.notes.count else { throw MobileLibraryStoreError.invalidSnapshot }
        let noteMap = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
        for briefing in snapshot.briefings {
            guard let note = noteMap[briefing.noteID], note.scope == .briefing, note.ownerID == briefing.id.uuidString else { throw MobileLibraryStoreError.invalidSnapshot }
            guard Set(briefing.checklist.flatMap(\.items).map(\.id)).count == briefing.checklist.flatMap(\.items).count else { throw MobileLibraryStoreError.invalidSnapshot }
        }
    }

    private static func changeID(_ change: MobileChange) -> UUID {
        switch change {
        case .checklistCompletion(let value): return value.changeID
        case .noteRevision(let value): return value.changeID
        }
    }

    private func atomicWrite<T: Codable>(_ value: T, to destination: URL, validate: ((T) throws -> Void)? = nil) throws {
        do {
            let data = try MobileJSON.encoder.encode(value)
            let decoded = try MobileJSON.decoder.decode(T.self, from: data)
            try validate?(decoded)
            try writeRaw(data, to: destination)
        } catch let error as MobileLibraryStoreError { throw error } catch { throw MobileLibraryStoreError.persistenceFailed }
    }

    private func writeRaw(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".(destination.lastPathComponent).(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw MobileLibraryStoreError.persistenceFailed }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    guard written > 0 else { throw MobileLibraryStoreError.persistenceFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw MobileLibraryStoreError.persistenceFailed }
            guard Darwin.close(descriptor) == 0 else { throw MobileLibraryStoreError.persistenceFailed }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw MobileLibraryStoreError.persistenceFailed }
        } catch {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }

    private static func defaultApplicationSupportURL() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("AstroTool", isDirectory: true)) ?? FileManager.default.temporaryDirectory.appendingPathComponent("AstroTool", isDirectory: true)
    }
}
