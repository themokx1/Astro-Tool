import Foundation

public enum FrameArchiveMode: String, Codable, Equatable, Sendable {
    case archive
    case restore
}

/// Exact, previewable one-file move. Both paths are library-root-relative;
/// the target/date scope is carried explicitly so the write boundary can
/// independently reconstruct and validate the operation before touching
/// disk.
public struct FrameArchivePlan: Codable, Equatable, Sendable {
    public var sourceRelative: String
    public var destinationRelative: String
    public var target: String
    public var date: String
    public var mode: FrameArchiveMode

    public init(
        sourceRelative: String,
        destinationRelative: String,
        target: String,
        date: String,
        mode: FrameArchiveMode
    ) {
        self.sourceRelative = sourceRelative
        self.destinationRelative = destinationRelative
        self.target = target
        self.date = date
        self.mode = mode
    }
}

public enum FrameArchivePlanner {
    /// Places `archive` immediately below the frame's own `lights` role
    /// folder. Any existing relative subpath is preserved:
    /// `lights/Review/a.fit` -> `lights/archive/Review/a.fit`.
    public static func plan(sourceRelative: String, mode: FrameArchiveMode) throws -> FrameArchivePlan {
        let components = sourceRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !sourceRelative.hasPrefix("/"), components.count >= 5,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components[0] == "sessions"
        else { throw AstroError.writeForbidden(path: sourceRelative) }

        let roleIndex: Int
        if components.count >= 5, components[3] == "lights" {
            roleIndex = 3
        } else if components.count >= 7, components[3] == "captures", components[5] == "lights" {
            roleIndex = 5
        } else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }
        guard roleIndex + 1 < components.count else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }

        var destination = components
        switch mode {
        case .archive:
            guard components[roleIndex + 1].caseInsensitiveCompare("archive") != .orderedSame else {
                throw AstroError.invalidInput("A frame már archívumban van: \(sourceRelative)")
            }
            destination.insert("archive", at: roleIndex + 1)
        case .restore:
            guard components[roleIndex + 1].caseInsensitiveCompare("archive") == .orderedSame,
                  roleIndex + 2 < components.count
            else { throw AstroError.invalidInput("A frame nincs archívumban: \(sourceRelative)") }
            destination.remove(at: roleIndex + 1)
        }

        return FrameArchivePlan(
            sourceRelative: sourceRelative,
            destinationRelative: destination.joined(separator: "/"),
            target: components[1],
            date: components[2],
            mode: mode
        )
    }

    public static func isArchived(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 5, components.first == "sessions" else { return false }
        if components.count >= 5, components[3] == "lights" {
            return components[4].caseInsensitiveCompare("archive") == .orderedSame
        }
        if components.count >= 7, components[3] == "captures", components[5] == "lights" {
            return components[6].caseInsensitiveCompare("archive") == .orderedSame
        }
        return false
    }
}

public enum FrameArchiveExecutor {
    /// Applies a previewed move while keeping the original `files.id`. All
    /// dependent FITS/rating/verdict/capture rows therefore remain attached.
    /// If the DB path update fails after the filesystem move, the file is
    /// immediately moved back before the error is surfaced.
    @discardableResult
    public static func apply(plan: FrameArchivePlan, root: URL, db: Database) throws -> FileRecord {
        let rebuilt = try FrameArchivePlanner.plan(sourceRelative: plan.sourceRelative, mode: plan.mode)
        guard rebuilt == plan else { throw AstroError.writeForbidden(path: plan.destinationRelative) }
        guard let tracked = try db.file(path: plan.sourceRelative), let fileID = tracked.id,
              tracked.target == plan.target, tracked.sessionDate == plan.date, tracked.role == .light
        else { throw AstroError.pathNotFound(path: plan.sourceRelative) }
        guard try db.file(path: plan.destinationRelative) == nil else {
            throw AstroError.writeForbidden(path: plan.destinationRelative)
        }

        let guardrail = WriteGuard(root: root)
        try guardrail.moveArchivedFrame(plan)
        do {
            try db.relocateFilePath(
                fileID: fileID,
                sourcePath: plan.sourceRelative,
                destinationPath: plan.destinationRelative
            )
        } catch {
            let rollbackMode: FrameArchiveMode = plan.mode == .archive ? .restore : .archive
            do {
                let rollback = try FrameArchivePlanner.plan(
                    sourceRelative: plan.destinationRelative, mode: rollbackMode
                )
                try guardrail.moveArchivedFrame(rollback)
            } catch let rollbackError {
                throw AstroError.databaseError(
                    "Archív DB-frissítés sikertelen (\(error)); a fájl-visszaállítás is sikertelen: \(rollbackError)"
                )
            }
            throw error
        }

        guard let updated = try db.file(path: plan.destinationRelative), updated.id == fileID else {
            throw AstroError.databaseError("Az archív útvonal frissült, de a fájlrekord nem olvasható vissza.")
        }
        return updated
    }
}
