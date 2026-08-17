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
/// operations (creating new session/capture trees, writing the tool's own
/// files under `.astro_tool/`, and executing a user-confirmed, exact-scope
/// session conversion) stay auditable in one place. WriteGuard never
/// overwrites or deletes a library file; conversion uses reversible moves
/// and leaves emptied source directories in place.
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
    /// The exact root-relative paths `createSessionTree(target:dateDir:
    /// readme:)` creates for THIS session -- in the same left-to-right order,
    /// computed with no filesystem access at all. Exists so a preview (V2's
    /// "New Session" sheet) can show precisely what the real call below will
    /// do before it runs, without a second hand-written copy of this list
    /// that could silently drift from the real one -- `SessionCreatorTests
    /// .previewedRelativePathsMatchWhatSessionCreatorActuallyCreates` pins
    /// exactly that. Deliberately excludes `calibration_library/{darks,
    /// flats,biases}`: those three directories are shared library
    /// scaffolding `createSessionTree` ensures with mkdir-p semantics on
    /// EVERY session creation (present whether or not this particular call
    /// is what first created them), not something that belongs to this one
    /// session -- a preview of "what will be created for this session"
    /// should not claim ownership of a shared directory some earlier session
    /// may already depend on.
    public static func sessionTreeRelativePaths(target: String, dateDir: String) throws -> [String] {
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        var paths: [String] = []
        for sub in ["lights", "flats", "darks", "biases"] {
            paths.append("sessions/\(target)/\(dateDir)/\(sub)")
        }
        paths.append("sessions/\(target)/\(dateDir)/README.txt")
        paths.append("stacks/\(target)/\(dateDir)")
        paths.append("processed/\(target)/\(dateDir)")
        return paths
    }

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

    /// The exact root-relative paths `createSessionRoot(target:dateDir:
    /// readme:)` creates -- just the README, mirroring that call's own
    /// reduced `created` list. See `createSessionRoot`'s own doc comment
    /// for why it omits the classic RAW quartet `createSessionTree` above
    /// makes.
    public static func sessionRootRelativePaths(target: String, dateDir: String) throws -> [String] {
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        return ["sessions/\(target)/\(dateDir)/README.txt"]
    }

    /// W3-10 owner correction (screenshot of the shipped V2 preview): "ezeket
    /// feleslegesen csinálja meg, a captures-be kellenek csak" (these are
    /// made unnecessarily; they only belong under captures/) -- creates the
    /// MINIMAL session root for a session whose first capture is created
    /// alongside it: the session directory itself, its `README.txt`, and
    /// the shared `calibration_library/{darks,flats,biases}` mkdir-p
    /// scaffolding (same as `createSessionTree`) -- but deliberately NO
    /// classic date-level `lights/flats/darks/biases` quartet and no bare
    /// `stacks/<dateDir>`/`processed/<dateDir>`. Once every raw frame for
    /// this session lives under a specific capture's own
    /// `captures/<slug>/{...}` branch, a parallel, always-empty classic
    /// quartet at the session root only misleads the card-copy workflow
    /// (which of the two lights/ folders does this camera's SD card go
    /// into?) -- it is dead weight, not a second valid destination. The
    /// actual capture tree (`captures/<slug>/...`, plus that capture's own
    /// `stacks/<dateDir>/<slug>`/`processed/<dateDir>/<slug>`) is created
    /// separately by `createCaptureTree`, called right after this by
    /// `SessionCreator`'s capture-aware overload -- `stacks/<dateDir>`/
    /// `processed/<dateDir>` still end up existing on disk as ordinary
    /// intermediate directories of THAT call, exactly as they do for
    /// `CaptureManager.create` adding a capture to an already-existing
    /// session; this call just never claims or tracks them as its own.
    /// Throws `AstroError.writeForbidden` under the same conditions
    /// `createSessionTree` does (invalid path components, or an
    /// already-existing session date directory).
    @discardableResult
    public func createSessionRoot(
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

        // Not appended to `created` -- `createSessionTree` never lists the
        // session date directory itself as one of its own created URLs
        // either; only its leaf children are tracked.
        try Self.classifyingPermissionErrors(path: sessionDir.path) {
            try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }

        let readmeURL = sessionDir.appendingPathComponent("README.txt", isDirectory: false)
        try Self.classifyingPermissionErrors(path: readmeURL.path) {
            try Data(readme.utf8).write(to: readmeURL, options: .withoutOverwriting)
        }
        created.append(readmeURL)

        let calibDir = root.appendingPathComponent("calibration_library", isDirectory: true)
        for sub in ["darks", "flats", "biases"] {
            try ensureDir(calibDir.appendingPathComponent(sub, isDirectory: true))
        }

        return created
    }

    /// The exact root-relative paths `createCaptureTree(target:dateDir:
    /// slug:)` creates for THIS capture -- same no-filesystem-access,
    /// same-order-as-the-real-call shape as `sessionTreeRelativePaths`
    /// above, and for the same reason: a preview (V2's "New Session"/"Add
    /// Capture" sheet) can show exactly what the real call below will do,
    /// with no second hand-written copy of the list to drift from it.
    /// Deliberately excludes the `sessions/<target>/<date>/captures/<slug>`
    /// wrapper directory itself and its `captures` parent -- like
    /// `createCaptureTree`'s own returned URLs, this lists only the six
    /// actual leaf destinations it creates.
    public static func captureTreeRelativePaths(target: String, dateDir: String, slug: String) throws -> [String] {
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        try Self.validatePathComponent(slug)
        var paths: [String] = []
        for sub in ["lights", "flats", "darks", "biases"] {
            paths.append("sessions/\(target)/\(dateDir)/captures/\(slug)/\(sub)")
        }
        paths.append("stacks/\(target)/\(dateDir)/\(slug)")
        paths.append("processed/\(target)/\(dateDir)/\(slug)")
        return paths
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

    /// Creates one planner-approved canonical conversion directory with
    /// mkdir-p semantics. Only the four capture role leaves and their
    /// mirrored stack/processed leaves for this exact scope are accepted.
    @discardableResult
    public func ensureConversionDirectory(
        relativePath: String,
        scope: SessionConversionScope
    ) throws -> URL {
        let components = try Self.validatedRelativeComponents(relativePath)
        let validSession = components.count == 6
            && components[0] == "sessions"
            && components[1] == scope.target
            && components[2] == scope.date
            && components[3] == "captures"
            && ["lights", "flats", "darks", "biases"].contains(components[5])
        let validOutput = components.count == 4
            && (components[0] == "stacks" || components[0] == "processed")
            && components[1] == scope.target
            && components[2] == scope.date
        guard validSession || validOutput else {
            throw AstroError.writeForbidden(path: relativePath)
        }
        let slug = validSession ? components[4] : components[3]
        try Self.validatePathComponent(slug)
        let url = try conversionURL(relativePath: relativePath, scope: scope)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw AstroError.writeForbidden(path: relativePath) }
            return url
        }
        try Self.classifyingPermissionErrors(path: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Read-only validation used before the first move. Both paths must be
    /// inside this one target/date's session, stack, or processed branch;
    /// the source must exist and the destination must not.
    public func preflightConversionMove(
        sourceRelative: String,
        destinationRelative: String,
        scope: SessionConversionScope
    ) throws {
        let source = try conversionURL(relativePath: sourceRelative, scope: scope)
        let destination = try conversionURL(relativePath: destinationRelative, scope: scope)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AstroError.pathNotFound(path: source.path)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AstroError.writeForbidden(path: destination.path)
        }
    }

    /// Executes one already-preflighted exact-scope move. No overwrite and
    /// no source-directory deletion are possible.
    public func moveConversionFile(
        sourceRelative: String,
        destinationRelative: String,
        scope: SessionConversionScope
    ) throws {
        try preflightConversionMove(
            sourceRelative: sourceRelative,
            destinationRelative: destinationRelative,
            scope: scope
        )
        let source = try conversionURL(relativePath: sourceRelative, scope: scope)
        let destination = try conversionURL(relativePath: destinationRelative, scope: scope)
        try Self.classifyingPermissionErrors(path: destination.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Reverses one conversion move under the same no-overwrite rules.
    public func rollbackConversionMove(
        _ move: ConversionMove,
        scope: SessionConversionScope
    ) throws {
        try moveConversionFile(
            sourceRelative: move.destinationRelative,
            destinationRelative: move.sourceRelative,
            scope: scope
        )
    }

    /// Executes one exact `FrameArchivePlanner` move. Rebuilding the plan
    /// here prevents callers from smuggling an arbitrary destination into a
    /// superficially valid value. Existing destinations are never replaced.
    public func moveArchivedFrame(_ plan: FrameArchivePlan) throws {
        let rebuilt = try FrameArchivePlanner.plan(
            sourceRelative: plan.sourceRelative, mode: plan.mode
        )
        guard rebuilt == plan else { throw AstroError.writeForbidden(path: plan.destinationRelative) }

        let rootURL = root.standardizedFileURL
        let source = root.appendingPathComponent(plan.sourceRelative).standardizedFileURL
        let destination = root.appendingPathComponent(plan.destinationRelative).standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let resolvedSource = source.resolvingSymlinksInPath()
        let resolvedDestination = destination.resolvingSymlinksInPath()
        guard source.path.hasPrefix(rootURL.path + "/"),
              destination.path.hasPrefix(rootURL.path + "/"),
              resolvedSource.path.hasPrefix(resolvedRoot.path + "/"),
              resolvedDestination.path.hasPrefix(resolvedRoot.path + "/")
        else { throw AstroError.writeForbidden(path: plan.destinationRelative) }

        // `resolvingSymlinksInPath()` does not reliably resolve a symlinked
        // parent when the final destination does not exist yet. Reject every
        // existing symlink component explicitly before creating a directory
        // or moving the file, so `lights/archive -> /outside` cannot redirect
        // a confirmed in-library operation.
        for relativePath in [plan.sourceRelative, plan.destinationRelative] {
            var componentURL = rootURL
            for component in relativePath.split(separator: "/") {
                componentURL.appendPathComponent(String(component))
                let attributes = try? FileManager.default.attributesOfItem(atPath: componentURL.path)
                if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw AstroError.writeForbidden(path: relativePath)
                }
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw AstroError.pathNotFound(path: source.path) }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AstroError.writeForbidden(path: destination.path)
        }

        try Self.classifyingPermissionErrors(path: destination.path) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
        }
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

    private static func validatedRelativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.hasPrefix("/") else {
            throw AstroError.writeForbidden(path: relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AstroError.writeForbidden(path: relativePath)
        }
        return components
    }

    private func conversionURL(relativePath: String, scope: SessionConversionScope) throws -> URL {
        try Self.validatePathComponent(scope.target)
        try Self.validatePathComponent(scope.date)
        let components = try Self.validatedRelativeComponents(relativePath)
        let allowedPrefix = components.count >= 4
            && (components[0] == "sessions" || components[0] == "stacks" || components[0] == "processed")
            && components[1] == scope.target
            && components[2] == scope.date
        guard allowedPrefix else { throw AstroError.writeForbidden(path: relativePath) }

        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootURL = root.standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else {
            throw AstroError.writeForbidden(path: relativePath)
        }
        return candidate
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

    /// Copies one external file (from a card-import source -- an SD card, an
    /// ASI Air's storage, any arbitrary folder the user picked) into one
    /// leaf of an already-existing canonical capture tree -- the copy-half
    /// counterpart of `createCaptureTree` above, and the card-import
    /// wizard's ONLY way to place bytes in the library, keeping this type's
    /// "sole filesystem-writing component" contract intact for that feature
    /// too.
    ///
    /// Unlike every other `WriteGuard` write, `sourceURL` is NOT required to
    /// live under `root` -- it names a file on the card/volume the user is
    /// importing from, which is the entire point of this call. Only the
    /// DESTINATION is guarded:
    ///
    /// - `destDirRelative` must be *exactly* `sessions/<target>/<date>/
    ///   captures/<slug>/(lights|flats|darks|biases)` -- six components, the
    ///   same shape `captureTreeRelativePaths(target:dateDir:slug:)` already
    ///   produces for these four leaves, both as a raw component check and,
    ///   again, via `standardizedFileURL` containment inside
    ///   `<root>/sessions/` for defense in depth. This never creates a
    ///   session or capture tree itself -- `createCaptureTree`/
    ///   `SessionCreationCommand` are what must have already made this
    ///   directory exist; a missing one is the caller's bug, not something
    ///   this call papers over by mkdir-p'ing an arbitrary new capture into
    ///   existence.
    /// - The destination file name is `destFileName` when given, otherwise
    ///   the source file's own last path component -- validated as a single
    ///   ordinary path component either way, so a pathological name can
    ///   never smuggle a `/`/`..` traversal into the destination.
    ///
    /// If a file already sits at the resolved destination, this makes NO
    /// change and returns `nil` -- the wizard's own "same-name file already
    /// there -> skip and report, never overwrite" rule, same shape as
    /// `linkCalibrationFile`/`linkStackListFile`'s own re-run behavior.
    ///
    /// Otherwise copies to a hidden temp name inside the SAME destination
    /// directory first, then atomically renames it into place -- so a copy
    /// that is interrupted (app quit, disk full, cancelled operation) never
    /// leaves a half-written file at the real destination name; a failure
    /// at either the copy or the rename step deletes the temp file before
    /// rethrowing. Permission failures are reclassified as
    /// `AstroError.accessDenied`, same as every other write in this type;
    /// a missing `sourceURL` throws `AstroError.pathNotFound`.
    @discardableResult
    public func copyCaptureFile(
        sourceURL: URL,
        destDirRelative: String,
        destFileName: String? = nil
    ) throws -> URL? {
        let destComponents = destDirRelative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard destComponents.count == 6,
              destComponents[0] == "sessions",
              destComponents[3] == "captures",
              ["lights", "flats", "darks", "biases"].contains(destComponents[5])
        else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }
        let target = destComponents[1]
        let dateDir = destComponents[2]
        let slug = destComponents[4]
        try Self.validatePathComponent(target)
        try Self.validatePathComponent(dateDir)
        try Self.validatePathComponent(slug)

        let sessionsBase = root.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL
        let destDirCandidate = root.appendingPathComponent(destDirRelative, isDirectory: true).standardizedFileURL
        guard destDirCandidate.path.hasPrefix(sessionsBase.path + "/") else {
            throw AstroError.writeForbidden(path: destDirRelative)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw AstroError.pathNotFound(path: sourceURL.path)
        }

        let fileName = destFileName ?? sourceURL.lastPathComponent
        try Self.validatePathComponent(fileName)
        let destFileURL = destDirCandidate.appendingPathComponent(fileName, isDirectory: false)

        guard !fm.fileExists(atPath: destFileURL.path) else {
            return nil
        }

        let tempFileURL = destDirCandidate.appendingPathComponent(
            ".importing-\(UUID().uuidString)-\(fileName)", isDirectory: false
        )

        try Self.classifyingPermissionErrors(path: destFileURL.path) {
            try fm.createDirectory(at: destDirCandidate, withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: sourceURL, to: tempFileURL)
            } catch {
                try? fm.removeItem(at: tempFileURL)
                throw error
            }
            do {
                try fm.moveItem(at: tempFileURL, to: destFileURL)
            } catch {
                try? fm.removeItem(at: tempFileURL)
                throw error
            }
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
