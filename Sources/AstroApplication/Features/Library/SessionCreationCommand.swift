import AstroCore
import Foundation

/// A read-only preview of exactly what `SessionCreationCommand.create(...)`
/// will do -- the same `targetFolder` resolution, the same
/// `WriteGuard.sessionTreeRelativePaths`/`captureTreeRelativePaths` lists
/// `create(...)` itself builds from, and the same `db.captureGroups`
/// lookup, never a second hand-written copy of any of them.
public struct SessionCreationPreview: Equatable, Sendable {
    public let targetFolder: String
    public let date: String
    /// `true` when `sessions/<targetFolder>/<date>` already exists --
    /// W3-10: a night can hold 2-3 captures with different filters/setups,
    /// so this is no longer a hard "already exists" refusal the way a
    /// brand-new session's own date directory is -- it instead means
    /// `create(...)` must be called WITH a capture draft (adding to the
    /// existing session), never without one (which would try, and fail, to
    /// recreate the session tree `WriteGuard.createSessionTree` already
    /// refuses to touch).
    public let sessionAlreadyExists: Bool
    /// Captures already recorded for this exact target/date -- so the sheet
    /// can show what is already there before adding another. Always empty
    /// when `sessionAlreadyExists` is `false`.
    public let existingCaptures: [CaptureGroupRecord]
    /// Every root-relative path this exact `create(...)` call will produce,
    /// in order: the bare session-tree paths (only when
    /// `!sessionAlreadyExists`) followed by the capture-specific paths
    /// (only when a capture draft was supplied to this preview).
    public let relativePaths: [String]

    public init(
        targetFolder: String,
        date: String,
        sessionAlreadyExists: Bool,
        existingCaptures: [CaptureGroupRecord],
        relativePaths: [String]
    ) {
        self.targetFolder = targetFolder
        self.date = date
        self.sessionAlreadyExists = sessionAlreadyExists
        self.existingCaptures = existingCaptures
        self.relativePaths = relativePaths
    }
}

/// What `SessionCreationCommand.create(...)` actually did -- kept around so
/// `undo(_:)` can reverse exactly this, and nothing else.
public struct SessionCreationReceipt: Equatable, Sendable {
    public let targetFolder: String
    public let date: String
    /// `true` when this `create(...)` call built the session tree itself
    /// (a brand-new `sessions/<targetFolder>/<date>`); `false` when it only
    /// added a capture below an already-existing session -- `undo(_:)` only
    /// ever removes the session's own date directory in the first case.
    public let sessionWasCreated: Bool
    /// The capture group's database id, if this call created one --
    /// `undo(_:)` deletes this row (`Database.deleteCaptureGroup`) once the
    /// filesystem side of the undo has been verified safe.
    public let captureGroupID: Int64?
    public let captureSlug: String?
    /// Every URL the underlying engine call(s) returned, unfiltered --
    /// including `calibration_library/{darks,flats,biases}`, which
    /// `SessionCreator.create` always reports (mkdir-p semantics) even when
    /// they already existed before this call.
    public let createdURLs: [URL]
    /// The subset `undo(_:)` is allowed to remove, and REQUIRES to be
    /// empty/unchanged before removing anything: `createdURLs` minus
    /// everything under `calibration_library/` (shared scaffolding no
    /// session owns), plus the wrapper directories neither
    /// `WriteGuard.createSessionTree` nor `.createCaptureTree` include in
    /// their own returned URLs (the session's own `.../<date>` directory
    /// when `sessionWasCreated`, and the capture's own
    /// `.../captures/<slug>` directory when a capture was created).
    public let undoableURLs: [URL]
    /// Directories `undo(_:)` opportunistically removes ONLY if they happen
    /// to be empty afterward, and never treats as a reason to refuse the
    /// rest of the undo -- today just the shared `.../captures` parent,
    /// which legitimately still holds OTHER captures' own subdirectories
    /// this receipt does not own.
    public let opportunisticURLs: [URL]
    /// The README's exact byte size at the moment `create(...)` wrote it --
    /// `nil` when this call did not write one (adding a capture to an
    /// already-existing session creates no README). `undo(_:)` re-checks
    /// the live file against this before removing it, so an edit the user
    /// made to their own session notes after creation blocks the automatic
    /// undo instead of silently discarding it.
    public let readmeSizeAtCreation: Int64?

    public init(
        targetFolder: String,
        date: String,
        sessionWasCreated: Bool,
        captureGroupID: Int64?,
        captureSlug: String?,
        createdURLs: [URL],
        undoableURLs: [URL],
        opportunisticURLs: [URL],
        readmeSizeAtCreation: Int64?
    ) {
        self.targetFolder = targetFolder
        self.date = date
        self.sessionWasCreated = sessionWasCreated
        self.captureGroupID = captureGroupID
        self.captureSlug = captureSlug
        self.createdURLs = createdURLs
        self.undoableURLs = undoableURLs
        self.opportunisticURLs = opportunisticURLs
        self.readmeSizeAtCreation = readmeSizeAtCreation
    }
}

public enum SessionCreationUndoError: Error, Equatable, Sendable {
    /// `path` still has content (a non-empty directory, or a file whose size
    /// no longer matches what was written) -- undo refuses rather than
    /// deleting anything the user or a later operation added.
    case notEmpty(path: String)
}

/// Wraps `SessionCreator`/`CaptureManager`/`WriteGuard` (AstroCore) for V2's
/// "New Session"/"Add Capture" sheet, the same way `SessionConversionCommand`
/// wraps V1's conversion engine: `preview(...)` is a pure, read-only
/// computation always available regardless of `accessMode`; `create(...)`
/// is the only call that touches the filesystem/database, gated exactly
/// like `SessionConversionCommand.apply`/`CalibrationLinkCommand` --
/// `LibraryMutationError.readOnly` before any write unless
/// `accessMode == .mutationEnabled`. Never re-implements `SessionCreator`'s
/// or `CaptureManager`'s sanitize/validate/tree-creation logic, or
/// `WriteGuard`'s path computation; this command only resolves inputs
/// against those entry points and forwards to them.
///
/// W3-10 (owner correction): a night can hold 2-3 captures with different
/// filters/setups, so `sessions/<target>/<date>/` alone is not the whole
/// story -- `create(...)` branches on whether that session date directory
/// already exists: if not, it builds the whole tree (optionally with an
/// initial capture, exactly like `SessionCreator`'s own two overloads); if
/// so, it can ONLY add another capture below it via `CaptureManager.create`
/// directly (never re-calls `SessionCreator.create`, which would fail
/// trying to recreate an existing session date directory).
public struct SessionCreationCommand: Sendable {
    private let root: URL
    private let db: Database
    private let accessMode: LibraryAccessMode
    private let indexedFolders: [String]

    public init(root: URL, db: Database, accessMode: LibraryAccessMode, indexedFolders: [String]) {
        self.root = root
        self.db = db
        self.accessMode = accessMode
        self.indexedFolders = indexedFolders
    }

    public static func production(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String]
    ) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let database = try Database(path: storage.indexDatabase.path)
        return Self(root: rootURL, db: database, accessMode: accessMode, indexedFolders: indexedFolders)
    }

    /// The canonical target folder `create(...)` would use for this exact
    /// input -- `SessionCreator.targetFolder` when a catalog target is
    /// known, `Sanitizer.makeTarget` otherwise. These are the SAME two entry
    /// points V1's `NewSessionSheet.previewTarget` already calls, never a
    /// re-derivation of either's sanitize/lookup logic.
    public func resolvedTargetFolder(
        catalogRaw: String,
        nameRaw: String,
        catalogTarget: CatalogTarget?
    ) -> String {
        if let catalogTarget {
            return SessionCreator.targetFolder(for: catalogTarget, root: root, indexedFolders: indexedFolders)
        }
        return Sanitizer.makeTarget(catalog: catalogRaw, name: nameRaw)
    }

    /// A read-only preview of exactly what `create(...)` will do for this
    /// input, INCLUDING an optional capture. Throws the same
    /// `AstroError.invalidInput` `create(...)` would for an
    /// empty-after-sanitize target, a non-canonical date, or (via
    /// `CaptureManager.validate`, the engine's own check) an invalid
    /// capture draft.
    public func preview(
        catalogRaw: String,
        nameRaw: String,
        date: String,
        catalogTarget: CatalogTarget?,
        capture: CaptureGroupDraft?
    ) throws -> SessionCreationPreview {
        let (targetFolder, canonicalDate) = try validatedTargetAndDate(
            catalogRaw: catalogRaw, nameRaw: nameRaw, date: date, catalogTarget: catalogTarget
        )
        if let capture {
            try CaptureManager.validate(draft: capture)
        }
        let sessionDir = sessionDateDirectory(targetFolder: targetFolder, date: canonicalDate)
        let sessionAlreadyExists = FileManager.default.fileExists(atPath: sessionDir.path)

        var relativePaths: [String] = []
        if !sessionAlreadyExists {
            relativePaths += try WriteGuard.sessionTreeRelativePaths(target: targetFolder, dateDir: canonicalDate)
        }
        if let capture {
            relativePaths += try WriteGuard.captureTreeRelativePaths(
                target: targetFolder, dateDir: canonicalDate, slug: capture.slug
            )
        }

        let existingCaptures = sessionAlreadyExists
            ? ((try? db.captureGroups(target: targetFolder, date: canonicalDate)) ?? [])
            : []

        return SessionCreationPreview(
            targetFolder: targetFolder,
            date: canonicalDate,
            sessionAlreadyExists: sessionAlreadyExists,
            existingCaptures: existingCaptures,
            relativePaths: relativePaths
        )
    }

    /// The only call in this type that touches the filesystem/database.
    /// Throws `LibraryMutationError.readOnly` before any write unless
    /// `accessMode == .mutationEnabled` -- same gate
    /// `SessionConversionCommand.apply`/`CalibrationLinkCommand` use.
    ///
    /// - If `sessions/<targetFolder>/<date>` does not exist yet: builds the
    ///   whole session tree via `SessionCreator.create`, WITH `capture` as
    ///   its initial capture when supplied, or the plain no-capture
    ///   overload when `capture` is `nil` (V1's own "Első capture-gyűjtés
    ///   létrehozása" toggle can be turned off; this preserves that).
    /// - If it already exists: `capture` MUST be supplied -- this is the
    ///   "add a second/third capture to the same night" path, and calls
    ///   `CaptureManager.create` directly rather than re-attempting
    ///   `SessionCreator.create` (which would throw trying to recreate an
    ///   existing session date directory). Throws `AstroError.invalidInput`
    ///   if `capture` is `nil` here -- there is nothing else this call could
    ///   legitimately do to an existing session.
    ///
    /// Invents no sanitize/validate/tree-creation logic of its own; forwards
    /// to `SessionCreator`/`CaptureManager` unchanged.
    @discardableResult
    public func create(
        catalogRaw: String,
        nameRaw: String,
        date: String,
        catalogTarget: CatalogTarget?,
        capture: CaptureGroupDraft?
    ) throws -> SessionCreationReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        let (targetFolder, canonicalDate) = try validatedTargetAndDate(
            catalogRaw: catalogRaw, nameRaw: nameRaw, date: date, catalogTarget: catalogTarget
        )
        let sessionDir = sessionDateDirectory(targetFolder: targetFolder, date: canonicalDate)
        let sessionAlreadyExists = FileManager.default.fileExists(atPath: sessionDir.path)

        if sessionAlreadyExists {
            guard let capture else {
                throw AstroError.invalidInput(
                    "session \"\(targetFolder)/\(canonicalDate)\" already exists; a capture is required to add to it"
                )
            }
            let captureResult = try CaptureManager.create(
                root: root, db: db, target: targetFolder, date: canonicalDate, draft: capture
            )
            return Self.receiptForCaptureOnly(
                targetFolder: targetFolder, date: canonicalDate, slug: capture.slug,
                sessionDir: sessionDir, captureResult: captureResult, root: root
            )
        }

        let targetFolderOverride = catalogTarget.map {
            SessionCreator.targetFolder(for: $0, root: root, indexedFolders: indexedFolders)
        }

        if let capture {
            let result = try SessionCreator.create(
                root: root, catalogRaw: catalogRaw, nameRaw: nameRaw, date: canonicalDate,
                initialCapture: capture, db: db, targetFolderOverride: targetFolderOverride
            )
            return Self.receiptForNewSession(
                result: result, date: canonicalDate, slug: capture.slug, sessionDir: sessionDir, root: root
            )
        }
        let result = try SessionCreator.create(
            root: root, catalogRaw: catalogRaw, nameRaw: nameRaw, date: canonicalDate,
            targetFolderOverride: targetFolderOverride
        )
        return Self.receiptForNewSession(result: result, date: canonicalDate, slug: nil, sessionDir: sessionDir, root: root)
    }

    /// Removes exactly what `create(...)` made for this one receipt -- and
    /// only the parts still empty (a directory with no entries beyond this
    /// receipt's own) or unchanged (the README, checked by byte size) --
    /// never anything with content. Checks EVERY `undoableURLs` entry first
    /// and performs no removal at all if any one of them fails that check,
    /// so a partial mismatch never leaves the session half-deleted.
    /// `calibration_library` is never in `undoableURLs` in the first place,
    /// so this can never touch it. `opportunisticURLs` (the shared
    /// `captures/` parent) is removed only if it happens to be empty
    /// afterward and never blocks the rest of the undo. Finally deletes the
    /// capture group's own database row, if one was created -- safe once
    /// the filesystem checks above already confirmed nothing was ever
    /// dropped into its folders.
    public func undo(_ receipt: SessionCreationReceipt) throws {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        let fm = FileManager.default

        // Deepest paths first, so a directory is only ever removed once
        // whatever it directly contains has already been removed.
        let ordered = receipt.undoableURLs.sorted { $0.path.count > $1.path.count }
        // A directory's own check below must not demand zero entries -- e.g.
        // `sessions/<target>/<date>` legitimately still contains its own
        // role subfolders and the README at check time, since nothing has
        // been removed yet (every entry is checked before anything is
        // removed, so a failed check never leaves a partial removal
        // behind). It is "empty enough to undo" when every entry it
        // actually has is itself one of THIS receipt's own `undoableURLs`
        // -- each of those gets its own, separate check in this same loop
        // -- rather than some unrelated file or folder nobody here created.
        //
        // `opportunisticURLs` (the shared `captures/` parent) is ALSO
        // tolerated as an expected child here, even though it is never
        // itself in `undoableURLs` and never required to be empty: the
        // session's own date directory legitimately contains a `captures/`
        // subfolder whenever ANY capture (this receipt's own, or a
        // sibling's) exists, and that must never look like unexpected
        // content blocking the whole undo -- `captures/`'s own fate is
        // decided separately, below, by the opportunistic pass alone.
        let undoablePaths = Set(ordered.map(\.standardizedFileURL.path))
            .union(receipt.opportunisticURLs.map(\.standardizedFileURL.path))

        for url in ordered {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                let unexpected = entries.filter { !undoablePaths.contains($0.standardizedFileURL.path) }
                guard unexpected.isEmpty else {
                    throw SessionCreationUndoError.notEmpty(path: url.path)
                }
            } else {
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                let actualSize = (attributes?[.size] as? NSNumber).map { Int64(truncating: $0) }
                guard let expected = receipt.readmeSizeAtCreation, actualSize == expected else {
                    throw SessionCreationUndoError.notEmpty(path: url.path)
                }
            }
        }

        for url in ordered {
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
        }

        // Opportunistic, never blocking: siblings under a shared `captures/`
        // parent belong to OTHER captures this receipt does not own.
        for url in receipt.opportunisticURLs {
            guard fm.fileExists(atPath: url.path),
                  let entries = try? fm.contentsOfDirectory(atPath: url.path),
                  entries.isEmpty
            else { continue }
            try? fm.removeItem(at: url)
        }

        if let captureGroupID = receipt.captureGroupID {
            try db.deleteCaptureGroup(id: captureGroupID)
        }
    }

    private func sessionDateDirectory(targetFolder: String, date: String) -> URL {
        root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(targetFolder, isDirectory: true)
            .appendingPathComponent(date, isDirectory: true)
    }

    /// Shared by `preview(...)` and `create(...)` -- the ONE place both
    /// validate `catalogRaw`/`nameRaw`/`date`, so they can never diverge on
    /// what counts as valid input.
    private func validatedTargetAndDate(
        catalogRaw: String,
        nameRaw: String,
        date: String,
        catalogTarget: CatalogTarget?
    ) throws -> (target: String, date: String) {
        let targetFolder = resolvedTargetFolder(catalogRaw: catalogRaw, nameRaw: nameRaw, catalogTarget: catalogTarget)
        guard !targetFolder.isEmpty else {
            throw AstroError.invalidInput(
                "catalog \"\(catalogRaw)\" and name \"\(nameRaw)\" sanitize to an empty target folder name"
            )
        }
        guard let parsedDate = SessionDateParser.parse(date), parsedDate.isCanonical else {
            throw AstroError.invalidInput("date \"\(date)\" is not a canonical YYYY-MM-DD date")
        }
        return (targetFolder, date)
    }

    /// Builds the receipt for a brand-new session (`SessionCreator.create`,
    /// with or without an initial capture).
    private static func receiptForNewSession(
        result: SessionCreator.Result,
        date: String,
        slug: String?,
        sessionDir: URL,
        root: URL
    ) -> SessionCreationReceipt {
        var undoable = Self.excludingCalibrationLibrary(result.createdURLs, root: root)
        undoable.append(sessionDir)
        var opportunistic: [URL] = []
        if let slug {
            let capturesParent = sessionDir.appendingPathComponent("captures", isDirectory: true)
            undoable.append(capturesParent.appendingPathComponent(slug, isDirectory: true))
            opportunistic.append(capturesParent)
        }
        let readmeURL = sessionDir.appendingPathComponent("README.txt", isDirectory: false)
        let readmeAttributes = try? FileManager.default.attributesOfItem(atPath: readmeURL.path)
        let readmeSize = (readmeAttributes?[.size] as? NSNumber).map { Int64(truncating: $0) }
        return SessionCreationReceipt(
            targetFolder: result.targetFolder,
            date: date,
            sessionWasCreated: true,
            captureGroupID: result.captureGroup?.id,
            captureSlug: slug,
            createdURLs: result.createdURLs,
            undoableURLs: undoable,
            opportunisticURLs: opportunistic,
            readmeSizeAtCreation: readmeSize
        )
    }

    /// Builds the receipt for adding a capture to an ALREADY-existing
    /// session (`CaptureManager.create`, called directly).
    private static func receiptForCaptureOnly(
        targetFolder: String,
        date: String,
        slug: String,
        sessionDir: URL,
        captureResult: CaptureManager.Result,
        root: URL
    ) -> SessionCreationReceipt {
        let capturesParent = sessionDir.appendingPathComponent("captures", isDirectory: true)
        var undoable = Self.excludingCalibrationLibrary(captureResult.createdURLs, root: root)
        undoable.append(capturesParent.appendingPathComponent(slug, isDirectory: true))
        return SessionCreationReceipt(
            targetFolder: targetFolder,
            date: date,
            sessionWasCreated: false,
            captureGroupID: captureResult.group.id,
            captureSlug: slug,
            createdURLs: captureResult.createdURLs,
            undoableURLs: undoable,
            opportunisticURLs: [capturesParent],
            readmeSizeAtCreation: nil
        )
    }

    /// `createdURLs` minus everything under `calibration_library/` -- those
    /// three directories are shared library scaffolding `WriteGuard`
    /// ensures with mkdir-p semantics on every session creation (present
    /// whether or not this particular call is what first created them), not
    /// something that belongs to any one session.
    private static func excludingCalibrationLibrary(_ createdURLs: [URL], root: URL) -> [URL] {
        let calibBase = root.appendingPathComponent("calibration_library", isDirectory: true)
            .standardizedFileURL.path
        return createdURLs.filter { !$0.standardizedFileURL.path.hasPrefix(calibBase + "/") }
    }
}
