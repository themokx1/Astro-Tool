import Foundation

/// Directory/path exclusion rules shared by anything that walks the library
/// tree read-only: `LibraryScanner` and `DirectoryLister` both need to agree
/// on exactly which directories are invisible to the tool, so the decision
/// lives here once rather than being duplicated (and risking drift) in both
/// walkers. Not `public` — an internal implementation detail of `Scan/`.
struct ExclusionRules {
    let config: AstroConfig

    func isExcludedDir(name: String, relativePath: String) -> Bool {
        // Any dot-directory is invisible to the tool: `.astro_tool` (this
        // tool's own state), `.DS_Store`-adjacent Finder/Spotlight noise, and
        // — on a real external volume — macOS housekeeping dirs like
        // `.Trashes` and `.fseventsd`. `.DS_Store` the *file* is deliberately
        // NOT covered by this (it's still recorded, see `isExcludedFile`).
        if name.hasPrefix(".") { return true }
        if isExcludedDirName(name: name, relativePath: relativePath) { return true }
        return isExcludedPath(relativePath)
    }

    // A bare name (no "/") that the tool SHIPS with -- see
    // `shippedDefaultDirNames` -- only hides a directory at the library
    // root: matching "tools" at every depth would make a target/capture/
    // filter folder that happens to share the name (e.g. a target literally
    // called "Tools") vanish silently from every session, and the default
    // exists purely to hide the one root housekeeping folder.
    //
    // A bare name the USER added keeps matching at ANY depth. They typed
    // "Siril_work"/"tmp" exactly because those folders sit deep inside their
    // sessions, and that is how such an entry always behaved -- narrowing it
    // to the root would silently start indexing everything underneath on
    // their next scan.
    //
    // An entry that contains "/" is a path, honored at any depth by
    // comparing it against the directory's own full relative path -- the
    // way to hide one specific deeper folder without hiding its name
    // everywhere.
    private func isExcludedDirName(name: String, relativePath: String) -> Bool {
        let isTopLevel = !relativePath.contains("/")
        for excluded in config.excludedDirNames {
            if excluded.contains("/") {
                if relativePath.caseInsensitiveCompare(excluded) == .orderedSame { return true }
                continue
            }
            guard excluded.caseInsensitiveCompare(name) == .orderedSame else { continue }
            if isTopLevel || !Self.isShippedDefaultDirName(excluded) { return true }
        }
        return false
    }

    /// The bare `excludedDirNames` entries the tool ships with, and so the
    /// only ones limited to the library root. Read off `AstroConfig()`'s own
    /// default so the two can never drift apart.
    private static let shippedDefaultDirNames: Set<String> = Set(
        AstroConfig().excludedDirNames.map { $0.lowercased() }
    )

    private static func isShippedDefaultDirName(_ name: String) -> Bool {
        shippedDefaultDirNames.contains(name.lowercased())
    }

    func isExcludedPath(_ relativePath: String) -> Bool {
        config.excludedPaths.contains { excluded in
            relativePath == excluded || relativePath.hasPrefix(excluded + "/")
        }
    }
}

/// Classifies a filesystem error as permission-denied (TCC / EPERM / EACCES),
/// possibly wrapped as an `NSUnderlyingErrorKey`. Shared by `LibraryScanner`
/// and `DirectoryLister` (both translate a permission failure into
/// `AstroError.accessDenied` with the offending relative path rather than
/// letting a raw `NSError` escape), and by `WriteGuard`'s own write-site
/// classification. `public` so the `astrotool` CLI target can reuse the
/// exact same classification when opening/creating `.astro_tool/` itself
/// (a different module, hence the wider access level rather than plain
/// `internal`).
public func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
        return true
    }
    if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)) {
        return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isPermissionError(underlying)
    }
    return false
}
