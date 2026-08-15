import Foundation
import Testing

/// Runs `scripts/extract-localizable-strings.swift` as a subprocess and
/// checks its output against `Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings`
/// -- the same script is the reproducible source of truth a human runs by
/// hand (`swift scripts/extract-localizable-strings.swift --missing`), so
/// this test enforces exactly what that command reports, nothing more and
/// nothing less.
struct LocalizationCoverageTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalizationCoverageTests.swift -> AstroUITests/
            .deletingLastPathComponent() // AstroUITests -> Tests/
            .deletingLastPathComponent() // Tests -> repository root
    }

    /// Brand names, product names, and astronomy acronyms that are not
    /// translated in Hungarian astrophotography usage -- see the localization
    /// plan's glossary (`docs/superpowers/plans/2026-08-15-localization.md`).
    /// Every other key extracted from `Sources/AstroUI` must have a Hungarian
    /// entry in `hu.lproj/Localizable.strings`.
    static let allowlist: Set<String> = [
        "AstroTool", // product name
        "FWHM", // Full Width at Half Maximum -- standard astronomy acronym
        "OK", // used as-is in Hungarian UI convention
    ]

    private func runExtractionScript(arguments: [String] = []) throws -> [String] {
        let scriptURL = repositoryRoot.appendingPathComponent("scripts/extract-localizable-strings.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", scriptURL.path] + arguments
        process.currentDirectoryURL = repositoryRoot
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard diagnostics; keep the test's own output clean
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func parseStringsFile(_ url: URL) throws -> Set<String> {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;"#)
        let nsRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var keys: Set<String> = []
        pattern.enumerateMatches(in: contents, range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: contents) else { return }
            keys.insert(String(contents[range]))
        }
        return keys
    }

    @Test("The extraction script finds a substantial number of AstroUI's user-facing literals")
    func extractionScriptFindsLiterals() throws {
        let keys = try runExtractionScript()
        // A loose floor, not an exact count: the real number will drift as
        // the app grows. What matters is that the script is actually
        // walking real source, not returning nothing or a handful of stubs.
        #expect(keys.count > 300)
    }

    @Test("Every extracted key has either a Hungarian translation or is on the explicit allowlist")
    func everyExtractedKeyIsTranslatedOrAllowlisted() throws {
        let keys = try runExtractionScript()
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )

        let untranslated = keys.filter { !translated.contains($0) && !Self.allowlist.contains($0) }

        #expect(untranslated.isEmpty, "Missing Hungarian translations: \(untranslated.prefix(20).joined(separator: " | "))")
    }

    @Test("The allowlist contains only short brand/domain terms, not full sentences")
    func allowlistStaysNarrow() {
        for term in Self.allowlist {
            #expect(!term.contains(" "), "allowlisted term '\(term)' looks like a sentence, not a brand/domain term")
        }
    }

    @Test("--missing reports zero keys once the translation is complete")
    func missingFlagReportsNothingOutstanding() throws {
        let missing = try runExtractionScript(arguments: ["--missing"])
        let stillMissing = missing.filter { !Self.allowlist.contains($0) }
        #expect(stillMissing.isEmpty, "swift scripts/extract-localizable-strings.swift --missing should report nothing outstanding: \(stillMissing.prefix(20))")
    }
}
