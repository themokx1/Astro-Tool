import Foundation
import Testing
@testable import AstroCore

// `excludedDirNames`' default ("tools") used to match a bare name at ANY
// depth -- a target, capture, or filter folder several levels down that
// happened to share the name (e.g. a target literally called "Tools") would
// vanish from the scan silently along with the real root housekeeping
// folder the default is meant to hide. These tests pin the fixed behavior:
// the SHIPPED default is root-only, a name the USER added still matches at
// any depth (that is what they wrote it for), and a slash-qualified entry
// hides one specific deeper folder by path.

@Test func excludedDirNameMatchesOnlyAtLibraryRootByDefault() {
    var config = AstroConfig()
    config.excludedDirNames = ["tools"]
    let rules = ExclusionRules(config: config)

    #expect(rules.isExcludedDir(name: "tools", relativePath: "tools") == true)
    #expect(rules.isExcludedDir(name: "Tools", relativePath: "Tools") == true) // case-insensitive
    #expect(rules.isExcludedDir(name: "tools", relativePath: "M31/tools") == false)
    #expect(rules.isExcludedDir(name: "tools", relativePath: "M31/2026-01-10/tools") == false)
}

@Test func excludedDirNameWithSlashMatchesAtAnyDepthByFullRelativePath() {
    var config = AstroConfig()
    config.excludedDirNames = ["M31/tools"]
    let rules = ExclusionRules(config: config)

    #expect(rules.isExcludedDir(name: "tools", relativePath: "M31/tools") == true)
    // A same-named "tools" dir elsewhere is untouched -- only the exact
    // configured path is hidden.
    #expect(rules.isExcludedDir(name: "tools", relativePath: "M42/tools") == false)
    #expect(rules.isExcludedDir(name: "tools", relativePath: "tools") == false)
}

/// Root-only is right for the SHIPPED default ("tools"), which exists to
/// hide one root housekeeping folder and must never swallow a target folder
/// that happens to share the name. A name the USER added is the opposite
/// case: they typed "Siril_work"/"tmp" precisely because those folders sit
/// deep inside their sessions, and before the root-only change those were
/// hidden at every depth. Their own entry keeps matching at any depth.
@Test func userConfiguredBareDirNamesStillMatchAtAnyDepth() {
    var config = AstroConfig()
    config.excludedDirNames = ["tools", "Siril_work", "tmp"]
    let rules = ExclusionRules(config: config)

    #expect(rules.isExcludedDir(name: "Siril_work", relativePath: "Siril_work") == true)
    #expect(rules.isExcludedDir(name: "Siril_work", relativePath: "sessions/M31/2026-01-10/Siril_work") == true)
    #expect(rules.isExcludedDir(name: "siril_work", relativePath: "sessions/M31/siril_work") == true) // case-insensitive
    #expect(rules.isExcludedDir(name: "tmp", relativePath: "sessions/M31/2026-01-10/lights/tmp") == true)

    // The shipped default stays root-only, even alongside user entries.
    #expect(rules.isExcludedDir(name: "tools", relativePath: "tools") == true)
    #expect(rules.isExcludedDir(name: "tools", relativePath: "sessions/M31/tools") == false)

    // An unrelated deeper folder is still untouched.
    #expect(rules.isExcludedDir(name: "lights", relativePath: "sessions/M31/2026-01-10/lights") == false)
}

/// Dropping the shipped default from the list makes it a user-chosen entry
/// again -- so a config that lists nothing but "tools" is indistinguishable
/// from the default and stays root-only.
@Test func aConfigListingOnlyTheShippedDefaultStaysRootOnly() {
    var config = AstroConfig()
    config.excludedDirNames = ["tools"]
    let rules = ExclusionRules(config: config)

    #expect(rules.isExcludedDir(name: "tools", relativePath: "sessions/M31/tools") == false)
}
