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
    case renamedBeforeDirectorySync(String)
    case cleanupUnlinked(String)
    case published(String)
}

struct LibraryMutationSimulatedCrash: Error, Sendable {}

public actor LibraryMutationAuthorizer {
    private struct FileState: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let owner: UInt32
        let linkCount: UInt64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            mode = UInt32(value.st_mode)
            size = Int64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            owner = UInt32(value.st_uid)
            linkCount = UInt64(value.st_nlink)
        }

        var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
        var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
        var permissions: UInt32 { mode & 0o777 }

        func isSameObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
                && owner == other.owner
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

    private enum JournalOperation: String, Codable, Equatable, Sendable {
        case apply
        case rollback
    }

    private enum JournalRecordKind: String, Codable, Equatable, Sendable {
        case pending
        case intent
        case progress
        case completed
        case aborted
        case recovered
    }

    private struct JournalRecord: Codable, Equatable, Sendable {
        let version: Int
        let transactionNonce: UUID
        let operation: JournalOperation
        let kind: JournalRecordKind
        let receipt: MutationReceipt
        let entryIndex: Int?
    }

    private struct JournalEnvelope: Codable, Sendable {
        let record: JournalRecord
        let authenticationCode: String
    }

    private struct PendingTransaction {
        let record: JournalRecord
        let intendedEntries: Set<Int>
    }

    private struct JournalChain {
        var records: [JournalRecord] = []
    }

    private struct LoadedJournal {
        var receipts: [UUID: MutationReceipt] = [:]
        var usedPlans: Set<UUID> = []
        var rolledBackReceipts: Set<UUID> = []
        var incompleteTransactions: [PendingTransaction] = []
    }

    private struct FileObservation {
        let state: FileState
        let fingerprint: String
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
    private let journalKey: Data
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
            Self.isSecureJournalDirectory(journalPathState)
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

        let key: Data
        var loaded: LoadedJournal
        do {
            key = try Self.loadOrCreateJournalKey(descriptor: journalDescriptor)
            loaded = try Self.loadJournal(
                descriptor: journalDescriptor,
                identity: identity,
                root: root,
                key: key
            )
            for transaction in loaded.incompleteTransactions {
                try Self.reconcile(
                    transaction,
                    root: root,
                    rootDescriptor: rootDescriptor,
                    journalDescriptor: journalDescriptor,
                    key: key
                )
            }
            loaded.incompleteTransactions.removeAll()
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
        self.journalKey = key
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
        let transactionNonce = UUID()
        try publishRecord(
            receipt: receipt,
            nonce: transactionNonce,
            operation: .apply,
            kind: .pending,
            entryIndex: nil,
            suffix: "pending"
        )

        var completed: [PreparedMove] = []
        do {
            for (index, move) in prepared.enumerated() {
                try beforeMove(index)
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .apply,
                    kind: .intent,
                    entryIndex: index,
                    suffix: String(format: "intent-%06d", index + 1)
                )
                try performRename(move)
                completed.append(move)
                try afterRename(index)
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .apply,
                    kind: .progress,
                    entryIndex: index,
                    suffix: String(format: "progress-%06d", completed.count)
                )
                guard Self.fileState(name: move.destinationName, relativeTo: move.destinationParent) == move.sourceState else {
                    throw LibraryMutationError.stalePlan
                }
            }
            try publishRecord(
                receipt: receipt,
                nonce: transactionNonce,
                operation: .apply,
                kind: .completed,
                entryIndex: nil,
                suffix: "receipt"
            )
            receipts[receipt.id] = receipt
            usedPlans.insert(plan.id)
            return receipt
        } catch {
            if error is LibraryMutationSimulatedCrash { throw error }
            if error as? LibraryMutationError == .incompleteTransaction { throw error }
            do {
                try restore(completed)
            } catch {
                throw LibraryMutationError.partialRollbackFailed
            }
            do {
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .apply,
                    kind: .aborted,
                    entryIndex: nil,
                    suffix: "aborted"
                )
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
        let transactionNonce = UUID()
        try publishRecord(
            receipt: receipt,
            nonce: transactionNonce,
            operation: .rollback,
            kind: .pending,
            entryIndex: nil,
            suffix: "rollback-pending"
        )

        var completed: [PreparedMove] = []
        do {
            for (index, move) in prepared.enumerated() {
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .rollback,
                    kind: .intent,
                    entryIndex: index,
                    suffix: String(format: "rollback-intent-%06d", index + 1)
                )
                try performRename(move)
                completed.append(move)
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .rollback,
                    kind: .progress,
                    entryIndex: index,
                    suffix: String(format: "rollback-progress-%06d", completed.count)
                )
                guard Self.fileState(name: move.destinationName, relativeTo: move.destinationParent) == move.sourceState else {
                    throw LibraryMutationError.stalePlan
                }
            }
            try publishRecord(
                receipt: receipt,
                nonce: transactionNonce,
                operation: .rollback,
                kind: .completed,
                entryIndex: nil,
                suffix: "rolledback"
            )
            rolledBackReceipts.insert(receiptID)
        } catch {
            if error as? LibraryMutationError == .incompleteTransaction { throw error }
            do {
                try restore(completed)
            } catch {
                throw LibraryMutationError.partialRollbackFailed
            }
            do {
                try publishRecord(
                    receipt: receipt,
                    nonce: transactionNonce,
                    operation: .rollback,
                    kind: .aborted,
                    entryIndex: nil,
                    suffix: "rollback-aborted"
                )
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

    private func publishRecord(
        receipt: MutationReceipt,
        nonce: UUID,
        operation: JournalOperation,
        kind: JournalRecordKind,
        entryIndex: Int?,
        suffix: String
    ) throws {
        try validatePinnedRoots()
        let record = JournalRecord(
            version: 1,
            transactionNonce: nonce,
            operation: operation,
            kind: kind,
            receipt: receipt,
            entryIndex: entryIndex
        )
        let filename = Self.filename(for: receipt.id, nonce: nonce, suffix: suffix)
        try Self.publish(
            envelope: Self.authenticatedEnvelope(for: record, key: journalKey),
            filename: filename,
            descriptor: journalDescriptor,
            stage: journalStage
        )
    }

    private static func filename(for id: UUID, nonce: UUID, suffix: String) -> String {
        "\(id.uuidString.lowercased()).\(nonce.uuidString.lowercased()).\(suffix).json"
    }

    private static func publish(
        envelope: JournalEnvelope,
        filename: String,
        descriptor journalDescriptor: Int32,
        stage: @Sendable (LibraryMutationJournalStage) throws -> Void
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else {
            throw LibraryMutationError.journalWriteFailed
        }
        let temporary = ".tmp-\(UUID().uuidString.lowercased())"
        var fileDescriptor = temporary.withCString {
            Darwin.openat(
                journalDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else { throw LibraryMutationError.journalWriteFailed }
        var temporaryExists = true
        defer {
            if fileDescriptor >= 0 { Darwin.close(fileDescriptor) }
            if temporaryExists {
                _ = temporary.withCString { Darwin.unlinkat(journalDescriptor, $0, 0) }
            }
        }
        do {
            try write(data, to: fileDescriptor)
            guard Darwin.fsync(fileDescriptor) == 0 else {
                throw LibraryMutationError.journalWriteFailed
            }
            try stage(.temporarySynced(filename))
        } catch {
            throw LibraryMutationError.journalWriteFailed
        }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1

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

        do {
            try stage(.renamedBeforeDirectorySync(filename))
            guard Darwin.fsync(journalDescriptor) == 0 else {
                throw LibraryMutationError.journalWriteFailed
            }
        } catch {
            let unlinked = filename.withCString { Darwin.unlinkat(journalDescriptor, $0, 0) }
            do {
                guard unlinked == 0 else { throw LibraryMutationError.incompleteTransaction }
                try stage(.cleanupUnlinked(filename))
                guard Darwin.fsync(journalDescriptor) == 0 else {
                    throw LibraryMutationError.incompleteTransaction
                }
            } catch {
                throw LibraryMutationError.incompleteTransaction
            }
            throw LibraryMutationError.journalWriteFailed
        }
        try? stage(.published(filename))
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
            Self.fileState(descriptor: journalDescriptor).map(Self.isSecureJournalDirectory) == true,
            Self.fileState(descriptor: reopenedJournal).map(Self.isSecureJournalDirectory) == true,
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
        root: URL,
        key: Data
    ) throws -> LoadedJournal {
        var loaded = LoadedJournal()
        var chains: [UUID: JournalChain] = [:]

        for name in try directoryEntryNames(descriptor: descriptor) {
            if name == ".journal-key" || name.hasPrefix(".tmp-") { continue }
            guard name.hasSuffix(".json") else {
                throw LibraryMutationError.invalidJournalRecord
            }
            let envelope: JournalEnvelope
            do {
                envelope = try JSONDecoder().decode(
                    JournalEnvelope.self,
                    from: read(name: name, descriptor: descriptor)
                )
            } catch {
                throw LibraryMutationError.invalidJournalRecord
            }
            guard verify(envelope: envelope, key: key) else {
                throw LibraryMutationError.invalidJournalRecord
            }
            try authenticate(
                envelope.record,
                filename: name,
                identity: identity,
                root: root
            )
            chains[envelope.record.transactionNonce, default: JournalChain()]
                .records.append(envelope.record)
        }

        var rolledBackRecords: [UUID: MutationReceipt] = [:]
        for chain in chains.values {
            let pendingRecords = chain.records.filter { $0.kind == .pending }
            guard pendingRecords.count == 1, let pending = pendingRecords.first else {
                throw LibraryMutationError.invalidJournalRecord
            }
            guard chain.records.allSatisfy({ record in
                record.transactionNonce == pending.transactionNonce
                    && record.operation == pending.operation
                    && record.receipt == pending.receipt
            }) else {
                throw LibraryMutationError.invalidJournalRecord
            }
            let intents = try uniqueEntryIndexes(kind: .intent, records: chain.records)
            let progress = try uniqueEntryIndexes(kind: .progress, records: chain.records)
            let terminals = chain.records.filter {
                $0.kind == .completed || $0.kind == .aborted || $0.kind == .recovered
            }
            guard terminals.count <= 1 else { throw LibraryMutationError.invalidJournalRecord }
            guard let terminal = terminals.first else {
                loaded.incompleteTransactions.append(PendingTransaction(
                    record: pending,
                    intendedEntries: intents
                ))
                continue
            }
            if terminal.kind == .completed {
                let allEntries = Set(pending.receipt.entries.indices)
                guard intents == allEntries, progress == allEntries else {
                    throw LibraryMutationError.invalidJournalRecord
                }
                if pending.operation == .apply {
                    guard loaded.receipts[pending.receipt.id] == nil else {
                        throw LibraryMutationError.invalidJournalRecord
                    }
                    loaded.receipts[pending.receipt.id] = pending.receipt
                    loaded.usedPlans.insert(pending.receipt.planID)
                } else {
                    guard rolledBackRecords[pending.receipt.id] == nil else {
                        throw LibraryMutationError.invalidJournalRecord
                    }
                    rolledBackRecords[pending.receipt.id] = pending.receipt
                    loaded.rolledBackReceipts.insert(pending.receipt.id)
                }
            }
        }
        for (id, rolledBackReceipt) in rolledBackRecords {
            guard loaded.receipts[id] == rolledBackReceipt else {
                throw LibraryMutationError.invalidJournalRecord
            }
        }
        return loaded
    }

    private static func uniqueEntryIndexes(
        kind: JournalRecordKind,
        records: [JournalRecord]
    ) throws -> Set<Int> {
        let values = records.filter { $0.kind == kind }.compactMap(\.entryIndex)
        guard values.count == Set(values).count else {
            throw LibraryMutationError.invalidJournalRecord
        }
        return Set(values)
    }

    private static func authenticate(
        _ record: JournalRecord,
        filename: String,
        identity: LibraryIdentity,
        root: URL
    ) throws {
        let receipt = record.receipt
        guard
            record.version == 1,
            receipt.libraryID == identity,
            !receipt.entries.isEmpty,
            receipt.totalBytes >= 0,
            receipt.entries.allSatisfy({ isSHA256($0.fingerprint) }),
            Set(receipt.entries.map { $0.source.standardizedFileURL.path }).count == receipt.entries.count,
            Set(receipt.entries.map { $0.destination.standardizedFileURL.path }).count == receipt.entries.count,
            receipt.entries.allSatisfy({ entry in
                isContained(entry.source, in: root)
                    && isContained(entry.destination, in: root)
                    && entry.source.standardizedFileURL.path != root.standardizedFileURL.path
                    && entry.destination.standardizedFileURL.path != root.standardizedFileURL.path
                    && entry.source.standardizedFileURL != entry.destination.standardizedFileURL
            }),
            filename == expectedFilename(for: record)
        else {
            throw LibraryMutationError.invalidJournalRecord
        }
        switch record.kind {
        case .intent, .progress:
            guard let index = record.entryIndex, receipt.entries.indices.contains(index) else {
                throw LibraryMutationError.invalidJournalRecord
            }
        case .pending, .completed, .aborted, .recovered:
            guard record.entryIndex == nil else {
                throw LibraryMutationError.invalidJournalRecord
            }
        }
    }

    private static func expectedFilename(for record: JournalRecord) -> String {
        let prefix = record.operation == .rollback ? "rollback-" : ""
        let suffix: String
        switch record.kind {
        case .pending: suffix = prefix + "pending"
        case .intent: suffix = prefix + String(format: "intent-%06d", (record.entryIndex ?? -1) + 1)
        case .progress: suffix = prefix + String(format: "progress-%06d", (record.entryIndex ?? -1) + 1)
        case .completed: suffix = record.operation == .apply ? "receipt" : "rolledback"
        case .aborted: suffix = prefix + "aborted"
        case .recovered: suffix = prefix + "recovered"
        }
        return filename(for: record.receipt.id, nonce: record.transactionNonce, suffix: suffix)
    }

    private static func authenticatedEnvelope(for record: JournalRecord, key: Data) -> JournalEnvelope {
        let data = canonicalData(for: record)
        let code = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        )
        return JournalEnvelope(
            record: record,
            authenticationCode: code.map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func verify(envelope: JournalEnvelope, key: Data) -> Bool {
        guard let code = hexadecimalData(envelope.authenticationCode), code.count == 32 else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: canonicalData(for: envelope.record),
            using: SymmetricKey(data: key)
        )
    }

    private static func canonicalData(for record: JournalRecord) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(record)) ?? Data()
    }

    private static func hexadecimalData(_ value: String) -> Data? {
        guard value.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func loadOrCreateJournalKey(descriptor: Int32) throws -> Data {
        let name = ".journal-key"
        var file = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if file < 0, errno == ENOENT {
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            file = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if file < 0, errno == EEXIST {
                file = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
            } else if file >= 0 {
                do {
                    try write(key, to: file)
                    guard Darwin.fsync(file) == 0, Darwin.fsync(descriptor) == 0 else {
                        throw LibraryMutationError.invalidJournalDirectory
                    }
                } catch {
                    Darwin.close(file)
                    _ = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                    throw LibraryMutationError.invalidJournalDirectory
                }
                guard let state = fileState(descriptor: file), isSecureKeyFile(state) else {
                    Darwin.close(file)
                    throw LibraryMutationError.invalidJournalDirectory
                }
                Darwin.close(file)
                return key
            }
        }
        guard file >= 0 else { throw LibraryMutationError.invalidJournalDirectory }
        defer { Darwin.close(file) }
        guard let state = fileState(descriptor: file), isSecureKeyFile(state) else {
            throw LibraryMutationError.invalidJournalDirectory
        }
        var key = Data()
        var buffer = [UInt8](repeating: 0, count: 32)
        while key.count < 32 {
            let count = Darwin.read(file, &buffer, 32 - key.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LibraryMutationError.invalidJournalDirectory }
            key.append(buffer, count: count)
        }
        var extra: UInt8 = 0
        guard Darwin.read(file, &extra, 1) == 0 else {
            throw LibraryMutationError.invalidJournalDirectory
        }
        guard fileState(descriptor: file) == state else {
            throw LibraryMutationError.invalidJournalDirectory
        }
        return key
    }

    private static func reconcile(
        _ transaction: PendingTransaction,
        root: URL,
        rootDescriptor: Int32,
        journalDescriptor: Int32,
        key: Data
    ) throws {
        let pending = transaction.record
        let entries: [LibraryMutationPlan.Entry]
        if pending.operation == .apply {
            entries = pending.receipt.entries
        } else {
            entries = pending.receipt.entries.reversed().map {
                LibraryMutationPlan.Entry(
                    source: $0.destination,
                    destination: $0.source,
                    fingerprint: $0.fingerprint
                )
            }
        }
        var moved: [Int] = []
        for (index, entry) in entries.enumerated() {
            let source = try observe(entry.source, root: root, rootDescriptor: rootDescriptor)
            let destination = try observe(entry.destination, root: root, rootDescriptor: rootDescriptor)
            if source?.fingerprint == entry.fingerprint, destination == nil {
                continue
            }
            if source == nil,
               destination?.fingerprint == entry.fingerprint,
               transaction.intendedEntries.contains(index) {
                moved.append(index)
                continue
            }
            throw LibraryMutationError.incompleteTransaction
        }

        for index in moved.reversed() {
            let entry = entries[index]
            let sourceComponents = try relativeComponents(
                for: entry.destination,
                root: root
            )
            let destinationComponents = try relativeComponents(
                for: entry.source,
                root: root
            )
            let sourceParent = try openParent(
                components: sourceComponents,
                rootDescriptor: rootDescriptor
            )
            defer { Darwin.close(sourceParent.descriptor) }
            let destinationParent = try openParent(
                components: destinationComponents,
                rootDescriptor: rootDescriptor
            )
            defer { Darwin.close(destinationParent.descriptor) }
            let renamed = sourceParent.name.withCString { sourceName in
                destinationParent.name.withCString { destinationName in
                    Darwin.renameatx_np(
                        sourceParent.descriptor,
                        sourceName,
                        destinationParent.descriptor,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renamed == 0,
                  Darwin.fsync(sourceParent.descriptor) == 0,
                  Darwin.fsync(destinationParent.descriptor) == 0
            else {
                throw LibraryMutationError.incompleteTransaction
            }
        }

        let recovered = JournalRecord(
            version: 1,
            transactionNonce: pending.transactionNonce,
            operation: pending.operation,
            kind: .recovered,
            receipt: pending.receipt,
            entryIndex: nil
        )
        let suffix = pending.operation == .apply ? "recovered" : "rollback-recovered"
        do {
            try publish(
                envelope: authenticatedEnvelope(for: recovered, key: key),
                filename: filename(
                    for: pending.receipt.id,
                    nonce: pending.transactionNonce,
                    suffix: suffix
                ),
                descriptor: journalDescriptor,
                stage: { _ in }
            )
        } catch {
            throw LibraryMutationError.incompleteTransaction
        }
    }

    private static func observe(
        _ url: URL,
        root: URL,
        rootDescriptor: Int32
    ) throws -> FileObservation? {
        let components = try relativeComponents(for: url, root: root)
        let parent = try openParent(components: components, rootDescriptor: rootDescriptor)
        defer { Darwin.close(parent.descriptor) }
        var status = stat()
        let exists = parent.name.withCString {
            Darwin.fstatat(parent.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) == 0
        }
        if !exists, errno == ENOENT { return nil }
        guard exists else { throw LibraryMutationError.incompleteTransaction }
        let observed = FileState(status)
        guard observed.isRegularFile else { throw LibraryMutationError.incompleteTransaction }
        let file = parent.name.withCString {
            Darwin.openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else { throw LibraryMutationError.incompleteTransaction }
        defer { Darwin.close(file) }
        guard fileState(descriptor: file) == observed else {
            throw LibraryMutationError.incompleteTransaction
        }
        do {
            return FileObservation(
                state: observed,
                fingerprint: try hash(descriptor: file, expected: observed)
            )
        } catch {
            throw LibraryMutationError.incompleteTransaction
        }
    }

    private static func relativeComponents(for url: URL, root: URL) throws -> [String] {
        let candidate = url.standardizedFileURL
        guard isContained(candidate, in: root), candidate.path != root.path else {
            throw LibraryMutationError.incompleteTransaction
        }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let components = String(candidate.path.dropFirst(prefix.count))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw LibraryMutationError.incompleteTransaction
        }
        return components
    }

    private static func openParent(
        components: [String],
        rootDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String) {
        guard let name = components.last else { throw LibraryMutationError.incompleteTransaction }
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw LibraryMutationError.incompleteTransaction }
        do {
            for component in components.dropLast() {
                let next = component.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw LibraryMutationError.incompleteTransaction }
                Darwin.close(descriptor)
                descriptor = next
            }
            return (descriptor, name)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func read(name: String, descriptor: Int32) throws -> Data {
        let file = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else { throw LibraryMutationError.invalidJournalRecord }
        defer { Darwin.close(file) }
        guard let state = fileState(descriptor: file), state.isRegularFile,
              state.size >= 0, state.size <= 16 * 1_024 * 1_024,
              state.owner == UInt32(Darwin.geteuid()),
              state.permissions == 0o600,
              state.linkCount == 1
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

    private static func isSecureJournalDirectory(_ state: FileState) -> Bool {
        state.isDirectory
            && state.owner == UInt32(Darwin.geteuid())
            && state.permissions == 0o700
            && state.linkCount >= 2
    }

    private static func isSecureKeyFile(_ state: FileState) -> Bool {
        state.isRegularFile
            && state.owner == UInt32(Darwin.geteuid())
            && state.permissions == 0o600
            && state.linkCount == 1
            && state.size == 32
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
