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
        if config.excludedDirNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return true }
        return isExcludedPath(relativePath)
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
