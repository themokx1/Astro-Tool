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
    public private(set) var durabilityWarning = false

    private let packageService: MobilePackageService
    private let testingBeforeStateCommit: @Sendable () throws -> Void
    private let fileManager = FileManager.default
    private var consumedPackageIDs: Set<UUID>
    private var keyFingerprints: [String: UUID]
    private var currentStagedPackage: CurrentStagedPackage?
    private var pendingImport: PendingImport?

    private var activeDirectory: URL { applicationSupportURL.appendingPathComponent("active", isDirectory: true) }
    private var changesDirectory: URL { applicationSupportURL.appendingPathComponent("changes", isDirectory: true) }
    private var stagingDirectory: URL { applicationSupportURL.appendingPathComponent("import-staging", isDirectory: true) }
    private var receiptsDirectory: URL { applicationSupportURL.appendingPathComponent("receipts", isDirectory: true) }
    private var snapshotURL: URL { activeDirectory.appendingPathComponent("snapshot.json") }
    private var queueURL: URL { changesDirectory.appendingPathComponent("queue.json") }
    private var deviceURL: URL { applicationSupportURL.appendingPathComponent("device-id") }
    private var consumedURL: URL { receiptsDirectory.appendingPathComponent("consumed.json") }
    private var stateURL: URL { applicationSupportURL.appendingPathComponent("state.json") }
    private var durabilityURL: URL { applicationSupportURL.appendingPathComponent(".state-durability") }
    private var keyURL: URL { receiptsDirectory.appendingPathComponent("keys.json") }

    public init(applicationSupportURL: URL? = nil, packageService: MobilePackageService = MobilePackageService()) {
        self.applicationSupportURL = applicationSupportURL ?? Self.defaultApplicationSupportURL()
        self.packageService = packageService
        self.testingBeforeStateCommit = {}
        self.activeSnapshot = nil
        self.queuedChanges = []
        self.deviceID = UUID()
        self.recoveryState = .empty
        self.consumedPackageIDs = []
        self.keyFingerprints = [:]
        self.currentStagedPackage = nil
        self.pendingImport = nil
        let initial = Self.bootstrap(applicationSupportURL: self.applicationSupportURL, fallbackDeviceID: self.deviceID)
        self.activeSnapshot = initial.snapshot
        self.queuedChanges = initial.queue
        self.deviceID = initial.deviceID
        self.recoveryState = initial.recoveryState
        self.consumedPackageIDs = initial.consumedPackageIDs
        self.keyFingerprints = initial.keyFingerprints
        self.durabilityWarning = initial.durabilityWarning
    }

    init(applicationSupportURL: URL, packageService: MobilePackageService, testingBeforeStateCommit: @escaping @Sendable () throws -> Void) {
        self.applicationSupportURL = applicationSupportURL
        self.packageService = packageService
        self.testingBeforeStateCommit = testingBeforeStateCommit
        self.activeSnapshot = nil
        self.queuedChanges = []
        self.deviceID = UUID()
        self.recoveryState = .empty
        self.consumedPackageIDs = []
        self.keyFingerprints = [:]
        self.currentStagedPackage = nil
        self.pendingImport = nil
        let initial = Self.bootstrap(applicationSupportURL: applicationSupportURL, fallbackDeviceID: self.deviceID)
        self.activeSnapshot = initial.snapshot
        self.queuedChanges = initial.queue
        self.deviceID = initial.deviceID
        self.recoveryState = initial.recoveryState
        self.consumedPackageIDs = initial.consumedPackageIDs
        self.keyFingerprints = initial.keyFingerprints
        self.durabilityWarning = initial.durabilityWarning
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

    public func receive(source: URL) async throws -> URL {
        await discardCurrentStagedPackage()
        return try stagePackageSync(from: source)
    }

    public func stagePackage(from source: URL) async throws -> URL {
        await discardCurrentStagedPackage()
        return try stagePackageSync(from: source)
    }

    private func stagePackageSync(from source: URL) throws -> URL {
        try ensureWritable()
        try ensureDirectories()
        guard fileManager.fileExists(atPath: source.path), isDirectory(source) else {
            throw MobilePackageError.sourceNotFound
        }
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            let sourceFD = source.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard sourceFD >= 0 else { throw MobilePackageError.malformedPackage }
            defer { Darwin.close(sourceFD) }
            let sourceIdentity = try directoryIdentity(fd: sourceFD)
            let children = try directoryEntries(fd: sourceFD)
            guard Set(children) == [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName],
                  !children.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") }) else {
                throw MobilePackageError.malformedPackage
            }
            for name in children {
                let target = destination.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: target.path) else { throw MobilePackageError.stagingFailed }
                try copyRegularFile(from: sourceFD, name: name, to: target)
                guard try directoryIdentity(fd: sourceFD) == sourceIdentity else { throw MobilePackageError.malformedPackage }
            }
            // The public manifest is inspected only after the operation-owned
            // copy is complete, so unlock UI never sees an unvalidated package.
            try validatePublicManifest(at: destination)
            currentStagedPackage = CurrentStagedPackage(url: destination, identity: try stagingIdentity(of: destination))
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw (error as? MobilePackageError) ?? MobilePackageError.stagingFailed
        }
    }

    /// Serializes replacement of the operation-owned staged child inside the
    /// store actor, so two incoming document URLs cannot strand a hidden copy.
    public var stagedPackageURL: URL? { currentStagedPackage?.url }

    public func discardCurrentStagedPackage() async {
        if let pendingImport {
            await packageService.discardImportPreview(token: pendingImport.token)
        }
        pendingImport = nil
        if let current = currentStagedPackage,
           let identity = try? stagingIdentity(of: current.url), identity == current.identity {
            try? fileManager.removeItem(at: current.url)
        }
        currentStagedPackage = nil
    }

    func discardStagedPackage(at url: URL) async {
        guard let current = currentStagedPackage, current.url == url,
              let identity = try? stagingIdentity(of: url), identity == current.identity else { return }
        await discardCurrentStagedPackage()
    }

    private struct CurrentStagedPackage {
        let url: URL
        let identity: StagingIdentity
    }

    private func validatePublicManifest(at package: URL) throws {
        let manifestURL = package.appendingPathComponent(MobilePackageService.manifestFileName)
        let payloadURL = package.appendingPathComponent(MobilePackageService.encryptedPayloadFileName)
        let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MobilePackageError.malformedPackage }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= MobilePackageService.maximumManifestByteCount else { throw MobilePackageError.invalidManifest }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["formatVersion", "packageID", "createdAt", "encryptedByteCount", "ciphertextSHA256", "keyMode", "wrappedContentKeyBase64"] else {
            throw MobilePackageError.invalidManifest
        }
        let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: data)
        guard manifest.formatVersion == MobilePackageService.currentFormatVersion,
              manifest.keyMode == .oneTimeQR,
              manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.encryptedByteCount >= 28,
              manifest.encryptedByteCount <= MobilePackageService.maximumEncryptedByteCount,
              manifest.ciphertextSHA256.count == 64,
              manifest.ciphertextSHA256.allSatisfy({ $0.isNumber || ($0 >= "a" && $0 <= "f") }),
              let wrapped = manifest.wrappedContentKeyBase64,
              let wrappedData = Data(base64Encoded: wrapped),
              !wrappedData.isEmpty,
              wrappedData.count <= MobilePackageService.maximumWrappedKeyByteCount,
              wrappedData.base64EncodedString() == wrapped else {
            throw MobilePackageError.unsupportedFormatVersion
        }
        let payload = try Data(contentsOf: payloadURL)
        guard Int64(payload.count) == manifest.encryptedByteCount,
              sha256Hex(payload) == manifest.ciphertextSHA256 else { throw MobilePackageError.manifestHashMismatch }
    }

    private func copyRegularFile(from rootFD: Int32, name: String, to destination: URL) throws {
        let fd = name.withCString { Darwin.openat(rootFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
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

    private func directoryIdentity(fd: Int32) throws -> StagingIdentity {
        var info = Darwin.stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw MobilePackageError.malformedPackage }
        return StagingIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size))
    }

    private func directoryEntries(fd: Int32) throws -> [String] {
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw MobilePackageError.malformedPackage
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            if names.count > 2 { throw MobilePackageError.malformedPackage }
        }
        guard errno == 0 else { throw MobilePackageError.malformedPackage }
        return names
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// Imports only the package this store copied into its private staging
    /// area. Callers never get to nominate a source URL at commit time.
    public func importCurrentStagedPackage(keyPayload: String) async throws {
        let key: OneTimePackageKey
        do {
            key = try OneTimePackageKey(scanning: keyPayload)
        } catch {
            throw error
        }
        try await performImport(key: key)
    }

    func importCurrentStagedPackage(key: OneTimePackageKey) async throws {
        try await performImport(key: key)
    }

    private func performImport(key: OneTimePackageKey) async throws {
        try ensureWritable()
        try Task.checkCancellation()
        guard let current = currentStagedPackage,
              let sourceIdentity = try? stagingIdentity(of: current.url), sourceIdentity == current.identity else {
            throw MobileLibraryStoreError.invalidPackage
        }
        let source = current.url
        let fingerprint = SHA256.hash(data: Data(key.qrPayload.utf8)).map { String(format: "%02x", $0) }.joined()
        if keyFingerprints[fingerprint] != nil {
            await discardCurrentStagedPackageIfMatching(source)
            throw MobileLibraryStoreError.packageAlreadyConsumed
        }
        let token: MobilePackagePreviewToken
        let preview: MobilePackageImportPreview
        if let pendingImport,
           pendingImport.source == source,
           pendingImport.sourceIdentity == sourceIdentity,
           pendingImport.fingerprint == fingerprint {
            token = pendingImport.token
            preview = pendingImport.preview
        } else {
            do {
                let authenticated = try await packageService.authenticatePreview(from: source, wrapping: key)
                token = authenticated.token
                preview = authenticated.preview
            } catch {
                await discardCurrentStagedPackageIfMatching(source)
                throw error
            }
        }
        guard !consumedPackageIDs.contains(preview.packageID) else {
            await packageService.discardImportPreview(token: token)
            await discardCurrentStagedPackageIfMatching(source)
            throw MobileLibraryStoreError.packageAlreadyConsumed
        }
        let envelope: MobilePackageEnvelope
        do {
            guard let validated = try await packageService.validatedEnvelope(token: token) else {
                throw MobileLibraryStoreError.invalidPackage
            }
            envelope = validated
        } catch {
            await packageService.discardImportPreview(token: token)
            pendingImport = nil
            await discardCurrentStagedPackageIfMatching(source)
            throw error
        }
        var stateCommitAttempted = false
        var stateCommitSucceeded = false
        do {
            guard let candidate = envelope.snapshot else { throw MobileLibraryStoreError.invalidPackage }
            guard Self.isSafeRevision(candidate.revision) else { throw MobileLibraryStoreError.revisionNotMonotonic }
            try Self.validate(candidate)
            if let current = activeSnapshot {
                guard current.libraryID == candidate.libraryID else { throw MobileLibraryStoreError.libraryMismatch }
                guard Self.isSafeRevision(candidate.revision), candidate.revision > current.revision,
                      candidate.revision - current.revision <= Self.maximumRevisionDelta else {
                    throw MobileLibraryStoreError.revisionNotMonotonic
                }
            } else {
                guard Self.isSafeRevision(candidate.revision) else { throw MobileLibraryStoreError.revisionNotMonotonic }
            }
            try Task.checkCancellation()
            guard let snapshot = envelope.snapshot else { throw MobileLibraryStoreError.invalidPackage }
            var nextReceipts = consumedPackageIDs
            nextReceipts.insert(preview.packageID)
            var nextKeys = keyFingerprints
            nextKeys[fingerprint] = preview.packageID
            try Self.validateKeyFingerprints(nextKeys, boundTo: nextReceipts)
            try Task.checkCancellation()
            stateCommitAttempted = true
            try commitState(snapshot: snapshot, queue: queuedChanges, receipts: nextReceipts, keyFingerprints: nextKeys)
            stateCommitSucceeded = true
            consumedPackageIDs = nextReceipts
            keyFingerprints = nextKeys
            activeSnapshot = snapshot
            recoveryState = .ready
            pendingImport = nil
            // A service acknowledgement is deliberately after the durable
            // store commit. If it fails, the durable receipt is authoritative.
            _ = try? await packageService.commitImport(token: token)
        } catch {
            if stateCommitAttempted && !stateCommitSucceeded {
                pendingImport = PendingImport(source: source, sourceIdentity: sourceIdentity, fingerprint: fingerprint, preview: preview, token: token)
            } else {
                await packageService.discardImportPreview(token: token)
                pendingImport = nil
                await discardCurrentStagedPackageIfMatching(source)
            }
            throw error
        }
        await discardCurrentStagedPackageIfMatching(source)
    }

    private func discardCurrentStagedPackageIfMatching(_ source: URL) async {
        guard currentStagedPackage?.url == source else { return }
        await discardCurrentStagedPackage()
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
        durabilityWarning = state.durabilityWarning
        consumedPackageIDs = state.consumedPackageIDs
        keyFingerprints = state.keyFingerprints
    }

    private struct BootstrapState {
        let snapshot: MobileLibrarySnapshot?
        let queue: [MobileChange]
        let deviceID: UUID?
        let recoveryState: MobileLibraryStoreRecoveryState
        let consumedPackageIDs: Set<UUID>
        let keyFingerprints: [String: UUID]
        let durabilityWarning: Bool

        init(snapshot: MobileLibrarySnapshot?, queue: [MobileChange], deviceID: UUID?, recoveryState: MobileLibraryStoreRecoveryState, consumedPackageIDs: Set<UUID>, keyFingerprints: [String: UUID], durabilityWarning: Bool = false) {
            self.snapshot = snapshot
            self.queue = queue
            self.deviceID = deviceID
            self.recoveryState = recoveryState
            self.consumedPackageIDs = consumedPackageIDs
            self.keyFingerprints = keyFingerprints
            self.durabilityWarning = durabilityWarning
        }
    }

    private struct PersistedState: Codable {
        let snapshot: MobileLibrarySnapshot?
        let queue: [MobileChange]
        let deviceID: UUID?
        let consumedPackageIDs: [UUID]
        let keyFingerprints: [String: UUID]
        let durabilityWarning: Bool

        init(snapshot: MobileLibrarySnapshot?, queue: [MobileChange], deviceID: UUID?, consumedPackageIDs: [UUID], keyFingerprints: [String: UUID], durabilityWarning: Bool = false) {
            self.snapshot = snapshot
            self.queue = queue
            self.deviceID = deviceID
            self.consumedPackageIDs = consumedPackageIDs
            self.keyFingerprints = keyFingerprints
            self.durabilityWarning = durabilityWarning
        }

        private enum CodingKeys: String, CodingKey { case snapshot, queue, deviceID, consumedPackageIDs, keyFingerprints, durabilityWarning }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            snapshot = try values.decodeIfPresent(MobileLibrarySnapshot.self, forKey: .snapshot)
            queue = try values.decode([MobileChange].self, forKey: .queue)
            deviceID = try values.decodeIfPresent(UUID.self, forKey: .deviceID)
            consumedPackageIDs = try values.decode([UUID].self, forKey: .consumedPackageIDs)
            keyFingerprints = try values.decode([String: UUID].self, forKey: .keyFingerprints)
            durabilityWarning = try values.decodeIfPresent(Bool.self, forKey: .durabilityWarning) ?? false
        }
    }

    private struct PendingImport {
        let source: URL
        let sourceIdentity: StagingIdentity?
        let fingerprint: String
        let preview: MobilePackageImportPreview
        let token: MobilePackagePreviewToken
    }

    private static let maximumRevision = 1_000_000_000
    private static let maximumRevisionDelta = 1_000_000

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
        let stateURL = applicationSupportURL.appendingPathComponent("state.json")
        do {
            for url in [applicationSupportURL, activeDirectory, changesDirectory, stagingDirectory, receiptsDirectory] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            cleanupOwnedStagingDirectory(stagingDirectory, fileManager: fileManager)
            var deviceID: UUID? = fallbackDeviceID
            var durabilityWarning = (try? String(contentsOf: applicationSupportURL.appendingPathComponent(".state-durability"), encoding: .utf8)) == "pending"
            var deviceError = false
            if fileManager.fileExists(atPath: stateURL.path) {
                do {
                    let state = try MobileJSON.decoder.decode(PersistedState.self, from: Data(contentsOf: applicationSupportURL.appendingPathComponent("state.json")))
                    if let snapshot = state.snapshot { try validate(snapshot) }
                    // state.json is the sole authoritative contract once it
                    // exists. Legacy mirrors are never consulted, so a valid
                    // state can never be paired with silently stale files.
                    let queueValid = (try? validateQueue(state.queue, deviceID: state.deviceID)) != nil
                    let receiptsValid = Set(state.consumedPackageIDs).count == state.consumedPackageIDs.count
                    let fingerprintsValid = (try? validateKeyFingerprints(state.keyFingerprints, boundTo: Set(state.consumedPackageIDs))) != nil
                    let recovery: MobileLibraryStoreRecoveryState
                    let queue = queueValid ? state.queue : []
                    if state.deviceID == nil {
                        recovery = .invalidDeviceID
                    } else if !queueValid {
                        recovery = .invalidQueue
                    } else if !receiptsValid || !fingerprintsValid {
                        recovery = .invalidReceipts
                    } else {
                        recovery = .ready
                    }
                    return BootstrapState(snapshot: state.snapshot, queue: queue, deviceID: state.deviceID, recoveryState: recovery, consumedPackageIDs: receiptsValid ? Set(state.consumedPackageIDs) : [], keyFingerprints: fingerprintsValid ? state.keyFingerprints : [:], durabilityWarning: state.durabilityWarning)
                } catch {
                    return BootstrapState(snapshot: nil, queue: [], deviceID: nil, recoveryState: .invalidSnapshot, consumedPackageIDs: [], keyFingerprints: [:])
                }
            }
            // Legacy mirrors are read only for a first migration, while no
            // authoritative state document exists. A corrupt legacy identity
            // is a visible lockout and is never regenerated.
            if fileManager.fileExists(atPath: deviceURL.path), let text = try? String(contentsOf: deviceURL, encoding: .utf8), let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                deviceID = id
            } else if fileManager.fileExists(atPath: deviceURL.path) {
                deviceID = nil
                deviceError = true
            } else if let deviceID {
                durabilityWarning = try durableWrite(Data(deviceID.uuidString.utf8), to: deviceURL)
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
                    try validateQueue(decoded, deviceID: deviceID)
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
            if (try? validateKeyFingerprints(keys, boundTo: consumed)) == nil { receiptsError = true }
            let recovery: MobileLibraryStoreRecoveryState = deviceError ? .invalidDeviceID : (receiptsError ? .invalidReceipts : (snapshotError ? .invalidSnapshot : (queueError ? .invalidQueue : (snapshot == nil ? .empty : .ready))))
            let result = BootstrapState(snapshot: snapshot, queue: queue, deviceID: deviceError ? nil : deviceID, recoveryState: recovery, consumedPackageIDs: consumed, keyFingerprints: keys)
            if !fileManager.fileExists(atPath: stateURL.path), recovery == .empty || recovery == .ready,
               let deviceID, let encoded = try? MobileJSON.encoder.encode(PersistedState(snapshot: snapshot, queue: queue, deviceID: deviceID, consumedPackageIDs: consumed.sorted { $0.uuidString < $1.uuidString }, keyFingerprints: keys, durabilityWarning: durabilityWarning)) {
                _ = try durableWrite(Data("pending".utf8), to: applicationSupportURL.appendingPathComponent(".state-durability"))
                let uncertain = try durableWrite(encoded, to: stateURL)
                if !uncertain { _ = try durableWrite(Data("clear".utf8), to: applicationSupportURL.appendingPathComponent(".state-durability")) }
                durabilityWarning = uncertain || durabilityWarning
            }
            return BootstrapState(snapshot: result.snapshot, queue: result.queue, deviceID: result.deviceID, recoveryState: result.recoveryState, consumedPackageIDs: result.consumedPackageIDs, keyFingerprints: result.keyFingerprints, durabilityWarning: durabilityWarning)
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
        guard snapshot.schemaVersion == MobileLibrarySnapshot.currentSchemaVersion, isSafeRevision(snapshot.revision),
              snapshot.createdAt.timeIntervalSince1970.isFinite,
              snapshot.projects.count <= MobilePackageService.maximumCollectionCount,
              snapshot.nights.count <= MobilePackageService.maximumCollectionCount,
              snapshot.captures.count <= MobilePackageService.maximumCollectionCount,
              snapshot.briefings.count <= MobilePackageService.maximumCollectionCount,
              snapshot.notes.count <= MobilePackageService.maximumCollectionCount else { throw MobileLibraryStoreError.invalidSnapshot }
        let nestedRecordCount = snapshot.projects.count + snapshot.nights.count + snapshot.captures.count + snapshot.briefings.count + snapshot.notes.count
            + snapshot.briefings.reduce(0) { partial, briefing in
                partial + briefing.targets.count + briefing.checklist.count + briefing.checklist.reduce(0) { $0 + $1.items.count }
            }
        guard nestedRecordCount <= MobilePackageService.maximumTotalNestedRecords else { throw MobileLibraryStoreError.invalidSnapshot }
        guard Set(snapshot.projects.map(\.id)).count == snapshot.projects.count,
              Set(snapshot.nights.map(\.id)).count == snapshot.nights.count,
              Set(snapshot.captures.map(\.id)).count == snapshot.captures.count,
              Set(snapshot.briefings.map(\.id)).count == snapshot.briefings.count,
              Set(snapshot.notes.map(\.id)).count == snapshot.notes.count else { throw MobileLibraryStoreError.invalidSnapshot }
        let projectIDs = Set(snapshot.projects.map(\.id))
        let nightIDs = Set(snapshot.nights.map(\.id))
        let noteMap = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
        for project in snapshot.projects {
            guard validString(project.displayName), validString(project.catalogID), validString(project.phase),
                  project.integrationSeconds.isFinite, project.integrationSeconds >= 0,
                  project.goalHours.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw MobileLibraryStoreError.invalidSnapshot }
        }
        for night in snapshot.nights { guard validString(night.localDate), validString(night.timeZoneID) else { throw MobileLibraryStoreError.invalidSnapshot } }
        for capture in snapshot.captures {
            guard projectIDs.contains(capture.projectID), nightIDs.contains(capture.nightID),
                  validString(capture.displayName), capture.filterName.map(validString) ?? true,
                  capture.exposureSeconds.isFinite, capture.exposureSeconds >= 0,
                  capture.integrationSeconds.isFinite, capture.integrationSeconds >= 0 else { throw MobileLibraryStoreError.invalidSnapshot }
        }
        for briefing in snapshot.briefings {
            guard isSafeRevision(briefing.revision), briefing.savedAt.timeIntervalSince1970.isFinite,
                  briefing.nightDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  validString(briefing.readiness), validString(briefing.noteID),
                  let note = noteMap[briefing.noteID], note.scope == .briefing, note.ownerID == briefing.id.uuidString else { throw MobileLibraryStoreError.invalidSnapshot }
            guard briefing.targets.count <= MobilePackageService.maximumCollectionCount,
                  briefing.checklist.count <= MobilePackageService.maximumCollectionCount,
                  Set(briefing.targets.map(\.id)).count == briefing.targets.count,
                  Set(briefing.checklist.map(\.id)).count == briefing.checklist.count,
                  Set(briefing.checklist.flatMap(\.items).map(\.id)).count == briefing.checklist.flatMap(\.items).count else { throw MobileLibraryStoreError.invalidSnapshot }
            for target in briefing.targets {
                guard target.start.timeIntervalSince1970.isFinite, target.end.timeIntervalSince1970.isFinite,
                      target.end >= target.start, validString(target.name), validString(target.role),
                      target.warnings.count <= MobilePackageService.maximumCollectionCount,
                      target.warnings.allSatisfy(validString) else { throw MobileLibraryStoreError.invalidSnapshot }
            }
            for section in briefing.checklist {
                guard validString(section.id), validString(section.title),
                      section.items.count <= MobilePackageService.maximumCollectionCount else { throw MobileLibraryStoreError.invalidSnapshot }
                for item in section.items { guard validString(item.id), validString(item.title), item.explanation.map(validString) ?? true, isSafeRevision(item.baseRevision) else { throw MobileLibraryStoreError.invalidSnapshot } }
            }
        }
        for note in snapshot.notes { guard validString(note.id), validString(note.ownerID), validString(note.text), isSafeRevision(note.baseRevision), note.updatedAt.timeIntervalSince1970.isFinite else { throw MobileLibraryStoreError.invalidSnapshot } }
    }

    private static func validString(_ value: String) -> Bool {
        value.utf8.count <= MobilePackageService.maximumStringByteCount
    }

    /// Queue records may outlive the snapshot record they originally edited.
    /// Task 7 resolves those conflicts when returning changes to the Mac; at
    /// rest we validate only the change's own shape and bounds.
    private static func validateQueue(_ queue: [MobileChange], deviceID: UUID?) throws {
        guard queue.count <= MobilePackageService.maximumCollectionCount,
              Set(queue.map(changeID)).count == queue.count,
              let deviceID else { throw MobileLibraryStoreError.invalidQueue }
        for change in queue {
            switch change {
            case .noteRevision(let value):
                guard validString(value.noteID), validString(value.ownerID), validString(value.text), isSafeRevision(value.baseRevision), value.createdAt.timeIntervalSince1970.isFinite,
                      value.deviceID == deviceID else { throw MobileLibraryStoreError.invalidQueue }
            case .checklistCompletion(let value):
                guard validString(value.itemID), isSafeRevision(value.baseRevision), value.createdAt.timeIntervalSince1970.isFinite,
                      value.deviceID == deviceID else { throw MobileLibraryStoreError.invalidQueue }
            }
        }
    }

    private static func cleanupOwnedStagingDirectory(_ directory: URL, fileManager: FileManager) {
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true, UUID(uuidString: child.lastPathComponent) != nil else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    private static func isSafeRevision(_ revision: Int?) -> Bool {
        guard let revision else { return true }
        return revision >= 0 && revision <= maximumRevision
    }

    private static func validateKeyFingerprints(_ values: [String: UUID], boundTo receipts: Set<UUID>? = nil) throws {
        guard values.values.count == Set(values.values).count else { throw MobileLibraryStoreError.invalidReceipts }
        if let receipts { guard values.values.allSatisfy(receipts.contains) else { throw MobileLibraryStoreError.invalidReceipts } }
        for (fingerprint, _) in values {
            guard fingerprint.count == 64,
                  fingerprint.allSatisfy({ $0.isNumber || ($0 >= "a" && $0 <= "f") }) else {
                throw MobileLibraryStoreError.invalidReceipts
            }
        }
    }

    private static func changeID(_ change: MobileChange) -> UUID {
        switch change {
        case .checklistCompletion(let value): return value.changeID
        case .noteRevision(let value): return value.changeID
        }
    }

    /// Returns whether the replacement committed but its parent directory
    /// could not be synced. That is a warning, not a false rollback result.
    private static func durableWrite(_ data: Data, to destination: URL) throws -> Bool {
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
            let parentDescriptor = destination.deletingLastPathComponent().path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            guard parentDescriptor >= 0 else { return true }
            let syncFailed = Darwin.fsync(parentDescriptor) != 0
            let closeFailed = Darwin.close(parentDescriptor) != 0
            return syncFailed || closeFailed
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func commitState(snapshot: MobileLibrarySnapshot?, queue: [MobileChange], receipts: Set<UUID>, keyFingerprints: [String: UUID]) throws {
        try Self.validateQueue(queue, deviceID: deviceID)
        guard let deviceID else { throw MobileLibraryStoreError.invalidDeviceID }
        try Self.validateKeyFingerprints(keyFingerprints, boundTo: receipts)
        let state = PersistedState(snapshot: snapshot, queue: queue, deviceID: deviceID, consumedPackageIDs: receipts.sorted { $0.uuidString < $1.uuidString }, keyFingerprints: keyFingerprints, durabilityWarning: durabilityWarning)
        try testingBeforeStateCommit()
        if try atomicWrite(state, to: stateURL) {
            // Rename already committed the new state. Keep a visible warning
            // through the next successful state write rather than reporting a
            // non-existent rollback.
            durabilityWarning = true
        }
    }

    private func atomicWrite<T: Codable>(_ value: T, to destination: URL, validate: ((T) throws -> Void)? = nil) throws -> Bool {
        do {
            let data = try MobileJSON.encoder.encode(value)
            let decoded = try MobileJSON.decoder.decode(T.self, from: data)
            try validate?(decoded)
            return try writeRaw(data, to: destination)
        } catch let error as MobileLibraryStoreError { throw error } catch { throw MobileLibraryStoreError.persistenceFailed }
    }

    private func writeRaw(_ data: Data, to destination: URL) throws -> Bool {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tracksDurability = destination == stateURL
        if tracksDurability {
            // This operation-owned journal makes a post-rename parent-sync
            // uncertainty survive process death. It is overwritten, never
            // deleted, only after the replacement is fully synced.
            _ = try Self.durableWrite(Data("pending".utf8), to: durabilityURL)
        }
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
            // The rename is already durable state from the store's point of
            // view. Parent sync is best-effort and reported as a warning.
            guard parentDescriptor >= 0 else { return true }
            let syncFailed = Darwin.fsync(parentDescriptor) != 0
            let closeFailed = Darwin.close(parentDescriptor) != 0
            let uncertain = syncFailed || closeFailed
            if tracksDurability && !uncertain {
                _ = try Self.durableWrite(Data("clear".utf8), to: durabilityURL)
            }
            return uncertain
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
