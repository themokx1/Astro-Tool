import AppKit
import AstroUI
import Foundation
import SwiftUI
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

        // result: W4-6 (owner decision) removed the lineage-vocabulary
        // provenance panel this used to render -- it read the `results`/
        // `lineage_edges` tables, which no writer anywhere in the product
        // ever populated and which schema v8 drops. `.result` now renders
        // the same honest, named placeholder as every other selection this
        // window cannot resolve, rather than a panel that could never have
        // shown anything real.
        #expect(source.contains("case .result"))
        #expect(source.contains("\"Result\", systemImage:"))

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
        // W3-9: `.english` was itself the leak this task fixed -- a
        // domain-layer `String` rendered directly, so `Text(String)` always
        // chose the verbatim, never-localized overload ("good tonight"
        // reaching a Hungarian screen verbatim). `.displayLabel`
        // (`PlanningStore.swift`'s `SkyVerdictKind` extension) maps the same
        // structured parse to a `LocalizedStringKey` instead; the underlying
        // guarantee this test exists to pin -- render the STRUCTURED parse,
        // never the raw engine verdict string -- is unchanged.
        #expect(source.contains("SkyVerdict.parse(recommendation.verdict).displayLabel"))
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

    // MARK: (k) Wave 2 Task 4 -- one format per unit.

    /// One file, one narrowly-scoped exemption: `SiteSettingsStore.swift`'s
    /// `latitudeText`/`longitudeText` are an EDITABLE draft that round-trips
    /// through `Double(_:)` on save (`SiteSettingsStore.swift`'s own
    /// `save()`), which requires a `.` decimal separator regardless of the
    /// user's locale. `AstroFormat.degrees` is deliberately locale-aware (a
    /// Hungarian system renders a comma), so routing this site through it
    /// would make `Double("47,4979")` fail to parse on any non-English
    /// system -- a real regression, not a style nit. This is a read/parse
    /// constraint on a specific field, not a blanket exemption for the
    /// file's directory or module.
    /// `NightsStore.swift` used to be a second exemption here, because
    /// routing `NightRow.integrationSummary` through
    /// `AstroFormat.duration(seconds:)` reproducibly crashed
    /// `GlobalSearchStoreTests.searchesAcrossWorkflowObjects` with `freed
    /// pointer was not the last allocation` (SIGABRT) on a clean build. The
    /// exemption is gone because the underlying defect was found and fixed,
    /// not worked around: that message comes from Swift's per-task
    /// `StackAllocator`, not from malloc, and the corruption was an
    /// `async` default argument emitted as a `linkonce_odr` async function
    /// pointer record with two different context sizes (80 bytes in the
    /// declaring module, 64 in a client), letting the linker pair a large
    /// function body with a small size record. Formatting had nothing to do
    /// with it -- `NightsStore.open`'s machine code was byte-for-byte
    /// identical across the crashing and passing builds, and this edit only
    /// moved the object file enough to flip the linker's pick, which is why
    /// five equivalent rewrites all crashed too. See
    /// `AsyncContextSizeGateTests`, which gates the real defect at the
    /// binary level, and `NightsStore.init(metadataFactory:calendarProvider:)`
    /// for the shape that fixes it.
    private static let handRolledFormattingExemptFiles: Set<String> = [
        "SiteSettingsStore.swift",
    ]

    /// Rule (spec 5.2, `P2` pattern): a second format for a unit that
    /// already has one is a second truth -- two screens can disagree about
    /// the same number and neither is "wrong". Scoped to `Sources/AstroUI`
    /// as a whole, excluding `DesignSystem/` (where `AstroFormat.swift`
    /// itself legitimately builds format strings) and `PreviewSupport/`
    /// (`V2PreviewFixtures.swift` uses `String(format: "%012d", ...)` to
    /// synthesize a UUID string for canned preview data -- a key, not a
    /// displayed value).
    ///
    /// What this does NOT catch:
    /// - `Sources/AstroApplication` or any other target/module -- a
    ///   hand-rolled format in the data layer, if one existed, would not be
    ///   caught here.
    /// - a unit that is ALREADY formatted through some means other than
    ///   `String(format:)` and duplicated that way (e.g. the eleven direct
    ///   `ByteCountFormatter.string(fromByteCount:countStyle:)` call sites
    ///   across `Archive/`, `Library/`, and `Search/` predate `AstroFormat`
    ///   and were out of this task's stated scope -- the system's own
    ///   formatter can't drift the way a hand-rolled `%d:%02d` can, but
    ///   routing them through `AstroFormat.bytes` for a single call site
    ///   is a reasonable follow-up, not covered by this gate).
    @Test("No file under Sources/AstroUI (outside DesignSystem/ and PreviewSupport/) formats a value by hand")
    func noHandRolledFormatting() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            if file.contains("/DesignSystem/") || file.contains("/PreviewSupport/") { continue }
            let filename = (file as NSString).lastPathComponent
            if Self.handRolledFormattingExemptFiles.contains(filename) { continue }
            let source = Self.removingLineComments(try contents(file))
            if source.contains("String(format:") { offenders.append(file) }
        }
        #expect(offenders.isEmpty, "use AstroFormat instead -- a second format for the same unit is a second truth: \(offenders.joined(separator: ", "))")
    }

    // MARK: (l) Task 16 -- workspace toolbar action titles must be translatable.

    @Test("Workspace toolbar actions carry translatable titles, not verbatim Strings")
    func workspaceActionTitlesAreLocalizable() throws {
        // `WorkspaceAction`/`WorkspaceActionMenu`/`WorkspaceMenuItem` used to
        // declare `title`/`help` as plain `String`, which routes SwiftUI's
        // `Label(_:systemImage:)`/`Text(_:)` calls in `V2RootView` to their
        // verbatim overload instead of the `LocalizedStringKey` one -- every
        // toolbar button title in the app (Review, Health, Nights, Planning,
        // Calibration, Archive) stayed English on a Hungarian interface. Same
        // defect as `MetricCard.title`, one layer up in shared infrastructure.
        let source = try contents("Sources/AstroUI/App/WorkspaceActions.swift")
        #expect(!source.contains("public let title: String"),
                "a String title routes SwiftUI to its verbatim overload and never localizes")
        #expect(!source.contains("public let help: String?"),
                "same for the tooltip")
    }

    // MARK: (m) Task 5b -- catch the whole CLASS of untranslatable UI text.

    /// UI-facing property names that, typed `String`, route SwiftUI's
    /// `Text`/`Label`/`Button`/`.help`/etc. overload resolution to the
    /// verbatim `StringProtocol` initializer instead of the translating
    /// `LocalizedStringKey` one -- it compiles, it renders, it passes every
    /// test, and it never translates. `MetricCard.title`, `ArchiveClass.
    /// displayName`, `ArchiveTargetRow.displayName`, `ArchiveStripView.
    /// reclaimHelpText`, `LibraryWelcomeView.actionableMessage`,
    /// `WorkspaceAction`/`Menu`/`MenuItem.title`+`help`, and `ExportMenu`/
    /// `ExportMenuItem.title` are seven separate, individually-fixed
    /// instances of this exact defect -- nothing stopped an eighth
    /// (`ExportMenu`'s own leak survived the sixth fix, in the SAME wave).
    /// This test holds the SHAPE -- any UI-named `String` property anywhere
    /// in `AstroUI` -- not any one name.
    private static let uiPropertyNames = [
        "title", "help", "label", "caption", "subtitle",
        "explanation", "actionTitle", "message", "placeholder",
    ]

    /// `"<file>#<propertyName>"` pairs deliberately left `String`, each with
    /// a reason specific to that field. "Left as-is for now" is not a
    /// reason -- an unjustified exemption is a permanent hole six months
    /// later (this wave already found one: a Task 2b gate exemption
    /// justified by an audit that had finished a day earlier). A reason of
    /// "UNDECIDED" is honest, not a loophole: it means a human still needs
    /// to make this call -- see Task 5b's own report for which ones and why.
    private static let uiPropertyAllowlist: [String: String] = [
        "Sources/AstroUI/Features/Exports/ExportMenu.swift#title":
            """
            DATA, of necessity: this entry covers `ExportMenuItem`'s own \
            per-case `title` (the `.file`/`.clipboard` associated value), NOT \
            `ExportMenu`'s own `title` (that one -- the menu's visible label, \
            used only for display -- IS `LocalizedStringKey` now). \
            `ExportMenuItem.title` also builds the `NSSavePanel` window title \
            and interpolated toast messages ("\\(title) failed: ...", \
            "\\(title) copied to clipboard") in `performFile`/`performClipboard` \
            -- both require a plain `String`; a `LocalizedStringKey` cannot be \
            interpolated into one or assigned to `NSSavePanel.title`. The real \
            display defect is fixed at its two render sites in `ExportMenu.body`, \
            which now force the translating overload with \
            `Label(LocalizedStringKey(itemTitle), systemImage:)` -- translation \
            works despite the stored type staying `String`.
            """,
        "Sources/AstroUI/Features/Search/GlobalSearchStore.swift#title":
            """
            DATA: a search result's `title` is the underlying record's own \
            display name/date/filename (a project's `displayName`, a night's \
            `date`, a file's last path component, a note's "key: value", a \
            result's software name) -- never authored prose. Routing it \
            through `LocalizedStringKey` would look up a target's folder name \
            or a capture date as if it were a translation key.
            """,
        "Sources/AstroUI/Operations/OperationHost.swift#title":
            """
            RESOLVED, not data: `ActiveOperation.title`/`OutcomeRecord.title` \
            can't be `LocalizedStringKey` -- both types are `Sendable` (they \
            cross the `Task.detached` boundary `run(kind:title:work:)` runs \
            `work` on), and `LocalizedStringKey` itself is explicitly NOT \
            `Sendable` (`extension LocalizedStringKey: Sendable` is \
            `@available(*, unavailable)` in SwiftUI -- confirmed by compiling \
            a throwaway `Sendable` conformance check against this SDK). Same \
            fix as `ProjectWorkspaceRow.nextAction`: every `run(kind:title:...)` \
            call site now resolves its own literal English fragment eagerly \
            via `OperationHost.localized(_:)` (`NSLocalizedString` against \
            `Bundle.main`) before interpolating any dynamic data (a filename, \
            a target label) around it, so what lands in `title` is already- \
            translated text, not an English literal waiting to be shown \
            verbatim. See `OperationHost.localized(_:)`'s own doc comment for \
            the full reasoning, and every call site under \
            `Sources/AstroUI/**/*.swift` for the resolved fragments \
            themselves (Task 5c, 2026-08-17).
            """,
        "Sources/AstroUI/Operations/OperationHost.swift#message":
            """
            RESOLVED, not data: same `Sendable`-vs-`LocalizedStringKey` \
            conflict as this file's `title` entry, for `Toast.message`. \
            Every `notify(_:message:)` call site and this file's own \
            success/failure/cancellation toasts now resolve only their own \
            literal English fragment via `OperationHost.localized(_:)`, \
            interpolating `error.localizedDescription` (or a filename, or an \
            already-resolved `title`) around the result rather than through \
            it -- so runtime data never enters a translation key, matching \
            this wave's own rule for `OperationHost.message` (Task 5c, \
            2026-08-17). `NightNoteSheet.save()`'s own \
            `store.errorMessage ?? "..."` is the one call site that stays \
            partly opaque: `NightNoteStore.errorMessage` is itself either a \
            raw `error.localizedDescription` or a fixed English literal \
            depending which branch of its own `save()` set it, indistinguishable \
            from here -- only that call site's own literal fallback branch is \
            resolved, `store.errorMessage` itself is left as opaque data.
            """,
        "Sources/AstroUI/App/V2RootView.swift#title":
            """
            DATA, of necessity: covers `PrimarySection.title` (a `private \
            extension` in this file) -- kept `String` because \
            `BreadcrumbBar`'s own `sectionTitle: String` also consumes it \
            (via `router.primarySection.title`), and `BreadcrumbModel.crumbs` \
            deliberately keeps that whole pipeline `String` (see its own doc \
            comment: its `label` closure mixes real prose with genuine data, \
            so there is no single honestly-typed choice). The actual sidebar \
            display defect -- `Label`/`accessibilityLabel` previously took \
            this value verbatim, one of the seven pre-existing instances of \
            this class of bug -- is fixed at `sectionRow`'s two call sites, \
            which wrap it as `LocalizedStringKey` explicitly. (`V2EmptyDetail` \
            and `V2PresentationPlaceholder`'s own `title` properties, earlier \
            in this same file, ARE `LocalizedStringKey` now; this entry \
            covers only `PrimarySection.title`.)
            """,
        "Sources/AstroUI/Features/Projects/ProjectRatingRunner.swift#title":
            """
            RESOLVED, not data: same `String`-not-`LocalizedStringKey` shape
            as `OperationHost.swift#title` right above, for the exact same
            reason -- this local `title` is built to be passed straight into
            `operationHost.run(kind:title:...)`, whose own `title` parameter
            is `String` (it crosses the `Task.detached` boundary `run` starts,
            and `LocalizedStringKey` is not `Sendable`). Both branches resolve
            their own literal English fragment via `OperationHost.localized(_:)`
            ("Rating Frames", "All Projects") before interpolating a project's
            `displayName`/the library's folder name around it, so what lands
            in `title` is already-translated text, never an English literal
            waiting to be shown verbatim (Task 4, 2026-08-17 owner-feedback
            wave 3).
            """,
        "Sources/AstroUI/Settings/SettingsStore.swift#title":
            """
            DATA, of necessity: `EquipmentFilterPassband.title` is kept \
            `String` because `V2SettingsView`'s equipment table sorts its \
            "Passband" column via `TableColumn(value: \\EquipmentFilter.\
            passband.title)`, which requires a `Comparable` sort key -- \
            `LocalizedStringKey` isn't one. Every actual display call site \
            (`V2SettingsView.swift`, `SeriesInspector.swift`) wraps this \
            value as `LocalizedStringKey(...)` at its own `Text(...)`, so \
            translation works despite the stored type staying `String`.
            """,
    ]

    @Test("No user-facing text in AstroUI is typed as String")
    func uiTextIsNeverAPlainString() throws {
        let namePattern = Self.uiPropertyNames.joined(separator: "|")
        // Stored/computed property declarations, e.g. `let title: String` or
        // `public var help: String?`.
        let propertyRegex = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+(\#(namePattern))\s*:\s*String\??"#
        )
        // A SINGLE-LINE enum case associated value, e.g.
        // `case clipboard(title: String, ...)`. Deliberately does not track
        // paren balance across lines -- see this test's own "does not catch"
        // note below for what that misses.
        let enumCaseRegex = try NSRegularExpression(
            pattern: #"\bcase\s+[A-Za-z_][A-Za-z0-9_]*\(.*\b(\#(namePattern))\s*:\s*String\??"#
        )

        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                let lineNumber = offset + 1
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                for regex in [propertyRegex, enumCaseRegex] {
                    guard let match = regex.firstMatch(in: line, range: nsRange),
                          let nameRange = Range(match.range(at: 1), in: line)
                    else { continue }
                    let name = String(line[nameRange])
                    if Self.uiPropertyAllowlist["\(file)#\(name)"] != nil { continue }
                    offenders.append("\(file):\(lineNumber): `\(name)` is `String`")
                    break
                }
            }
        }

        #expect(offenders.isEmpty, """
            \(offenders.count) UI-named String propert(y/ies) in AstroUI will \
            never localize -- a plain String selects SwiftUI's verbatim \
            overload, so it compiles, renders, and passes every test without \
            ever translating (see this test's own doc comment for the 7 \
            instances that already shipped this way). Change the type to \
            LocalizedStringKey, or -- ONLY if the value is genuinely data, a \
            target name, a file path, a catalog designation -- add \
            "<file>#<propertyName>" to uiPropertyAllowlist above with a \
            reason specific to that field:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // What this gate does NOT catch, by construction:
    // - A property whose UI-facing name isn't one of `uiPropertyNames` above
    //   (this task found two: `FirstStepsView.Step.reason`, fixed anyway
    //   since it sat right next to `title`/`actionTitle` in the same struct,
    //   and `GlossaryView.Term.name`, classified as data by hand). The list
    //   is a heuristic, not a type system -- a ninth instance under a tenth
    //   name is still possible.
    // - An enum case's associated value declared across MULTIPLE lines
    //   (`enumCaseRegex` only matches a single source line) -- e.g.
    //   `ExportMenuItem.file(title: String, ...)` itself spans lines and is
    //   invisible to this gate; only its single-line `.clipboard` sibling is
    //   ever actually caught by the mechanism. Both cases share one
    //   allowlist entry today because both are handled the same way at the
    //   call site, but a future multi-line-only enum case with no
    //   single-line sibling would slip through entirely.
    // - Any file outside `Sources/AstroUI` (a `String`-typed UI property in
    //   `AstroToolApp` or `AstroApplication` is out of this gate's scope).
    // - A property already typed `LocalizedStringKey` but constructed from a
    //   raw runtime `String` via `LocalizedStringKey(someValue)` at a
    //   DIFFERENT, non-declaring call site -- this gate reads declarations,
    //   not every construction call site, so it cannot tell a deliberate
    //   "wrap a known-safe value as a lookup key" conversion (this task adds
    //   several) from an accidental one.
    // - Two DIFFERENT enum types in the same file sharing both a property
    //   name and an allowlist reason -- the allowlist key is `file#name`,
    //   not `file#type#name`, so it cannot distinguish them. Not a problem
    //   for anything in this file today, but a real limitation of the key
    //   shape if it ever comes up.

    // MARK: (n) Task 6 (2026-08-17, Liquid Glass) -- a Table/List must never
    // have a glassEffect parent.

    /// Two synthetic-source tests exercise `GlassTableGate.offendingLines`
    /// directly against hand-written snippets BEFORE the real-tree scan
    /// below trusts it: `glassTableGateDetectsAViolation` proves the
    /// detector actually fires on the exact failure mode this gate exists
    /// to prevent (a `Table`/`List` whose direct container is glassed,
    /// either by a chained `.glassEffect(` or by `GlassEffectContainer`
    /// itself), and `glassTableGateAllowsTheRealShape` proves it does NOT
    /// fire on the shape this task's own code actually uses (glass on the
    /// container, an explicit solid `.background` between it and the
    /// table). Without these two, a future edit that quietly weakened the
    /// detector (e.g. by only matching `.glassEffect(.regular` and missing
    /// a tinted/interactive variant) could still show a clean real-tree
    /// scan for the wrong reason -- no violation existed to catch, not
    /// because the detector would have caught one.
    @Test("The Table/List-glass-parent detector flags a deliberate violation")
    func glassTableGateDetectsAViolation() {
        let chainedAfterClosure = """
            struct BadCard: View {
                var body: some View {
                    VStack {
                        Table(rows) {
                            TableColumn("Path") { row in Text(row.path) }
                        }
                    }
                    .glassEffect(.regular, in: ConcentricRectangle())
                }
            }
            """
        #expect(!GlassTableGate.offendingLines(in: chainedAfterClosure).isEmpty)

        let glassEffectContainerItself = """
            struct BadList: View {
                var body: some View {
                    GlassEffectContainer {
                        List(rows) { row in Text(row.path) }
                    }
                }
            }
            """
        #expect(!GlassTableGate.offendingLines(in: glassEffectContainerItself).isEmpty)

        // Same failure mode as `chainedAfterClosure` above, but with an
        // unrelated modifier (`.padding()`) sitting between the container's
        // closing brace and the `.glassEffect(` call -- the detector must
        // keep scanning chained modifier lines rather than stopping at the
        // first one that is not itself `.glassEffect(`.
        let anotherModifierBeforeGlassEffect = """
            struct BadTable: View {
                var body: some View {
                    VStack {
                        Table(rows) {
                            TableColumn("x") { r in Text(r.x) }
                        }
                    }
                    .padding()
                    .glassEffect(.regular.tint(.blue), in: ConcentricRectangle())
                }
            }
            """
        #expect(!GlassTableGate.offendingLines(in: anotherModifierBeforeGlassEffect).isEmpty)
    }

    @Test("The Table/List-glass-parent detector allows the container-glass/dense-content-solid split")
    func glassTableGateAllowsTheRealShape() {
        // Mirrors `WorkspaceTablePage.body` and `ArchiveTaskDetailView
        // .tableContent`'s own real shape: the OUTER page carries the glass,
        // a `GroupBox` is the table's actual direct parent, and an explicit
        // solid `.background` sits between the two -- never `.glassEffect`
        // touching the same container as the table.
        let realShape = """
            struct GoodPage: View {
                var body: some View {
                    VStack {
                        GlassEffectContainer {
                            toolbar
                                .glassEffect(.regular, in: ConcentricRectangle())
                        }
                        GroupBox("Findings") {
                            Table(rows) {
                                TableColumn("Path") { row in Text(row.path) }
                            }
                        }
                        .background(AstroTokens.Color.surface, in: ConcentricRectangle())
                    }
                    .padding()
                }
            }
            """
        #expect(GlassTableGate.offendingLines(in: realShape).isEmpty)
    }

    /// The real-tree scan the two synthetic tests above exist to justify
    /// trusting: every `.swift` file under `Sources/AstroUI` today, checked
    /// with the exact same detector. This is the gate itself, not a demo of
    /// it -- see this task's own report for the actual red/green run
    /// performed against a temporary real violation before this test was
    /// written (introduced in `ArchiveTaskDetailView.swift`, confirmed this
    /// test failed, then reverted).
    @Test("No Table or List in Sources/AstroUI has a glassEffect container as its direct parent")
    func noTableOrListHasAGlassParent() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = GlassTableGate.offendingLines(in: source)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, "Table/List with a glassEffect container as its direct parent: \(offenders.joined(separator: "; "))")
    }

    // MARK: (o) Task 7 (2026-08-17) -- GroupBox is a blocker, not a tidy-up.
    //
    // `GroupBox` paints macOS's own opaque, non-configurable grey background
    // plus its own padding and corner radius -- none of it drawn from
    // `AstroTokens`. Task 6 (Liquid Glass) put real glass on cards, panels
    // and inspectors, but every `GroupBox` painted right over it: the owner
    // installed the build and reported "not glassy, strange grey box in a
    // box, inconsistent padding/margins/corners, things hanging over the
    // edge" -- one cause (this type), three symptoms. `ReviewWorkspace`
    // (0 `GroupBox`, 0 `WorkspacePage`) is the one screen he singled out as
    // beautiful, and it never used this type at all. Grouping is a heading
    // plus spacing (`ReviewWorkspace.frameReview`'s own "HStack header,
    // Divider, content" shape), or a standard `Form`/`Section` for
    // label-value rows (`FrameInspector`'s own shape) -- never a border on
    // a border.
    @Test("No feature view uses GroupBox -- it paints an opaque box over the design")
    func noGroupBoxInFeatureViews() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI/Features") {
            let source = Self.removingLineComments(try contents(file))
            if source.contains("GroupBox") { offenders.append(file) }
        }
        #expect(offenders.isEmpty, "GroupBox still used in: \(offenders.joined(separator: ", "))")
    }

    // MARK: (p) Task 7b (2026-08-17) -- the page backdrop is opaque `ground`,
    // or it is not the page backdrop.
    //
    // `AstroTokens.Color.ground` (`0xF6F7FB` light / `0x070A10` dark) is the
    // grouped WINDOW BACKDROP half of this design system's own layering
    // pair; `surface` (`0xFFFFFF` / `0x10151F`) is the CONTENT half raised
    // on top of it. That pair is the macOS default for layered content --
    // System Settings, Mail's message list, Finder's info panes -- and it
    // only works when the backdrop is actually painted, at full strength.
    //
    // A PARTIAL `ground` is neither half. It is `ground` blended with
    // whatever happens to be behind it, which means the resulting colour is
    // one nobody chose and nobody can predict from reading the call site --
    // and when what is behind it is the window itself (essentially white in
    // light appearance), a 22-36% `ground` is very nearly white, which is
    // how five workspace roots ended up flush with the white `surface`
    // cards sitting on them. The four different strengths the tree carried
    // at once (36% x4, 32%, 22%) are the tell: they were not a decision,
    // they were five people guessing.
    //
    // The rule is therefore about STRENGTH, not about which files: paint
    // `ground` opaque or do not paint it. The detector below is
    // deliberately written against the token, so a NEW view inventing a
    // sixth tint strength is caught the day it is written -- unlike a gate
    // that had enumerated the five known offenders, which is exactly the
    // failure mode `noInlineColorsInFeatureViews` and
    // `uiTextIsNeverAPlainString` both document having been bitten by.

    @Test("The partial-ground detector flags every shape a tint can be written in")
    func groundOpacityGateDetectsViolations() {
        // Same-line, the shape all five real offenders used.
        #expect(!GroundOpacityGate.offendingLines(
            in: ".background(AstroTokens.Color.ground.opacity(0.36))"
        ).isEmpty)

        // Wrapped across lines -- a detector that scanned line-by-line
        // would miss this, and reformatting is not a fix.
        #expect(!GroundOpacityGate.offendingLines(in: """
            .background(
                AstroTokens.Color.ground
                    .opacity(0.22)
            )
            """).isEmpty)

        // Whitespace around the member accesses, and a non-`.background`
        // consumer (`fill`) -- the rule is about the token's strength, not
        // about which modifier happens to receive it.
        #expect(!GroundOpacityGate.offendingLines(
            in: ".fill(AstroTokens.Color.ground . opacity( 0.5 ))"
        ).isEmpty)

        // Bare `.ground` (no `AstroTokens.Color` prefix), e.g. inside a
        // `Color` extension or after a `typealias`.
        #expect(!GroundOpacityGate.offendingLines(
            in: ".background(.ground.opacity(0.9))"
        ).isEmpty)
    }

    @Test("The partial-ground detector allows opaque ground and unrelated opacity")
    func groundOpacityGateAllowsTheRealShape() {
        // The two real paint sites in the tree today.
        #expect(GroundOpacityGate.offendingLines(
            in: ".background(AstroTokens.Color.ground)"
        ).isEmpty)

        // `.opacity` on something that is NOT `ground` must not trip it --
        // fading a card, a chart series, a disabled control is all normal.
        #expect(GroundOpacityGate.offendingLines(in: """
            .background(AstroTokens.Color.surface.opacity(0.5))
            .opacity(isEnabled ? 1 : 0.4)
            Circle().fill(AstroTokens.Color.dataLight.opacity(0.3))
            """).isEmpty)

        // `ground` used opaquely, with an `.opacity` elsewhere in the same
        // chain applying to the composed view rather than to the token --
        // a different thing, and not what this gate is about.
        #expect(GroundOpacityGate.offendingLines(in: """
            .background(AstroTokens.Color.ground)
            .opacity(0.5)
            """).isEmpty)

        // A word merely ENDING in "ground" is not the token.
        #expect(GroundOpacityGate.offendingLines(
            in: ".background(theme.playground.opacity(0.4))"
        ).isEmpty)
    }

    /// The real-tree scan the two synthetic tests above exist to justify
    /// trusting. See this task's own report for the red/green run performed
    /// by reverting a real fix (`ReviewWorkspace`'s 22% tint) and watching
    /// this test fail, then restoring it.
    ///
    /// What this does NOT catch, by construction:
    /// - `ground` reached through a local alias or a computed property
    ///   (`let base = AstroTokens.Color.ground` … `base.opacity(0.3)`) --
    ///   a source-text scan cannot follow a binding.
    /// - an opacity applied through a modifier other than `.opacity(`
    ///   (`.blendMode`, a `LinearGradient` of `ground` stops with alpha, a
    ///   `Material` over `ground`), which would produce a similarly
    ///   unpredictable colour by a route this pattern does not describe.
    /// - anything outside `Sources/AstroUI`.
    @Test("No view in Sources/AstroUI paints ground at partial opacity")
    func groundIsNeverPaintedAtPartialOpacity() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = GroundOpacityGate.offendingLines(in: source)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, """
            `ground` is the grouped window backdrop -- paint it opaque or do \
            not paint it. A partial tint blends it with an unknown parent \
            (in light appearance, a near-white window), which is how the \
            page backdrop silently disappeared and left white `surface` \
            cards on a white page. If this view needs to sit ON the \
            backdrop rather than BE it, use `AstroTokens.Color.surface` (or \
            a `.glassEffect`) instead of a weakened `ground`:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The other half of the rule: the backdrop must actually be painted
    /// somewhere. The rule above only forbids a WEAK `ground` -- deleting
    /// the paint entirely satisfies it perfectly, which is precisely what
    /// Task 6 did (three sites, on the incorrect theory that a transparent
    /// detail pane would show the window's own macOS 26 system glass; on
    /// macOS that material is in the sidebar and toolbar, never in a plain
    /// window's content area, so the pane fell through to a near-white
    /// window and the whole layering went flat).
    ///
    /// This one deliberately IS specific to `V2RootView`, and that is not
    /// the "list of names" antipattern: the rule this file settled on is
    /// that the detail column is the SINGLE owner of the page backdrop
    /// (`DetailHost` has 21 routes and only 8 go through
    /// `WorkspacePage`/`WorkspaceTablePage`, so per-page backdrops would
    /// cover a minority of the app). A single owner can only be pinned by
    /// naming it. What would make this a bad gate is if the owner moved and
    /// this test kept passing -- it cannot, because it asserts the exact
    /// token paint that constitutes ownership.
    @Test("The detail column still paints the opaque ground backdrop it owns")
    func theDetailColumnPaintsTheOpaqueBackdrop() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/App/V2RootView.swift"))
        #expect(source.contains(".background(AstroTokens.Color.ground)"), """
            V2RootView's detail column is the single owner of the page \
            backdrop -- without it every route falls through to the window \
            background (near-white in light appearance) and every `surface` \
            card on every page goes white-on-white. If ownership moved, \
            move this assertion with it rather than deleting it.
            """)
    }

    // MARK: (q) Task 7c (2026-08-17) -- there is ONE raised layer, and it
    // never contains itself.
    //
    // Task 7 removed 35 `GroupBox`es and Task 7b restored the `ground`
    // backdrop underneath them. What was left was a backdrop with nothing on
    // it: `surface` was painted at exactly one site in the whole tree
    // (`WorkspaceTablePage`'s table slot), `surfaceRaised` at none, and the
    // one `.shadow(` belonged to a toast. Outside the eight table pages,
    // every route was bare text on grey -- and in LIGHT appearance, which is
    // what the owner runs, `ground` (`0xF6F7FB`) and `surface` (`0xFFFFFF`)
    // are a 4% tonal step apart, so even the one painted surface had no
    // edge.
    //
    // `View.astroRaisedSurface(_:)` (`DesignSystem/AstroSurface.swift`) is
    // the single treatment that fixes that: one fill, one hairline, one
    // shadow, one corner shape, one padding value. The three gates below
    // hold the three properties that make it a design system rather than a
    // 36th kind of box.

    @Test("The raised-surface nesting detector flags a deliberate box-in-box")
    func raisedSurfaceGateDetectsNesting() {
        // The literal defect the owner reported for `GroupBox`: "doboz a
        // dobozban" -- a card whose content is another card.
        let nested = """
            struct BadCard: View {
                var body: some View {
                    VStack {
                        VStack {
                            Text("inner")
                        }
                        .astroRaisedSurface()
                    }
                    .astroRaisedSurface()
                }
            }
            """
        // Only the INNER one is reported: the outer surface is legitimate,
        // it is the second one that has nowhere to be.
        #expect(RaisedSurfaceGate.nestedOccurrences(in: nested) == [7])

        // Two levels apart rather than immediately adjacent -- the walk must
        // keep going outward, not stop at the first enclosing block.
        let nestedDeeper = """
            struct BadCard: View {
                var body: some View {
                    VStack {
                        HStack {
                            Section {
                                Text("inner").astroRaisedSurface()
                            }
                        }
                    }
                    .astroRaisedSurface(.flush)
                }
            }
            """
        #expect(!RaisedSurfaceGate.nestedOccurrences(in: nestedDeeper).isEmpty)

        // The outer surface declared by wrapping rather than by chaining,
        // with an unrelated modifier between the closing brace and the call.
        let modifierInBetween = """
            struct BadCard: View {
                var body: some View {
                    VStack {
                        Text("inner").astroRaisedSurface()
                    }
                    .padding()
                    .astroRaisedSurface()
                }
            }
            """
        #expect(!RaisedSurfaceGate.nestedOccurrences(in: modifierInBetween).isEmpty)
    }

    @Test("The raised-surface nesting detector allows siblings and lone surfaces")
    func raisedSurfaceGateAllowsTheRealShape() {
        // Two cards side by side on the same page is the NORMAL shape --
        // Insights renders six of them. Neither encloses the other.
        let siblings = """
            struct GoodPage: View {
                var body: some View {
                    VStack {
                        VStack { Text("a") }
                            .astroRaisedSurface()
                        VStack { Text("b") }
                            .astroRaisedSurface()
                    }
                }
            }
            """
        #expect(RaisedSurfaceGate.nestedOccurrences(in: siblings).isEmpty)

        // A helper property that raises, declared as a SIBLING of the body
        // that uses it, is not lexical nesting -- and must not be reported
        // as such, or every file with a `private var card: some View` would
        // fail. (The cross-file/cross-function case this cannot see is
        // handled at runtime instead -- see the collapse gate below.)
        let helperProperty = """
            struct GoodPage: View {
                var body: some View {
                    VStack {
                        card
                    }
                }

                private var card: some View {
                    VStack { Text("a") }
                        .astroRaisedSurface()
                }
            }
            """
        #expect(RaisedSurfaceGate.nestedOccurrences(in: helperProperty).isEmpty)
    }

    /// The real-tree scan the two synthetic tests above exist to justify
    /// trusting.
    ///
    /// What this does NOT catch, by construction: a raised surface reached
    /// through a helper function, a computed property, or another file --
    /// a lexical brace walk cannot follow a call. That case is covered by
    /// construction rather than by scanning: `AstroRaisedSurface` publishes
    /// `astroIsInsideRaisedSurface` into the environment and a nested
    /// application collapses to its inset alone, which
    /// `theRaisedSurfaceCollapsesWhenNested` below pins down.
    @Test("No raised surface in Sources/AstroUI contains another raised surface")
    func noRaisedSurfaceNestsInsideAnother() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = RaisedSurfaceGate.nestedOccurrences(in: source)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, """
            A raised surface inside a raised surface is the "doboz a dobozban" \
            defect that made `GroupBox` unusable -- a border on a border, with \
            two paddings and two corner radii. Grouping WITHIN a card is a \
            heading plus spacing or a `Divider`, exactly as macOS does it:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The runtime half of the same rule, and the reason the lexical gate
    /// above is allowed to have blind spots. Asserted as a structural
    /// property of the modifier, the same way
    /// `theDetailColumnPaintsTheOpaqueBackdrop` asserts the backdrop's single
    /// owner: if the guard is deleted, a helper-function or cross-file
    /// nesting starts painting a second card and nothing else in this suite
    /// would notice.
    @Test("The raised-surface modifier collapses instead of painting a second card")
    func theRaisedSurfaceCollapsesWhenNested() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/DesignSystem/AstroSurface.swift"))
        #expect(source.contains("@Environment(\\.astroIsInsideRaisedSurface) private var isNested"),
                "the modifier no longer reads whether an ancestor already raised")
        #expect(source.contains("if isNested {"),
                "the modifier no longer branches on the nesting guard")
        #expect(source.contains(".environment(\\.astroIsInsideRaisedSurface, true)"),
                "the modifier no longer publishes the guard to its descendants")
        // The collapsed branch must paint NOTHING -- no fill, no hairline,
        // no shadow. Checked by counting: each painted layer appears exactly
        // once in the file, in the non-nested branch only.
        for painted in [".fill(AstroTokens.Color.surface", ".strokeBorder(AstroTokens.Color.edge", ".shadow(color: shadowColor"] {
            #expect(source.components(separatedBy: painted).count == 2,
                    "\(painted) must appear exactly once -- the collapsed branch paints nothing")
        }
    }

    /// One file, one justified exemption: `AstroSurface.swift` is the shared
    /// treatment itself, and something has to actually paint the token.
    private static let surfacePaintExemptFiles: Set<String> = ["AstroSurface.swift"]

    @Test("No view outside the shared treatment paints surface or surfaceRaised")
    func surfaceTokensAreOnlyPaintedByTheSharedTreatment() throws {
        // Stated as a rule over the whole source tree, deliberately NOT as a
        // list of view names: the failure mode this file has documented
        // three times over (`noInlineColorsInFeatureViews`,
        // `uiTextIsNeverAPlainString`, `groundIsNeverPaintedAtPartialOpacity`)
        // is a gate that enumerated the offenders an audit happened to find,
        // and was therefore blind to the next one written. A NEW view that
        // hand-rolls its own card is caught the day it is written.
        //
        // Matches the token by name in any form -- fully qualified
        // (`AstroTokens.Color.surface`), through the enum
        // (`Color.surfaceRaised`), or bare (`.surface` after a `typealias`).
        // The leading `\.` is what anchors it to a member access, so no
        // lookbehind is wanted here: the character before the dot is the
        // END of the qualifier (`...Color.surface`), and a `(?<![A-Za-z0-9_])`
        // in front of the dot would reject exactly the fully-qualified form
        // this gate most needs to catch. (It did, when first written --
        // caught by running the gate against a deliberately-injected
        // `.background(AstroTokens.Color.surfaceRaised)` and watching it
        // pass.) The trailing lookahead is real: it keeps a longer
        // identifier (`.surfaceArea`) from matching, and it must try
        // `surfaceRaised` before `surface` or the alternation settles on the
        // shorter branch.
        //
        // Task 7d added `recess` to the same alternation rather than writing
        // a second, near-identical scanner: the rule is "a structural surface
        // token is painted by its own shared treatment, never by a view", and
        // there are now three such tokens.
        let pattern = try NSRegularExpression(
            pattern: #"\.(surfaceRaised|surface|recess)(?![A-Za-z0-9_])"#
        )
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            if Self.surfacePaintExemptFiles.contains((file as NSString).lastPathComponent) { continue }
            // `AstroTokens.swift` DECLARES the tokens; declaring is not
            // painting. Matched by the declaration form specifically rather
            // than exempting the whole file, so a stray paint added to it
            // later is still caught.
            let source = Self.removingLineComments(try contents(file))
            for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                if line.contains("public static let surface") { continue }
                if line.contains("public static let recess") { continue }
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                guard pattern.firstMatch(in: line, range: nsRange) != nil else { continue }
                offenders.append("\(file):\(offset + 1)")
            }
        }
        #expect(offenders.isEmpty, """
            `surface`/`surfaceRaised` are the FILL of the one raised layer, \
            not a colour a view picks up on its own -- a bare fill has no \
            edge, and in light appearance it is a 4% step off `ground`, which \
            is how the tree ended up with a backdrop and nothing readable on \
            it. Use `.astroRaisedSurface()` (or `.astroRaisedSurface(.flush)` \
            for a `Table`/`List`/self-chromed panel), which owns the fill, \
            the hairline, the shadow, the corner shape and the padding \
            together:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: (r) Task 7d (2026-08-17) -- the recessed layer, and the one
    // vocabulary that cannot express it.
    //
    // Three wells, three recipes: `.quaternary.opacity(0.45)`
    // (`ProjectsView`), `.quaternary.opacity(0.5)` at a corner radius of 10
    // (`ResultsView`), and a bare `.quaternary` (`MutationConfirmationSheet`).
    // The inconsistency is the owner's own complaint; the INVERSION is the
    // part nobody could see. See `RecessedFillGate`'s own doc comment for the
    // measurements, and `astroRecessedSurface(_:)` for the treatment.

    @Test("The recessed-fill detector flags every shape a hierarchical fill can be written in")
    func recessedFillGateDetectsViolations() {
        // The three real offenders' own shapes: bare, with an opacity, and
        // as an `in:`-shaped background.
        #expect(!RecessedFillGate.offendingLines(
            in: ".background(.quaternary, in: RoundedRectangle(cornerRadius: 12))"
        ).isEmpty)
        #expect(!RecessedFillGate.offendingLines(
            in: ".background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))"
        ).isEmpty)
        #expect(!RecessedFillGate.offendingLines(
            in: ".background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))"
        ).isEmpty)

        // Qualified through the type, and fully qualified -- the exact blind
        // spot the last agent's negative lookbehind produced on
        // `AstroTokens.Color.surfaceRaised`, checked here deliberately.
        #expect(!RecessedFillGate.offendingLines(in: ".background(Color.secondary.opacity(0.18))").isEmpty)
        #expect(!RecessedFillGate.offendingLines(in: ".background(HierarchicalShapeStyle.quaternary)").isEmpty)
        #expect(!RecessedFillGate.offendingLines(in: "Rectangle().fill(.tertiary)").isEmpty)
        #expect(!RecessedFillGate.offendingLines(in: ".fill(SwiftUI.HierarchicalShapeStyle.primary)").isEmpty)

        // Wrapped across lines -- reformatting is not a fix.
        #expect(!RecessedFillGate.offendingLines(in: """
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
            )
            """).isEmpty)

        // Whitespace around the member accesses.
        #expect(!RecessedFillGate.offendingLines(in: ".fill( Color . secondary )").isEmpty)

        // The reported line number is the line the call STARTS on, so a
        // human can find it.
        #expect(RecessedFillGate.offendingLines(in: """
            VStack {
                Text("hi")
            }
            .background(.quaternary)
            """) == [4])
    }

    @Test("The recessed-fill detector allows the shared treatment, foreground styles, and badges")
    func recessedFillGateAllowsTheRealShapes() {
        // The treatment itself, and the token behind it.
        #expect(RecessedFillGate.offendingLines(in: ".astroRecessedSurface()").isEmpty)
        #expect(RecessedFillGate.offendingLines(in: ".background { shape.fill(AstroTokens.Color.recess) }").isEmpty)

        // The FOREGROUND use of the very same names, which is correct and
        // used on nearly every screen. A gate that flagged this would be
        // unusable and would be turned off within a week.
        #expect(RecessedFillGate.offendingLines(in: """
            Text("detail").foregroundStyle(.secondary)
            Text("path").foregroundStyle(.tertiary)
            .foregroundStyle(isCurrent ? .white : .primary)
            """).isEmpty)

        // Badge vocabulary: a tinted pill or disc sized to a glyph is not a
        // surface, and its colour means a status rather than a depth.
        #expect(RecessedFillGate.offendingLines(
            in: ".background(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18), in: Circle())"
        ).isEmpty)
        #expect(RecessedFillGate.offendingLines(in: ".background(.quaternary, in: Capsule())").isEmpty)

        // A design token used as a fill is the whole point -- only the
        // HIERARCHICAL vocabulary is forbidden here. (`surface`/`recess`
        // being reserved to their shared treatments is a different rule,
        // gated by `surfaceTokensAreOnlyPaintedByTheSharedTreatment`.)
        #expect(RecessedFillGate.offendingLines(in: """
            .background(AstroTokens.Color.ok.opacity(0.18), in: Capsule())
            Rectangle().fill(AstroTokens.Color.edge.opacity(0.08))
            .background(AstroTokens.Color.ground)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            """).isEmpty)

        // An identifier merely BEGINNING with one of the four names.
        #expect(RecessedFillGate.offendingLines(in: ".background(.secondaryLabelWell)").isEmpty)
        #expect(RecessedFillGate.offendingLines(in: ".fill(theme.primaryAccent)").isEmpty)
    }

    /// The real-tree scan the two synthetic tests above exist to justify
    /// trusting. NO exemptions, not even a temporary one: the third
    /// offender (`ResultsView`'s `.quaternary.opacity(0.5)` at a corner
    /// radius of 10 -- the only panel-shaped radius in the app that was not
    /// `AstroTokens.CornerRadius.panel`) belonged to a concurrent task's
    /// file, and that task adopted the shared treatment itself rather than
    /// leaving a hole in the rule.
    @Test("No view in Sources/AstroUI paints a recessed fill by hand")
    func noViewPaintsARecessedFillByHand() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = RecessedFillGate.offendingLines(in: source)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, """
            A hierarchical style (`.primary`/`.secondary`/`.tertiary`/\
            `.quaternary`) is a FOREGROUND vocabulary: as a fill it is black \
            at ~10% in light appearance and WHITE at ~10% in dark, so the \
            same call site reads recessed for one user and raised for \
            another. Use `.astroRecessedSurface()` (or \
            `.astroRecessedSurface(.flush)` for content that insets itself), \
            which owns the fill, the corner shape and the padding together \
            and whose direction is measured in both appearances:
            \(offenders.joined(separator: "\n"))
            """)
    }

    @Test("No recessed surface is applied inside another recessed surface")
    func noRecessedSurfaceIsNested() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = RaisedSurfaceGate.nestedOccurrences(in: source, modifier: RaisedSurfaceGate.recessedModifier)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, """
            A well inside a well is the same defect as a box inside a box: \
            two identical fills meet, so the inner one is invisible and only \
            its doubled gutter shows:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The runtime half of the rule above, and the reason the lexical gate is
    /// allowed to have blind spots -- exactly the pairing
    /// `theRaisedSurfaceCollapsesWhenNested` documents for the raised layer.
    @Test("The recessed-surface modifier collapses instead of painting a second well")
    func theRecessedSurfaceCollapsesWhenNested() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/DesignSystem/AstroSurface.swift"))
        #expect(source.contains("@Environment(\\.astroIsInsideRecessedSurface) private var isNested"),
                "the modifier no longer reads whether an ancestor already recessed")
        #expect(source.contains(".environment(\\.astroIsInsideRecessedSurface, true)"),
                "the modifier no longer publishes the guard to its descendants")
        // The collapsed branch must paint NOTHING. Counted the same way the
        // raised gate counts, so the fill cannot quietly move into it.
        #expect(source.components(separatedBy: ".fill(AstroTokens.Color.recess)").count == 2,
                "the recess fill must appear exactly once -- the collapsed branch paints nothing")
        // A well never carries the raised layer's edge cues: a stroke inside
        // the card's own stroke is a border on a border, and a drop shadow
        // says "above", which is the opposite of what the fill says.
        #expect(!source.contains("recess).shadow"), "a well must not carry a shadow")
        #expect(!source.contains("strokeBorder(AstroTokens.Color.recess"), "a well must not carry a hairline")
    }

    /// Resolves the three structural tokens through
    /// `NSAppearance.performAsCurrentDrawingAppearance` and asserts the
    /// direction of the layering in BOTH appearances: raised is lighter than
    /// the backdrop, never the other way round. `GroupBox`'s defect was not
    /// only that it painted its own box -- it painted a GREY one over white
    /// content, i.e. the layering upside down. A token edit that reversed
    /// `ground` and `surface` would leave every source-text gate in this file
    /// perfectly green.
    @Test("Raised is lighter than the backdrop in both appearances, and the edge is distinct from both")
    @MainActor
    func theRaisedLayerIsLighterThanTheBackdrop() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                Issue.record("Could not build \(appearanceName.rawValue)")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let ground = Self.luminance(of: AstroTokens.Color.ground)
                let surface = Self.luminance(of: AstroTokens.Color.surface)
                let raised = Self.luminance(of: AstroTokens.Color.surfaceRaised)
                let edge = Self.luminance(of: AstroTokens.Color.edge)
                #expect(surface > ground, "\(appearanceName.rawValue): surface must be lighter than ground")
                #expect(raised >= surface, "\(appearanceName.rawValue): surfaceRaised must not be darker than surface")
                #expect(abs(edge - surface) > 0.01, "\(appearanceName.rawValue): the hairline must be distinguishable from the surface it edges")
            }
        }
    }

    /// The recessed half of the same idea, and the gate the whole of Task 7d
    /// hangs on. `astroRecessedSurface` paints a FILL and nothing else -- no
    /// hairline, no shadow -- so unlike the raised layer it has no fallback
    /// cue if the fill is wrong. It has to be measurably below both the
    /// backdrop and the surface, in both appearances, or it is not recessed;
    /// the three `.quaternary` recipes it replaced satisfied that in light
    /// appearance and failed it in dark, which is the defect this test
    /// exists to make impossible to reintroduce silently.
    @Test("The recessed layer is darker than both the backdrop and the raised surface, in both appearances")
    @MainActor
    func theRecessedLayerIsDarkerThanBothInBothAppearances() {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                Issue.record("Could not build \(appearanceName.rawValue)")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let name = appearanceName.rawValue
                let ground = Self.luminance(of: AstroTokens.Color.ground)
                let surface = Self.luminance(of: AstroTokens.Color.surface)
                let recess = Self.luminance(of: AstroTokens.Color.recess)
                let edge = Self.luminance(of: AstroTokens.Color.edge)
                #expect(recess < surface, "\(name): a well must be darker than the surface it is sunk into")
                #expect(recess < ground, "\(name): a well must be darker than the page backdrop too, so it reads the same way wherever it is put")
                // Direction alone is not enough: a 0.4% step is technically
                // darker and visually nothing. `surface` -> `ground` is 3.1%
                // in light and that pair needs a hairline AND a shadow to
                // read; a fill-only treatment needs more than that on its
                // own.
                #expect(surface - recess > 0.04, "\(name): the well is too shallow to read on fill alone (\(surface - recess))")
                // A well often sits next to a `Divider`, which is `edge`. If
                // the two resolve to the same tone the divider vanishes into
                // the well -- in light appearance these are only 2.4 points
                // apart, so this is a real constraint, not a formality.
                #expect(abs(edge - recess) > 0.02, "\(name): the hairline must stay distinguishable from the recessed fill")
            }
        }
    }

    /// Relative luminance of a token resolved in whatever appearance is
    /// current. `usingColorSpace(.sRGB)` because a dynamic `NSColor` has no
    /// components until it is resolved into a concrete space.
    @MainActor
    private static func luminance(of color: SwiftUI.Color) -> Double {
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return .nan }
        return 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
    }

    // MARK: (r2) W2-10 (2026-08-17) -- flush content is clipped to the
    // surface's own shape, unconditionally.
    //
    // Part 1 of this task ("lekerekítések is legyenek szépek" -- corners
    // should be beautiful) asked for `.flush` content (a `Table`/`List`)
    // to be clipped to its card's rounded shape so square corners cannot
    // punch through. That clip already existed at this task's start
    // (Task 7c/7d, `AstroRaisedSurface`/`AstroRecessedSurface.body`'s
    // `.clipShape(shape)`) -- but it is applied in the SAME branch for
    // both `AstroSurfaceFit` cases, which is easy to state and easy to
    // silently break by adding a second switch on `fit` later. This test
    // pins the structural guarantee down directly, rather than trusting a
    // one-time reading of the file.
    @Test("AstroSurfaceFit is switched on in exactly one place (inset), so flush content cannot get a different clip/fill/shadow than padded content")
    func fitOnlyEverChangesThePaddingValue() throws {
        let source = try contents("Sources/AstroUI/DesignSystem/AstroSurface.swift")
        // Each case must appear EXACTLY once (not `min`-of-the-two, which a
        // first draft of this test used and which stayed green when a
        // defect added a second `case .flush` alone, with no matching
        // `case .padded` -- caught by injecting exactly that shape and
        // watching this version fail where the `min` version did not; see
        // this task's own report for the transcript). A second occurrence
        // of EITHER case anywhere in this file means `fit` is being
        // switched on a second time, outside `inset`.
        let paddedCaseCount = source.components(separatedBy: "case .padded").count - 1
        let flushCaseCount = source.components(separatedBy: "case .flush").count - 1
        #expect(paddedCaseCount == 1, "`case .padded` must be switched on in exactly one place (`inset`) -- found \(paddedCaseCount)")
        #expect(flushCaseCount == 1, "`case .flush` must be switched on in exactly one place (`inset`) -- found \(flushCaseCount)")
    }

    @Test("Neither shared treatment's body branches beyond the single nested/non-nested if-else")
    func bothTreatmentsHaveExactlyOneBranchPoint() throws {
        let source = try contents("Sources/AstroUI/DesignSystem/AstroSurface.swift")
        // `AstroRaisedSurface.body`/`AstroRecessedSurface.body` each have
        // exactly one branch point: `if isNested { ... } else { ... }`. An
        // `else if` anywhere in this file would mean a THIRD path was
        // added -- the exact shape of the real defect this test exists to
        // catch (a `fit`-conditional branch that gives `.flush` a
        // different clip/fill/shadow than `.padded`, silently skipping
        // `.clipShape(shape)` for exactly the content -- a `Table`/`List`
        // -- this task's corners fix is about). Counting occurrences of
        // `.clipShape(shape)` alone does NOT catch this: a defect that
        // moves the existing call into a narrower branch leaves the
        // literal text's occurrence count unchanged, which is exactly why
        // this checks branch SHAPE instead of a call count.
        #expect(!source.contains("else if"), "an `else if` means a third branch was added to a shared treatment's body -- verify `.flush` still reaches `.clipShape(shape)`")
        #expect(source.components(separatedBy: "if isNested {").count - 1 == 2, "each treatment must have exactly one nested/non-nested branch point")
    }

    // MARK: (s) W2-10 (2026-08-17) -- corners: one radius family, no
    // literals invented at a call site.
    //
    // The owner's own words: "lekerekítések is legyenek szépek" (corners
    // should be beautiful too). `AstroTokens.CornerRadius.panel` is the one
    // radius every surface (`AstroSurface.swift`) already draws from; a
    // `RoundedRectangle(cornerRadius: 6)` or a `.cornerRadius(10)` typed at
    // a call site is a radius nobody chose and nothing else in the app
    // matches -- the same "assorted small radii" defect the corners
    // complaint names. Two vocabularies are exempt, by NAME + FILE, not by
    // directory: chart marks (`Chart`'s own bar corner rounding) and
    // small (<=32pt) data-graphic/thumbnail chips, both of which are a
    // decorative scale below anything `AstroTokens.CornerRadius.panel` is
    // meant to describe. Every occurrence found sweeping `Sources/AstroUI`
    // for `cornerRadius`/`RoundedRectangle(` at this task's start is listed
    // here explicitly; a NEW literal anywhere else is caught the day it is
    // written.

    @Test("The corner-radius-literal detector flags every shape a literal radius can be written in")
    func cornerRadiusLiteralGateDetectsViolations() {
        #expect(!CornerRadiusLiteralGate.offendingLines(in: "RoundedRectangle(cornerRadius: 6)").isEmpty)
        #expect(!CornerRadiusLiteralGate.offendingLines(in: ".overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))").isEmpty)
        #expect(!CornerRadiusLiteralGate.offendingLines(in: "Rectangle().cornerRadius(4)").isEmpty)
        // Wrapped across lines, and with unusual spacing -- reformatting is
        // not a fix.
        #expect(!CornerRadiusLiteralGate.offendingLines(in: """
            RoundedRectangle(
                cornerRadius:   8
            )
            """).isEmpty)
    }

    @Test("The corner-radius-literal detector allows the token, ConcentricRectangle, and the two named exemptions")
    func cornerRadiusLiteralGateAllowsTheRealShapes() {
        #expect(CornerRadiusLiteralGate.offendingLines(
            in: "RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel, style: .continuous)"
        ).isEmpty)
        #expect(CornerRadiusLiteralGate.offendingLines(in: "ConcentricRectangle()").isEmpty)
        // A radius that happens to start with a token-like identifier rather
        // than a digit must not be mistaken for a literal.
        #expect(CornerRadiusLiteralGate.offendingLines(in: ".background(x, in: RoundedRectangle(cornerRadius: someToken))").isEmpty)
    }

    /// The real-tree scan, with the two chart/thumbnail exemptions this
    /// task's own report enumerates: `ArchiveStripView`/`ArchiveTargetRowView`
    /// (data-graphic bar clips, radius 5/4) and `FrameThumbnailCell` (a
    /// 28pt thumbnail chip, radius 4) are decorative scale below a panel
    /// radius, not a second surface vocabulary; `InsightsView`'s `BarMark
    /// .cornerRadius(4)` is `Chart`'s own mark-rounding API, which does not
    /// accept a token. Each exemption is matched by its EXACT source
    /// substring, not by file name alone, so a second, different literal
    /// added to one of these same files is still caught.
    private static let cornerRadiusLiteralExemptions: [(file: String, substring: String)] = [
        ("ArchiveStripView.swift", "RoundedRectangle(cornerRadius: 5)"),
        ("ArchiveTargetRowView.swift", "RoundedRectangle(cornerRadius: 4)"),
        ("FrameThumbnailCell.swift", "RoundedRectangle(cornerRadius: 4)"),
        ("InsightsView.swift", ".cornerRadius(4)"),
    ]

    @Test("No cornerRadius literal exists under Sources/AstroUI outside the token and the named chart/thumbnail exemptions")
    func noCornerRadiusLiteralsOutsideTheTokenFamily() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let filename = (file as NSString).lastPathComponent
            let source = Self.removingLineComments(try contents(file))
            let exemptSubstrings = Self.cornerRadiusLiteralExemptions
                .filter { $0.file == filename }
                .map(\.substring)
            let lines = source.components(separatedBy: "\n")
            for lineNumber in CornerRadiusLiteralGate.offendingLines(in: source) {
                let line = lines[lineNumber - 1]
                if exemptSubstrings.contains(where: { line.contains($0) }) { continue }
                offenders.append("\(file):\(lineNumber)")
            }
        }
        #expect(offenders.isEmpty, """
            A cornerRadius literal that matches nothing else in the app -- \
            use AstroTokens.CornerRadius.panel (via .astroRaisedSurface()/\
            .astroRecessedSurface()), or ConcentricRectangle() to match an \
            enclosing container's own shape:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: (t) W2-10 (2026-08-17) -- sibling glass shapes must share a
    // GlassEffectContainer.
    //
    // The owner asked for more Liquid Glass; `GlassEffectContainer` is what
    // lets the system MERGE and MORPH sibling glass shapes instead of each
    // one compositing its own independent blur pass next to the others --
    // without it, two or more glass shapes side by side look like two
    // separate panes of glass touching, not one coherent material. This
    // gate is deliberately narrow: it only flags `.glassEffect(` literals
    // that are LEXICAL siblings (share the same nearest enclosing block) in
    // the SAME file, because a source-text scan cannot follow a shape
    // reached through a helper function/computed property/another file --
    // `FirstScanSummaryView.countTile`'s three call sites are exactly that
    // blind spot (one `.glassEffect(` literal, called three times), and are
    // wrapped in `GlassEffectContainer` at their call site by construction
    // rather than by anything this gate can see.
    @Test("The glass-sibling detector flags glass shapes that share a parent with no GlassEffectContainer ancestor")
    func glassSiblingGateDetectsViolations() {
        let ungrouped = """
            struct BadRow: View {
                var body: some View {
                    HStack {
                        Text("a").glassEffect(.regular, in: ConcentricRectangle())
                        Text("b").glassEffect(.regular, in: ConcentricRectangle())
                    }
                }
            }
            """
        #expect(GlassSiblingGate.offendingLines(in: ungrouped) == [4, 5])

        // Three siblings, not just two -- the walk must group ALL of them,
        // not just a pair.
        let threeUngrouped = """
            HStack {
                a.glassEffect(.regular, in: ConcentricRectangle())
                b.glassEffect(.regular, in: ConcentricRectangle())
                c.glassEffect(.regular, in: ConcentricRectangle())
            }
            """
        #expect(GlassSiblingGate.offendingLines(in: threeUngrouped).count == 3)
    }

    @Test("The glass-sibling detector allows a GlassEffectContainer ancestor and lone glass shapes")
    func glassSiblingGateAllowsTheRealShapes() {
        let grouped = """
            struct GoodRow: View {
                var body: some View {
                    GlassEffectContainer {
                        HStack {
                            Text("a").glassEffect(.regular, in: ConcentricRectangle())
                            Text("b").glassEffect(.regular, in: ConcentricRectangle())
                        }
                    }
                }
            }
            """
        #expect(GlassSiblingGate.offendingLines(in: grouped).isEmpty)

        // A single glass shape with no sibling needs no container -- most of
        // the tree's glass sites (MetricCard, the Inspector panels, the
        // ProjectsView folder-preview chip) are exactly this shape.
        let lone = """
            struct GoodCard: View {
                var body: some View {
                    VStack { Text("a") }
                        .glassEffect(.regular, in: ConcentricRectangle())
                }
            }
            """
        #expect(GlassSiblingGate.offendingLines(in: lone).isEmpty)

        // Two glass shapes far apart in unrelated blocks/properties of the
        // same file -- `InspectorView`'s own real shape (four `.glassEffect(`
        // sites, one per selection-kind property, never rendered together).
        let unrelatedProperties = """
            struct GoodInspector: View {
                private var project: some View {
                    VStack { Text("p") }.glassEffect(.regular, in: ConcentricRectangle())
                }
                private var night: some View {
                    VStack { Text("n") }.glassEffect(.regular, in: ConcentricRectangle())
                }
            }
            """
        #expect(GlassSiblingGate.offendingLines(in: unrelatedProperties).isEmpty)
    }

    /// The real-tree scan the three synthetic tests above exist to justify
    /// trusting.
    @Test("No sibling glass shapes in Sources/AstroUI share a parent without a GlassEffectContainer ancestor")
    func noGlassSiblingsShareAParentWithoutAContainer() throws {
        var offenders: [String] = []
        for file in try swiftFiles(under: "Sources/AstroUI") {
            let source = Self.removingLineComments(try contents(file))
            let lines = GlassSiblingGate.offendingLines(in: source)
            if !lines.isEmpty {
                offenders.append("\(file): line(s) \(lines.map(String.init).joined(separator: ", "))")
            }
        }
        #expect(offenders.isEmpty, """
            Sibling glass shapes with no GlassEffectContainer ancestor look \
            like separate panes of glass rather than one material -- wrap \
            them together, the way WorkspaceTablePage's toolbar slot and \
            FirstScanSummaryView's three count tiles already do:
            \(offenders.joined(separator: "; "))
            """)
    }

    // MARK: (u) W2-10 (2026-08-17) -- hand-verified translations for the two
    // leftover localization leaks another agent reported but could not
    // reach: `LibraryHealthCategory.displayLabel` (`HealthView.swift`) and
    // three `V2SettingsView.swift` switch/function-returned
    // `LocalizedStringKey`s, none of which are literal `Text("...")`
    // arguments and are therefore invisible to
    // `scripts/extract-localizable-strings.swift` and to
    // `LocalizationCoverageTests`'s automated coverage check -- same shape
    // as `archiveClassDisplayNamesAreTranslated` above, for this task's own
    // two fixes.
    @Test("LibraryHealthCategory.displayLabel and the three V2SettingsView leaks have Hungarian translations")
    func w2t10LocalizationLeaksAreTranslated() throws {
        let strings = try contents("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        let expectedEntries = [
            #""Integrity" = "Integritás";"#,
            #""Storage" = "Tárhely";"#,
            #""From this library's configured observing site." = "A könyvtár beállított megfigyelési helyéről.";"#,
            #""Derived automatically from this library's own scanned FITS headers -- no site is explicitly configured." = "Automatikusan származtatva a könyvtár beolvasott FITS-headerjeiből -- nincs kifejezetten beállítva megfigyelési hely.";"#,
            #""Not downloaded yet — Planning uses the built-in 217-object catalog." = "Még nincs letöltve — a Tervezés a beépített 217 objektumos katalógust használja.";"#,
            #""%lld cached targets, updated %@." = "%lld gyorsítótárazott célpont, frissítve: %@.";"#,
            #""Remove \"%@\"?" = "„%@” eltávolítása?";"#,
        ]
        for entry in expectedEntries {
            #expect(strings.contains(entry), "hu.lproj is missing: \(entry)")
        }
        // "Flat"/"Dark"/"Bias" are deliberately absent -- this file's own
        // glossary states they stay English, so `LibraryHealthCategory
        // .displayLabel`'s three matching cases must resolve to the literal
        // fallback, not an invented translation.
        for englishOnly in ["\"Flat\" = ", "\"Dark\" = ", "\"Bias\" = "] {
            #expect(!strings.contains(englishOnly), "hu.lproj should not translate '\(englishOnly)' -- the glossary keeps flat/dark/bias in English")
        }
    }
}

/// Detects a `.astroRaisedSurface(` applied inside a block that is itself
/// raised -- the box-in-box defect. Walks OUTWARD through every enclosing
/// brace block (not just the direct parent, unlike `GlassTableGate` below,
/// whose rule genuinely is about the direct container only), because a card
/// three levels down inside another card is the same defect.
///
/// A standalone `enum` for the same reason as `GlassTableGate` and
/// `GroundOpacityGate`: synthetic snippets and the real-tree scan call the
/// same function, and a snippet is not a file under `Sources/AstroUI`.
enum RaisedSurfaceGate {
    /// Task 7d generalized this from a constant to a parameter so the
    /// RECESSED treatment gets the identical lexical check for free. The two
    /// modifiers have the same nesting defect for the same reason (two
    /// identical fills meeting), and a second copy of this brace walker
    /// would be a second place for it to be wrong.
    static let raisedModifier = ".astroRaisedSurface("
    static let recessedModifier = ".astroRecessedSurface("

    /// 1-based line numbers (matching how a human reads the source) of every
    /// raised surface that has a raised ancestor in the same file.
    static func nestedOccurrences(in source: String, modifier: String = raisedModifier) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var offenders: [Int] = []
        for (index, line) in lines.enumerated() where line.contains(modifier) {
            if hasRaisedAncestor(lines: lines, from: index, modifier: modifier) {
                offenders.append(index + 1)
            }
        }
        return offenders
    }

    private static func hasRaisedAncestor(lines: [String], from targetIndex: Int, modifier: String) -> Bool {
        var childIndex = targetIndex
        while let openerIndex = enclosingOpener(lines: lines, of: childIndex) {
            if blockIsRaised(lines: lines, openerIndex: openerIndex, modifier: modifier) { return true }
            childIndex = openerIndex
        }
        return false
    }

    /// The nearest `{` that directly encloses `lines[index]`, found by
    /// walking backward with a brace-balance counter -- closing braces seen
    /// on the way up push the counter positive (a sibling block to skip
    /// past); the first `{` that would take it negative is the one that
    /// actually opens around this line.
    private static func enclosingOpener(lines: [String], of index: Int) -> Int? {
        var depth = 0
        var i = index - 1
        while i >= 0 {
            depth += lines[i].filter { $0 == "}" }.count
            depth -= lines[i].filter { $0 == "{" }.count
            if depth < 0 { return i }
            i -= 1
        }
        return nil
    }

    /// Whether the block opened at `openerIndex` carries the modifier --
    /// either on its own opening statement (including a multi-line chain
    /// immediately above it) or chained after its matching closing brace,
    /// possibly behind other modifiers.
    private static func blockIsRaised(lines: [String], openerIndex: Int, modifier: String) -> Bool {
        var openStatement = lines[openerIndex]
        var j = openerIndex - 1
        while j >= 0 {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            // Blank lines do not end a chain. This matters far more than it
            // looks: callers are scanned AFTER `removingLineComments`, which
            // replaces every comment line with an EMPTY line rather than
            // deleting it -- and this codebase documents almost every
            // surface application with a comment block sitting between the
            // container's closing brace and the modifier chained onto it. A
            // walker that stopped at the first blank line therefore declared
            // every well-documented card "not raised", which is most of
            // them, and would have let a nested one through in exactly the
            // files most likely to have one. Found by injecting a nested
            // `.astroRecessedSurface()` into `ProjectNightSection` and
            // watching the gate stay green.
            if trimmed.isEmpty { j -= 1; continue }
            guard trimmed.hasPrefix(".") || trimmed.hasSuffix(",") || trimmed.hasSuffix("(") else { break }
            openStatement = lines[j] + "\n" + openStatement
            j -= 1
        }
        if openStatement.contains(modifier) { return true }

        var depth = 1
        var k = openerIndex + 1
        while k < lines.count {
            depth += lines[k].filter { $0 == "{" }.count
            depth -= lines[k].filter { $0 == "}" }.count
            if depth == 0 { break }
            k += 1
        }
        guard k < lines.count else { return false }
        var m = k + 1
        while m < lines.count {
            let trimmed = lines[m].trimmingCharacters(in: .whitespaces)
            // Blank lines do not end a chain -- see the identical skip in the
            // backward walk above for why this is the difference between a
            // working gate and a decorative one. This is the half that
            // actually mattered: EVERY surface application in this tree is
            // `Container { ... }` / comment block / `.astroRaisedSurface()`,
            // so before this line the walker never once recognized a real
            // card as raised.
            if trimmed.isEmpty { m += 1; continue }
            guard trimmed.hasPrefix(".") else { break }
            if trimmed.hasPrefix(modifier) { return true }
            m += 1
        }
        return false
    }
}

/// Detects a HIERARCHICAL SHAPE STYLE (`.primary`/`.secondary`/`.tertiary`/
/// `.quaternary`) handed to `.background(` or `.fill(` as a container fill --
/// the shape all three of the app's hand-rolled recessed wells were written
/// in before Task 7d.
///
/// # Why this is a rule and not a tidy-up
///
/// A hierarchical style is a FOREGROUND vocabulary. As a fill it resolves to
/// black at ~10% alpha in light appearance and WHITE at ~10% alpha in dark,
/// so the same call site is recessed in one appearance and raised in the
/// other -- measured, over `surface`: .9020 light / .1711 dark at full
/// strength, against a surface of 1.0000 / .0810. All three real offenders
/// were therefore inverted for every user in dark mode, and no gate written
/// against the source TEXT could have seen it, because the text is fine and
/// the resolution is what is wrong. That is exactly why the rule has to
/// forbid the vocabulary rather than police the values:
/// `AstroTokens.Color.recess` is an explicit two-appearance token whose
/// direction `V2PolishSurfaceTests
/// .theRecessedLayerIsDarkerThanBothInBothAppearances` can actually measure.
///
/// # What it deliberately allows
///
/// A fill whose `in:` shape is a `Circle(` or a `Capsule(`. Those are the
/// BADGE vocabulary -- a step-indicator disc, a status pill -- not a surface:
/// they size to a glyph, they never contain layout, and their colour means
/// something (`ok`/`attention`/`critical`) rather than marking a depth. This
/// is stated as a shape rule rather than a file list on purpose; the failure
/// mode this suite has documented three times over is a gate that enumerated
/// the offenders one audit happened to find.
///
/// # What it cannot see, by construction
///
/// A style reached through a binding (`let dim = HierarchicalShapeStyle
/// .quaternary` … `.background(dim)`), a `Material`, or a hierarchical style
/// applied through some third modifier. A source-text scan cannot follow a
/// binding, which is why the token's own DIRECTION is gated numerically as
/// well.
enum RecessedFillGate {
    private static let pattern = try! NSRegularExpression(
        // `\.(?:background|fill)\(` anchors to the consumer, so
        // `.foregroundStyle(.secondary)` -- the correct, extremely common use
        // of exactly these names -- is untouched. The qualifier group is
        // OPTIONAL and dotted so all three real spellings match: bare
        // (`.quaternary`), through the type (`Color.secondary`), and fully
        // qualified (`HierarchicalShapeStyle.quaternary`). Every separator is
        // `\s*`, so wrapping the call across lines does not hide it. The
        // trailing lookahead keeps a longer identifier (`.secondaryLabel`,
        // `.primaryAction`) from matching.
        pattern: #"\.(?:background|fill)\(\s*(?:[A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*\s*)?\.\s*(?:primary|secondary|tertiary|quaternary)(?![A-Za-z0-9_])"#
    )

    /// 1-based line numbers (matching how a human reads the source) of every
    /// hierarchical style used as a container fill.
    static func offendingLines(in source: String) -> [Int] {
        let characters = Array(source)
        let nsRange = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            guard let parenIndex = source[range].firstIndex(of: "(") else { return nil }
            let openOffset = source.distance(from: source.startIndex, to: parenIndex)
            let argument = balancedArgument(characters, openParenAt: openOffset)
                .filter { !$0.isWhitespace }
            if argument.contains("in:Circle(") || argument.contains("in:Capsule(") { return nil }
            return source[source.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
        }
    }

    /// The text between `characters[openParenAt]` and its matching `)`, found
    /// with the same depth-counting walk the brace gates in this file use.
    /// Returns everything to the end of input if the parenthesis is never
    /// closed -- a truncated snippet should still be scanned, not silently
    /// treated as clean.
    private static func balancedArgument(_ characters: [Character], openParenAt start: Int) -> String {
        var depth = 0
        var index = start
        while index < characters.count {
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" {
                depth -= 1
                if depth == 0 { return String(characters[(start + 1)..<index]) }
            }
            index += 1
        }
        return String(characters[min(start + 1, characters.count)...])
    }
}

/// Detects `AstroTokens.Color.ground` (or a bare `.ground`) with an
/// `.opacity(...)` applied directly to it -- the shape Task 7b's rule
/// forbids. Scans across line breaks, so wrapping the expression does not
/// hide it.
///
/// A standalone `enum` for the same reason as `GlassTableGate` above: both
/// synthetic-snippet tests and the real-tree scan call the same function,
/// and a snippet is not a file under `Sources/AstroUI`.
enum GroundOpacityGate {
    /// 1-based line numbers (matching how a human reads the source) where
    /// `ground` is weakened by an `.opacity(` applied to the token itself.
    ///
    /// The leading `(?<![A-Za-z0-9_])` is what keeps an identifier merely
    /// ENDING in "ground" (`playground`, `foreground`) from matching, while
    /// still allowing both the fully-qualified `AstroTokens.Color.ground`
    /// and a bare leading-dot `.ground`.
    static func offendingLines(in source: String) -> [Int] {
        let pattern = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])ground\s*\.\s*opacity\s*\("#
        )
        let nsRange = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            return source[source.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
        }
    }
}

/// Detects the one shape Task 6's plan explicitly forbids: a `Table`/`List`
/// view construction whose DIRECT enclosing container is itself glassed --
/// either by `GlassEffectContainer` wrapping it, or by a `.glassEffect(`
/// modifier chained onto that same container (before or after its trailing
/// closure). Dense rows rendered on top of a blurred, moving background are
/// unreadable; the plan's whole design keeps glass on the container and
/// dense content on an explicit solid `surface` one layer in
/// (`WorkspaceTablePage.body`, `ArchiveTaskDetailView.tableContent`).
///
/// A standalone `enum` rather than a nested type: both a synthetic-snippet
/// test suite and a real-tree scan call the same function, and a synthetic
/// snippet is not itself a file under `Sources/AstroUI`, so this cannot be
/// folded into that scan's own helpers.
///
/// What this does NOT catch, by construction: it scans ONE FILE's source
/// text at a time, so it cannot see a glass ancestor introduced in a
/// DIFFERENT file. `WorkspaceTablePage.body` (`WorkspaceComponents.swift`)
/// wraps its own `toolbar` slot in `GlassEffectContainer`/`.glassEffect(`,
/// but every real `Table`/`List` call site lives one file away, inside the
/// `table:` closure each of its eight callers supplies -- invisible to a
/// single-file scan either way. That cross-file case is handled by
/// construction instead: `WorkspaceTablePage.body` gives `table` its own
/// explicit solid `.background(AstroTokens.Color.surface, ...)`, so no
/// caller can put a `Table`/`List` under real glass by using this
/// component as intended, regardless of what this gate can see.
enum GlassTableGate {
    /// 1-based line numbers (matching how a human would read the source)
    /// where a `Table(`/`List(` construction's direct enclosing block is
    /// glassed.
    static func offendingLines(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        // Task 7d widened this from `\(` to `[({]`. The original saw only
        // the parenthesized form, so `List { ... }` -- SwiftUI's static-row
        // spelling, and the one `ArchiveView` and `SensorProfilesView`
        // actually use -- was invisible to the rule stated as
        // non-negotiable. Found by injecting a glassed `List { }` into
        // `ArchiveView` and watching the gate stay green. Verified not to
        // change the verdict on the tree as it stands: clean before, clean
        // after; the two newly-visible lists are both unglassed.
        let constructorPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(Table|List)\s*[({]"#)
        var offenders: [Int] = []
        for (index, line) in lines.enumerated() {
            let nsRange = NSRange(line.startIndex..., in: line)
            guard constructorPattern.firstMatch(in: line, range: nsRange) != nil else { continue }
            if directContainerIsGlassed(lines: lines, targetIndex: index) {
                offenders.append(index + 1)
            }
        }
        return offenders
    }

    /// Finds the nearest `{` that directly encloses `lines[targetIndex]` by
    /// walking backward with a brace-balance counter (closing braces seen
    /// while walking up push the counter positive -- a nested block we must
    /// skip past; the first `{` that would take it negative is the block
    /// that actually opens around our line, with no other block boundary in
    /// between). Then checks three places a `.glassEffect` could reach that
    /// exact block: `GlassEffectContainer` or `.glassEffect(` on the opening
    /// statement itself (including any multi-line chain immediately above
    /// it), or `.glassEffect(` chained onto the block AFTER its matching
    /// closing `}` (found the same way, forward).
    private static func directContainerIsGlassed(lines: [String], targetIndex: Int) -> Bool {
        var depth = 0
        var openerIndex: Int?
        var i = targetIndex - 1
        while i >= 0 {
            depth += lines[i].filter { $0 == "}" }.count
            depth -= lines[i].filter { $0 == "{" }.count
            if depth < 0 { openerIndex = i; break }
            i -= 1
        }
        guard let openerIndex else { return false }

        var openStatement = lines[openerIndex]
        var j = openerIndex - 1
        while j >= 0 {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            // Task 7d: blank lines do not end a chain. Same blind spot, same
            // fix, same reason as `RaisedSurfaceGate.blockIsRaised` -- these
            // scans run on comment-STRIPPED source, in which every documented
            // modifier chain is separated from its container's brace by a run
            // of empty lines. Found while proving the recessed gate red;
            // this gate had it too, and it guards the one rule in this file
            // that is stated as non-negotiable (dense rows over moving glass
            // are unreadable). Verified not to change the verdict on the tree
            // as it stands: clean before, clean after.
            if trimmed.isEmpty { j -= 1; continue }
            guard trimmed.hasPrefix(".") || trimmed.hasSuffix(",") || trimmed.hasSuffix("(") else { break }
            openStatement = lines[j] + "\n" + openStatement
            j -= 1
        }
        if openStatement.contains(".glassEffect(") || openStatement.contains("GlassEffectContainer") {
            return true
        }

        var forwardDepth = 1
        var k = openerIndex + 1
        while k < lines.count {
            forwardDepth += lines[k].filter { $0 == "{" }.count
            forwardDepth -= lines[k].filter { $0 == "}" }.count
            if forwardDepth == 0 { break }
            k += 1
        }
        guard k < lines.count else { return false }
        var m = k + 1
        while m < lines.count {
            let trimmed = lines[m].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { m += 1; continue }
            guard trimmed.hasPrefix(".") else { break }
            if trimmed.hasPrefix(".glassEffect(") { return true }
            m += 1
        }
        return false
    }
}

/// Detects a numeric literal handed to `cornerRadius:` (either
/// `RoundedRectangle(cornerRadius:)` or the deprecated `.cornerRadius(_:)`
/// view modifier) -- the "assorted small radii" the owner's corners
/// complaint named, none of them derived from `AstroTokens.CornerRadius
/// .panel`. Deliberately matches only a DIGIT immediately after the colon/
/// open-paren, which is what keeps a token reference
/// (`cornerRadius: AstroTokens.CornerRadius.panel`) or a variable
/// (`cornerRadius: someToken`) from ever matching -- this gate is about
/// literals invented at the call site, not about the token itself.
///
/// A standalone `enum` for the same reason as every other detector in this
/// file: a synthetic snippet is not a file under `Sources/AstroUI`, and both
/// the snippet tests and the real-tree scan need to call the same function.
enum CornerRadiusLiteralGate {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:cornerRadius\s*:\s*|\.cornerRadius\s*\(\s*)[0-9]"#
    )

    /// 1-based line numbers (matching how a human reads the source) where a
    /// `cornerRadius` is given a numeric literal. Scans across line breaks
    /// via `\s*`, so wrapping the call does not hide it.
    static func offendingLines(in source: String) -> [Int] {
        let nsRange = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            return source[source.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1
        }
    }
}

/// Detects `.glassEffect(` applications that are LEXICAL SIBLINGS -- they
/// share the same nearest enclosing `{...}` block -- with no
/// `GlassEffectContainer` anywhere in that block's ancestor chain. Two or
/// more glass shapes side by side with no shared container each composite
/// their own independent blur pass rather than merging into one material,
/// which is the opposite of what "more Liquid Glass" (the owner's own ask)
/// is supposed to read like.
///
/// What this does NOT catch, by construction: a glass shape reached through
/// a helper function, a computed property, or another file -- exactly the
/// same class of blind spot `RaisedSurfaceGate`/`GlassTableGate` already
/// document, and for the same reason (a lexical brace walk cannot follow a
/// call). `FirstScanSummaryView.countTile` is this shape today: one
/// `.glassEffect(` literal in the function body, called three times, so
/// only one lexical occurrence ever exists for this gate to see -- its
/// `GlassEffectContainer` wrapping is correct by construction at the call
/// site, not by anything this gate verifies.
enum GlassSiblingGate {
    /// 1-based line numbers of every `.glassEffect(` application that has at
    /// least one sibling `.glassEffect(` in the same immediate enclosing
    /// block, with no `GlassEffectContainer` in that block's ancestor chain.
    static func offendingLines(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        let glassLineIndices = lines.indices.filter { lines[$0].contains(".glassEffect(") }
        guard glassLineIndices.count > 1 else { return [] }

        var groups: [Int: [Int]] = [:]
        for index in glassLineIndices {
            guard let opener = enclosingOpener(lines: lines, of: index) else { continue }
            groups[opener, default: []].append(index)
        }

        var offenders: [Int] = []
        for (opener, members) in groups where members.count > 1 {
            if !hasGlassContainerAncestor(lines: lines, from: opener) {
                offenders.append(contentsOf: members)
            }
        }
        return offenders.map { $0 + 1 }.sorted()
    }

    /// The nearest `{` that directly encloses `lines[index]`, found the same
    /// way every other brace walker in this file finds it: closing braces
    /// seen while walking backward push a balance counter positive (a
    /// sibling block to skip past); the first `{` that would take it
    /// negative is the block that actually opens around this line.
    private static func enclosingOpener(lines: [String], of index: Int) -> Int? {
        var depth = 0
        var i = index - 1
        while i >= 0 {
            depth += lines[i].filter { $0 == "}" }.count
            depth -= lines[i].filter { $0 == "{" }.count
            if depth < 0 { return i }
            i -= 1
        }
        return nil
    }

    /// Whether `GlassEffectContainer` appears on the opener line itself
    /// (its usual shape -- `GlassEffectContainer {` opens the very block
    /// being checked) or on any OUTER enclosing block's opener line, walked
    /// the same way `RaisedSurfaceGate.hasRaisedAncestor` walks outward for
    /// the nesting rule.
    private static func hasGlassContainerAncestor(lines: [String], from openerIndex: Int) -> Bool {
        var current: Int? = openerIndex
        while let index = current {
            if lines[index].contains("GlassEffectContainer") { return true }
            current = enclosingOpener(lines: lines, of: index)
        }
        return false
    }
}
