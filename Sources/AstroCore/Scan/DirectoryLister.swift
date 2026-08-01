import Foundation

/// Read-only directory enumeration for the audit engine. The scanner only
/// ever records *files* into the DB, so an otherwise-empty directory (e.g.
/// `stacks/M42_Orion_Nebula/2026-01-18/` with nothing in it yet) is
/// invisible there — several audit rules need to see directories directly.
/// This walks the tree with the exact same exclusions as `LibraryScanner`
/// and never writes, deletes, or moves anything.
public enum DirectoryLister {
    /// All directories under `root`, as root-relative "/"-separated paths
    /// (no leading or trailing "/"), honoring the same exclusions as
    /// `LibraryScanner`: `.astro_tool` always, `config.excludedDirNames`
    /// case-insensitively, and `config.excludedPaths` prefixes.
    public static func listDirectories(root: URL, config: AstroConfig) throws -> [String] {
        let exclusion = ExclusionRules(config: config)
        var result: [String] = []
        try walk(dirURL: root, relPrefix: "", exclusion: exclusion, result: &result)
        return result
    }

    private static func walk(
        dirURL: URL,
        relPrefix: String,
        exclusion: ExclusionRules,
        result: inout [String]
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            if isPermissionError(error) {
                throw AstroError.accessDenied(path: relPrefix)
            }
            throw error
        }

        for entryURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entryURL.lastPathComponent
            let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }

            let relativePath = relPrefix.isEmpty ? name : relPrefix + "/" + name
            guard !exclusion.isExcludedDir(name: name, relativePath: relativePath) else { continue }

            result.append(relativePath)
            try walk(dirURL: entryURL, relPrefix: relativePath, exclusion: exclusion, result: &result)
        }
    }
}
