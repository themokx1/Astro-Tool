import Foundation
import Testing

/// Wave 3 Task 8: the Apple-HIG polish sweep's own gate. Follows this
/// repo's established "surface" suite convention (`HelpSurfaceTests`,
/// `V2ShellSurfaceTests`): literal source-text assertions rather than
/// rendering the view tree, since these are wiring/vocabulary/consistency
/// contracts, not layout contracts.
@Suite("V2 Apple-HIG polish sweep")
struct V2PolishSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func filenames(under relativePath: String) throws -> [String] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    /// Repository-relative paths of every `.swift` file under `relativePath`,
    /// recursing into subdirectories. Same enumeration approach as
    /// `AstroTokensTests.filenames(under:recursive:)`.
    private func swiftFiles(under relativePath: String) throws -> [String] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
        }
        return results
    }

    private var featureViewPaths: [(name: String, path: String)] {
        [
            ("HomeView", "Sources/AstroUI/Features/Home/HomeView.swift"),
            ("ProjectsView", "Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            ("NightsView", "Sources/AstroUI/Features/Nights/NightsView.swift"),
            ("PlanningView", "Sources/AstroUI/Features/Planning/PlanningView.swift"),
            // Task 10: `.library` now renders `ArchiveView`, the deleted
            // `LibraryView`'s replacement.
            ("ArchiveView", "Sources/AstroUI/Features/Archive/ArchiveView.swift"),
            ("InsightsView", "Sources/AstroUI/Features/Insights/InsightsView.swift"),
            ("ResultsView", "Sources/AstroUI/Features/Results/ResultsView.swift"),
            ("HealthView", "Sources/AstroUI/Features/Library/HealthView.swift"),
            ("SensorProfilesView", "Sources/AstroUI/Features/Library/SensorProfilesView.swift"),
            ("CalibrationView", "Sources/AstroUI/Features/Library/CalibrationView.swift"),
        ]
    }

    // MARK: (a) The Inspector is contextual, not a Type/Identifier stub.

    @Test("InspectorView no longer shows the flat Type/Identifier stub")
    func inspectorIsNotAStub() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        // The old stub rendered exactly these two rows and nothing else for
        // every selection kind -- if both literal rows are still here
        // (still reachable from `selectionDetails`), the stub survived.
        let hasStubTypeRow = source.contains(#"LabeledContent("Type", value: kind(for: selection))"#)
        let hasStubIdentifierRow = source.contains(#"LabeledContent("Identifier", value: identifier(for: selection))"#)
        #expect(!(hasStubTypeRow && hasStubIdentifierRow))
    }

    @Test("InspectorView renders real, distinct content for project, night, series, and result selections")
    func inspectorHasContextualContentForEverySelectionKind() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")

        // project: a real project summary, not just its raw identifier.
        #expect(source.contains("case .project"))
        #expect(source.contains("projectsStore.selectedProject"))

        // night: a real night summary from the already-loaded NightRow.
        #expect(source.contains("case .night"))
        #expect(source.contains("nightsStore.nights"))

        // series: reuses the existing SeriesInspector when review data is
        // loaded, and otherwise a lean summary built from already-loaded
        // project data -- either way, real capture data, not an identifier.
        #expect(source.contains("case .series"))
        #expect(source.contains("SeriesInspector("))

        // result: a provenance summary (the Results workspace's own
        // lineage vocabulary), not just the raw result identifier.
        #expect(source.contains("case .result"))
        #expect(source.contains("ResultsQuery("))
        #expect(source.contains("Lineage"))

        // Nothing selected still gets a quiet, honest empty state.
        #expect(source.contains("ContentUnavailableView"))
    }

    // MARK: (b) Every main feature view has a ContentUnavailableView empty state.

    @Test("Every main feature view expresses its empty state through ContentUnavailableView")
    func everyFeatureViewHasAContentUnavailableEmptyState() throws {
        for (name, path) in featureViewPaths {
            let source = try contents(path)
            #expect(source.contains("ContentUnavailableView"), "\(name) has no ContentUnavailableView")
        }
    }

    // MARK: (c) No inline colors under Features/ or Settings/ (Wave 2 Task 2c).

    // Wave 2 Task 2: the former single allowed exception, `ArchivePalette.swift`
    // (the palette definition itself, which could contain hex literals), was
    // absorbed into `AstroTokens.swift` under `DesignSystem/` -- outside
    // `Features/`/`Settings/` entirely -- and deleted, so no file under either
    // scanned directory needs an exemption anymore.
    private static let colorLiteralExemptFiles: Set<String> = []

    /// One narrowly-scoped, justified exception: `ConversionWorkspace.swift`'s
    /// step-rail badge fills its `Circle` with `Color.accentColor` when a
    /// step is current -- the OS-level system accent (Blue/Purple/Pink/Red/
    /// Orange/Yellow/Green/Graphite/Multicolor, whatever the user picked in
    /// System Settings), NOT this app's own `AstroTokens.Color.accent` teal;
    /// there is no `Assets.xcassets` in this project overriding it. `.white`
    /// on top is the platform's own convention for a badge on a filled
    /// accent shape (macOS's own segmented controls and notification badges
    /// do the same regardless of the user's accent choice) -- `.primary`
    /// would flip to near-black in light mode, which is a worse, not
    /// better, contrast pair against several accent colors (yellow, orange)
    /// and would make this the only badge in the OS that doesn't follow the
    /// platform convention. Kept as literal `.white` on purpose; matched by
    /// exact source substring so nothing else on this line class can hide
    /// behind it.
    private static let inlineColorExemptions: [(file: String, substring: String)] = [
        ("ConversionWorkspace.swift", "isCurrent ? .white : .primary"),
    ]

    /// Every built-in SwiftUI `Color` static member that names a specific
    /// color (Apple's complete list: black/white/gray/grey/red/orange/
    /// yellow/green/mint/teal/cyan/blue/indigo/purple/pink/brown), plus the
    /// three semantic system ROLES (`clear`/`primary`/`secondary`).
    ///
    /// This gate replaces two earlier ones that each named a subset instead
    /// of stating the rule: `noHardcodedColorLiterals` matched only
    /// numeric literals (`Color(red:`, `Color(#colorLiteral`), and
    /// `noBareStatusColorLiterals` matched exactly four names (`green`,
    /// `orange`, `red`, `purple`) chosen because they were the ones a 2026
    /// -08-14 audit happened to find. SwiftUI ships far more named colors
    /// than that, so `.yellow`, `.blue`, `.gray`, and `.white` sat in the
    /// tree completely invisible to both gates -- nine sites across seven
    /// files (Wave 2 Task 2c). Listing the SwiftUI vocabulary itself, not a
    /// sample of it, is what makes a color invisible to this gate
    /// structurally impossible rather than merely unlikely.
    ///
    /// `.primary`/`.secondary`/`.clear` are deliberately EXCLUDED from the
    /// banned set even though they appear in the full vocabulary above: they
    /// are semantic system roles that adapt with the platform's own
    /// appearance and accessibility settings (Increase Contrast, Dark Mode,
    /// tinted backgrounds), not a specific hue standing in for one of this
    /// app's own meanings the way `.yellow` or `.blue` would be. Banning
    /// them would just push call sites toward inventing their own literal
    /// gray/black substitutes -- the opposite of this gate's purpose. A
    /// future reader should not "complete" this list by adding them back.
    private static let allSwiftUIColorNames =
        "black|white|gray|grey|red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|clear|primary|secondary"
    private static let allowedColorRoles: Set<String> = ["clear", "primary", "secondary"]

    @Test("No file under Features/ or Settings/ uses an inline SwiftUI color literal -- use AstroTokens.Color instead")
    func noInlineColorsInFeatureViews() throws {
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let directories = ["Features", "Settings"]
        // Two traps: (1) a bare identifier check must not match a color name
        // that is only a PREFIX of a longer identifier (`.redacted`,
        // `.grayscale`, `.blueprint`, `.greenwich`) -- the trailing
        // negative lookahead below requires a non-identifier character (or
        // end of line) right after the color name. (2) a doc comment that
        // names a color (e.g. explaining what it used to be) must not fail
        // its own gate -- comments are stripped before scanning, the same
        // way `archiveSurfacesUseHumanWords` above strips them.
        let namedColorPattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])\.(\#(Self.allSwiftUIColorNames))(?![A-Za-z0-9_])|\bColor\.(\#(Self.allSwiftUIColorNames))\b"#
        )
        var offenders: [String] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if Self.colorLiteralExemptFiles.contains(url.lastPathComponent) { continue }
                guard let rawText = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let text = Self.removingLineComments(rawText)
                let exemptSubstrings = Self.inlineColorExemptions
                    .filter { $0.file == url.lastPathComponent }
                    .map(\.substring)

                var fileOffenders: Set<String> = []
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if exemptSubstrings.contains(where: { line.contains($0) }) { continue }

                    if line.contains("Color(red:") || line.contains("Color(#colorLiteral") {
                        fileOffenders.insert("Color(red:/#colorLiteral")
                        continue
                    }

                    let lineString = String(line)
                    let range = NSRange(lineString.startIndex..., in: lineString)
                    namedColorPattern.enumerateMatches(in: lineString, range: range) { match, _, _ in
                        guard let match else { return }
                        // Group 1 is the bare `.name` form, group 2 the
                        // qualified `Color.name` form -- exactly one fires.
                        let name = (1...2).lazy.compactMap { index -> String? in
                            guard let r = Range(match.range(at: index), in: lineString) else { return nil }
                            return String(lineString[r])
                        }.first
                        guard let name, !Self.allowedColorRoles.contains(name) else { return }
                        fileOffenders.insert(name)
                    }
                }
                if !fileOffenders.isEmpty {
                    offenders.append("\(url.lastPathComponent): .\(fileOffenders.sorted().joined(separator: ", ."))")
                }
            }
        }
        #expect(offenders.isEmpty, "Inline SwiftUI color literals in: \(offenders.joined(separator: "; "))")
    }

    // MARK: (d) Primary toolbar buttons carry `.help(` tooltips.

    @Test("Primary toolbar controls in the main workspaces carry .help( tooltips")
    func primaryToolbarControlsHaveTooltips() throws {
        // Wave 4 Task 2: `ProjectWorkspaceView`'s own Review Frames/Results
        // buttons moved out of its body into structured `WorkspaceAction`
        // values (a plain `help: String?` data field, not a `.help(`
        // modifier call) -- the shell's own toolbar (`V2RootView`, already
        // in this list) is what actually calls `.help(action.help ?? "")`
        // to render their tooltips now, so that's where this gate reads
        // them from for that workspace. `ReviewWorkspace`/`CalibrationView`/
        // `ResultsView` each still carry an UNRELATED literal `.help(` call
        // of their own (an outlier/percentile-dot tooltip, a calibration
        // preview/link tooltip, an "Open Result" tooltip respectively), so
        // those stay checked for the literal modifier.
        //
        // Wave 4 (post-20014) fix: `HealthView`'s "Run Audit" tooltip moved
        // the same way Review Frames/Results did above -- Run Audit is now
        // a fully data-driven `WorkspaceActionMenu(help: ...)` published to
        // `WorkspaceActionCenter` (see that type's own doc comment for why
        // its OLD `.custom(id:) { ... .help(...) }` closure-based shape was
        // the very thing that caused the invalidation storm this fixes), so
        // `HealthView.swift` itself no longer contains a literal `.help(`
        // call at all -- its tooltip text lives in a plain `help:` argument
        // instead, and `V2RootView` (already in this list) is what actually
        // renders it via `.help(menu.help ?? "")`.
        let literalHelpFiles = [
            "Sources/AstroUI/Features/Review/ReviewWorkspace.swift",
            "Sources/AstroUI/Features/Library/CalibrationView.swift",
            "Sources/AstroUI/Features/Results/ResultsView.swift",
            "Sources/AstroUI/App/V2RootView.swift",
        ]
        for path in literalHelpFiles {
            let source = try contents(path)
            #expect(source.contains(".help("), "\(path) has no .help( tooltip")
        }

        let health = try contents("Sources/AstroUI/Features/Library/HealthView.swift")
        #expect(health.contains("help: \"Scan the library"), "HealthView no longer carries its Run Audit tooltip text")
    }

    // MARK: (e) No engine-layer Hungarian on a V2 render path (2026-08-15 audit, section 4).

    @Test("No file under Sources/AstroUI renders a property whose name ends in HU")
    func noSourceUnderAstroUIRendersAHUSuffixedProperty() throws {
        // `displayNameHU`/`humanSummaryHU` (and any future `...HU` property)
        // are V1/CLI's own vocabulary -- V2 must always go through the
        // English sibling (`displayName`, `humanSummary`, `.english`, ...)
        // instead. `commonNameHU` is deliberately exempted: a separate,
        // pre-existing, out-of-scope field (a real Hungarian common name,
        // not an untranslated engine sentence) that `PlanningView.swift`'s
        // own `displayName(_:)` reads as a documented fallback -- this gate
        // is about the 2026-08-15 audit's own P1 pattern, not that field.
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let pattern = try NSRegularExpression(pattern: #"\.[A-Za-z0-9_]*HU\b"#)
        let exemptSuffixes = ["commonNameHU"]
        var offenders: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text) }.map { text[$0] }
            let realOffenders = matches.filter { match in !exemptSuffixes.contains { match.hasSuffix($0) } }
            if !realOffenders.isEmpty {
                offenders.append("\(url.lastPathComponent): \(realOffenders.joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, "HU-suffixed property access in: \(offenders.joined(separator: "; "))")
    }

    @Test("No file under Sources/AstroUI contains the engine's raw Hungarian verdict/capture/conversion vocabulary")
    func noSourceUnderAstroUIContainsTheKnownHungarianVocabulary() throws {
        // The exact Hungarian words/phrases the 2026-08-15 audit's section 4
        // found rendered directly on V2 screens -- `SkyVerdict`'s own
        // vocabulary, `SensorMode`/`SignalMode`'s labels, and the
        // conversion ambiguity/conflict/summary sentences. None of these
        // should ever appear as source text under `Sources/AstroUI`: the
        // real fix is a translated field/computed property, never a
        // hardcoded literal pasted into a view.
        let hungarianVocabulary = [
            "nincs koordináta", "nem látszik ma éjjel", "alacsony (max", "Hold zavar (",
            "üstökös — a tárolt koordináta",
            "Monokróm", "Ismeretlen szenzor", "Szélessáv", "Keskenysáv", "Szűrő nélkül", "Ismeretlen fénysáv",
            "frame-ek gyűjtése nem egyértelmű", "kézi döntést kérnek",
            "célútvonal már foglalt", "célútvonala már foglalt",
            "nyers expozíció", "kalibrációs frame közül", "kiválasztott sessionben nincs konvertálható",
        ]
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        var offenders: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for phrase in hungarianVocabulary where text.contains(phrase) {
                offenders.append("\(url.lastPathComponent): \(phrase)")
            }
        }
        #expect(offenders.isEmpty, "Hardcoded Hungarian vocabulary in: \(offenders.joined(separator: "; "))")
    }

    @Test("HomeView translates the engine's raw verdict before rendering it")
    func homeViewTranslatesTheVerdictBeforeRendering() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains("SkyVerdict.parse(recommendation.verdict).english"))
        #expect(!source.contains("Text(recommendation.verdict)"), "HomeView must not render the raw engine verdict directly")
    }

    @Test("ConversionWorkspace reads the English sibling of every V1/CLI Hungarian conversion field")
    func conversionWorkspaceReadsEnglishConversionFields() throws {
        let source = try contents("Sources/AstroUI/Features/Library/ConversionWorkspace.swift")
        #expect(source.contains("plan.humanSummary "))
        #expect(source.contains(".titleEnglish"))
        #expect(source.contains(".explanationEnglish"))
        #expect(source.contains(".messageEnglish"))
        #expect(!source.contains("Text(ambiguity.explanation)"), "must render explanationEnglish, not the raw Hungarian explanation")
        #expect(!source.contains("Label(ambiguity.title,"), "must render titleEnglish, not the raw Hungarian title")
    }

    // MARK: (f) Archive views read their category colors from AstroTokens, never inline.

    @Test("Archive views read their category colors from AstroTokens, never inline")
    func archiveViewsUseThePalette() throws {
        // Wave 2 Task 2: `ArchivePalette` (five data-category colors plus its
        // own `dynamic(dark:light:)` helper) was absorbed into `AstroTokens`
        // and the file deleted -- `AstroTokens.Color.forArchiveClass` and
        // `AstroTokens.Color.data*` are now the only source of these colors,
        // so this gate no longer carves out an exempt palette file; every
        // file under Archive/ is checked.
        let archiveDirectory = "Sources/AstroUI/Features/Archive"
        for file in try filenames(under: archiveDirectory) {
            let source = try contents("\(archiveDirectory)/\(file)")
            #expect(!source.contains("NSColor(hex:"), "\(file) defines its own color")
            #expect(!source.contains("Color(red:"), "\(file) defines its own color")
        }
    }

    // MARK: (g) No Archive view returns user-facing text as a plain String (Task 7b).

    @Test("No Archive view returns user-facing text as a plain String")
    func archiveViewsDoNotReturnUserFacingStringsFromSwitches() throws {
        // A `var x: String { switch … }` over UI words never localizes: the
        // extraction script only sees LocalizedStringKey literals, so no key is
        // ever produced and the Hungarian build silently shows English. This is
        // the exact defect that forced MetricCard.title from String to
        // LocalizedStringKey -- gate it at the layer where it recurs.
        for file in try filenames(under: "Sources/AstroUI/Features/Archive") {
            let source = try contents("Sources/AstroUI/Features/Archive/\(file)")
            #expect(!source.contains("var displayName: String"),
                    "\(file) returns display text as String -- use LocalizedStringKey")
        }
    }

    @Test("ArchiveClass's display names and the archive strip's detail format have Hungarian translations")
    func archiveClassDisplayNamesAreTranslated() throws {
        // `scripts/extract-localizable-strings.swift` only finds
        // literal-first-argument call sites (`Text("...")`, `.help("...")`,
        // etc.) -- a `switch` that maps cases to `LocalizedStringKey`
        // (`ArchiveClass.displayName`, same shape as the precedented
        // `ProjectWorkflowPhase.displayLabel`/`PlanningFit.displayLabel`) is
        // invisible to it, so `LocalizationCoverageTests`' automated
        // coverage check cannot catch a missing entry here. This pins the
        // translations down by hand instead, the same way hu.lproj's own
        // tail groups already do for those other two switch-mapped
        // properties.
        let strings = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        let expectedEntries = [
            #""Light frames" = "Light frame-ek";"#,
            #""Stacks" = "Stackek";"#,
            #""Processed" = "Feldolgozott";"#,
            #""Calibration" = "Kalibráció";"#,
            #""Unclassified" = "Besorolatlan";"#,
            #""Other" = "Egyéb";"#,
            #""%@ · %@ files" = "%@ · %@ fájl";"#,
        ]
        for entry in expectedEntries {
            #expect(strings.contains(entry), "hu.lproj is missing: \(entry)")
        }
    }

    // MARK: (h) Task 12 -- the actionability gate and the engine-vocabulary gate.

    @Test("The archive never renders a task card without an executable action")
    func archiveTaskCardsAreAlwaysActionable() throws {
        // `ArchiveTaskQuery` must keep filtering out any task whose action
        // resolved to `.unavailable` BEFORE a card is ever built -- the old
        // library-health table's "Next step" column was a static label with
        // no button behind it for exactly this case, and this gate exists so
        // that regression can't come back silently.
        let source = try contents("Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift")
        #expect(source.contains("guard action != .unavailable else { return nil }"),
                "the actionability gate was removed from ArchiveTaskQuery")
        let card = try contents("Sources/AstroUI/Features/Archive/ArchiveTaskCard.swift")
        #expect(!card.contains("Text(nextStep"), "a card must render a Button, never a next-step label")
    }

    /// Banned engine-internal vocabulary, scanned for USER-FACING TEXT ONLY.
    ///
    /// The plan this test comes from listed `"Residue"` and `"Finding("`
    /// among the banned words, but `ArchiveTaskQuery.findingCategories`
    /// (`Sources/AstroApplication/Features/Archive/ArchiveTaskQuery.swift`)
    /// legitimately contains the lowercase string `"residue"` as a raw
    /// `findings.category` SQL value -- not user-facing text, and never
    /// rendered anywhere. A naive "does this file contain this word
    /// anywhere" scan over that file would either have to special-case that
    /// value or fail the build on a legitimate identifier, so this gate:
    ///
    /// 1. Scans only `Sources/AstroUI/Features/Archive` -- the render
    ///    layer -- and never `Sources/AstroApplication`, where the query
    ///    layer's category identifiers and SQL live. This alone already
    ///    keeps `ArchiveTaskQuery.swift`'s `"residue"` out of scope, since
    ///    it lives in a different module entirely.
    /// 2. Strips comments before scanning, so a doc comment that explains
    ///    (or warns about) one of these words by name -- this codebase's own
    ///    established style, see `ArchiveTaskCard.swift`'s and
    ///    `ArchiveStripView.swift`'s header comments -- cannot trip its own
    ///    gate.
    /// 3. Only flags a banned word when it appears INSIDE a double-quoted
    ///    string literal (an actual candidate for rendered text), not
    ///    merely following a quote character anywhere in the file.
    ///
    /// This does NOT prove no engine vocabulary ever reaches the user by any
    /// path (a value read from the database at runtime and interpolated
    /// into a `Text` would not appear as a literal here at all -- that is a
    /// data-flow property no source-text scan can verify), only that none of
    /// these five words appears as literal text in this directory today.
    @Test("No archive UI surface uses the engine's internal vocabulary as literal text")
    func archiveSurfacesUseHumanWords() throws {
        let banned = ["Triage", "Frame fill", "Photographable", "Residue", "Finding("]
        let literalPattern = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        for file in try filenames(under: "Sources/AstroUI/Features/Archive") {
            let raw = try contents("Sources/AstroUI/Features/Archive/\(file)")
            let source = Self.removingLineComments(raw)
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            var literals: [String] = []
            literalPattern.enumerateMatches(in: source, range: nsRange) { match, _, _ in
                guard let match, let range = Range(match.range(at: 1), in: source) else { return }
                literals.append(String(source[range]))
            }
            for word in banned {
                #expect(!literals.contains(where: { $0.contains(word) }),
                        "\(file) shows the user the word \(word)")
            }
        }
    }

    /// Strips `//` and `///` line comments (block comments are not this
    /// codebase's convention in `Sources/AstroUI/Features/Archive` and are
    /// not handled here) -- tracks whether it is inside a string literal so
    /// a literal that happens to contain `//` is never mistaken for a
    /// comment.
    private static func removingLineComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var i = source.startIndex
        var inLineComment = false
        var inString = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false; result.append(c) }
                i = next
                continue
            }
            if inString {
                result.append(c)
                if c == "\\", next < source.endIndex {
                    result.append(source[next])
                    i = source.index(after: next)
                    continue
                }
                if c == "\"" { inString = false }
                i = next
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i = next
                continue
            }
            if c == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true
                i = source.index(after: next)
                continue
            }
            result.append(c)
            i = next
        }
        return result
    }

    // MARK: (i) Task 12 -- hand-verified translations for the wave's OTHER
    // switch-returning-LocalizedStringKey blind spots (Archive Map wave,
    // 2026-08-16). `archiveClassDisplayNamesAreTranslated` above already
    // covers `ArchiveClass.displayName` (Task 7b/10); these two cover the
    // other two Archive `switch`es of the same invisible-to-the-extractor
    // shape, so a regression removing any of THEIR hu.lproj entries is also
    // caught, not just eyeballed once during this audit.

    @Test("ArchiveVerdictHeader's headline and integrity-state switches have Hungarian translations")
    func archiveVerdictSwitchTextsAreTranslated() throws {
        let strings = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        let expectedEntries = [
            #""I have not looked through this library yet." = "Ezt a könyvtárat még nem néztem át.";"#,
            #""The last check is older than your most recent scan." = "Az utolsó ellenőrzés régebbi, mint a legutóbbi beolvasásod.";"#,
            #""Nothing needs you right now." = "Jelenleg semmi sem vár rád.";"#,
            #""One thing needs you." = "Egy dolog vár rád.";"#,
            #""%lld things need you." = "%lld dolog vár rád.";"#,
            #""%lld file(s) changed content since the last check." = "%lld fájl tartalma megváltozott az utolsó ellenőrzés óta.";"#,
            #""Nothing has been corrupted since the last check." = "Az utolsó ellenőrzés óta semmi nem sérült.";"#,
            #""I have not checked this library's integrity yet." = "Az adatépséget még nem ellenőriztem.";"#,
        ]
        for entry in expectedEntries {
            #expect(strings.contains(entry), "hu.lproj is missing: \(entry)")
        }
    }

    @Test("ArchiveTaskCard's title/explanation/actionTitle switches have Hungarian translations")
    func archiveTaskCardSwitchTextsAreTranslated() throws {
        let strings = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        let expectedEntries = [
            #""Stacking leftovers" = "Stack-maradványok";"#,
            #""Byte-identical copies" = "Bájtazonos másolatok";"#,
            #""Calibration in the wrong folder" = "Kalibráció rossz mappában";"#,
            #""Folder names that break scanning" = "Mappanevek, amelyek megakasztják a beolvasást";"#,
            #""Checksum mismatch" = "Ellenőrzőösszeg-eltérés";"#,
            #""Could not be confirmed" = "Nem sikerült megerősíteni";"#,
            #""Not checked yet" = "Még nincs ellenőrizve";"#,
            #""Preview Quarantine…" = "Karantén előnézete…";"#,
            #""Reveal in Finder" = "Megjelenítés a Finderben";"#,
            #""Run Check" = "Ellenőrzés futtatása";"#,
        ]
        for entry in expectedEntries {
            #expect(strings.contains(entry), "hu.lproj is missing: \(entry)")
        }
    }

    // MARK: (j) Wave 2 Task 3 -- fixed-size numeric text is always tabular.

    /// Finds every `Text(...)` statement's own modifier chain (the
    /// constructor plus its immediately-chained `.modifier(...)` calls,
    /// stopping at the next statement) in a comment-stripped source file.
    ///
    /// Chains are found by paren-balance, not indentation: starting at a
    /// line containing `Text(`, subsequent lines are folded into the same
    /// chain while EITHER the running paren balance is still open (so a
    /// multi-line argument, like a ternary passed to `.foregroundStyle`,
    /// does not split the chain) OR the next line's trimmed text starts
    /// with `.` (a same-line-balanced chained modifier). The chain ends at
    /// the first line that is neither.
    private static func textModifierChains(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var chains: [String] = []
        var index = 0
        func parenBalance(_ line: String) -> Int {
            line.reduce(0) { $0 + ($1 == "(" ? 1 : ($1 == ")" ? -1 : 0)) }
        }
        while index < lines.count {
            guard lines[index].contains("Text(") else { index += 1; continue }
            var chain = lines[index]
            var balance = parenBalance(lines[index])
            var next = index + 1
            while next < lines.count {
                let trimmed = lines[next].trimmingCharacters(in: .whitespaces)
                guard balance > 0 || trimmed.hasPrefix(".") else { break }
                chain += "\n" + lines[next]
                balance += parenBalance(lines[next])
                next += 1
            }
            chains.append(chain)
            index = next
        }
        return chains
    }

    /// Rule 1 (spec 5.2): every numeric display is `monospacedDigit()` --
    /// a proportional digit column jitters as values change, unreadable in
    /// a table and actively dishonest in a bar chart, where width reads as
    /// magnitude. Scoped to `Text(...)` chains specifically (not
    /// `Image(systemName:)`, which also uses `.font(.system(size:` for
    /// plain icon glyphs and would otherwise be a false positive -- see
    /// `ResultsView.swift:242` and `FrameThumbnailCell.swift:57`, both
    /// fixed-size icon glyphs with no digit content at all).
    ///
    /// What this does NOT catch:
    /// - a `Text` built from `AstroType`'s own `.astroData()`/
    ///   `.astroDataHero()` text-style-based fonts never has a literal
    ///   `.font(.system(size:` at all, so it is invisible to this scan by
    ///   construction -- that is fine, since those two already bake
    ///   `monospacedDigit()` into the modifier itself and cannot regress
    ///   independently of `AstroType.swift`.
    /// - a fixed-size, non-numeric `Text` (decorative prose at a literal
    ///   pixel size) would also be flagged, since this scan has no way to
    ///   know the rendered value is a number -- there is no such case in
    ///   the tree today, and the fix (adding `.monospacedDigit()`) is
    ///   harmless even when the text is not numeric.
    /// - a numeric value threaded through a `Label(`, a computed `Text`
    ///   wrapper one level of indirection away, or a fixed size expressed
    ///   as `.font(Font.system(size:` (fully qualified) rather than the
    ///   literal `.font(.system(size:` this scan matches.
    @Test("Numeric display text at a fixed point size is always tabular")
    func numericDisplayIsAlwaysTabular() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI/Features") {
            let source = Self.removingLineComments(try contents(file))
            for chain in Self.textModifierChains(in: source) where chain.contains(".font(.system(size:") {
                if !chain.contains("monospacedDigit") {
                    offenders.append(file)
                }
            }
        }
        #expect(offenders.isEmpty, "Fixed-size Text without monospacedDigit() in: \(offenders.joined(separator: ", "))")
    }
}
