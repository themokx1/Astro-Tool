import Foundation

/// Directory/path exclusion rules shared by anything that walks the library
/// tree read-only: `LibraryScanner` and `DirectoryLister` both need to agree
/// on exactly which directories are invisible to the tool, so the decision
/// lives here once rather than being duplicated (and risking drift) in both
/// walkers. Not `public` — an internal implementation detail of `Scan/`.
struct ExclusionRules {
    let config: AstroConfig

    func isExcludedDir(name: String, relativePath: String) -> Bool {
        if name == ".astro_tool" { return true }
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
/// and `DirectoryLister` so both translate a permission failure into
/// `AstroError.accessDenied` with the offending relative path rather than
/// letting a raw `NSError` escape.
func isPermissionError(_ error: Error) -> Bool {
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
