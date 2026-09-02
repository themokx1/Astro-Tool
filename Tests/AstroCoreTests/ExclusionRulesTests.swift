import Foundation
import Testing
@testable import AstroCore

// `excludedDirNames`' default ("tools") used to match a bare name at ANY
// depth -- a target, capture, or filter folder several levels down that
// happened to share the name (e.g. a target literally called "Tools") would
// vanish from the scan silently along with the real root housekeeping
// folder the default is meant to hide. These tests pin the fixed,
// root-only-by-default behavior plus the slash-qualified escape hatch for a
// user who really does want one specific deeper folder hidden by name.

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

@Test func excludedDirNameStillHonorsUserConfiguredBareNamesAtRootOnly() {
    var config = AstroConfig()
    config.excludedDirNames = ["tools", "junk"]
    let rules = ExclusionRules(config: config)

    #expect(rules.isExcludedDir(name: "junk", relativePath: "junk") == true)
    #expect(rules.isExcludedDir(name: "junk", relativePath: "M31/junk") == false)
}
