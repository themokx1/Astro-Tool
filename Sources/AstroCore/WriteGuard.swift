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

    /// Creates `sessions/<target>/<dateDir>/{lights,flats,darks,biases}` plus
    /// a `README.txt` under the new date directory, and returns the created
    /// URLs (subdirectories first, then the README). Throws
    /// `AstroError.writeForbidden` if `target`/`dateDir` are not valid single
    /// path components, or if the date directory already exists — this call
    /// only ever creates a brand-new session tree, never overwrites one.
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
        for sub in ["lights", "flats", "darks", "biases"] {
            let dirURL = sessionDir.appendingPathComponent(sub, isDirectory: true)
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            created.append(dirURL)
        }

        let readmeURL = sessionDir.appendingPathComponent("README.txt", isDirectory: false)
        try Data(readme.utf8).write(to: readmeURL, options: .withoutOverwriting)
        created.append(readmeURL)

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
        try fm.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: candidate)

        return candidate
    }

    /// A valid `target`/`dateDir` component: non-empty, no path separators,
    /// and not a `..` traversal segment.
    private static func validatePathComponent(_ component: String) throws {
        guard !component.isEmpty, !component.contains("/"), component != ".", component != ".." else {
            throw AstroError.writeForbidden(path: component)
        }
    }
}
