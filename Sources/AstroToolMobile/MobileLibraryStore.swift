import Darwin
import CryptoKit
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
    case recoveryRequired
    case invalidDeviceID
    case invalidReceipts

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
        case .recoveryRequired: return "AstroTool needs recovery before it can change this iPhone's library."
        case .invalidDeviceID: return "The iPhone identity is damaged. Nothing will be overwritten."
        case .invalidReceipts: return "The package receipt record is damaged. Imports are locked until recovery."
        }
    }
}

public enum MobileLibraryStoreRecoveryState: Equatable, Sendable {
    case ready
    case empty
    case invalidSnapshot
    case invalidQueue
    case invalidDeviceID
    case invalidReceipts
}

/// The iPhone's private, append-only local state. This actor never receives a
/// source photo path and never exposes a generic file operation.
public actor MobileLibraryStore {
    public let applicationSupportURL: URL
    public private(set) var activeSnapshot: MobileLibrarySnapshot?
    public private(set) var queuedChanges: [MobileChange]
    public private(set) var deviceID: UUID?
    public private(set) var recoveryState: MobileLibraryStoreRecoveryState

    private let packageService: MobilePackageService
    private let fileManager = FileManager.default
    private var consumedPackageIDs: Set<UUID>
    private var keyFingerprints: [String: UUID]
    private var ownedStaging: [URL: StagingIdentity]

    private var activeDirectory: URL { applicationSupportURL.appendingPathComponent("active", isDirectory: true) }
    private var changesDirectory: URL { applicationSupportURL.appendingPathComponent("changes", isDirectory: true) }
    private var stagingDirectory: URL { applicationSupportURL.appendingPathComponent("import-staging", isDirectory: true) }
    private var receiptsDirectory: URL { applicationSupportURL.appendingPathComponent("receipts", isDirectory: true) }
    private var snapshotURL: URL { activeDirectory.appendingPathComponent("snapshot.json") }
    private var queueURL: URL { changesDirectory.appendingPathComponent("queue.json") }
    private var deviceURL: URL { applicationSupportURL.appendingPathComponent("device-id") }
    private var consumedURL: URL { receiptsDirectory.appendingPathComponent("consumed.json") }
    private var stateURL: URL { applicationSupportURL.appendingPathComponent("state.json") }
    private var keyURL: URL { receiptsDirectory.appendingPathComponent("keys.json") }

    public init(applicationSupportURL: URL? = nil, packageService: MobilePackageService = MobilePackageService()) {
        self.applicationSupportURL = applicationSupportURL ?? Self.defaultApplicationSupportURL()
        self.packageService = packageService
        self.activeSnapshot = nil
        self.queuedChanges = []
        self.deviceID = UUID()
        self.recoveryState = .empty
        self.consumedPackageIDs = []
        self.keyFingerprints = [:]
        self.ownedStaging = [:]
        let initial = Self.bootstrap(applicationSupportURL: self.applicationSupportURL, fallbackDeviceID: self.deviceID)
        self.activeSnapshot = initial.snapshot
        self.queuedChanges = initial.queue
        self.deviceID = initial.deviceID
        self.recoveryState = initial.recoveryState
        self.consumedPackageIDs = initial.consumedPackageIDs
        self.keyFingerprints = initial.keyFingerprints
    }

    /// Compatibility spelling for callers that use the shorter root label.
    public init(rootURL: URL, packageService: MobilePackageService = MobilePackageService()) {
        self.init(applicationSupportURL: rootURL, packageService: packageService)
    }

    public func reload() { recover() }

    private var writesAllowed: Bool {
        recoveryState == .ready || recoveryState == .empty
    }

    private func ensureWritable() throws {
        guard writesAllowed else { throw MobileLibraryStoreError.recoveryRequired }
    }

    public func stagePackage(from source: URL) throws -> URL {
        try ensureWritable()
        try ensureDirectories()
        guard fileManager.fileExists(atPath: source.path), isDirectory(source) else {
            throw MobilePackageError.sourceNotFound
        }
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            guard Set(children.map(\.lastPathComponent)) == [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName] else {
                throw MobilePackageError.malformedPackage
            }
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory != true else { throw MobilePackageError.malformedPackage }
                let target = destination.appendingPathComponent(child.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { throw MobilePackageError.stagingFailed }
                try copyRegularFile(from: child, to: target)
            }
            // The public manifest is inspected only after the operation-owned
            // copy is complete, so unlock UI never sees an unvalidated package.
            try validatePublicManifest(at: destination)
            ownedStaging[destination] = try stagingIdentity(of: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw (error as? MobilePackageError) ?? MobilePackageError.stagingFailed
        }
    }

    func discardStagedPackage(at url: URL) {
        guard let expected = ownedStaging.removeValue(forKey: url),
              let current = try? stagingIdentity(of: url), current == expected else { return }
        try? fileManager.removeItem(at: url)
    }

    private func validatePublicManifest(at package: URL) throws {
        let manifestURL = package.appendingPathComponent(MobilePackageService.manifestFileName)
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MobilePackageError.malformedPackage }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= MobilePackageService.maximumManifestByteCount else { throw MobilePackageError.invalidManifest }
        let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: data)
        guard manifest.formatVersion == MobilePackageService.currentFormatVersion,
              manifest.keyMode == .oneTimeQR,
              manifest.encryptedByteCount > 0,
              manifest.encryptedByteCount <= MobilePackageService.maximumEncryptedByteCount else {
            throw MobilePackageError.unsupportedFormatVersion
        }
    }

    private func copyRegularFile(from source: URL, to destination: URL) throws {
        let fd = source.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw MobilePackageError.malformedPackage }
        defer { Darwin.close(fd) }
        var info = Darwin.stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= MobilePackageService.maximumEncryptedByteCount else {
            throw MobilePackageError.malformedPackage
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw MobilePackageError.malformedPackage }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard Int64(data.count) == Int64(info.st_size) else { throw MobilePackageError.malformedPackage }
        try data.write(to: destination, options: .withoutOverwriting)
    }

    private struct StagingIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
    }

    private func stagingIdentity(of url: URL) throws -> StagingIdentity {
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw MobilePackageError.stagingFailed }
        return StagingIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size))
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
        try ensureWritable()
        let fingerprint = SHA256.hash(data: Data(key.qrPayload.utf8)).map { String(format: "%02x", $0) }.joined()
        if keyFingerprints[fingerprint] != nil {
            if removeStagedSource { discardStagedPackage(at: source) }
            throw MobileLibraryStoreError.packageAlreadyConsumed
        }
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
            guard let envelope = try await packageService.previewEnvelope(packageID: preview.packageID), let candidate = envelope.snapshot else {
                await packageService.discardImportPreview(packageID: preview.packageID)
                throw MobileLibraryStoreError.invalidPackage
            }
            try Self.validate(candidate)
            if let current = activeSnapshot {
                guard current.libraryID == candidate.libraryID else { throw MobileLibraryStoreError.libraryMismatch }
                guard candidate.revision > current.revision, candidate.revision < current.revision + 1_000_000 else { throw MobileLibraryStoreError.revisionNotMonotonic }
            }
            let committed = try await packageService.commitImport(packageID: preview.packageID)
            guard let snapshot = committed.snapshot else { throw MobileLibraryStoreError.invalidPackage }
            var nextReceipts = consumedPackageIDs
            nextReceipts.insert(preview.packageID)
            var nextKeys = keyFingerprints
            nextKeys[fingerprint] = preview.packageID
            try commitState(snapshot: snapshot, queue: queuedChanges, receipts: nextReceipts, keyFingerprints: nextKeys)
            consumedPackageIDs = nextReceipts
            keyFingerprints = nextKeys
            activeSnapshot = snapshot
            recoveryState = .ready
        } catch {
            await packageService.discardImportPreview(packageID: preview.packageID)
            if removeStagedSource { discardStagedPackage(at: source) }
            throw error
        }
        if removeStagedSource { discardStagedPackage(at: source) }
    }

    public func editNote(id: String, text: String) throws {
        try ensureWritable()
        guard let snapshot = activeSnapshot else { throw MobileLibraryStoreError.noLibrary }
        guard let deviceID else { throw MobileLibraryStoreError.recoveryRequired }
        guard let note = snapshot.notes.first(where: { $0.id == id }) else { throw MobileLibraryStoreError.unknownNote }
        guard note.isEditableOnPhone else { throw MobileLibraryStoreError.noteNotEditable }
        let effectiveText = queuedChanges.reversed().compactMap { change -> String? in
            guard case .noteRevision(let revision) = change, revision.noteID == id else { return nil }
            return revision.text
        }.first ?? note.text
        guard effectiveText != text else { throw MobileLibraryStoreError.noOpChange }
        let change = MobileChange.noteRevision(NoteRevisionChange(
            changeID: UUID(), deviceID: deviceID, noteID: note.id, ownerID: note.ownerID,
            baseRevision: note.baseRevision, text: text, createdAt: Date()
        ))
        try append(change)
    }

    public func toggleChecklistItem(briefingID: UUID, itemID: String, isCompleted: Bool? = nil) throws {
        try ensureWritable()
        guard let snapshot = activeSnapshot else { throw MobileLibraryStoreError.noLibrary }
        guard let deviceID else { throw MobileLibraryStoreError.recoveryRequired }
        guard let briefing = snapshot.briefings.first(where: { $0.id == briefingID }),
              let item = briefing.checklist.flatMap(\.items).first(where: { $0.id == itemID }) else {
            throw MobileLibraryStoreError.unknownChecklistItem
        }
        let effectiveValue = queuedChanges.reversed().compactMap { change -> Bool? in
            guard case .checklistCompletion(let completion) = change,
                  completion.briefingID == briefingID, completion.itemID == itemID else { return nil }
            return completion.isCompleted
        }.first ?? item.isCompleted
        let value = isCompleted ?? !effectiveValue
        guard value != effectiveValue else { throw MobileLibraryStoreError.noOpChange }
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
        try ensureWritable()
        guard !queuedChanges.contains(where: { Self.changeID($0) == id }) else { throw MobileLibraryStoreError.duplicateChange }
        var updated = queuedChanges
        updated.append(change)
        do {
            try commitState(snapshot: activeSnapshot, queue: updated, receipts: consumedPackageIDs, keyFingerprints: keyFingerprints)
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
        let deviceID: UUID?
        let recoveryState: MobileLibraryStoreRecoveryState
        let consumedPackageIDs: Set<UUID>
        let keyFingerprints: [String: UUID]
    }

    private struct PersistedState: Codable {
        let snapshot: MobileLibrarySnapshot?
        let queue: [MobileChange]
        let deviceID: UUID?
        let consumedPackageIDs: [UUID]
        let keyFingerprints: [String: UUID]
    }

    private static func bootstrap(applicationSupportURL: URL, fallbackDeviceID: UUID?) -> BootstrapState {
        let fileManager = FileManager.default
        let activeDirectory = applicationSupportURL.appendingPathComponent("active", isDirectory: true)
        let changesDirectory = applicationSupportURL.appendingPathComponent("changes", isDirectory: true)
        let stagingDirectory = applicationSupportURL.appendingPathComponent("import-staging", isDirectory: true)
        let receiptsDirectory = applicationSupportURL.appendingPathComponent("receipts", isDirectory: true)
        let snapshotURL = activeDirectory.appendingPathComponent("snapshot.json")
        let queueURL = changesDirectory.appendingPathComponent("queue.json")
        let deviceURL = applicationSupportURL.appendingPathComponent("device-id")
        let consumedURL = receiptsDirectory.appendingPathComponent("consumed.json")
        let keyURL = receiptsDirectory.appendingPathComponent("keys.json")
        do {
            for url in [applicationSupportURL, activeDirectory, changesDirectory, stagingDirectory, receiptsDirectory] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            var deviceID: UUID? = fallbackDeviceID
            var deviceError = false
            if fileManager.fileExists(atPath: deviceURL.path), let text = try? String(contentsOf: deviceURL, encoding: .utf8), let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                deviceID = id
            } else if fileManager.fileExists(atPath: deviceURL.path) {
                deviceID = nil
                deviceError = true
            } else if !fileManager.fileExists(atPath: deviceURL.path) {
                if let deviceID { try durableWrite(Data(deviceID.uuidString.utf8), to: deviceURL) }
            }
            if fileManager.fileExists(atPath: applicationSupportURL.appendingPathComponent("state.json").path) {
                do {
                    let state = try MobileJSON.decoder.decode(PersistedState.self, from: Data(contentsOf: applicationSupportURL.appendingPathComponent("state.json")))
                    if let snapshot = state.snapshot { try validate(snapshot) }
                    guard Set(state.queue.map(changeID)).count == state.queue.count,
                          Set(state.consumedPackageIDs).count == state.consumedPackageIDs.count,
                          state.deviceID != nil else { throw MobileLibraryStoreError.recoveryRequired }
                    let mirrorSnapshotCorrupt: Bool = {
                        guard fileManager.fileExists(atPath: snapshotURL.path) else { return false }
                        guard let data = try? Data(contentsOf: snapshotURL), let value = try? MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: data) else { return true }
                        return (try? validate(value)) == nil
                    }()
                    let mirrorQueueCorrupt: Bool = {
                        guard fileManager.fileExists(atPath: queueURL.path) else { return false }
                        guard let data = try? Data(contentsOf: queueURL), let value = try? MobileJSON.decoder.decode([MobileChange].self, from: data) else { return true }
                        return Set(value.map(changeID)).count != value.count
                    }()
                    let mirrorReceiptsCorrupt = fileManager.fileExists(atPath: consumedURL.path) && (try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: consumedURL))) == nil
                    let mirrorKeysCorrupt = fileManager.fileExists(atPath: keyURL.path) && (try? JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: keyURL))) == nil
                    let recovery: MobileLibraryStoreRecoveryState = deviceError ? .invalidDeviceID : (mirrorSnapshotCorrupt ? .invalidSnapshot : (mirrorQueueCorrupt ? .invalidQueue : ((mirrorReceiptsCorrupt || mirrorKeysCorrupt) ? .invalidReceipts : .ready)))
                    return BootstrapState(snapshot: state.snapshot, queue: state.queue, deviceID: deviceError ? nil : state.deviceID, recoveryState: recovery, consumedPackageIDs: Set(state.consumedPackageIDs), keyFingerprints: state.keyFingerprints)
                } catch {
                    return BootstrapState(snapshot: nil, queue: [], deviceID: nil, recoveryState: .invalidSnapshot, consumedPackageIDs: [], keyFingerprints: [:])
                }
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
            var receiptsError = false
            if fileManager.fileExists(atPath: consumedURL.path) {
                do {
                    let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: consumedURL))
                    guard Set(ids).count == ids.count else { throw MobileLibraryStoreError.invalidQueue }
                    consumed = Set(ids)
                } catch { receiptsError = true }
            }
            var keys: [String: UUID] = [:]
            if fileManager.fileExists(atPath: applicationSupportURL.appendingPathComponent("receipts/keys.json").path) {
                do { keys = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: applicationSupportURL.appendingPathComponent("receipts/keys.json"))) }
                catch { receiptsError = true }
            }
            let recovery: MobileLibraryStoreRecoveryState = deviceError ? .invalidDeviceID : (receiptsError ? .invalidReceipts : (snapshotError ? .invalidSnapshot : (queueError ? .invalidQueue : (snapshot == nil ? .empty : .ready))))
            return BootstrapState(snapshot: snapshot, queue: queue, deviceID: deviceError ? nil : deviceID, recoveryState: recovery, consumedPackageIDs: consumed, keyFingerprints: keys)
        } catch let error as MobileLibraryStoreError {
            return BootstrapState(snapshot: nil, queue: [], deviceID: fallbackDeviceID, recoveryState: error == .invalidSnapshot ? .invalidSnapshot : .invalidQueue, consumedPackageIDs: [], keyFingerprints: [:])
        } catch {
            return BootstrapState(snapshot: nil, queue: [], deviceID: fallbackDeviceID, recoveryState: fileManager.fileExists(atPath: snapshotURL.path) ? .invalidSnapshot : .invalidQueue, consumedPackageIDs: [], keyFingerprints: [:])
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

    private static func durableWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
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
            guard try Data(contentsOf: temporary) == data else { throw MobileLibraryStoreError.persistenceFailed }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw MobileLibraryStoreError.persistenceFailed }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func commitState(snapshot: MobileLibrarySnapshot?, queue: [MobileChange], receipts: Set<UUID>, keyFingerprints: [String: UUID]) throws {
        guard Set(queue.map(Self.changeID)).count == queue.count else { throw MobileLibraryStoreError.invalidQueue }
        guard let deviceID else { throw MobileLibraryStoreError.invalidDeviceID }
        let state = PersistedState(snapshot: snapshot, queue: queue, deviceID: deviceID, consumedPackageIDs: receipts.sorted { $0.uuidString < $1.uuidString }, keyFingerprints: keyFingerprints)
        try atomicWrite(state, to: stateURL)
        // state.json is the transaction authority. These mirrors are only for
        // compatibility/inspection; a mirror failure cannot report a failed
        // transaction after the durable state commit.
        try? atomicWrite(queue, to: queueURL)
        try? atomicWrite(Array(receipts).sorted { $0.uuidString < $1.uuidString }, to: consumedURL)
        try? atomicWrite(keyFingerprints, to: keyURL)
        if let snapshot { try? atomicWrite(snapshot, to: snapshotURL, validate: Self.validate) }
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
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
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
            let persisted = try Data(contentsOf: temporary)
            guard persisted == data else { throw MobileLibraryStoreError.persistenceFailed }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw MobileLibraryStoreError.persistenceFailed }
            let parentDescriptor = destination.deletingLastPathComponent().path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            if parentDescriptor >= 0 { _ = Darwin.fsync(parentDescriptor); _ = Darwin.close(parentDescriptor) }
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
