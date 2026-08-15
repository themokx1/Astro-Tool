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

    private var featureViewPaths: [(name: String, path: String)] {
        [
            ("HomeView", "Sources/AstroUI/Features/Home/HomeView.swift"),
            ("ProjectsView", "Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            ("NightsView", "Sources/AstroUI/Features/Nights/NightsView.swift"),
            ("PlanningView", "Sources/AstroUI/Features/Planning/PlanningView.swift"),
            ("LibraryView", "Sources/AstroUI/Features/Library/LibraryView.swift"),
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

    // MARK: (c) No hardcoded colors under Features/ or Settings/.

    @Test("No file under Features/ or Settings/ hardcodes a color literal")
    func noHardcodedColorLiterals() throws {
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let directories = ["Features", "Settings"]
        var offenders: [String] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains("Color(red:") || text.contains("Color(#colorLiteral") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "Hardcoded color literals in: \(offenders.joined(separator: ", "))")
    }

    // MARK: (c2) No bare status colors under Features/ or Settings/ (S9).

    @Test("No file under Features/ or Settings/ hardcodes a bare status color -- use AstroTokens.Color instead")
    func noBareStatusColorLiterals() throws {
        // V2 UI/UX audit (2026-08-14) systemic pattern S9: `AstroTokens`
        // now has `success`/`warning`/`danger` tokens specifically so status
        // meaning (healthy/needs-attention/failed) reads consistently across
        // every screen -- this gate keeps a bare `.green`/`.orange`/`.red`/
        // `.purple` (or the explicit `Color.` spelling of the same) from
        // creeping back in. Planning is intentionally excluded: it is under
        // a separate, currently-frozen read-only audit and was not part of
        // this sweep.
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let directories = ["Features", "Settings"]
        let excludedPathSuffixes = ["Features/Planning/PlanningView.swift", "Features/Planning/SkyPathChart.swift"]
        let bareColorPattern = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])\.(green|orange|red|purple)(?![A-Za-z0-9_])|\bColor\.(green|orange|red|purple)\b"#
        )
        var offenders: [String] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if excludedPathSuffixes.contains(where: { url.path.hasSuffix($0) }) { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if bareColorPattern.firstMatch(in: text, range: range) != nil {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "Bare status color literals in: \(offenders.joined(separator: ", "))")
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
}
