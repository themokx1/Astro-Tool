import CryptoKit
import Darwin
import Foundation

public enum LibraryMutationError: Error, Equatable, Sendable {
    case invalidRoot
    case staleLibraryIdentity
    case invalidJournalDirectory
    case journalInsideLibrary
    case invalidJournalRecord
    case incompleteTransaction
    case readOnly
    case libraryIdentityMismatch
    case staleRevision
    case invalidPlan
    case planAlreadyRegistered
    case unknownPlan
    case invalidConfirmation
    case sourceOutsideLibrary
    case destinationOutsideLibrary
    case unsafeSource
    case unsafeDestination
    case stalePlan
    case collision
    case planAlreadyUsed
    case journalWriteFailed
    case partialRollbackFailed
    case unknownReceipt
    case rollbackCollision
    case receiptAlreadyRolledBack
}

enum LibraryMutationJournalStage: Equatable, Sendable {
    case temporarySynced(String)
    case published(String)
}

public actor LibraryMutationAuthorizer {
    private struct FileState: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            mode = UInt32(value.st_mode)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }

        var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
        var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }

        func isSameObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
        }
    }

    private struct PreparedMove {
        let entry: LibraryMutationPlan.Entry
        let sourceDescriptor: Int32
        let sourceParent: Int32
        let sourceName: String
        let destinationParent: Int32
        let destinationName: String
        let sourceState: FileState

        func close() {
            Darwin.close(sourceDescriptor)
            Darwin.close(sourceParent)
            Darwin.close(destinationParent)
        }
    }

    private struct JournalTransaction: Codable {
        let version: Int
        let receipt: MutationReceipt
        let completedEntryCount: Int
    }

    private struct LoadedJournal {
        var receipts: [UUID: MutationReceipt] = [:]
        var usedPlans: Set<UUID> = []
        var rolledBackReceipts: Set<UUID> = []
    }

    private let root: URL
    private let identity: LibraryIdentity
    private let currentRevision: UInt64
    private let accessMode: LibraryAccessMode
    private let journalDirectory: URL
    private let rootDescriptor: Int32
    private let journalDescriptor: Int32
    private let rootState: FileState
    private let journalState: FileState
    private let beforeMove: @Sendable (Int) throws -> Void
    private let afterRename: @Sendable (Int) throws -> Void
    private let journalStage: @Sendable (LibraryMutationJournalStage) throws -> Void

    private var plans: [UUID: LibraryMutationPlan] = [:]
    private var usedPlans: Set<UUID>
    private var receipts: [UUID: MutationReceipt]
    private var rolledBackReceipts: Set<UUID>

    public init(
        root: URL,
        identity: LibraryIdentity,
        currentRevision: UInt64,
        accessMode: LibraryAccessMode,
        journalDirectory: URL
    ) throws {
        try self.init(
            root: root,
            identity: identity,
            currentRevision: currentRevision,
            accessMode: accessMode,
            journalDirectory: journalDirectory,
            beforeMove: { _ in },
            afterRename: { _ in },
            journalStage: { _ in }
        )
    }

    init(
        root: URL,
        identity: LibraryIdentity,
        currentRevision: UInt64,
        accessMode: LibraryAccessMode,
        journalDirectory: URL,
        beforeMove: @escaping @Sendable (Int) throws -> Void,
        afterRename: @escaping @Sendable (Int) throws -> Void,
        journalStage: @escaping @Sendable (LibraryMutationJournalStage) throws -> Void
    ) throws {
        let root = root.standardizedFileURL
        guard
            let rootPathState = Self.fileState(at: root),
            rootPathState.isDirectory,
            !Self.isSymbolicLink(at: root),
            identity == LibraryIdentity(rootURL: root)
        else {
            throw LibraryMutationError.invalidRoot
        }
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard
            rootDescriptor >= 0,
            let openedRootState = Self.fileState(descriptor: rootDescriptor),
            openedRootState == rootPathState
        else {
            if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
            throw LibraryMutationError.invalidRoot
        }

        let journal = journalDirectory.standardizedFileURL
        guard
            let canonicalJournal = Self.canonicalExistingPath(journal),
            let canonicalRoot = Self.canonicalExistingPath(root)
        else {
            Darwin.close(rootDescriptor)
            throw LibraryMutationError.invalidJournalDirectory
        }
        guard !Self.isContained(canonicalJournal, in: canonicalRoot) else {
            Darwin.close(rootDescriptor)
            throw LibraryMutationError.journalInsideLibrary
        }
        guard
            !Self.isSymbolicLink(at: journal),
            let journalPathState = Self.fileState(at: journal),
            journalPathState.isDirectory
        else {
            Darwin.close(rootDescriptor)
            throw LibraryMutationError.invalidJournalDirectory
        }
        let journalDescriptor = Self.openAbsoluteDirectory(canonicalJournal)
        guard
            journalDescriptor >= 0,
            let openedJournalState = Self.fileState(descriptor: journalDescriptor),
            openedJournalState == journalPathState
        else {
            Darwin.close(rootDescriptor)
            if journalDescriptor >= 0 { Darwin.close(journalDescriptor) }
            throw LibraryMutationError.invalidJournalDirectory
        }

        let loaded: LoadedJournal
        do {
            loaded = try Self.loadJournal(
                descriptor: journalDescriptor,
                identity: identity,
                revision: currentRevision
            )
        } catch {
            Darwin.close(rootDescriptor)
            Darwin.close(journalDescriptor)
            throw error
        }

        self.root = root
        self.identity = identity
        self.currentRevision = currentRevision
        self.accessMode = accessMode
        self.journalDirectory = canonicalJournal
        self.rootDescriptor = rootDescriptor
        self.journalDescriptor = journalDescriptor
        self.rootState = rootPathState
        self.journalState = journalPathState
        self.beforeMove = beforeMove
        self.afterRename = afterRename
        self.journalStage = journalStage
        self.receipts = loaded.receipts
        self.usedPlans = loaded.usedPlans
        self.rolledBackReceipts = loaded.rolledBackReceipts
    }

    deinit {
        Darwin.close(rootDescriptor)
        Darwin.close(journalDescriptor)
    }

    public func register(_ plan: LibraryMutationPlan) throws {
        guard plan.libraryID == identity else { throw LibraryMutationError.libraryIdentityMismatch }
        guard plan.revision == currentRevision else { throw LibraryMutationError.staleRevision }
        guard plans[plan.id] == nil, !usedPlans.contains(plan.id) else {
            throw LibraryMutationError.planAlreadyRegistered
        }
        guard
            !plan.entries.isEmpty,
            plan.totalBytes >= 0,
            !plan.confirmationToken.isEmpty,
            Set(plan.entries.map { $0.source.standardizedFileURL.path }).count == plan.entries.count,
            Set(plan.entries.map { $0.destination.standardizedFileURL.path }).count == plan.entries.count
        else {
            throw LibraryMutationError.invalidPlan
        }

        for entry in plan.entries {
            guard Self.isSHA256(entry.fingerprint) else { throw LibraryMutationError.invalidPlan }
            let sourceComponents = try relativeComponents(
                for: entry.source,
                outsideError: .sourceOutsideLibrary
            )
            let destinationComponents = try relativeComponents(
                for: entry.destination,
                outsideError: .destinationOutsideLibrary
            )
            guard sourceComponents != destinationComponents else {
                throw LibraryMutationError.invalidPlan
            }
            let source = try openSource(components: sourceComponents)
            Darwin.close(source.descriptor)
            let destinationParent = try openParent(
                components: destinationComponents,
                error: .unsafeDestination
            )
            Darwin.close(destinationParent.descriptor)
        }
        plans[plan.id] = plan
    }

    public func apply(planID: UUID, confirmation: String) async throws -> MutationReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        guard !usedPlans.contains(planID) else { throw LibraryMutationError.planAlreadyUsed }
        guard let plan = plans[planID] else { throw LibraryMutationError.unknownPlan }
        guard confirmation == plan.confirmationToken else {
            throw LibraryMutationError.invalidConfirmation
        }
        guard plan.libraryID == identity else { throw LibraryMutationError.libraryIdentityMismatch }
        guard plan.revision == currentRevision else { throw LibraryMutationError.staleRevision }
        try validatePinnedRoots()

        let prepared = try prepare(plan.entries, rollback: false, expectedTotalBytes: plan.totalBytes)
        defer { prepared.forEach { $0.close() } }
        let receipt = MutationReceipt(
            planID: plan.id,
            libraryID: plan.libraryID,
            revision: plan.revision,
            entries: prepared.map(\.entry),
            totalBytes: plan.totalBytes
        )
        try publishTransaction(receipt, completedEntryCount: 0, suffix: "pending")

        var completed: [PreparedMove] = []
        do {
            for (index, move) in prepared.enumerated() {
                try beforeMove(index)
                try performRename(move)
                completed.append(move)
                try publishTransaction(
                    receipt,
                    completedEntryCount: completed.count,
                    suffix: String(format: "progress-%06d", completed.count)
                )
                try afterRename(index)
                guard Self.fileState(name: move.destinationName, relativeTo: move.destinationParent) == move.sourceState else {
                    throw LibraryMutationError.stalePlan
                }
            }
            try publish(receipt, filename: filename(for: receipt.id, suffix: "receipt"))
            receipts[receipt.id] = receipt
            usedPlans.insert(plan.id)
            return receipt
        } catch {
            do {
                try restore(completed)
            } catch {
                throw LibraryMutationError.partialRollbackFailed
            }
            do {
                try publishTransaction(receipt, completedEntryCount: 0, suffix: "aborted")
            } catch {
                throw LibraryMutationError.journalWriteFailed
            }
            throw error
        }
    }

    public func rollback(receiptID: UUID) async throws {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        guard !rolledBackReceipts.contains(receiptID) else {
            throw LibraryMutationError.receiptAlreadyRolledBack
        }
        guard let receipt = receipts[receiptID] else { throw LibraryMutationError.unknownReceipt }
        guard receipt.libraryID == identity else { throw LibraryMutationError.libraryIdentityMismatch }
        guard receipt.revision == currentRevision else { throw LibraryMutationError.staleRevision }
        try validatePinnedRoots()

        let reverseEntries = receipt.entries.reversed().map {
            LibraryMutationPlan.Entry(
                source: $0.destination,
                destination: $0.source,
                fingerprint: $0.fingerprint
            )
        }
        let prepared: [PreparedMove]
        do {
            prepared = try prepare(reverseEntries, rollback: true, expectedTotalBytes: receipt.totalBytes)
        } catch LibraryMutationError.collision {
            throw LibraryMutationError.rollbackCollision
        }
        defer { prepared.forEach { $0.close() } }
        try publishTransaction(receipt, completedEntryCount: 0, suffix: "rollback-pending")

        var completed: [PreparedMove] = []
        do {
            for move in prepared {
                try performRename(move)
                completed.append(move)
                try publishTransaction(
                    receipt,
                    completedEntryCount: completed.count,
                    suffix: String(format: "rollback-progress-%06d", completed.count)
                )
                guard Self.fileState(name: move.destinationName, relativeTo: move.destinationParent) == move.sourceState else {
                    throw LibraryMutationError.stalePlan
                }
            }
            try publish(receipt, filename: filename(for: receipt.id, suffix: "rolledback"))
            rolledBackReceipts.insert(receiptID)
        } catch {
            do {
                try restore(completed)
            } catch {
                throw LibraryMutationError.partialRollbackFailed
            }
            do {
                try publishTransaction(receipt, completedEntryCount: 0, suffix: "rollback-aborted")
            } catch {
                throw LibraryMutationError.journalWriteFailed
            }
            if error as? LibraryMutationError == .collision {
                throw LibraryMutationError.rollbackCollision
            }
            throw error
        }
    }

    private func prepare(
        _ entries: [LibraryMutationPlan.Entry],
        rollback: Bool,
        expectedTotalBytes: Int64
    ) throws -> [PreparedMove] {
        let sorted = rollback ? entries : entries.sorted {
            ($0.source.standardizedFileURL.path, $0.destination.standardizedFileURL.path)
                < ($1.source.standardizedFileURL.path, $1.destination.standardizedFileURL.path)
        }
        var prepared: [PreparedMove] = []
        var totalBytes: Int64 = 0

        do {
            for entry in sorted {
                let sourceComponents = try relativeComponents(
                    for: entry.source,
                    outsideError: rollback ? .unsafeSource : .sourceOutsideLibrary
                )
                let destinationComponents = try relativeComponents(
                    for: entry.destination,
                    outsideError: rollback ? .unsafeDestination : .destinationOutsideLibrary
                )
                let openedSource = try openSource(components: sourceComponents)
                let observedFingerprint: String
                do {
                    observedFingerprint = try Self.hash(
                        descriptor: openedSource.descriptor,
                        expected: openedSource.state
                    )
                } catch {
                    Darwin.close(openedSource.descriptor)
                    throw error
                }
                guard observedFingerprint == entry.fingerprint else {
                    Darwin.close(openedSource.descriptor)
                    throw LibraryMutationError.stalePlan
                }

                let sourceParent: (descriptor: Int32, name: String)
                do {
                    sourceParent = try openParent(components: sourceComponents, error: .unsafeSource)
                } catch {
                    Darwin.close(openedSource.descriptor)
                    throw error
                }
                let destinationParent: (descriptor: Int32, name: String)
                do {
                    destinationParent = try openParent(
                        components: destinationComponents,
                        error: .unsafeDestination
                    )
                } catch {
                    Darwin.close(openedSource.descriptor)
                    Darwin.close(sourceParent.descriptor)
                    throw error
                }

                var destinationState = stat()
                let destinationExists = destinationParent.name.withCString {
                    Darwin.fstatat(destinationParent.descriptor, $0, &destinationState, AT_SYMLINK_NOFOLLOW) == 0
                }
                guard !destinationExists, errno == ENOENT else {
                    Darwin.close(openedSource.descriptor)
                    Darwin.close(sourceParent.descriptor)
                    Darwin.close(destinationParent.descriptor)
                    if destinationExists { throw LibraryMutationError.collision }
                    throw LibraryMutationError.unsafeDestination
                }

                prepared.append(PreparedMove(
                    entry: entry,
                    sourceDescriptor: openedSource.descriptor,
                    sourceParent: sourceParent.descriptor,
                    sourceName: sourceParent.name,
                    destinationParent: destinationParent.descriptor,
                    destinationName: destinationParent.name,
                    sourceState: openedSource.state
                ))
                let addition = totalBytes.addingReportingOverflow(openedSource.state.size)
                guard !addition.overflow else { throw LibraryMutationError.invalidPlan }
                totalBytes = addition.partialValue
            }
            guard totalBytes == expectedTotalBytes else { throw LibraryMutationError.stalePlan }
            return prepared
        } catch {
            prepared.forEach { $0.close() }
            throw error
        }
    }

    private func performRename(_ move: PreparedMove) throws {
        guard
            Self.fileState(name: move.sourceName, relativeTo: move.sourceParent) == move.sourceState,
            try Self.hash(descriptor: move.sourceDescriptor, expected: move.sourceState) == move.entry.fingerprint
        else {
            throw LibraryMutationError.stalePlan
        }
        var destinationState = stat()
        let destinationExists = move.destinationName.withCString {
            Darwin.fstatat(move.destinationParent, $0, &destinationState, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard !destinationExists, errno == ENOENT else {
            throw LibraryMutationError.collision
        }
        let result = move.sourceName.withCString { sourceName in
            move.destinationName.withCString { destinationName in
                Darwin.renameatx_np(
                    move.sourceParent,
                    sourceName,
                    move.destinationParent,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw LibraryMutationError.collision }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func restore(_ completed: [PreparedMove]) throws {
        for move in completed.reversed() {
            let result = move.destinationName.withCString { destinationName in
                move.sourceName.withCString { sourceName in
                    Darwin.renameatx_np(
                        move.destinationParent,
                        destinationName,
                        move.sourceParent,
                        sourceName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else { throw LibraryMutationError.partialRollbackFailed }
        }
    }

    private func publishTransaction(
        _ receipt: MutationReceipt,
        completedEntryCount: Int,
        suffix: String
    ) throws {
        try publish(
            JournalTransaction(version: 1, receipt: receipt, completedEntryCount: completedEntryCount),
            filename: filename(for: receipt.id, suffix: suffix)
        )
    }

    private func filename(for id: UUID, suffix: String) -> String {
        "\(id.uuidString.lowercased()).\(suffix).json"
    }

    private func publish<Value: Encodable>(_ value: Value, filename: String) throws {
        do {
            try validatePinnedRoots()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            let temporary = ".tmp-\(UUID().uuidString.lowercased())"
            let descriptor = temporary.withCString {
                Darwin.openat(
                    journalDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else { throw LibraryMutationError.journalWriteFailed }
            var temporaryExists = true
            defer {
                Darwin.close(descriptor)
                if temporaryExists {
                    _ = temporary.withCString { Darwin.unlinkat(journalDescriptor, $0, 0) }
                }
            }
            try Self.write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw LibraryMutationError.journalWriteFailed
            }
            try journalStage(.temporarySynced(filename))
            let renamed = temporary.withCString { temporaryName in
                filename.withCString { finalName in
                    Darwin.renameatx_np(
                        journalDescriptor,
                        temporaryName,
                        journalDescriptor,
                        finalName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renamed == 0 else { throw LibraryMutationError.journalWriteFailed }
            temporaryExists = false
            guard Darwin.fsync(journalDescriptor) == 0 else {
                throw LibraryMutationError.journalWriteFailed
            }
            try journalStage(.published(filename))
        } catch {
            throw LibraryMutationError.journalWriteFailed
        }
    }

    private func validatePinnedRoots() throws {
        let reopenedRoot = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if reopenedRoot >= 0 { Darwin.close(reopenedRoot) } }
        guard
            reopenedRoot >= 0,
            Self.fileState(descriptor: rootDescriptor)?.isSameObject(as: rootState) == true,
            Self.fileState(descriptor: reopenedRoot)?.isSameObject(as: rootState) == true,
            Self.fileState(at: root)?.isSameObject(as: rootState) == true
        else {
            throw LibraryMutationError.staleLibraryIdentity
        }
        let reopenedJournal = Self.openAbsoluteDirectory(journalDirectory)
        defer { if reopenedJournal >= 0 { Darwin.close(reopenedJournal) } }
        guard
            reopenedJournal >= 0,
            Self.fileState(descriptor: journalDescriptor)?.isSameObject(as: journalState) == true,
            Self.fileState(descriptor: reopenedJournal)?.isSameObject(as: journalState) == true,
            Self.fileState(at: journalDirectory)?.isSameObject(as: journalState) == true
        else {
            throw LibraryMutationError.invalidJournalDirectory
        }
    }

    private func relativeComponents(
        for url: URL,
        outsideError: LibraryMutationError
    ) throws -> [String] {
        let candidate = url.standardizedFileURL
        guard Self.isContained(candidate, in: root), candidate.path != root.path else {
            throw outsideError
        }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let relative = String(candidate.path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw outsideError
        }
        return components
    }

    private func openSource(components: [String]) throws -> (descriptor: Int32, state: FileState) {
        let parent = try openParent(components: components, error: .unsafeSource)
        defer { Darwin.close(parent.descriptor) }
        let descriptor = parent.name.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard
            descriptor >= 0,
            let state = Self.fileState(descriptor: descriptor),
            state.isRegularFile,
            Self.fileState(name: parent.name, relativeTo: parent.descriptor) == state
        else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw LibraryMutationError.unsafeSource
        }
        return (descriptor, state)
    }

    private func openParent(
        components: [String],
        error: LibraryMutationError
    ) throws -> (descriptor: Int32, name: String) {
        guard let name = components.last else { throw error }
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw error }
        do {
            for component in components.dropLast() {
                let next = component.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw error }
                Darwin.close(descriptor)
                descriptor = next
            }
            return (descriptor, name)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func loadJournal(
        descriptor: Int32,
        identity: LibraryIdentity,
        revision: UInt64
    ) throws -> LoadedJournal {
        var loaded = LoadedJournal()
        var pending: Set<UUID> = []
        var aborted: Set<UUID> = []
        var rollbackPending: Set<UUID> = []
        var rollbackAborted: Set<UUID> = []
        var rolledBackRecords: [UUID: MutationReceipt] = [:]

        for name in try directoryEntryNames(descriptor: descriptor) where !name.hasPrefix(".tmp-") {
            if name.hasSuffix(".receipt.json") {
                let receipt = try decode(MutationReceipt.self, name: name, descriptor: descriptor)
                try authenticate(receipt, filename: name, identity: identity, revision: revision)
                loaded.receipts[receipt.id] = receipt
                loaded.usedPlans.insert(receipt.planID)
            } else if name.hasSuffix(".rolledback.json") {
                let receipt = try decode(MutationReceipt.self, name: name, descriptor: descriptor)
                try authenticate(receipt, filename: name, identity: identity, revision: revision)
                loaded.rolledBackReceipts.insert(receipt.id)
                rolledBackRecords[receipt.id] = receipt
            } else if name.hasSuffix(".json") {
                let transaction = try decode(JournalTransaction.self, name: name, descriptor: descriptor)
                guard transaction.version == 1,
                      (0...transaction.receipt.entries.count).contains(transaction.completedEntryCount)
                else {
                    throw LibraryMutationError.invalidJournalRecord
                }
                try authenticate(
                    transaction.receipt,
                    filename: name,
                    identity: identity,
                    revision: revision
                )
                if name.hasSuffix(".pending.json") { pending.insert(transaction.receipt.id) }
                if name.hasSuffix(".aborted.json") { aborted.insert(transaction.receipt.id) }
                if name.hasSuffix(".rollback-pending.json") { rollbackPending.insert(transaction.receipt.id) }
                if name.hasSuffix(".rollback-aborted.json") { rollbackAborted.insert(transaction.receipt.id) }
            }
        }
        let completed = Set(loaded.receipts.keys)
        guard pending.subtracting(completed).subtracting(aborted).isEmpty else {
            throw LibraryMutationError.incompleteTransaction
        }
        guard rollbackPending.subtracting(loaded.rolledBackReceipts).subtracting(rollbackAborted).isEmpty else {
            throw LibraryMutationError.incompleteTransaction
        }
        guard loaded.rolledBackReceipts.isSubset(of: completed) else {
            throw LibraryMutationError.invalidJournalRecord
        }
        for (id, rolledBackReceipt) in rolledBackRecords {
            guard loaded.receipts[id] == rolledBackReceipt else {
                throw LibraryMutationError.invalidJournalRecord
            }
        }
        return loaded
    }

    private static func authenticate(
        _ receipt: MutationReceipt,
        filename: String,
        identity: LibraryIdentity,
        revision: UInt64
    ) throws {
        let expectedPrefix = receipt.id.uuidString.lowercased() + "."
        guard
            filename.hasPrefix(expectedPrefix),
            receipt.libraryID == identity,
            receipt.revision == revision,
            !receipt.entries.isEmpty,
            receipt.totalBytes >= 0,
            receipt.entries.allSatisfy({ isSHA256($0.fingerprint) })
        else {
            throw LibraryMutationError.invalidJournalRecord
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        name: String,
        descriptor: Int32
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: read(name: name, descriptor: descriptor))
        } catch let error as LibraryMutationError {
            throw error
        } catch {
            throw LibraryMutationError.invalidJournalRecord
        }
    }

    private static func read(name: String, descriptor: Int32) throws -> Data {
        let file = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else { throw LibraryMutationError.invalidJournalRecord }
        defer { Darwin.close(file) }
        guard let state = fileState(descriptor: file), state.isRegularFile,
              state.size >= 0, state.size <= 16 * 1_024 * 1_024
        else {
            throw LibraryMutationError.invalidJournalRecord
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LibraryMutationError.invalidJournalRecord }
            data.append(buffer, count: count)
        }
        guard fileState(descriptor: file) == state else {
            throw LibraryMutationError.invalidJournalRecord
        }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw LibraryMutationError.journalWriteFailed }
                offset += written
            }
        }
    }

    private static func hash(descriptor: Int32, expected: FileState) throws -> String {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw LibraryMutationError.stalePlan
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LibraryMutationError.stalePlan }
            hasher.update(data: Data(buffer[0..<count]))
        }
        guard fileState(descriptor: descriptor) == expected else {
            throw LibraryMutationError.stalePlan
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw LibraryMutationError.invalidJournalDirectory
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw LibraryMutationError.invalidJournalDirectory }
        return names.sorted()
    }

    private static func openAbsoluteDirectory(_ url: URL) -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in url.pathComponents.dropFirst() {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func canonicalExistingPath(_ url: URL) -> URL? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func fileState(descriptor: Int32) -> FileState? {
        var value = stat()
        return Darwin.fstat(descriptor, &value) == 0 ? FileState(value) : nil
    }

    private static func fileState(at url: URL) -> FileState? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &value) } ?? -1
        }
        return result == 0 ? FileState(value) : nil
    }

    private static func fileState(name: String, relativeTo descriptor: Int32) -> FileState? {
        var value = stat()
        let result = name.withCString {
            Darwin.fstatat(descriptor, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? FileState(value) : nil
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        guard let state = fileState(at: url) else { return false }
        return state.mode & UInt32(S_IFMT) == UInt32(S_IFLNK)
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if candidatePath == rootPath { return true }
        return candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
