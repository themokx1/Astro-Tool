import Testing
@testable import AstroCore

private func finding(
    severity: Severity = .suspicious,
    category: String,
    path: String,
    message: String = "m"
) -> Finding {
    Finding(severity: severity, category: category, path: path, message: message, suggestion: nil)
}

@Test func findingGrouperGroupsResidueByLiteralFileName() {
    let config = AstroConfig()
    let findings = [
        finding(category: "residue", path: "stacks/A/2026-01-01/.DS_Store"),
        finding(category: "residue", path: "stacks/B/2026-01-02/.DS_Store"),
    ]

    let groups = FindingGrouper.group(findings, config: config)
    #expect(groups.count == 1)
    #expect(groups[0].key.groupKey == ".DS_Store")
    #expect(groups[0].count == 2)
}

@Test func findingGrouperGroupsResidueByExtensionClass() throws {
    let config = AstroConfig()
    let findings = [
        finding(category: "residue", path: "stacks/A/2026-01-01/x.seq"),
        finding(category: "residue", path: "stacks/B/2026-01-02/y.seq"),
        finding(category: "residue", path: "stacks/A/2026-01-01/x.lst"),
    ]

    let groups = FindingGrouper.group(findings, config: config)
    let seqGroup = try #require(groups.first { $0.key.groupKey == "*.seq" })
    #expect(seqGroup.count == 2)
    let lstGroup = try #require(groups.first { $0.key.groupKey == "*.lst" })
    #expect(lstGroup.count == 1)
}

@Test func findingGrouperGroupsResidueDirectoryByOwnName() {
    let config = AstroConfig()
    let findings = [finding(category: "residue", path: "stacks/A/2026-01-01/process")]

    let groups = FindingGrouper.group(findings, config: config)
    #expect(groups.count == 1)
    #expect(groups[0].key.groupKey == "process")
}

@Test func findingGrouperGroupsPerFileCategoriesByParentDirectory() {
    let config = AstroConfig()
    let nestedDir = "sessions/T/2026-01-01/flats/sessions/session1/darks"
    let findings = (1...5).map { i in
        finding(severity: .sureError, category: "calib-in-wrong-dir", path: "\(nestedDir)/dark_000\(i).fit")
    }

    let groups = FindingGrouper.group(findings, config: config)
    #expect(groups.count == 1)
    #expect(groups[0].key.groupKey == nestedDir)
    #expect(groups[0].count == 5)
}

@Test func findingGrouperKeepsDirLevelFindingsUngroupedByOwnPath() {
    let config = AstroConfig()
    let findings = [
        finding(severity: .sureError, category: "nested-session-tree", path: "stacks/M42_Orion/2026-01-17/sessions"),
        finding(severity: .sureError, category: "placeholder-name", path: "stacks/Please_enter_a_value"),
    ]

    let groups = FindingGrouper.group(findings, config: config)
    #expect(groups.count == 2)
    #expect(Set(groups.map(\.key.groupKey)) == Set(findings.map(\.path)))
}

@Test func findingGrouperSortsSeverityFirstThenGroupSizeDescending() {
    let config = AstroConfig()
    let findings = [
        finding(severity: .probablyIntentional, category: "tool-output", path: "sessions/T/2026-01-10/lights/Stack"),
        finding(severity: .suspicious, category: "residue", path: "stacks/A/x.seq"),
        finding(severity: .suspicious, category: "residue", path: "stacks/B/y.seq"),
        finding(severity: .sureError, category: "calib-in-wrong-dir", path: "sessions/T/2026-01-10/lights/a.fit"),
    ]

    let groups = FindingGrouper.group(findings, config: config)
    #expect(groups[0].key.severity == .sureError)
    #expect(groups[1].key.severity == .suspicious)
    #expect(groups[1].count == 2)
    #expect(groups[2].key.severity == .probablyIntentional)
}
