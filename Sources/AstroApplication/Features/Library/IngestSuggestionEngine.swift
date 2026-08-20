import Foundation

/// V3 pre-stack program, section 5.1 (Ingest-figyelő): "ma nem létezik ilyen
/// motor -- a cél/dátum/slug 100%-ban kézi". This is the new terméklogika --
/// matching a mounted source's own name (or any other folder-shaped label
/// the ingest watcher hands it) against a known `ProjectRecord`, so the
/// card-import wizard's Destination step can arrive pre-filled instead of
/// starting empty every time.
///
/// The one hard rule the spec calls out twice: a false positive here would
/// import real frames into the WRONG project's folder. So this only ever
/// returns a match that is either an exact normalized equality, or an
/// UNAMBIGUOUS substring relationship (exactly one project qualifies) --
/// anything else (nothing matches, or more than one project could
/// plausibly match) returns `nil`. Callers must still show whatever this
/// returns as an editable, confirmable field, never a silent auto-assign
/// (`CaptureImportStore`'s `destinationStore` already requires that, being
/// a perfectly normal user-editable `NewSessionStore`).
public enum IngestSuggestionEngine {
    public enum Confidence: Equatable, Sendable {
        /// The normalized folder label equals a project's own normalized
        /// `catalogID` or `displayName`.
        case exact
        /// The normalized folder label and exactly one project's normalized
        /// `catalogID`/`displayName` contain one another (in either
        /// direction) -- e.g. "M31_Andromeda_Card" against a project whose
        /// `catalogID` is "M31".
        case fuzzy
    }

    public struct ProjectMatch: Equatable, Sendable {
        public let project: ProjectRecord
        public let confidence: Confidence

        public init(project: ProjectRecord, confidence: Confidence) {
            self.project = project
            self.confidence = confidence
        }
    }

    /// - Parameters:
    ///   - folderName: the mounted source's own display name (or a folder
    ///     name found on it) -- never a full path; this only ever compares
    ///     against the LAST path component's shape of a label.
    ///   - projects: every project this library already knows about.
    /// - Returns: `nil` whenever nothing normalizes to an unambiguous match
    ///   -- an empty/blank `folderName`, no project sharing any text with
    ///   it, or more than one project that could equally plausibly be it.
    public static func matchProject(folderName: String, projects: [ProjectRecord]) -> ProjectMatch? {
        let normalizedFolder = normalize(folderName)
        guard !normalizedFolder.isEmpty else { return nil }

        if let exact = projects.first(where: { project in
            let normalizedCatalog = normalize(project.catalogID)
            let normalizedDisplay = normalize(project.displayName)
            return (!normalizedCatalog.isEmpty && normalizedCatalog == normalizedFolder)
                || (!normalizedDisplay.isEmpty && normalizedDisplay == normalizedFolder)
        }) {
            return ProjectMatch(project: exact, confidence: .exact)
        }

        let fuzzyCandidates = projects.filter { project in
            let normalizedCatalog = normalize(project.catalogID)
            let normalizedDisplay = normalize(project.displayName)
            return contains(normalizedFolder, normalizedCatalog) || contains(normalizedFolder, normalizedDisplay)
        }
        guard fuzzyCandidates.count == 1, let only = fuzzyCandidates.first else { return nil }
        return ProjectMatch(project: only, confidence: .fuzzy)
    }

    /// `true` when either non-empty string contains the other -- both
    /// directions matter ("M31_Andromeda_Card" contains "M31", but a
    /// project display name "Andromeda Galaxy Widefield Mosaic" would
    /// contain a short card label like "andromeda" the other way around).
    private static func contains(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    /// Lowercased, alphanumerics-only -- the same "ignore case/whitespace/
    /// punctuation drift" normalization spirit `ProjectsQuery
    /// .canonicalFolderName` and `Sanitizer.sanitize` already apply
    /// elsewhere in this codebase for comparing a catalog identity against a
    /// real, human-typed folder/volume name.
    private static func normalize(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}
