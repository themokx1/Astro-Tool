import Foundation

// MARK: - Small standalone helpers (unit-tested directly)

/// Tiny, case-insensitive glob matcher supporting only the `*` wildcard —
/// exactly what `config.residuePatterns` needs (`*.seq`, `r_*`, `*_conv*`,
/// literal patterns like `.DS_Store` with no wildcard at all). Classic
/// two-pointer wildcard match; no regex engine involved.
enum GlobMatcher {
    static func matches(pattern: String, name: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(name.lowercased())

        var pi = 0, si = 0
        var starIdx = -1
        var matchIdx = 0

        while si < s.count {
            if pi < p.count, p[pi] == "*" {
                starIdx = pi
                matchIdx = si
                pi += 1
            } else if pi < p.count, p[pi] == s[si] {
                pi += 1
                si += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                matchIdx += 1
                si = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }
}

/// Shared residue-matching primitives used by both `ResidueRule` (the
/// per-run audit finding) and `CleanupReport` (the aggregated, size-ordered
/// cleanup summary) so the two never drift on what counts as residue.
enum ResidueMatcher {
    /// Whether `name` (a bare filename, no path) matches one of
    /// `config.residuePatterns`.
    static func matchesFilePattern(name: String, config: AstroConfig) -> Bool {
        config.residuePatterns.contains { GlobMatcher.matches(pattern: $0, name: name) }
    }

    /// Whether `name` (a bare directory name, no path) is one of
    /// `config.residueDirNames`, case-insensitively.
    static func isResidueDirName(_ name: String, config: AstroConfig) -> Bool {
        config.residueDirNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Detects a target-name-token list whose leading run repeats itself
/// (`["C2025","R3","C2025","R3","Panstarrs"]` → the "C2025 R3" prefix was
/// duplicated by a copy-paste), and returns the deduplicated token list. The
/// longest possible repeated run wins when more than one `k` would work.
enum DuplicatedPrefixDetector {
    static func dedupe(_ tokens: [String]) -> [String]? {
        let n = tokens.count
        let maxK = n / 2
        guard maxK >= 1 else { return nil }

        for k in stride(from: maxK, through: 1, by: -1) {
            let first = tokens[0..<k].map { $0.lowercased() }
            let second = tokens[k..<(2 * k)].map { $0.lowercased() }
            if first == second {
                var result = Array(tokens[0..<k])
                result.append(contentsOf: tokens[(2 * k)...])
                return result
            }
        }
        return nil
    }
}

/// Normalizes a target name for the "same object, different name" grouping:
/// lowercase, split on `_`, drop filler tokens (`wide`/`field`/`nebula`/
/// `widefield`) and digit-with-unit tokens (`70mm`, `300s`).
enum TargetNameNormalizer {
    private static let dropTokens: Set<String> = ["wide", "field", "nebula", "widefield"]

    static func normalize(_ name: String) -> [String] {
        name.split(separator: "_").map { String($0).lowercased() }.filter { token in
            !dropTokens.contains(token) && !isDigitWithUnit(token)
        }
    }

    private static func isDigitWithUnit(_ token: String) -> Bool {
        guard let firstNonDigit = token.firstIndex(where: { !$0.isNumber }) else { return false }
        guard firstNonDigit != token.startIndex else { return false }
        return token[firstNonDigit...].allSatisfy { $0.isLetter }
    }
}

// MARK: - 1. placeholder-name

/// Any directory whose name (case-insensitively) still carries the
/// `add_new_session.sh` prompt text that leaked in because the user hit
/// enter without typing a real target name. Only the top-most offending
/// directory is reported — nothing nested under it needs its own finding.
public struct PlaceholderNameRule: AuditRule {
    public let id = "placeholder-name"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var seen = Set<String>()
        var offendingPaths: [String] = []

        for dir in ctx.directories {
            let components = dir.split(separator: "/").map(String.init)
            guard let index = components.firstIndex(where: Self.isPlaceholder) else { continue }
            let offending = components[0...index].joined(separator: "/")
            if seen.insert(offending).inserted {
                offendingPaths.append(offending)
            }
        }

        return offendingPaths.map { path in
            Finding(
                severity: .sureError,
                category: id,
                path: path,
                message: "A mappa neve még mindig a session-létrehozó szkript promptszövegét tartalmazza — úgy tűnik, senki nem írt be valódi célpontnevet.",
                suggestion: .review(note: "Nevezd át ezt a mappát a tényleges célpont nevére; az eredetileg szánt név automatikusan nem állítható vissza.")
            )
        }
    }

    private static func isPlaceholder(_ component: String) -> Bool {
        component.lowercased().contains("please_enter") || component.caseInsensitiveCompare("value") == .orderedSame
    }
}

// MARK: - 2. orphan-calib-dir (+ misplaced-file)

/// A direct child of `calibration_library/` that isn't one of the three
/// canonical subdirectories. Also flags every file inside it, proposing a
/// move to the correct subdirectory when the orphan name is an obvious
/// singular/misspelling of a canonical one.
public struct OrphanCalibDirRule: AuditRule {
    public let id = "orphan-calib-dir"
    private static let canonical: Set<String> = ["darks", "flats", "biases"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        let orphanDirs = ctx.directories.filter { dir in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 2, comps[0] == "calibration_library" else { return false }
            return !Self.canonical.contains(comps[1].lowercased())
        }

        var findings: [Finding] = []
        for dirPath in orphanDirs {
            let name = (dirPath as NSString).lastPathComponent
            findings.append(Finding(
                severity: .sureError,
                category: id,
                path: dirPath,
                message: "\"\(name)\" nem kanonikus calibration_library almappa (darks/flats/biases).",
                suggestion: .review(note: "Mozgasd vagy nevezd át ezt a mappát calibration_library/darks, /flats vagy /biases alá.")
            ))

            let canonicalName = Self.canonicalMapping(for: name)
            for file in ctx.files where file.path.hasPrefix(dirPath + "/") {
                let filename = (file.path as NSString).lastPathComponent
                let suggestion: SuggestedAction
                if let canonicalName {
                    suggestion = .move(from: file.path, to: "calibration_library/\(canonicalName)/\(filename)")
                } else {
                    suggestion = .review(note: "Nem állapítható meg biztosan, hogy dark/flat/bias felvétel-e; mozgasd kézzel a megfelelő calibration_library almappába.")
                }
                findings.append(Finding(
                    severity: .sureError,
                    category: "misplaced-file",
                    path: file.path,
                    message: "A fájl a nem kanonikus calibration_library almappában van: \"\(name)\".",
                    suggestion: suggestion
                ))
            }
        }
        return findings
    }

    private static func canonicalMapping(for orphanName: String) -> String? {
        let lower = orphanName.lowercased()
        if lower.contains("bias") { return "biases" }
        if lower.contains("dark") { return "darks" }
        if lower.contains("flat") { return "flats" }
        return nil
    }
}

// MARK: - 3. duplicated-catalog-prefix

/// A target directory (2nd path component under sessions/stacks/processed)
/// whose name repeats its own leading `_`-tokens — a copy-paste artifact
/// like `C2025_R3_C2025_R3_Panstarrs`.
public struct DuplicatedCatalogPrefixRule: AuditRule {
    public let id = "duplicated-catalog-prefix"
    private static let areas: Set<String> = ["sessions", "stacks", "processed"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 2, Self.areas.contains(comps[0]) else { return nil }

            let name = comps[1]
            let tokens = name.split(separator: "_").map(String.init)
            guard let deduped = DuplicatedPrefixDetector.dedupe(tokens) else { return nil }

            let renamed = deduped.joined(separator: "_")
            return Finding(
                severity: .sureError,
                category: id,
                path: dir,
                message: "A célpont neve (\"\(name)\") megismétli a saját kezdő token-jeit — valószínűleg copy-paste duplikáció.",
                suggestion: .rename(from: dir, to: "\(comps[0])/\(renamed)")
            )
        }
    }
}

// MARK: - 4. nested-session-tree

/// A directory named `sessions` (case-insensitive) that is NOT the
/// top-level `sessions/` tree — e.g. a whole session accidentally nested
/// under `stacks/<target>/<date>/sessions/`.
public struct NestedSessionTreeRule: AuditRule {
    public let id = "nested-session-tree"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories
            .filter { dir in
                dir != "sessions" && (dir as NSString).lastPathComponent.caseInsensitiveCompare("sessions") == .orderedSame
            }
            .map { dir in
                Finding(
                    severity: .sureError,
                    category: id,
                    path: dir,
                    message: "a \"sessions\" mappa a felső szintű sessions/ fán kívül van beágyazva.",
                    suggestion: .review(note: "Mozgasd át ennek a beágyazott sessions/ fának a tartalmát a valódi sessions/ területre; egy teljes fa áthelyezéséhez emberi döntés kell a célhelyre.")
                )
            }
    }
}

// MARK: - 5. noncanonical-subdir

/// A directory directly under `stacks/<target>/<date>/` that isn't one of
/// the four canonical frame-role folders and matches a known "leftover
/// working folder" pattern (`collected_lights`, `paneled_mosaic_process`,
/// ...). The nested-`sessions` case is rule 4's, not this one's.
public struct NoncanonicalSubdirRule: AuditRule {
    public let id = "noncanonical-subdir"
    private static let canonicalRoleDirs: Set<String> = ["lights", "flats", "darks", "biases"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 4, comps[0] == "stacks" else { return nil }

            let name = comps[3]
            let lower = name.lowercased()
            guard !Self.canonicalRoleDirs.contains(lower), lower != "sessions" else { return nil }
            // A known tool-output dir isn't a stray working folder --
            // ToolOutputRule owns it instead.
            guard !ctx.config.toolOutputDirNames.contains(name) else { return nil }
            guard lower.contains("collected") || lower.contains("mosaic") || lower.hasSuffix("_process") else { return nil }

            return Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" egy stack dátum-mappa alatt nem tűnik normál frame-role mappának.",
                suggestion: nil
            )
        }
    }
}

// MARK: - 6. assets-without-date

/// A direct child of `stacks/<target>/` (3rd path level) that doesn't parse
/// as a session date at all — a report/asset folder like
/// `light_frame_rating_report_assets` sitting alongside the real dated
/// stacks.
public struct AssetsWithoutDateRule: AuditRule {
    public let id = "assets-without-date"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 3, comps[0] == "stacks" else { return nil }

            let name = comps[2]
            guard SessionDateParser.parse(name, patterns: ctx.config.intentional) == nil else { return nil }
            // A known tool-output dir (e.g. LightFrameRater's report-assets
            // bundle) isn't a mislabeled date folder -- ToolOutputRule owns
            // it instead.
            guard !ctx.config.toolOutputDirNames.contains(name) else { return nil }

            return Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" közvetlenül a célpont-mappa alatt van, de nem dátum-mappa.",
                suggestion: nil
            )
        }
    }
}

// MARK: - 7. similar-target-names

/// Groups target names that likely refer to the same object under
/// different spellings (case/underscore/filler-word variants). Reports the
/// grouping only — never a merge suggestion, since picking the canonical
/// name is a human call.
public struct SimilarTargetNamesRule: AuditRule {
    public let id = "similar-target-names"
    private static let areas: Set<String> = ["sessions", "stacks", "processed"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var pathByName: [String: String] = [:]

        for dir in ctx.directories {
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 2, Self.areas.contains(comps[0]) else { continue }
            if pathByName[comps[1]] == nil { pathByName[comps[1]] = dir }
        }
        for file in ctx.files {
            guard let target = file.target, Self.areas.contains(file.area.rawValue) else { continue }
            if pathByName[target] == nil { pathByName[target] = "\(file.area.rawValue)/\(target)" }
        }

        var buckets: [(tokens: [String], names: Set<String>)] = []
        for name in pathByName.keys {
            let tokens = TargetNameNormalizer.normalize(name)
            if let index = buckets.firstIndex(where: { $0.tokens == tokens }) {
                buckets[index].names.insert(name)
            } else {
                buckets.append((tokens: tokens, names: [name]))
            }
        }

        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<buckets.count {
                var j = i + 1
                while j < buckets.count {
                    if Self.isStrictPrefix(buckets[i].tokens, of: buckets[j].tokens)
                        || Self.isStrictPrefix(buckets[j].tokens, of: buckets[i].tokens)
                        || Self.catalogTokenSetsRelated(buckets[i].tokens, buckets[j].tokens)
                    {
                        buckets[i].names.formUnion(buckets[j].names)
                        buckets.remove(at: j)
                        merged = true
                        break outer
                    }
                    j += 1
                }
            }
        }

        return buckets.compactMap { bucket -> Finding? in
            guard bucket.names.count >= 2 else { return nil }
            let sortedNames = bucket.names.sorted()
            guard let firstName = sortedNames.first, let path = pathByName[firstName] else { return nil }
            return Finding(
                severity: .suspicious,
                category: id,
                path: path,
                message: "Valószínűleg ugyanaz a célpont különböző néven: \(sortedNames.joined(separator: ", "))",
                suggestion: nil
            )
        }
    }

    private static func isStrictPrefix(_ a: [String], of b: [String]) -> Bool {
        guard a.count < b.count else { return false }
        return Array(b.prefix(a.count)) == a
    }

    /// Comet-style names (`R3_C2025`, `C2025_R3_C2025_R3_Panstarrs`, ...)
    /// share a catalog-designation token set even when word order or
    /// incidental extra tokens (a duplicated prefix, a "Panstarrs" suffix)
    /// differ enough that the prefix-merge above doesn't catch them. Two
    /// token lists are related when, restricted to just their catalog-like
    /// tokens (`m42`, `ngc7000`, `c2025`, `r3`, ...), the two sets are equal
    /// or one is a subset of the other — and neither set is empty, so two
    /// targets with no catalog designation at all (e.g. "M_Milky_Way" and
    /// the placeholder name) never match by this rule.
    private static func catalogTokenSetsRelated(_ a: [String], _ b: [String]) -> Bool {
        let setA = Set(a.filter(isCatalogToken))
        let setB = Set(b.filter(isCatalogToken))
        guard !setA.isEmpty, !setB.isEmpty else { return false }
        return setA == setB || setA.isSubset(of: setB) || setB.isSubset(of: setA)
    }

    /// Matches `^(ngc|ic|sh2)\d+$` (multi-letter catalog prefixes) or
    /// `^[a-z]\d+$` (single-letter ones — `m42`, `c2025`, `r3`, ...).
    private static func isCatalogToken(_ token: String) -> Bool {
        for prefix in ["ngc", "sh2", "ic"] {
            if token.hasPrefix(prefix) {
                let rest = token.dropFirst(prefix.count)
                if !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) { return true }
            }
        }
        guard token.count >= 2, let first = token.first, first.isLetter else { return false }
        return token.dropFirst().allSatisfy { $0.isNumber }
    }
}

// MARK: - 8. missing-counterpart

/// Flags targets/dates that don't have all the expected counterparts across
/// sessions/stacks/processed: a stack with no overlapping session, a
/// processed result with neither a session nor a stack, or a session that
/// hasn't been stacked yet.
public struct MissingCounterpartRule: AuditRule {
    public let id = "missing-counterpart"
    public init() {}

    private struct Span {
        let start: String
        let end: String
    }

    private struct Entry {
        let target: String
        let path: String
        let span: Span
    }

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        let sessionsEntries = collectEntries(area: "sessions", ctx: ctx)
        let stacksEntries = collectEntries(area: "stacks", ctx: ctx)
        let processedEntries = collectEntries(area: "processed", ctx: ctx)

        var findings: [Finding] = []

        for stack in stacksEntries {
            let hasSession = sessionsEntries.contains { $0.target == stack.target && Self.overlaps($0.span, stack.span) }
            if !hasSession {
                findings.append(Finding(severity: .suspicious, category: id, path: stack.path, message: "stack session nélkül", suggestion: nil))
            }
        }

        for processed in processedEntries {
            let hasCounterpart = sessionsEntries.contains { $0.target == processed.target && Self.overlaps($0.span, processed.span) }
                || stacksEntries.contains { $0.target == processed.target && Self.overlaps($0.span, processed.span) }
            if !hasCounterpart {
                findings.append(Finding(severity: .suspicious, category: id, path: processed.path, message: "feldolgozott anyag session vagy stack nélkül", suggestion: nil))
            }
        }

        for session in sessionsEntries {
            let hasStack = stacksEntries.contains { $0.target == session.target && Self.overlaps($0.span, session.span) }
            if !hasStack {
                findings.append(Finding(severity: .suspicious, category: id, path: session.path, message: "session még nincs stackelve", suggestion: nil))
            }
        }

        return findings
    }

    private func collectEntries(area: String, ctx: AuditContext) -> [Entry] {
        ctx.directories.compactMap { dir -> Entry? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 3, comps[0] == area else { return nil }
            guard let parsed = SessionDateParser.parse(comps[2], patterns: ctx.config.intentional) else { return nil }
            return Entry(target: comps[1], path: dir, span: Span(start: parsed.start, end: parsed.end))
        }
    }

    private static func overlaps(_ a: Span, _ b: Span) -> Bool {
        a.start <= b.end && b.start <= a.end
    }
}

// MARK: - 9. intentional-date

/// A date directory (3rd path level) whose name parses as a recognized
/// deliberate deviation from the canonical `YYYY-MM-DD` form — a run
/// suffix, a date range, or a label. Informational only.
public struct IntentionalDateRule: AuditRule {
    public let id = "intentional-date"
    private static let areas: Set<String> = ["sessions", "stacks", "processed"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 3, Self.areas.contains(comps[0]) else { return nil }
            guard let parsed = SessionDateParser.parse(comps[2], patterns: ctx.config.intentional), !parsed.isCanonical else { return nil }

            return Finding(
                severity: .probablyIntentional,
                category: id,
                path: dir,
                message: Self.message(for: parsed),
                suggestion: nil
            )
        }
    }

    private static func message(for date: SessionDate) -> String {
        switch date.kind {
        case .canonical:
            return "kanonikus dátum"
        case .runSuffix(let n):
            return "run jelölés: a(z) \(date.start) \(n). futása"
        case .range:
            return "dátum-tartomány: \(date.start) – \(date.end)"
        case .labeled:
            return "\"\(date.label ?? "")\" címke a(z) \(date.start) dátumon"
        }
    }
}

// MARK: - 10. invalid-date-dir

/// A 3rd-level directory under `sessions/` (only sessions — `stacks/` is
/// rule 6's job) whose name doesn't parse as a date at all, not even with a
/// recognized intentional-deviation suffix.
public struct InvalidDateDirRule: AuditRule {
    public let id = "invalid-date-dir"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 3, comps[0] == "sessions" else { return nil }
            guard SessionDateParser.parse(comps[2], patterns: ctx.config.intentional) == nil else { return nil }

            return Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(comps[2])\" a sessions/\(comps[1]) alatt nem értelmezhető dátumként.",
                suggestion: .review(note: "Nevezd át ezt a mappát valódi ÉÉÉÉ-HH-NN dátumra, vagy mozgasd a tartalmát a megfelelő session dátum-mappába.")
            )
        }
    }
}

// MARK: - 11. residue

/// Files whose name matches one of `config.residuePatterns` (a tiny glob,
/// `*` only, case-insensitive), or directories whose name is in
/// `config.residueDirNames` — leftover stacking/processing byproducts that
/// don't belong in the library long-term.
public struct ResidueRule: AuditRule {
    public let id = "residue"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var findings: [Finding] = []

        for file in ctx.files {
            let name = (file.path as NSString).lastPathComponent
            guard ResidueMatcher.matchesFilePattern(name: name, config: ctx.config) else { continue }
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: file.path,
                message: "\"\(name)\" feldolgozási maradéknak tűnik.",
                suggestion: nil
            ))
        }

        for dir in ctx.directories {
            let name = (dir as NSString).lastPathComponent
            guard ResidueMatcher.isResidueDirName(name, config: ctx.config) else { continue }
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" egy feldolgozó eszközök által hátrahagyott maradék-mappa.",
                suggestion: nil
            ))
        }

        return findings
    }
}

// MARK: - 12. calib-in-wrong-dir

/// A file whose FITS `IMAGETYP` (flat/dark/bias/light) contradicts the frame
/// role implied by its path — e.g. a flat frame that ended up in `lights/`
/// under `sessions/`, or in `darks/` under `calibration_library/`.
public struct CalibInWrongDirRule: AuditRule {
    public let id = "calib-in-wrong-dir"
    private static let sessionPathRoles: Set<FrameRole> = [.light, .flat, .dark, .bias]
    /// `calibration_library/` only ever has darks/flats/biases subdirs — no
    /// "lights" sibling to move a mislabeled light frame into, so a light
    /// IMAGETYP there isn't actionable by this rule. A file whose *current*
    /// role isn't one of these three either is an orphan-dir concern
    /// (`OrphanCalibDirRule`'s job), not this rule's.
    private static let calibPathRoles: Set<FrameRole> = [.flat, .dark, .bias]
    private static let calibImpliedRoles: Set<FrameRole> = [.flat, .dark, .bias]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.files.compactMap { file -> Finding? in
            guard let fileID = file.id, let meta = ctx.fitsMetaByFileID[fileID], let imagetyp = meta.imagetyp else { return nil }
            return Self.misplacedFinding(file: file, imagetyp: imagetyp, id: id, toolOutputDirNames: ctx.config.toolOutputDirNames)
        }
    }

    /// Core misplaced-frame check, shared with `SessionMatcher` so it can
    /// flag the same contradictions when it scopes its own scan to a single
    /// session — reproduces exactly what `evaluate` used to inline: a file
    /// whose FITS IMAGETYP contradicts the frame role implied by its path,
    /// either under `sessions/` or `calibration_library/`. `nil` when the
    /// IMAGETYP matches the path, the location isn't one this rule acts on
    /// (e.g. a light frame under `calibration_library/`, which has no
    /// "lights" sibling dir to move it into), or the file sits anywhere
    /// under a known tool-output dir (e.g. a stacked master kept in a
    /// deliberate `masters/` subfolder next to the raws) — that's
    /// `ToolOutputRule`'s territory, not a misplacement.
    static func misplacedFinding(file: FileRecord, imagetyp: String, id: String, toolOutputDirNames: [String] = []) -> Finding? {
        guard let implied = impliedRole(from: imagetyp), implied != file.role else { return nil }
        let pathComponents = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !pathComponents.contains(where: { toolOutputDirNames.contains($0) }) else { return nil }

        if file.area == .sessions, sessionPathRoles.contains(file.role) {
            return finding(file: file, imagetyp: imagetyp, implied: implied, roleDirIndex: nil, id: id)
        }
        if file.area == .calibration, calibPathRoles.contains(file.role), calibImpliedRoles.contains(implied) {
            // The role subdir always sits directly under
            // `calibration_library/` (index 1), regardless of any
            // further nesting beneath it (e.g. `darks/60sec_-10deg/`).
            return finding(file: file, imagetyp: imagetyp, implied: implied, roleDirIndex: 1, id: id)
        }
        return nil
    }

    /// Builds the finding, replacing the path component that names the
    /// (wrong) role directory with the implied-correct one. `roleDirIndex`
    /// is the fixed component index to replace (calibration_library's case);
    /// `nil` means "the directory directly containing the file" (sessions'
    /// canonical `.../<role>/<file>` shape).
    private static func finding(file: FileRecord, imagetyp: String, implied: FrameRole, roleDirIndex: Int?, id: String) -> Finding? {
        guard let impliedDir = dirName(for: implied) else { return nil }

        var comps = file.path.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return nil }
        let filename = comps.removeLast()
        let indexToReplace = roleDirIndex ?? (comps.count - 1)
        guard comps.indices.contains(indexToReplace) else { return nil }
        comps[indexToReplace] = impliedDir
        let to = (comps + [filename]).joined(separator: "/")

        return Finding(
            severity: .sureError,
            category: id,
            path: file.path,
            message: "A FITS IMAGETYP (\"\(imagetyp)\") nem illik a fájl helyéhez (várt hely: \(impliedDir)/).",
            suggestion: .move(from: file.path, to: to)
        )
    }

    private static func impliedRole(from imagetyp: String) -> FrameRole? {
        let lower = imagetyp.lowercased()
        if lower.contains("flat") { return .flat }
        if lower.contains("dark") { return .dark }
        if lower.contains("bias") { return .bias }
        if lower.contains("light") { return .light }
        return nil
    }

    private static func dirName(for role: FrameRole) -> String? {
        switch role {
        case .light: return "lights"
        case .flat: return "flats"
        case .dark: return "darks"
        case .bias: return "biases"
        default: return nil
        }
    }
}

// MARK: - 13. empty-target-component

/// A target directory (2nd path component under sessions/stacks/processed)
/// that's empty-ish once you look past sanitization — a name that begins
/// with `_` (a leading separator with nothing meaningful before it) or is
/// made up of nothing but underscores/dots.
public struct EmptyTargetComponentRule: AuditRule {
    public let id = "empty-target-component"
    private static let areas: Set<String> = ["sessions", "stacks", "processed"]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.directories.compactMap { dir -> Finding? in
            let comps = dir.split(separator: "/").map(String.init)
            guard comps.count == 2, Self.areas.contains(comps[0]) else { return nil }

            let name = comps[1]
            guard Self.isEmptyish(name) else { return nil }

            return Finding(
                severity: .sureError,
                category: id,
                path: dir,
                message: "\"\(name)\" nem tűnik valódi célpontnévnek — sanitizálás után üres vagy csak elválasztó karakterekből áll.",
                suggestion: .review(note: "Nevezd át ezt a mappát a tényleges célpont nevére; az eredetileg szánt név automatikusan nem állítható vissza.")
            )
        }
    }

    private static func isEmptyish(_ name: String) -> Bool {
        name.hasPrefix("_") || name.allSatisfy { $0 == "_" || $0 == "." }
    }
}

// MARK: - 14. loose-frames-in-date-dir

/// Session-area frames (light/flat/dark/bias role) sitting DIRECTLY in a
/// `sessions/<target>/<date>/` dir instead of the canonical
/// `lights/flats/darks/biases` subdirectory underneath it -- a real-library
/// pattern the scanner still classifies correctly (`Scanner` refines the
/// role from the FITS `IMAGETYP` for these), but the layout itself is still
/// worth flagging. Fires once per `(target, date)`, not once per file.
public struct LooseFramesInDateDirRule: AuditRule {
    public let id = "loose-frames-in-date-dir"
    private static let frameRoles: Set<FrameRole> = [.light, .flat, .dark, .bias]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var seen = Set<String>()
        var findings: [Finding] = []

        for file in ctx.files {
            guard file.area == .sessions, Self.frameRoles.contains(file.role) else { continue }
            guard let target = file.target, let date = file.sessionDate else { continue }

            // A frame sitting under a known tool-output dir (e.g.
            // LightFrameRater's Stack/Review/Reject triage) isn't loose --
            // ToolOutputRule owns that dir instead.
            let pathComponents = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !pathComponents.contains(where: { ctx.config.toolOutputDirNames.contains($0) }) else { continue }

            // Path depth 4 (`sessions/<target>/<date>/<file>`) is exactly a
            // file sitting directly in the date dir -- one level deeper
            // (`.../<role>/<file>`, depth 5) is the canonical layout and
            // isn't this rule's concern.
            guard pathComponents.count == 4 else { continue }

            let dirPath = "sessions/\(target)/\(date)"
            guard seen.insert(dirPath).inserted else { continue }

            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: dirPath,
                message: "A felvételek közvetlenül ebben a dátum-mappában vannak, nem egy lights/flats/darks/biases almappában.",
                suggestion: nil
            ))
        }
        return findings
    }
}

// MARK: - 15. tool-output

/// A directory whose name (case-sensitive) matches one of
/// `config.toolOutputDirNames` -- a known output of a coexisting tool, e.g.
/// `tools/rate/LightFrameRater.py`'s `Stack`/`Review`/`Reject` triage folders
/// (with `Best`/`Good`/`Ok` subdirs) inside a session's `lights/`, or its
/// `light_frame_rating_report_assets` report bundle. Informational only --
/// these are intentional tool outputs, not mess, and the
/// noncanonical-subdir/assets-without-date/loose-frames-in-date-dir rules
/// above all defer to this one instead of flagging them as suspicious. Only
/// the top-most matched directory is reported -- nothing nested under it
/// (e.g. `Stack/Best`) needs its own finding.
public struct ToolOutputRule: AuditRule {
    public let id = "tool-output"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var seen = Set<String>()
        var offendingPaths: [String] = []

        for dir in ctx.directories {
            let components = dir.split(separator: "/").map(String.init)
            guard let index = components.firstIndex(where: { ctx.config.toolOutputDirNames.contains($0) }) else { continue }
            let offending = components[0...index].joined(separator: "/")
            if seen.insert(offending).inserted {
                offendingPaths.append(offending)
            }
        }

        return offendingPaths.map { path in
            let name = (path as NSString).lastPathComponent
            return Finding(
                severity: .probablyIntentional,
                category: id,
                path: path,
                message: "\"\(name)\" ismert tool-kimenet (pl. a rate/LightFrameRater triázs-eszköz Stack/Review/Reject mappái vagy riport-melléklete).",
                suggestion: nil
            )
        }
    }
}

// MARK: - 16. cooler-not-reaching-setpoint

/// Per (target, session): the cooler failing to hold its CCD at `SET-TEMP`
/// silently degrades dark calibration (dark current tracks the ACTUAL sensor
/// temperature, not the requested one) -- a real risk on a hot summer night
/// with a cooled CMOS camera like the ASI2600. Fires once a session's usable
/// light frames (deduped via `FrameSet`, paired `CCD-TEMP`/`SET-TEMP` only)
/// exceed `NightHealth.coolerOutOfBandFractionThreshold` (10%) beyond
/// `config.calib.coolerToleranceC` -- exactly the same paired-delta
/// convention and threshold `NightHealth`'s cooler-health verdict uses, so
/// the two never disagree about what "the cooler isn't holding" means. A
/// session with no paired reading at all (e.g. an all-DSLR night) is silent,
/// same as `NightHealth`'s own "n/a" case.
public struct CoolerNotReachingSetpointRule: AuditRule {
    public let id = "cooler-not-reaching-setpoint"
    public init() {}

    private struct SessionKey: Hashable {
        var target: String
        var date: String
    }

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var sessionKeys = Set<SessionKey>()
        for file in ctx.files where file.area == .sessions && file.role == .light {
            guard let target = file.target, let date = file.sessionDate else { continue }
            sessionKeys.insert(SessionKey(target: target, date: date))
        }

        var findings: [Finding] = []
        for key in sessionKeys.sorted(by: { ($0.target, $0.date) < ($1.target, $1.date) }) {
            let sessionLights = ctx.files.filter {
                $0.area == .sessions && $0.role == .light && $0.target == key.target && $0.sessionDate == key.date
            }
            let buckets = FrameSet.lightBuckets(files: sessionLights, meta: ctx.fitsMetaByFileID, config: ctx.config)
            let usableMetas = buckets.usable.compactMap { $0.id.flatMap { ctx.fitsMetaByFileID[$0] } }

            let deltas = CoolerStats.pairedDeltas(usableMetas)
            guard !deltas.isEmpty else { continue }

            let outOfBandCount = deltas.filter { abs($0) > ctx.config.calib.coolerToleranceC }.count
            let fraction = Double(outOfBandCount) / Double(deltas.count)
            guard fraction > NightHealth.coolerOutOfBandFractionThreshold else { continue }

            let worst = deltas.max(by: { abs($0) < abs($1) }) ?? 0
            let percent = Int((fraction * 100).rounded())
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: "sessions/\(key.target)/\(key.date)",
                message: "A hűtő nem tartja a célhőmérsékletet: a keretek \(percent)%-a \(formatted(ctx.config.calib.coolerToleranceC))°C-nál jobban eltér a célhőmérséklettől (max \(String(format: "%+.1f", worst))°C).",
                suggestion: nil
            ))
        }
        return findings
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

// MARK: - 17. mixed-setup-in-session

/// A session whose usable lights (deduped via `FrameSet`) map to two or more
/// distinct `SetupFingerprint`s -- e.g. half the night shot on one camera/
/// focal length, the other half on another after a mid-session gear swap.
/// Stacking a session like this together silently mixes pixel scales/
/// rotations, which is much harder to recover from after the fact than
/// noticing it now. Frames with no derivable fingerprint (see
/// `EquipmentProfile.fingerprint`'s doc) are ignored -- they neither confirm
/// nor contradict uniformity.
public struct MixedSetupInSessionRule: AuditRule {
    public let id = "mixed-setup-in-session"
    public init() {}

    private struct SessionKey: Hashable {
        var target: String
        var date: String
    }

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var sessionKeys = Set<SessionKey>()
        for file in ctx.files where file.area == .sessions && file.role == .light {
            guard let target = file.target, let date = file.sessionDate else { continue }
            sessionKeys.insert(SessionKey(target: target, date: date))
        }

        var findings: [Finding] = []
        for key in sessionKeys.sorted(by: { ($0.target, $0.date) < ($1.target, $1.date) }) {
            let sessionLights = ctx.files.filter {
                $0.area == .sessions && $0.role == .light && $0.target == key.target && $0.sessionDate == key.date
            }
            let buckets = FrameSet.lightBuckets(files: sessionLights, meta: ctx.fitsMetaByFileID, config: ctx.config)
            let counts = EquipmentProfile.fingerprintCounts(usableLights: buckets.usable, meta: ctx.fitsMetaByFileID)
            guard counts.count >= 2 else { continue }

            let descriptors = counts.keys.map(\.descriptor).sorted()
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: "sessions/\(key.target)/\(key.date)",
                message: "A session felvételei eltérő eszköz-összeállítással készültek: \(descriptors.joined(separator: ", ")).",
                suggestion: nil
            ))
        }
        return findings
    }
}

// MARK: - 18. mixed-setup-in-target

/// A target whose sessions' DOMINANT `SetupFingerprint` differs from one
/// session to another -- e.g. one night at 302mm, another at 480mm after
/// swapping optics. Unlike the in-session variant, this is
/// `probablyIntentional`: switching gear between nights is a common,
/// deliberate choice for a long-running project -- the finding only exists
/// so the user notices before stacking the two nights together as if they
/// were one uniform setup.
public struct MixedSetupInTargetRule: AuditRule {
    public let id = "mixed-setup-in-target"
    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        var datesByTarget: [String: Set<String>] = [:]
        for file in ctx.files where file.area == .sessions && file.role == .light {
            guard let target = file.target, let date = file.sessionDate else { continue }
            datesByTarget[target, default: []].insert(date)
        }

        var findings: [Finding] = []
        for target in datesByTarget.keys.sorted() {
            let dates = (datesByTarget[target] ?? []).sorted()

            var dominantDescriptors: [String] = []
            for date in dates {
                let sessionLights = ctx.files.filter {
                    $0.area == .sessions && $0.role == .light && $0.target == target && $0.sessionDate == date
                }
                let buckets = FrameSet.lightBuckets(files: sessionLights, meta: ctx.fitsMetaByFileID, config: ctx.config)
                let counts = EquipmentProfile.fingerprintCounts(usableLights: buckets.usable, meta: ctx.fitsMetaByFileID)
                if let dominant = EquipmentProfile.dominant(counts) {
                    dominantDescriptors.append(dominant.descriptor)
                }
            }

            let distinct = Set(dominantDescriptors).sorted()
            guard distinct.count >= 2 else { continue }

            findings.append(Finding(
                severity: .probablyIntentional,
                category: id,
                path: "sessions/\(target)",
                message: "A célpont session-jei eltérő eszköz-összeállítást használnak: \(distinct.joined(separator: ", ")).",
                suggestion: nil
            ))
        }
        return findings
    }
}

// MARK: - 19. corrupt-fits

/// A fits-kind file (`.fit`/`.fits`/`.fz` extension, light/flat/dark/bias/
/// master role) that the scanner successfully recorded in `files` but has NO
/// `fits_meta` row at all -- `LibraryScanner.captureMeta` silently drops a
/// file whose FITS header it can't parse (`guard let header = try?
/// FITSReader.readHeader(url: url) else { return }`), so a missing row here
/// means the header read genuinely failed, not merely that this particular
/// frame lacks some optional keyword `fits_meta` happens to store. That
/// parse failure isn't surfaced anywhere else today -- this rule is the only
/// thing that turns it into something the user can act on.
///
/// Deliberately scoped to FITS-kind extensions only: a wide-field DSLR
/// light (CR3/TIF) never gets a `fits_meta` row either -- it isn't FITS at
/// all, and its metadata comes from `ImageIO`/EXIF instead -- so gating on
/// extension keeps every legitimate wide-field frame from false-positiving
/// as "corrupt". Likewise scoped to actual frame roles (not `.stack`/
/// `.processed`/`.other`): a finished stack or a loose top-level FITS file
/// was never expected to carry `fits_meta` in the first place.
public struct CorruptFITSRule: AuditRule {
    public let id = "corrupt-fits"

    private static let checkedExtensions: Set<String> = ["fit", "fits", "fz"]
    private static let checkedRoles: Set<FrameRole> = [.light, .flat, .dark, .bias, .master]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.files.compactMap { file -> Finding? in
            guard Self.checkedExtensions.contains(file.ext.lowercased()) else { return nil }
            guard Self.checkedRoles.contains(file.role) else { return nil }
            guard let fileID = file.id, ctx.fitsMetaByFileID[fileID] == nil else { return nil }

            return Finding(
                severity: .sureError,
                category: id,
                path: file.path,
                message: "nem olvasható FITS-fejléc — sérült vagy csonka fájl lehet",
                suggestion: nil
            )
        }
    }
}
