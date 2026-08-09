import Foundation

public enum SessionConversionStatus: String, Codable, Sendable {
    case applied
    case rolledBack = "rolled_back"
}

public struct ConversionAssignmentBackup: Codable, Equatable, Sendable {
    public var fileID: Int64
    public var previous: FileCaptureAssignmentRecord?

    public init(fileID: Int64, previous: FileCaptureAssignmentRecord?) {
        self.fileID = fileID
        self.previous = previous
    }
}

public struct ConversionSourceBackup: Codable, Equatable, Sendable {
    public var relativePath: String
    public var previous: CaptureSourceRecord?

    public init(relativePath: String, previous: CaptureSourceRecord?) {
        self.relativePath = relativePath
        self.previous = previous
    }
}

public struct ConversionMetadataBackup: Codable, Equatable, Sendable {
    public var createdGroupIDs: [Int64]
    public var createdGroupSlugs: [String]
    public var assignmentBackups: [ConversionAssignmentBackup]
    public var sourceBackups: [ConversionSourceBackup]

    public init(
        createdGroupIDs: [Int64] = [],
        createdGroupSlugs: [String] = [],
        assignmentBackups: [ConversionAssignmentBackup] = [],
        sourceBackups: [ConversionSourceBackup] = []
    ) {
        self.createdGroupIDs = createdGroupIDs
        self.createdGroupSlugs = createdGroupSlugs
        self.assignmentBackups = assignmentBackups
        self.sourceBackups = sourceBackups
    }
}

public struct SessionConversionReceipt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var planID: String
    public var scope: SessionConversionScope
    public var mode: SessionConversionMode
    public var status: SessionConversionStatus
    public var appliedAt: Double
    public var rolledBackAt: Double?
    public var moves: [ConversionMove]
    public var metadataBackup: ConversionMetadataBackup
    public var planRelativePath: String
    public var receiptRelativePath: String

    public init(
        id: String,
        planID: String,
        scope: SessionConversionScope,
        mode: SessionConversionMode,
        status: SessionConversionStatus,
        appliedAt: Double,
        rolledBackAt: Double? = nil,
        moves: [ConversionMove],
        metadataBackup: ConversionMetadataBackup,
        planRelativePath: String,
        receiptRelativePath: String
    ) {
        self.id = id
        self.planID = planID
        self.scope = scope
        self.mode = mode
        self.status = status
        self.appliedAt = appliedAt
        self.rolledBackAt = rolledBackAt
        self.moves = moves
        self.metadataBackup = metadataBackup
        self.planRelativePath = planRelativePath
        self.receiptRelativePath = receiptRelativePath
    }
}

/// Applies one previously previewed plan. Logical mode changes only capture
/// metadata; physical mode additionally performs the exact listed moves.
/// Any failure after the first mutation triggers reverse-order rollback.
public enum SessionConversionExecutor {
    @discardableResult
    public static func apply(
        plan: SessionConversionPlan,
        root: URL,
        db: Database,
        now: Date = Date(),
        failureAfterMoves: Int? = nil
    ) throws -> SessionConversionReceipt {
        guard plan.canApply else {
            throw AstroError.invalidInput("A konverziós tervben még blokkoló bizonytalanság vagy ütközés van.")
        }
        let guard_ = WriteGuard(root: root)
        let currentFingerprint = try filesystemFingerprint(root: root, scope: plan.scope)
        guard currentFingerprint == plan.sourceFingerprint else {
            throw AstroError.invalidInput(
                "A session tartalma megváltozott az előnézet óta. Készíts új konverziós tervet."
            )
        }
        for move in plan.moves {
            try guard_.preflightConversionMove(
                sourceRelative: move.sourceRelative,
                destinationRelative: move.destinationRelative,
                scope: plan.scope
            )
        }

        let conversionID = UUID().uuidString.lowercased()
        let base = "conversions/\(conversionID)"
        let planToolRelative = "\(base)/plan.json"
        let receiptToolRelative = "\(base)/receipt.json"
        let planLibraryRelative = ".astro_tool/\(planToolRelative)"
        let receiptLibraryRelative = ".astro_tool/\(receiptToolRelative)"
        _ = try guard_.writeToolFile(relativePath: planToolRelative, data: try encoded(plan))

        var backup: ConversionMetadataBackup?
        var executedMoves: [ConversionMove] = []
        do {
            let metadataBackup = try db.applySessionConversionMetadata(plan: plan, now: now.timeIntervalSince1970)
            backup = metadataBackup
            for directory in plan.directoryCreations {
                _ = try guard_.ensureConversionDirectory(
                    relativePath: directory.relativePath,
                    scope: plan.scope
                )
            }
            for move in plan.moves {
                try guard_.moveConversionFile(
                    sourceRelative: move.sourceRelative,
                    destinationRelative: move.destinationRelative,
                    scope: plan.scope
                )
                executedMoves.append(move)
                if let failureAfterMoves, executedMoves.count == failureAfterMoves {
                    throw AstroError.invalidInput("Szimulált konverziós hiba a rollback tesztjéhez.")
                }
            }

            let receipt = SessionConversionReceipt(
                id: conversionID,
                planID: plan.id,
                scope: plan.scope,
                mode: plan.mode,
                status: .applied,
                appliedAt: now.timeIntervalSince1970,
                moves: executedMoves,
                metadataBackup: metadataBackup,
                planRelativePath: planLibraryRelative,
                receiptRelativePath: receiptLibraryRelative
            )
            _ = try guard_.writeToolFile(relativePath: receiptToolRelative, data: try encoded(receipt))
            return receipt
        } catch {
            var rollbackError: Error?
            for move in executedMoves.reversed() {
                do {
                    try guard_.rollbackConversionMove(move, scope: plan.scope)
                } catch {
                    rollbackError = error
                    break
                }
            }
            if let backup {
                do {
                    try db.rollbackSessionConversionMetadata(backup)
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackError {
                throw AstroError.databaseError(
                    "A konverzió hibázott, és az automatikus visszaállítás sem volt teljes: \(rollbackError)"
                )
            }
            throw error
        }
    }

    @discardableResult
    public static func rollback(
        receipt: SessionConversionReceipt,
        root: URL,
        db: Database,
        now: Date = Date()
    ) throws -> SessionConversionReceipt {
        guard receipt.status == .applied else {
            throw AstroError.invalidInput("Ez a konverzió már vissza lett állítva.")
        }
        let guard_ = WriteGuard(root: root)
        for move in receipt.moves.reversed() {
            try guard_.preflightConversionMove(
                sourceRelative: move.destinationRelative,
                destinationRelative: move.sourceRelative,
                scope: receipt.scope
            )
        }

        var reversedMoves: [ConversionMove] = []
        do {
            for move in receipt.moves.reversed() {
                try guard_.rollbackConversionMove(move, scope: receipt.scope)
                reversedMoves.append(move)
            }
            try db.rollbackSessionConversionMetadata(receipt.metadataBackup)
        } catch {
            // If metadata rollback fails, put the already reversed files back
            // into their applied destinations so the receipt remains truthful.
            for move in reversedMoves.reversed() {
                try? guard_.moveConversionFile(
                    sourceRelative: move.sourceRelative,
                    destinationRelative: move.destinationRelative,
                    scope: receipt.scope
                )
            }
            throw error
        }

        var updated = receipt
        updated.status = .rolledBack
        updated.rolledBackAt = now.timeIntervalSince1970
        let toolRelative = String(updated.receiptRelativePath.dropFirst(".astro_tool/".count))
        _ = try guard_.writeToolFile(relativePath: toolRelative, data: try encoded(updated))
        return updated
    }

    public static func loadReceipt(id: String, root: URL) throws -> SessionConversionReceipt {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw AstroError.invalidInput("Érvénytelen konverzióazonosító.")
        }
        let url = root.appendingPathComponent(".astro_tool/conversions/\(id)/receipt.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AstroError.pathNotFound(path: url.path)
        }
        return try JSONDecoder().decode(SessionConversionReceipt.self, from: Data(contentsOf: url))
    }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func filesystemFingerprint(
        root: URL,
        scope: SessionConversionScope
    ) throws -> ConversionSourceFingerprint {
        let fm = FileManager.default
        let branches = ["sessions", "stacks", "processed"].map {
            root.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent(scope.target, isDirectory: true)
                .appendingPathComponent(scope.date, isDirectory: true)
        }
        var records: [FileRecord] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for branch in branches where fm.fileExists(atPath: branch.path) {
            guard let enumerator = fm.enumerator(
                at: branch,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            ) else {
                throw AstroError.accessDenied(path: branch.path)
            }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let rootPrefix = root.standardizedFileURL.path + "/"
                let absolute = url.standardizedFileURL.path
                guard absolute.hasPrefix(rootPrefix) else {
                    throw AstroError.writeForbidden(path: absolute)
                }
                let relative = String(absolute.dropFirst(rootPrefix.count))
                let info = PathClassifier.classify(relativePath: relative)
                records.append(
                    FileRecord(
                        path: relative,
                        size: Int64(values.fileSize ?? 0),
                        mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        ext: url.pathExtension.lowercased(),
                        kind: "fingerprint",
                        area: info.area,
                        target: info.target,
                        sessionDate: info.dateRaw,
                        role: info.role,
                        scannedAt: 0
                    )
                )
            }
        }
        return SessionConversionPlanner.sourceFingerprint(records)
    }
}
