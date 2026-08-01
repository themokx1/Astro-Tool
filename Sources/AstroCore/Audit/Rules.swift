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
                message: "Directory name still contains the session-creation script's prompt text — it looks like nobody typed a real target name.",
                suggestion: .review(note: "Rename this directory to the actual target name; the intended name can't be recovered automatically.")
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
                message: "\"\(name)\" is not one of the canonical calibration_library subdirectories (darks/flats/biases).",
                suggestion: .review(note: "Move or rename this directory into calibration_library/darks, /flats, or /biases.")
            ))

            let canonicalName = Self.canonicalMapping(for: name)
            for file in ctx.files where file.path.hasPrefix(dirPath + "/") {
                let filename = (file.path as NSString).lastPathComponent
                let suggestion: SuggestedAction
                if let canonicalName {
                    suggestion = .move(from: file.path, to: "calibration_library/\(canonicalName)/\(filename)")
                } else {
                    suggestion = .review(note: "Could not tell whether this is a dark/flat/bias frame; move it into the correct calibration_library subdirectory by hand.")
                }
                findings.append(Finding(
                    severity: .sureError,
                    category: "misplaced-file",
                    path: file.path,
                    message: "File is inside the non-canonical calibration_library subdirectory \"\(name)\".",
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
                message: "Target name \"\(name)\" repeats its own leading tokens — likely a copy-paste duplication.",
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
                    message: "A \"sessions\" directory is nested outside the top-level sessions/ tree.",
                    suggestion: .review(note: "Move this nested sessions/ tree's contents into the real sessions/ area; a whole-tree move needs a human to pick the destination.")
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
            guard lower.contains("collected") || lower.contains("mosaic") || lower.hasSuffix("_process") else { return nil }

            return Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" under a stack date directory doesn't look like a normal frame-role folder.",
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

            return Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" sits directly under the target directory but isn't a date folder.",
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
                message: "Possibly the same target under different names: \(sortedNames.joined(separator: ", "))",
                suggestion: nil
            )
        }
    }

    private static func isStrictPrefix(_ a: [String], of b: [String]) -> Bool {
        guard a.count < b.count else { return false }
        return Array(b.prefix(a.count)) == a
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
                findings.append(Finding(severity: .suspicious, category: id, path: stack.path, message: "stack without session", suggestion: nil))
            }
        }

        for processed in processedEntries {
            let hasCounterpart = sessionsEntries.contains { $0.target == processed.target && Self.overlaps($0.span, processed.span) }
                || stacksEntries.contains { $0.target == processed.target && Self.overlaps($0.span, processed.span) }
            if !hasCounterpart {
                findings.append(Finding(severity: .suspicious, category: id, path: processed.path, message: "processed without session or stack", suggestion: nil))
            }
        }

        for session in sessionsEntries {
            let hasStack = stacksEntries.contains { $0.target == session.target && Self.overlaps($0.span, session.span) }
            if !hasStack {
                findings.append(Finding(severity: .suspicious, category: id, path: session.path, message: "session not yet stacked", suggestion: nil))
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
            return "canonical date"
        case .runSuffix(let n):
            return "run suffix: run \(n) of \(date.start)"
        case .range:
            return "date range: \(date.start) to \(date.end)"
        case .labeled:
            return "label \"\(date.label ?? "")\" on \(date.start)"
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
                message: "\"\(comps[2])\" under sessions/\(comps[1]) doesn't parse as a date.",
                suggestion: .review(note: "Rename this folder to a real YYYY-MM-DD date, or move its contents into the correct session date folder.")
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
            guard ctx.config.residuePatterns.contains(where: { GlobMatcher.matches(pattern: $0, name: name) }) else { continue }
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: file.path,
                message: "\"\(name)\" looks like leftover processing residue.",
                suggestion: nil
            ))
        }

        for dir in ctx.directories {
            let name = (dir as NSString).lastPathComponent
            guard ctx.config.residueDirNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            findings.append(Finding(
                severity: .suspicious,
                category: id,
                path: dir,
                message: "\"\(name)\" is a residue directory left behind by processing tools.",
                suggestion: nil
            ))
        }

        return findings
    }
}

// MARK: - 12. calib-in-wrong-dir

/// A file under `sessions/` whose FITS `IMAGETYP` (flat/dark/bias/light)
/// contradicts the frame role implied by its path — e.g. a flat frame that
/// ended up in `lights/`.
public struct CalibInWrongDirRule: AuditRule {
    public let id = "calib-in-wrong-dir"
    private static let pathRoles: Set<FrameRole> = [.light, .flat, .dark, .bias]

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        ctx.files.compactMap { file -> Finding? in
            guard file.area == .sessions, Self.pathRoles.contains(file.role) else { return nil }
            guard let fileID = file.id, let meta = ctx.fitsMetaByFileID[fileID], let imagetyp = meta.imagetyp else { return nil }
            guard let implied = Self.impliedRole(from: imagetyp), implied != file.role else { return nil }
            guard let impliedDir = Self.dirName(for: implied) else { return nil }

            var comps = file.path.split(separator: "/").map(String.init)
            guard comps.count >= 2 else { return nil }
            let filename = comps.removeLast()
            comps[comps.count - 1] = impliedDir
            let to = (comps + [filename]).joined(separator: "/")

            return Finding(
                severity: .sureError,
                category: id,
                path: file.path,
                message: "FITS IMAGETYP \"\(imagetyp)\" doesn't match this file's location (expected under \(impliedDir)/).",
                suggestion: .move(from: file.path, to: to)
            )
        }
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
