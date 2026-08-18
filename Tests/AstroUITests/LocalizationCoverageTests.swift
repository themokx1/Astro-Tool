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
        // W4-1 (card-import wizard, CaptureImportView.swift's "Set Role"
        // menu): this file's own glossary (top of file) already established
        // that frame-role names stay English in Hungarian astrophotography
        // usage -- `LibraryHealthCategory.displayLabel`'s own `Flat`/`Dark`/
        // `Bias` cases (HealthView.swift) rely on the same convention, but
        // as a `switch`-returned `LocalizedStringKey` the extraction script
        // never sees those in the first place. These four are literal
        // `Button(...)` arguments the script DOES see, so they need an
        // explicit allowlist entry rather than silently passing already.
        "Light",
        "Flat",
        "Dark",
        "Bias",
    ]

    /// W5-2 fix (discovered running this task's own new `--verbose` test):
    /// `waitUntilExit()` used to run BEFORE draining `stdout`'s pipe. A
    /// child process blocks once it fills the OS pipe buffer (64KB) if
    /// nobody is reading the other end -- `--missing`/no-args output is
    /// small enough to never hit that, but `--verbose` prints one
    /// `file:line: key` per extraction (700+ lines), comfortably over 64KB,
    /// so the very first test to pass `--verbose` deadlocked the whole
    /// suite: parent blocked in `waitUntilExit()`, child blocked writing to
    /// a full, undrained pipe, neither ever proceeding. Reading the pipe to
    /// EOF FIRST (which itself only returns once the child closes stdout,
    /// i.e. at or before exit) and waiting on the process afterward drains
    /// concurrently with the child's writes, so no output size can ever
    /// deadlock this again.
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
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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

    // MARK: - Gap 1 regression (V2 UI/UX audit, 2026-08-16)
    //
    // An owner screenshot showed `GroupBox("Target recommendations")`,
    // `GroupBox("Sky path tonight")`, `GroupBox("Saved projects")` and others
    // rendering in English on an otherwise-Hungarian screen: the extraction
    // script's construct list didn't cover `GroupBox`, `Section`,
    // `LabeledContent`, `TextField`, `DatePicker`, `Stepper`, `Menu` or
    // `Link` yet, even though every one of those has the exact same
    // literal-first-argument `LocalizedStringKey` shape `Text`/`Button`/etc.
    // already had support for. These tests pin that fix down two ways: (1)
    // literal spot checks for the exact strings the screenshot showed, and
    // (2) an independent, regex-based re-scan of `Sources/AstroUI` for
    // *every* non-interpolated literal call site of the newly covered
    // constructs, cross-checked against the script's own output -- so this
    // doesn't just prove "the strings I happened to notice work", it proves
    // "grep can't find a call site the script doesn't already report".

    @Test("Literals the owner's Hungarian screenshot showed in English are now extracted and translated")
    func previouslyMissedGroupBoxAndLabeledContentLiteralsAreCovered() throws {
        let keys = Set(try runExtractionScript())
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )
        // One representative literal per newly covered construct:
        // GroupBox, Section, LabeledContent, TextField (placeholder),
        // DatePicker, Menu, Link, plus MetricCard's `title:`.
        let mustBeCovered = [
            "Target recommendations", "Sky path tonight", "Saved projects", // GroupBox
            "Experience", // Section
            "Latitude", // LabeledContent
            "Name (optional)", // TextField placeholder
            "Night", // DatePicker
            "Choose Filter…", // Menu
            "Privacy notice", // Link
            "Reference", "Focal length", "Useful matches", // MetricCard(title:)
        ]
        for literal in mustBeCovered {
            #expect(keys.contains(literal), "\"\(literal)\" is no longer found by the extraction script")
            #expect(translated.contains(literal), "\"\(literal)\" has no Hungarian translation")
        }
    }

    /// Independently re-derives every non-interpolated literal-first-argument
    /// call site for the newly covered constructs by walking
    /// `Sources/AstroUI` with its own regex (deliberately not reusing any of
    /// `extract-localizable-strings.swift`'s own code), then asserts each one
    /// is present in the script's own extracted key set. A call site with
    /// string interpolation (`\(...)`) is skipped here, not because it's out
    /// of scope, but because re-deriving its exact placeholder-substituted
    /// key would mean re-implementing `inferPlaceholder` a second time --
    /// the non-interpolated literals alone are more than enough real call
    /// sites to catch a regression where a construct silently drops out of
    /// `constructPatterns` again.
    @Test("A grep-style re-scan finds no literal call site the extraction script misses")
    func grepCrossCheckFindsNothingTheScriptMisses() throws {
        let keys = Set(try runExtractionScript())
        let constructs = [
            "GroupBox", "Section", "LabeledContent", "TextField", "DatePicker", "Stepper", "Menu", "Link",
        ]
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:"# + constructs.joined(separator: "|") + #")\(\s*"([^"\\]*)""#
        )
        let astroUIRoot = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        var sampledCallSiteCount = 0
        for file in try swiftFiles(under: astroUIRoot) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: nsRange) {
                guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
                let literal = String(source[literalRange])
                guard !literal.isEmpty else { continue }
                sampledCallSiteCount += 1
                #expect(
                    keys.contains(literal),
                    "grep-style re-scan found a literal call site the extraction script missed: \"\(literal)\" in \(file.lastPathComponent)"
                )
            }
        }
        // A loose floor: proves the regex itself is actually matching real
        // call sites rather than silently matching nothing.
        #expect(sampledCallSiteCount > 20, "the cross-check's own regex found suspiciously few call sites (\(sampledCallSiteCount)) -- did it break?")
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    // MARK: - Gap 2 regression (V2 UI/UX audit, 2026-08-16)
    //
    // `MetricCard.title`/`.detail` used to be plain `String`, which routes
    // `Label`/`Text` through their verbatim, never-localized overload
    // instead of the `LocalizedStringKey` one -- that's why "Reference",
    // "Focal length" and "Useful matches" stayed English on every metric
    // card in the app even with a complete Hungarian table. This pins the
    // fix down by name (not just via the general coverage test above, which
    // would silently stop catching a regression here since a `String`
    // literal is *also* valid input to a `LocalizedStringKey` parameter --
    // the type is what changes behavior, not the literal's spelling).

    @Test("MetricCard's title/detail stay LocalizedStringKey, not String, so this regression cannot return")
    func metricCardStaysLocalizedStringKeyTyped() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift"),
            encoding: .utf8
        )
        guard let structRange = source.range(of: "struct MetricCard: View {"),
              let bodyRange = source.range(of: "var body: some View {", range: structRange.upperBound..<source.endIndex)
        else {
            Issue.record("MetricCard's declaration shape changed enough that this test's landmarks no longer find it -- update them")
            return
        }
        let declaration = source[structRange.upperBound..<bodyRange.lowerBound]
        #expect(
            declaration.contains("let title: LocalizedStringKey"),
            "MetricCard.title regressed back to String -- Label(title, ...) would stop localizing"
        )
        #expect(
            declaration.contains("let detail: LocalizedStringKey"),
            "MetricCard.detail regressed back to String -- Text(detail) would stop localizing"
        )
    }

    /// `Button(cond ? "Saved" : "Save Target")` looks like a plain literal
    /// call site but isn't one: a ternary of two string literals infers as
    /// `String`, not `LocalizedStringKey`, so it silently renders verbatim
    /// English forever, no matter what's in `hu.lproj`. `PlanningView.swift`
    /// works around this by wrapping the ternary in `LocalizedStringKey(_:)`
    /// explicitly -- this pins that specific workaround down, since a
    /// "helpful" cleanup that unwraps it back to a bare ternary would
    /// compile fine and silently reintroduce the bug.
    @Test("\"Save Target\" is wrapped in LocalizedStringKey so it actually localizes despite the ternary")
    func saveTargetLocalizesDespiteTernary() throws {
        let view = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningView.swift"),
            encoding: .utf8
        )
        #expect(
            view.contains(#"Button(LocalizedStringKey(isSelectedRowSaved ? "Saved" : "Save Target"))"#),
            "the Save/Saved ternary must stay wrapped in LocalizedStringKey(...) -- a bare ternary of two literals resolves to Button's verbatim String overload instead"
        )
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )
        #expect(translated.contains("Save Target"))
        #expect(translated.contains("Saved"))
    }

    /// `PlanningFit.label`, `ProjectWorkflowPhase.rawValue.capitalized` and
    /// `ProjectNextAction.title`/`.explanation` are `String`s computed in
    /// `AstroApplication`/`AstroCore` -- rendering them directly is the same
    /// verbatim-overload bug as `MetricCard`. The fix maps each engine
    /// *case* (never the rendered sentence) to a `LocalizedStringKey` at the
    /// view layer instead (`PlanningStore.swift`'s `PlanningFit.displayLabel`,
    /// `ProjectsStore.swift`'s `ProjectWorkflowPhase.displayLabel` and
    /// `ProjectNextActionKind.titleKey`/`.explanationKey`). This just checks
    /// every case's Hungarian text made it into `hu.lproj`.
    @Test("Framing, phase, and next-action labels mapped from engine enum cases are translated")
    func engineCrossingDisplayLabelsAreTranslated() throws {
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )
        let expected = [
            // PlanningFit.displayLabel
            "Mosaic", "Too small", "Wide composition", "Good framing", "Tight framing",
            // ProjectWorkflowPhase.displayLabel
            "Planned", "Collecting", "Processing", "Complete", "Archived",
            // ProjectNextActionKind.titleKey / .explanationKey
            "Plan the first night", "Start collecting", "Keep collecting", "Keep processing",
            "Write the final report", "Project archived",
            "Choose a setup, a filter and an exposure series.",
            "Add the missing series on the next good night.",
            "Check the stacks and the results' lineage.",
            "The project is done; export the shareable summary.",
            "Nothing to do.",
        ]
        for key in expected {
            #expect(translated.contains(key), "missing Hungarian translation for \"\(key)\"")
        }
    }

    // MARK: - W3-9 regression (owner screenshot, 2026-08-17)
    //
    // The 9th/10th instances of the same bug class, via two sub-variants
    // none of the tests above catch: (1) a Store builds a plain `String`
    // display property by direct interpolation (`HomeStore.NightContext
    // .leadingLabel`/`.centerLabel`/`.trailingLabel`), and (2) a domain-layer
    // enum's own `String`-typed rendering (`SkyVerdictKind.english`,
    // `NightRow.TriageState.rawValue`, `CatalogTargetKind.rawValue`, and
    // siblings) gets displayed raw. Both route through `Text`'s verbatim
    // overload no matter what `hu.lproj` says, because the PROPERTY's
    // static type decides the overload, not the literal that produced its
    // value.

    @Test("Domain-layer/engine enum cases fixed by this sweep are translated")
    func w3t9EngineEnumDisplayLabelsAreTranslated() throws {
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )
        let expected = [
            // SkyVerdictKind.displayLabel (PlanningStore.swift)
            "good tonight", "no coordinates", "not visible tonight",
            "comet -- stored coordinate is from capture time, not valid for tonight",
            "low (max %lld°)", "Moon interferes (%lld°, %@)",
            // CatalogTargetKind.displayLabel
            "Galaxy", "Emission nebula", "Planetary nebula", "Supernova remnant",
            "Open cluster", "Globular cluster", "Reflection nebula", "Dark nebula",
            // PlanningEstimateConfidence.displayLabel
            "Curated", "Estimated", "Fallback",
            // NightRow.TriageState.displayLabel/.localizedText (NightsStore.swift)
            "Ready", "Needs review", "No usable frames",
            // SeriesPassband.displayLabel/.localizedText
            "Broadband", "Dual band", "Narrowband", "LRGB", "Luminance", "Unfiltered",
        ]
        for key in expected {
            #expect(translated.contains(key), "missing Hungarian translation for \"\(key)\"")
        }
    }

    /// The store-composed-`String` sub-variant: a `Store` type in
    /// `Sources/AstroUI` assigns (`name = "..."`) or passes as a labeled
    /// constructor argument (`name: "..."`) a NON-EMPTY string literal
    /// directly to a property/parameter whose name ends in `Label`/`Title`/
    /// `Text` (case-sensitive, so a lowercase `title:`/`text:` parameter --
    /// e.g. `MetricCard(title: "Reference")`, whose `title` IS
    /// `LocalizedStringKey`-typed and localizes correctly -- never matches).
    /// `""` alone is excluded: it is how this codebase initializes editable
    /// `TextField` buffers (`SiteSettingsStore.latitudeText`, `PlanningStore
    /// .searchText`), never a display phrase.
    ///
    /// This is deliberately narrow, not a general string-literal ban: it
    /// exists to catch `HomeStore.NightContext.leadingLabel`/`.centerLabel`/
    /// `.trailingLabel`'s exact shape specifically, both of its two
    /// manifestations (a labeled constructor argument, `leadingLabel:
    /// "Dusk"`, and a bare re-assignment, `centerLabel = "Before tonight's
    /// dusk"`). Verified by hand against the pre-fix `HomeStore.swift` (this
    /// task's own git history): this exact pattern matches every one of the
    /// 8 lines that file used to have, and matches none of them once they
    /// route through `NSLocalizedString(...)`/`String(format:
    /// NSLocalizedString(...), ...)` -- neither of those right-hand sides
    /// starts with a `"` immediately after the `:`/`=`, which is exactly
    /// what this pattern requires to match at all.
    @Test("Store files never assign or pass a non-empty string literal directly to a Label/Title/Text-suffixed property")
    func storeFilesNeverDirectlyAssignDisplayStringLiterals() throws {
        let pattern = try NSRegularExpression(pattern: #"\b[A-Za-z_]*(?:Label|Title|Text)\s*[:=]\s*"[^"]+""#)
        let astroUIRoot = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        var violations: [String] = []
        for file in try swiftFiles(under: astroUIRoot) where file.lastPathComponent.hasSuffix("Store.swift") {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in pattern.matches(in: source, range: nsRange) {
                guard let range = Range(match.range, in: source) else { continue }
                let line = source.distance(from: source.startIndex, to: range.lowerBound)
                violations.append("\(file.lastPathComponent) offset \(line): \(source[range])")
            }
        }
        #expect(
            violations.isEmpty,
            "Store-composed display string(s) bypassing localization -- route these through NSLocalizedString/String(format:)/LocalizedStringKey instead: \(violations.joined(separator: " | "))"
        )
    }

    // MARK: - W5-2 findings 1 & 3 regression (owner pixel review, real library)
    //
    // A literal `%` inside an INTERPOLATED `LocalizedStringKey` (one that
    // contains at least one `\(...)`) is escaped to `%%` by the real Swift
    // compiler -- verified empirically with `dump()` on the actual SwiftUI
    // type: `"\(x)% of edge"` builds key `"%@%% of edge"`, not `"%@% of
    // edge"`. Before `assembleKey` in `extract-localizable-strings.swift`
    // accounted for this, three call sites (`ArchiveStripView.reclaimHelpText`,
    // and `PlanningView`'s two "of edge"/"of short edge" cells) were hand-added
    // to `hu.lproj` under the WRONG (single-`%`) key, so the Hungarian
    // translation could never be found at runtime and all three silently
    // rendered in English -- exactly what the owner's screenshot showed.
    //
    // `ArchiveStripView.reclaimHelpText`'s own call site no longer has this
    // shape as of W6-C: routing its percent number through
    // `AstroFormat.percentOneDecimal(_:)` moved the literal `%` INSIDE the
    // interpolation, so its real runtime key is the plain, undoubled `%@
    // reclaimable, %@ of the archive` -- see that call site's own hu.lproj
    // comment. The doubling behavior itself is still exercised for real by
    // `PlanningView`'s two untouched "of edge"/"of short edge" cells below.

    @Test("The extraction script doubles a literal % inside an interpolated LocalizedStringKey, matching the real compiler")
    func extractionScriptDoublesPercentInInterpolatedKeys() throws {
        // Matched by file + exact trailing key text, not by line number --
        // an unrelated doc-comment edit anywhere earlier in either file
        // shifts every subsequent line number without changing which key
        // the call site actually produces, so pinning an exact line here
        // would make this test fragile for reasons that have nothing to do
        // with what it is actually checking.
        let extractions = try runExtractionScript(arguments: ["--verbose"])
        func hasExtraction(inFile file: String, key: String) -> Bool {
            extractions.contains { $0.hasPrefix(file + ":") && $0.hasSuffix(": " + key) }
        }
        #expect(hasExtraction(inFile: "Sources/AstroUI/Features/Archive/ArchiveStripView.swift", key: "%@ reclaimable, %@ of the archive"))
        #expect(hasExtraction(inFile: "Sources/AstroUI/Features/Planning/PlanningView.swift", key: "%@%% of edge"))
        #expect(hasExtraction(inFile: "Sources/AstroUI/Features/Planning/PlanningView.swift", key: "%@%% of short edge"))
    }

    @Test("hu.lproj carries the correctly double-%-escaped keys for the two coverage-percent cells, and the plain undoubled key for the reclaim sentence")
    func percentEscapedKeysAreTranslated() throws {
        let translated = try parseStringsFile(
            repositoryRoot.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        )
        #expect(translated.contains("%@ reclaimable, %@ of the archive"))
        #expect(translated.contains("%@%% of edge"))
        #expect(translated.contains("%@%% of short edge"))
        // The old, never-matchable single-`%` keys must be gone, not just
        // supplemented -- a stale wrong entry sitting next to the correct
        // one is exactly the kind of thing that gets copy-pasted forward.
        // (The reclaim sentence's OLD doubled key, `%@ reclaimable, %@%% of
        // the archive`, is also stale now that W6-C moved the `%` inside the
        // interpolation -- it is checked as absent by
        // `everyExtractedKeyIsTranslatedOrAllowlisted`/`missingFlagReportsNothingOutstanding`
        // simply no longer asking for it, not by a separate negative
        // assertion here.)
        #expect(!translated.contains("%@ reclaimable, %@% of the archive"))
        #expect(!translated.contains("%@% of edge"))
        #expect(!translated.contains("%@% of short edge"))
    }

    // MARK: - W6-D gate: rawValue reaching a display construct

    /// Extracts the balanced-parenthesis argument list that immediately
    /// follows the `(` at `openIndex` in `line`, stopping at ITS matching
    /// close paren (or end of line if the call is not balanced within this
    /// one line). Every real violation this gate exists to catch --
    /// `Text(item.category.rawValue.capitalized)`,
    /// `LabeledContent("Sensor", value: mode.rawValue.uppercased())`,
    /// `.help(mode.rawValue)`, `Label(state.rawValue, systemImage: ...)` --
    /// is written on one line in this codebase's own style (the same
    /// single-line-call assumption `storeFilesNeverDirectlyAssignDisplayStringLiterals`
    /// above already relies on), so a full multi-line Swift parser would be
    /// solving a problem this codebase doesn't actually have.
    private static func balancedArguments(openParenAt openIndex: String.Index, in line: String) -> Substring {
        var depth = 0
        var index = openIndex
        let argsStart = line.index(after: openIndex)
        while index < line.endIndex {
            let character = line[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return line[argsStart..<index] }
            }
            index = line.index(after: index)
        }
        return line[argsStart...]
    }

    /// Flags `.rawValue` reaching `Text(...)`, `Label(...)`, `.help(...)`,
    /// or `LabeledContent(_:value:)`'s own `value:` argument on one line --
    /// the exact defect class this task's own W6-D sweep fixed repeatedly
    /// (`HealthView.swift`'s `Text(item.category.rawValue.capitalized)`,
    /// `SeriesInspector.swift`/`SeriesWorkspaceView.swift`'s
    /// `LabeledContent("Sensor", value: sensorMode.rawValue.uppercased())`):
    /// a raw case name reaching the screen untranslated, in whichever
    /// language the enum's Swift source happens to spell its cases in.
    ///
    /// Deliberately narrow, matching this file's own `storeFilesNeverDirectlyAssignDisplayStringLiterals`
    /// precedent: a full-line comment (trimmed prefix `//`, covers this
    /// codebase's own `///` doc-comment convention, including the several
    /// doc comments elsewhere in `Features/` that literally quote this bad
    /// pattern as a fixed-away example) is skipped entirely, and any line
    /// -- code or comment -- naming the `rawValue-display-safe` marker is
    /// allowlisted BY THAT LINE'S OWN JUSTIFICATION, not by which file it
    /// lives in, for a genuinely non-display use this gate's heuristic
    /// cannot tell apart from a real one (none exist in this codebase today
    /// -- `TableColumn(_:value:)` sort keypaths are a DIFFERENT `value:`
    /// parameter, on a construct this gate does not scan at all, so they
    /// need no marker).
    private static func rawValueDisplayViolations(inLine rawLine: String) -> [String] {
        let line = rawLine
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return [] }
        guard !line.contains("rawValue-display-safe") else { return [] }

        var findings: [String] = []
        for keyword in ["Text(", "Label(", ".help("] {
            var searchRange = line.startIndex..<line.endIndex
            while let keywordRange = line.range(of: keyword, range: searchRange) {
                let openParen = line.index(before: keywordRange.upperBound)
                let arguments = balancedArguments(openParenAt: openParen, in: line)
                if arguments.contains(".rawValue") {
                    findings.append("\(keyword) argument contains .rawValue: \(trimmed)")
                }
                searchRange = keywordRange.upperBound..<line.endIndex
            }
        }
        // `LabeledContent(_:)` alone, or with a trailing content closure, is
        // fine -- only its OWN `value:` parameter renders verbatim
        // (`LabeledContent(_:value:)`), so both must be present in the same
        // balanced argument list before this counts as a hit.
        var searchRange = line.startIndex..<line.endIndex
        while let keywordRange = line.range(of: "LabeledContent(", range: searchRange) {
            let openParen = line.index(before: keywordRange.upperBound)
            let arguments = balancedArguments(openParenAt: openParen, in: line)
            if arguments.contains("value:"), arguments.contains(".rawValue") {
                findings.append("LabeledContent(value:) argument contains .rawValue: \(trimmed)")
            }
            searchRange = keywordRange.upperBound..<line.endIndex
        }
        return findings
    }

    @Test("The rawValue-display detector actually catches the pre-fix shapes it exists to prevent")
    func rawValueDisplayDetectorCatchesKnownPreFixShapes() {
        // Real pre-fix lines from this task's own git history (`HealthView
        // .swift`, `SeriesInspector.swift`, `SeriesWorkspaceView.swift`,
        // `NightsStore.swift`'s own doc comment) -- proves this detector is
        // actually red against the shape it exists to catch, not just
        // vacuously green.
        let preFixSamples = [
            #"Text(item.category.rawValue.capitalized)"#,
            #"LabeledContent("Sensor", value: snapshot.series.sensorMode.rawValue.uppercased())"#,
            #".help(mode.rawValue)"#,
            #"Label(night.triageState.rawValue, systemImage: "checklist")"#,
        ]
        for sample in preFixSamples {
            #expect(!Self.rawValueDisplayViolations(inLine: sample).isEmpty, "detector failed to flag a known pre-fix shape: \(sample)")
        }

        // Three shapes that must NOT be flagged: a `TableColumn(_:value:)`
        // sort keypath (a different `value:` parameter than `LabeledContent`'s,
        // on a construct this gate does not scan), a `///` doc comment
        // quoting the bad pattern for documentation (several exist for real
        // in `Features/` today), and a line carrying the explicit
        // `rawValue-display-safe` justification marker.
        let safeSamples = [
            #"TableColumn("Category", value: \LibraryHealthItem.category.rawValue) { item in"#,
            #"/// (`Label(night.triageState.rawValue, ...)`) -- a `String`, so"#,
            #"Text(value.rawValue) // rawValue-display-safe: synthetic example for this test only"#,
        ]
        for sample in safeSamples {
            #expect(Self.rawValueDisplayViolations(inLine: sample).isEmpty, "detector false-positived on a safe shape: \(sample)")
        }
    }

    @Test("No rawValue-derived text reaches Text/Label/.help/LabeledContent(value:) in Features/, unjustified")
    func rawValueNeverReachesDisplayConstructsInFeaturesUnjustified() throws {
        let featuresRoot = repositoryRoot.appendingPathComponent("Sources/AstroUI/Features")
        var violations: [String] = []
        for file in try swiftFiles(under: featuresRoot) {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                for finding in Self.rawValueDisplayViolations(inLine: String(line)) {
                    violations.append("\(file.lastPathComponent): \(finding)")
                }
            }
        }
        #expect(violations.isEmpty, "rawValue reaching a display construct, unjustified: \(violations.prefix(10).joined(separator: " | "))")
    }
}
