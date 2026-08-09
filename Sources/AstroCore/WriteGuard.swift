import Foundation

/// Outcome of `WriteGuard.linkCalibrationFile` applied over a whole
/// `CalibLinkPlan` (see `CalibLinker.apply`): which destination paths were
/// newly hard-linked, and which were left alone because a file already sat
/// there.
public struct LinkResult: Codable, Equatable, Sendable {
    /// Root-relative destination paths this run actually created.
    public var linked: [String]
    /// Root-relative destination paths that already existed -- skipped,
    /// never overwritten.
    public var skipped: [String]

    public init(linked: [String] = [], skipped: [String] = []) {
        self.linked = linked
        self.skipped = skipped
    }
}

/// The sole filesystem-writing component of Astro-Tool. Nothing else in
/// AstroCore may create, write, or delete anything under the library root —
/// every write in the package goes through here so the two allowed
/// operations (creating new session directory trees, and writing the tool's
/// own files under `.astro_tool/`) stay auditable in one place. WriteGuard
/// never overwrites or deletes anything the user's library already has;
/// `FileManager.removeItem` is never called here or anywhere else in the
/// package.
public struct WriteGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Root-relative directory the tool may freely read/write/overwrite its
    /// own state and reports in.
    public var toolDir: URL {
        root.appendingPathComponent(".astro_tool", isDirectory: true)
    }

    /// Creates the full session tree the real `add_new_session.sh` builds
    /// for a brand-new session -- `sessions/<target>/<dateDir>/
    /// {lights,flats,darks,biases}` plus a `README.txt` under the new date
    /// directory, `stacks/<target>/<dateDir>/`, `processed/<target>/
    /// <dateDir>/`, and (mkdir -p semantics -- fine if they already exist)
    /// the base `calibration_library/{darks,flats,biases}` directories.
    /// Returns every directory/file this call created or ensured existed.
    /// Throws `AstroError.writeForbidden` if `target`/`dateDir` are not valid
    /// single path components, or if the *session* date directory already
    /// exists — this call only ever creates a brand-new session, never
    /// overwrites one; the sibling `stacks`/`processed`/
    /// `calibration_library` directories are ensured with mkdir -p semantics
    /// and are never themselves treated as a conflict.
    @discardableResult
    public func createSessionTree(
        target: String,
        dateDir: String,
        readme: String
    ) throws -> [URL] {
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)

        let fm = FileManager.default
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(dateDir, isDirectory: true)

        guard !fm.fileExists(atPath: sessionDir.path) else {
            throw AstroError.writeForbidden(path: sessionDir.path)
        }

        var created: [URL] = []

        func ensureDir(_ url: URL) throws {
            try Self.classifyingPermissionErrors(path: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            created.append(url)
        }

        for sub in ["lights", "flats", "darks", "biases"] {
            try ensureDir(sessionDir.appendingPathComponent(sub, isDirectory: true))
        }

        let readmeURL = sessionDir.appendingPathComponent("README.txt", isDirectory: false)
        try Self.classifyingPermissionErrors(path: readmeURL.path) {
            try Data(readme.utf8).write(to: readmeURL, options: .withoutOverwriting)
        }
        created.append(readmeURL)

        let stacksDateDir = root
            .appendingPathComponent("stacks", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(dateDir, isDirectory: true)
        try ensureDir(stacksDateDir)

        let processedDateDir = root
            .appendingPathComponent("processed", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(dateDir, isDirectory: true)
        try ensureDir(processedDateDir)

        let calibDir = root.appendingPathComponent("calibration_library", isDirectory: true)
        for sub in ["darks", "flats", "biases"] {
            try ensureDir(calibDir.appendingPathComponent(sub, isDirectory: true))
        }

        return created
    }

    /// Adds one canonical capture tree below an already existing exact
    /// target/date session. It creates no README and never touches classic
    /// role folders or files. All six leaf destinations must be absent, so
    /// this cannot silently adopt or alter a pre-existing user directory.
    @discardableResult
    public func createCaptureTree(
        target: String,
        dateDir: String,
        slug: String
    ) throws -> [URL] {
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        try Self.validatePathComponent(slug)

        let fm = FileManager.default
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(dateDir, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sessionDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AstroError.pathNotFound(path: sessionDir.path)
        }

        let captureDir = sessionDir
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        let destinations = ["lights", "flats", "darks", "biases"].map {
            captureDir.appendingPathComponent($0, isDirectory: true)
        } + [
            root.appendingPathComponent("stacks", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent(dateDir, isDirectory: true)
                .appendingPathComponent(slug, isDirectory: true),
            root.appendingPathComponent("processed", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent(dateDir, isDirectory: true)
                .appendingPathComponent(slug, isDirectory: true),
        ]

        if let existing = destinations.first(where: { fm.fileExists(atPath: $0.path) }) {
            throw AstroError.writeForbidden(path: existing.path)
        }

        for destination in destinations {
            try Self.classifyingPermissionErrors(path: destination.path) {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            }
        }
        return destinations
    }

    /// Writes `data` to `relativePath` resolved under `toolDir`, creating
    /// intermediate directories as needed. Overwriting an existing file
    /// under `.astro_tool/` is allowed — that's the tool's own state, not
    /// the user's library. Throws `AstroError.writeForbidden` if
    /// `relativePath` is absolute, or if it (after resolving `..`/`.`) would
    /// land outside `toolDir`.
    @discardableResult
    public func writeToolFile(relativePath: String, data: Data) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: relativePath)
        }

        let base = toolDir.standardizedFileURL
        let candidate = toolDir.appendingPathComponent(relativePath).standardizedFileURL

        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else {
            throw AstroError.writeForbidden(path: relativePath)
        }

        let fm = FileManager.default
        try Self.classifyingPermissionErrors(path: candidate.path) {
            try fm.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: candidate)
        }

        return candidate
    }

    /// A valid `target`/`dateDir` component: non-empty, no path separators,
    /// and not a `..` traversal segment.
    private static func validatePathComponent(_ component: String) throws {
        guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else {
            throw AstroError.writeForbidden(path: component)
        }
    }

    /// Hard-links one file from the shared `calibration_library/` into a
    /// session's own `darks`/`biases`/`flats` folder -- the sole additive
    /// write operation this tool performs against files the user already
    /// has (spec section 11 point 4). Everything else `WriteGuard` does
    /// either creates brand-new session scaffolding or writes the tool's own
    /// `.astro_tool/` state; this is the only place a *pre-existing* library
    /// file gets a new name anywhere.
    ///
    /// Validates, in order:
    /// - `sourceRelative` resolves (after `standardizedFileURL`, same
    ///   defense as `writeToolFile`'s traversal check) to a path inside
    ///   `<root>/calibration_library/`.
    /// - `destDirRelative` is *exactly* `sessions/<target>/<date>/
    ///   (darks|biases|flats)` -- one target component, one date component,
    ///   one of the three allowed role directories, no more and no fewer --
    ///   both as a raw component check (rejecting `.`/`..`/empty segments
    ///   outright) and, again, via `standardizedFileURL` containment inside
    ///   `<root>/sessions/` for defense in depth.
    ///
    /// Creates `destDirRelative` (mkdir -p semantics) if it doesn't exist
    /// yet. The destination file name is always the source file's own last
    /// path component. If a file already sits there, this makes NO change
    /// and returns `nil` -- the existing library file is never overwritten,
    /// touched, or replaced. Otherwise links via `FileManager.linkItem`
    /// (hard link, same volume) and returns the new destination URL. A
    /// cross-device link failure (`EXDEV` -- shouldn't happen since source
    /// and destination are always under the same root) surfaces as
    /// whatever error `linkItem` throws; this never silently falls back to
    /// copying. Permission failures are reclassified as
    /// `AstroError.accessDenied`, same as every other write in this type.
    @discardableResult
    public func linkCalibrationFile(sourceRelative: String, destDirRelative: String) throws -> URL? {
        guard !sourceRelative.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }

        let calibBase = root.appendingPathComponent("calibration_library", isDirectory: true).standardizedFileURL
        let sourceCandidate = root.appendingPathComponent(sourceRelative).standardizedFileURL
        guard sourceCandidate.path.hasPrefix(calibBase.path + "/") else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }

        guard !destDirRelative.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        let destComponents = destDirRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard destComponents.count == 4, destComponents[0] == "sessions" else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }
        let target = destComponents[1]
        let dateDir = destComponents[2]
        let role = destComponents[3]
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        guard ["darks", "biases", "flats"].contains(role) else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        let sessionsBase = root.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        let destDirCandidate = root.appendingPathComponent(destDirRelative, isDirectory: true).standardizedFileURL
        guard destDirCandidate.path.hasPrefix(sessionsBase.path + "/") else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        let fm = FileManager.default
        let destFileURL = destDirCandidate.appendingPathComponent(sourceCandidate.lastPathComponent, isDirectory: false)

        guard !fm.fileExists(atPath: destFileURL.path) else {
            return nil
        }

        try Self.classifyingPermissionErrors(path: destFileURL.path) {
            try fm.createDirectory(at: destDirCandidate, withIntermediateDirectories: true)
            try fm.linkItem(at: sourceCandidate, to: destFileURL)
        }

        return destFileURL
    }

    /// Hard-links one SELECTED light frame from `sessions/...` into a
    /// stack-list export's own `lights/` folder under `.astro_tool/
    /// stacklists/<slug>/lights` -- the export-side counterpart of
    /// `linkCalibrationFile` (R7-B4, `StackList.export`): additive,
    /// same-volume, hardlink only, and (same as every other WriteGuard
    /// write) never overwrites anything already there.
    ///
    /// Validates, in order:
    /// - `sourceRelative` resolves (via `standardizedFileURL`, same
    ///   traversal defense as every other WriteGuard check) to a path
    ///   inside `<root>/sessions/` -- this only ever links a frame that's
    ///   actually part of the scanned session library, never an arbitrary
    ///   file elsewhere (in particular, never anything under
    ///   `calibration_library/`, which is `linkCalibrationFile`'s domain,
    ///   not this one's).
    /// - `destDirRelative` is *exactly* `.astro_tool/stacklists/<slug>/
    ///   lights` -- one slug component (validated the same way `target`/
    ///   `dateDir` are: non-empty, no path separators, not `.`/`..`), the
    ///   literal `lights` role directory, no more and no fewer -- both as a
    ///   raw component check (rejecting empty/`.`/`..` segments outright)
    ///   and, again, via `standardizedFileURL` containment inside `toolDir`
    ///   for defense in depth. R11-T11 (F15): OR `.astro_tool/stacklists/
    ///   <slug>/lights/<filter>` -- one extra, equally-validated component
    ///   for a multi-filter export's own `lights/<FILTER>/` subfolder
    ///   (`StackList.export`'s per-filter tree).
    ///
    /// Creates `destDirRelative` (mkdir -p semantics) if it doesn't exist
    /// yet. The destination file name is `destFileName` when given,
    /// otherwise the source file's own last path component (R12-U2, point
    /// 4: `StackList.disambiguatedFileNames` passes an explicit
    /// `destFileName` whenever two different source files in the same
    /// bucket would otherwise share a basename -- every pre-existing caller
    /// that never had that problem keeps getting the plain basename it
    /// always did). If a file already sits there, this makes NO change and
    /// returns `nil` -- a re-export of the same selection is fully
    /// idempotent, exactly like `linkCalibrationFile`'s own re-run
    /// behavior. Permission failures are reclassified as
    /// `AstroError.accessDenied`, same as every other write in this type.
    @discardableResult
    public func linkStackListFile(
        sourceRelative: String, destDirRelative: String, destFileName: String? = nil
    ) throws -> URL? {
        guard !sourceRelative.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }

        let sessionsBase = root.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        let sourceCandidate = root.appendingPathComponent(sourceRelative).standardizedFileURL
        guard sourceCandidate.path.hasPrefix(sessionsBase.path + "/") else {
            throw AstroError.writeForbidden(path: sourceRelative)
        }

        guard !destDirRelative.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        let destComponents = destDirRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard destComponents.count == 4 || destComponents.count == 5,
              destComponents[0] == ".astro_tool",
              destComponents[1] == "stacklists",
              destComponents[3] == "lights"
        else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }
        try Self.validatePathComponent(destComponents[2])
        if destComponents.count == 5 {
            try Self.validatePathComponent(destComponents[4])
        }

        let toolBase = toolDir.standardizedFileURL
        let destDirCandidate = root.appendingPathComponent(destDirRelative, isDirectory: true).standardizedFileURL
        guard destDirCandidate.path.hasPrefix(toolBase.path + "/") else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        // R12-U2 (point 4): an explicit `destFileName` must be a single,
        // ordinary path component -- same validation every other
        // caller-influenced path component in this type gets, so a
        // pathological disambiguated name (there shouldn't be one, but
        // defense in depth) can never smuggle a `/`/`..` traversal into
        // `destDirCandidate`.
        if let destFileName {
            try Self.validatePathComponent(destFileName)
        }

        let fm = FileManager.default
        let destFileURL = destDirCandidate.appendingPathComponent(
            destFileName ?? sourceCandidate.lastPathComponent, isDirectory: false
        )

        guard !fm.fileExists(atPath: destFileURL.path) else {
            return nil
        }

        try Self.classifyingPermissionErrors(path: destFileURL.path) {
            try fm.createDirectory(at: destDirCandidate, withIntermediateDirectories: true)
            try fm.linkItem(at: sourceCandidate, to: destFileURL)
        }

        return destFileURL
    }

    /// Runs a filesystem-writing `body`, reclassifying a permission failure
    /// (TCC / EPERM / EACCES -- e.g. a read-only root, or a directory whose
    /// TCC grant was revoked mid-session) as `AstroError.accessDenied(path:)`
    /// instead of letting the raw `NSError` (`NSCocoaErrorDomain` 513
    /// wrapping POSIX `EPERM`, typically) escape. Any other error — out of
    /// disk space, a genuinely malformed path, etc. — passes through
    /// unchanged; only permission failures get this special treatment, since
    /// only those map to the CLI/app's dedicated "grant Full Disk Access"
    /// guidance.
    private static func classifyingPermissionErrors<T>(path: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AstroError {
            throw error
        } catch {
            if isPermissionError(error) {
                throw AstroError.accessDenied(path: path)
            }
            throw error
        }
    }
}
