import Foundation
import Testing
@testable import AstroCore

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-suggestionscript-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func renameSureErrorProducesQuotedGuardedMv() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let finding = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "sessions/M31/light_001.fit",
        message: "placeholder name",
        suggestion: .rename(from: "sessions/M31/light_001.fit", to: "sessions/M31/M31_light_001.fit")
    )

    let script = try #require(SuggestionScript.generate(findings: [finding], root: root))

    #expect(script.hasPrefix("#!/bin/bash\n"))
    #expect(script.contains("set -euo pipefail"))
    #expect(script.contains("REVIEW EVERY LINE BEFORE RUNNING"))
    #expect(script.contains("NOT executed by astrotool"))
    #expect(script.contains("read -r -p \"Type YES to continue: \" CONFIRM"))
    #expect(script.contains("[ \"$CONFIRM\" = \"YES\" ] || { echo \"Aborted.\"; exit 1; }"))
    #expect(script.contains("echo \"Done. Re-run 'astrotool scan' to refresh the index.\""))

    let src = root.appendingPathComponent("sessions/M31/light_001.fit").path
    let dest = root.appendingPathComponent("sessions/M31/M31_light_001.fit").path
    #expect(script.contains("if [ -e '\(dest)' ]; then"))
    #expect(script.contains("mv '\(src)' '\(dest)'"))
    #expect(script.contains("# [sure_error] placeholder-name: placeholder name"))
}

@Test func embeddedSingleQuoteIsEscapedCorrectly() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let finding = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "stacks/O'Neill/x.fit",
        message: "placeholder name",
        suggestion: .rename(from: "stacks/O'Neill/x.fit", to: "stacks/O'Neill/y.fit")
    )

    let script = try #require(SuggestionScript.generate(findings: [finding], root: root))

    let srcAbs = root.appendingPathComponent("stacks/O'Neill/x.fit").path
    let destAbs = root.appendingPathComponent("stacks/O'Neill/y.fit").path
    // Shell single-quote escaping idiom: close quote, escaped quote, reopen quote.
    let expectedSrc = "'" + srcAbs.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let expectedDest = "'" + destAbs.replacingOccurrences(of: "'", with: "'\\''") + "'"

    #expect(script.contains("mv \(expectedSrc) \(expectedDest)"))
}

@Test func moveGeneratesMkdirPForDestParentInsideElseBranch() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let finding = Finding(
        severity: .sureError,
        category: "misplaced-file",
        path: "stacks/loose/x.fit",
        message: "misplaced file",
        suggestion: .move(from: "stacks/loose/x.fit", to: "stacks/M31/2026-01-01/x.fit")
    )

    let script = try #require(SuggestionScript.generate(findings: [finding], root: root))

    let destParent = root.appendingPathComponent("stacks/M31/2026-01-01").path
    let dest = root.appendingPathComponent("stacks/M31/2026-01-01/x.fit").path

    #expect(script.contains("mkdir -p '\(destParent)'"))

    // mkdir -p must live in the else-branch, before the mv, guarded by the exists-check.
    let elseRange = try #require(script.range(of: "\nelse\n"))
    let mkdirRange = try #require(script.range(of: "mkdir -p '\(destParent)'"))
    let mvRange = try #require(script.range(of: "  mv '"))
    let fiRange = try #require(script.range(of: "\nfi\n"))
    #expect(elseRange.lowerBound < mkdirRange.lowerBound)
    #expect(mkdirRange.lowerBound < mvRange.lowerBound)
    #expect(mvRange.lowerBound < fiRange.lowerBound)
    #expect(script.contains("'\(dest)'"))
}

@Test func reviewProducesCommentOnlyNoMv() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let finding = Finding(
        severity: .sureError,
        category: "ambiguous-target",
        path: "sessions/unknown/x.fit",
        message: "cannot determine correct target automatically",
        suggestion: .review(note: "check FITS OBJECT header manually")
    )

    let script = try #require(SuggestionScript.generate(findings: [finding], root: root))

    #expect(script.contains("# REVIEW: check FITS OBJECT header manually"))
    #expect(!script.contains("mv "))
    #expect(!script.contains("mkdir -p"))
}

@Test func nilSuggestionIsSkippedEntirely() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let withSuggestion = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "sessions/M31/a.fit",
        message: "placeholder name",
        suggestion: .rename(from: "sessions/M31/a.fit", to: "sessions/M31/M31_a.fit")
    )
    let withoutSuggestion = Finding(
        severity: .sureError,
        category: "some-other-issue",
        path: "sessions/M31/b.fit",
        message: "THIS_MESSAGE_MUST_NOT_APPEAR_ANYWHERE",
        suggestion: nil
    )

    let script = try #require(SuggestionScript.generate(findings: [withSuggestion, withoutSuggestion], root: root))

    #expect(!script.contains("THIS_MESSAGE_MUST_NOT_APPEAR_ANYWHERE"))
    #expect(!script.contains("some-other-issue"))
}

@Test func suspiciousExcludedByDefaultIncludedButCommentedWhenEnabled() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sureError = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "sessions/M31/a.fit",
        message: "placeholder name",
        suggestion: .rename(from: "sessions/M31/a.fit", to: "sessions/M31/M31_a.fit")
    )
    let suspicious = Finding(
        severity: .suspicious,
        category: "maybe-misplaced",
        path: "stacks/loose/z.fit",
        message: "possibly misplaced file",
        suggestion: .move(from: "stacks/loose/z.fit", to: "stacks/M31/z.fit")
    )

    let defaultScript = try #require(SuggestionScript.generate(findings: [sureError, suspicious], root: root))
    #expect(!defaultScript.contains("maybe-misplaced"))
    #expect(!defaultScript.contains("possibly misplaced file"))

    let withSuspicious = try #require(SuggestionScript.generate(
        findings: [sureError, suspicious], root: root, includeSuspicious: true
    ))
    #expect(withSuspicious.contains("maybe-misplaced"))
    #expect(withSuspicious.contains("possibly misplaced file"))
    #expect(withSuspicious.contains("suspicious — uncomment only after review") || withSuspicious.contains("suspicious - uncomment only after review"))

    let destAbs = root.appendingPathComponent("stacks/M31/z.fit").path
    let srcAbs = root.appendingPathComponent("stacks/loose/z.fit").path
    // Every command line belonging to the suspicious finding must be commented out
    // (the "# " comment prefix is prepended to the original, already-indented line).
    #expect(withSuspicious.contains("# " + "  mv '\(srcAbs)' '\(destAbs)'"))
    #expect(!withSuspicious.contains("\n  mv '\(srcAbs)' '\(destAbs)'"))
    #expect(withSuspicious.contains("# " + "  mkdir -p '\(root.appendingPathComponent("stacks/M31").path)'"))

    // The sure_error finding's command must remain uncommented.
    let sureSrc = root.appendingPathComponent("sessions/M31/a.fit").path
    let sureDest = root.appendingPathComponent("sessions/M31/M31_a.fit").path
    #expect(withSuspicious.contains("\n  mv '\(sureSrc)' '\(sureDest)'"))
}

@Test func probablyIntentionalNeverIncludedEvenWithSuspiciousFlag() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let sureError = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "sessions/M31/a.fit",
        message: "placeholder name",
        suggestion: .rename(from: "sessions/M31/a.fit", to: "sessions/M31/M31_a.fit")
    )
    let intentional = Finding(
        severity: .probablyIntentional,
        category: "custom-naming",
        path: "sessions/custom/x.fit",
        message: "THIS_INTENTIONAL_MESSAGE_MUST_NEVER_APPEAR",
        suggestion: .review(note: "THIS_INTENTIONAL_NOTE_MUST_NEVER_APPEAR")
    )

    let script = try #require(SuggestionScript.generate(
        findings: [sureError, intentional], root: root, includeSuspicious: true
    ))

    #expect(!script.contains("THIS_INTENTIONAL_MESSAGE_MUST_NEVER_APPEAR"))
    #expect(!script.contains("THIS_INTENTIONAL_NOTE_MUST_NEVER_APPEAR"))
    #expect(!script.contains("custom-naming"))
}

@Test func allNilSuggestionsProduceNilGenerateAndNilWrite() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let findings = [
        Finding(severity: .sureError, category: "a", path: "x", message: "m1", suggestion: nil),
        Finding(severity: .suspicious, category: "b", path: "y", message: "m2", suggestion: nil),
        Finding(severity: .probablyIntentional, category: "c", path: "z", message: "m3", suggestion: .review(note: "n")),
    ]

    #expect(SuggestionScript.generate(findings: findings, root: root, includeSuspicious: true) == nil)

    let writeGuard = WriteGuard(root: root)
    let result = try SuggestionScript.write(
        findings: findings, root: root, includeSuspicious: true,
        timestamp: Date(), using: writeGuard
    )
    #expect(result == nil)

    let suggestionsDir = root.appendingPathComponent(".astro_tool/suggestions")
    #expect(!FileManager.default.fileExists(atPath: suggestionsDir.path))
}

@Test func writePlacesFileAtExpectedPathWithMatchingContent() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let finding = Finding(
        severity: .sureError,
        category: "placeholder-name",
        path: "sessions/M31/a.fit",
        message: "placeholder name",
        suggestion: .rename(from: "sessions/M31/a.fit", to: "sessions/M31/M31_a.fit")
    )

    var components = DateComponents()
    components.year = 2026
    components.month = 3
    components.day = 15
    components.hour = 9
    components.minute = 7
    components.second = 42
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let timestamp = try #require(calendar.date(from: components))

    let writeGuard = WriteGuard(root: root)
    let url = try #require(try SuggestionScript.write(
        findings: [finding], root: root, includeSuspicious: false,
        timestamp: timestamp, using: writeGuard
    ))

    let expectedURL = root.appendingPathComponent(".astro_tool/suggestions/suggestions-20260315-090742.sh")
    #expect(url.standardizedFileURL.path == expectedURL.standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let writtenContent = try String(contentsOf: url, encoding: .utf8)
    let regenerated = try #require(SuggestionScript.generate(findings: [finding], root: root, includeSuspicious: false))
    #expect(writtenContent == regenerated)
}

@Test func noDestructiveTokensAppearInGeneratedScript() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let findings = [
        Finding(
            severity: .sureError,
            category: "placeholder-name",
            path: "sessions/M31/a.fit",
            message: "placeholder name",
            suggestion: .rename(from: "sessions/M31/a.fit", to: "sessions/M31/M31_a.fit")
        ),
        Finding(
            severity: .sureError,
            category: "misplaced-file",
            path: "stacks/loose/x.fit",
            message: "misplaced file",
            suggestion: .move(from: "stacks/loose/x.fit", to: "stacks/M31/2026-01-01/x.fit")
        ),
        Finding(
            severity: .suspicious,
            category: "maybe-misplaced",
            path: "stacks/loose/z.fit",
            message: "possibly misplaced file",
            suggestion: .move(from: "stacks/loose/z.fit", to: "stacks/M31/z.fit")
        ),
        Finding(
            severity: .sureError,
            category: "ambiguous-target",
            path: "sessions/unknown/x.fit",
            message: "cannot determine target",
            suggestion: .review(note: "check manually")
        ),
    ]

    let script = try #require(SuggestionScript.generate(findings: findings, root: root, includeSuspicious: true))

    #expect(!script.contains("rm "))
    #expect(!script.contains("rm\t"))
    #expect(!script.contains("rmdir"))
    #expect(!script.contains("trash"))
    #expect(!script.contains(" > "))
}
