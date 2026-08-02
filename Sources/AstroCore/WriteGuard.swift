import Foundation

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
