import Foundation

/// Composes a brand-new session end to end -- sanitizes catalog/name into
/// the canonical `<TARGET>` folder name, validates the date, builds the
/// `README.txt` (the exact template ground-truthed against the real
/// `add_new_session.sh`), and creates the full directory tree via
/// `WriteGuard.createSessionTree`. Both the CLI (`new-session`) and the app
/// (`AppState.createSession`) call this single entry point instead of each
/// duplicating the sanitize+README+tree-creation logic themselves.
public enum SessionCreator {
    public struct Result: Sendable {
        public var createdURLs: [URL]
        public var targetFolder: String

        public init(createdURLs: [URL], targetFolder: String) {
            self.createdURLs = createdURLs
            self.targetFolder = targetFolder
        }
    }

    /// - Parameters:
    ///   - root: library root.
    ///   - catalogRaw: catalog string exactly as typed (e.g. `"M1"`).
    ///   - nameRaw: target-name string exactly as typed (e.g. `"Crab Nebula"`).
    ///   - date: must parse as a canonical `YYYY-MM-DD` date -- a run-suffix,
    ///     range, or labeled variant only ever makes sense for a date
    ///     directory that already exists, never for a brand-new session.
    ///   - now: creation timestamp for the README, injectable for tests.
    /// - Throws: `AstroError.invalidInput` if `catalogRaw`/`nameRaw` sanitize
    ///   to an empty target folder name, or if `date` isn't a canonical
    ///   date; any error `WriteGuard.createSessionTree` throws otherwise
    ///   (e.g. `.writeForbidden` if the session already exists).
    public static func create(
        root: URL,
        catalogRaw: String,
        nameRaw: String,
        date: String,
        now: Date = Date()
    ) throws -> Result {
        let targetFolder = Sanitizer.makeTarget(catalog: catalogRaw, name: nameRaw)
        guard !targetFolder.isEmpty else {
            throw AstroError.invalidInput(
                "catalog \"\(catalogRaw)\" and name \"\(nameRaw)\" sanitize to an empty target folder name"
            )
        }

        guard let parsedDate = SessionDateParser.parse(date), parsedDate.isCanonical else {
            throw AstroError.invalidInput(
                "date \"\(date)\" is not a canonical YYYY-MM-DD date"
            )
        }

        let readme = Self.readmeText(
            root: root, targetFolder: targetFolder, catalogRaw: catalogRaw,
            nameRaw: nameRaw, date: date, now: now
        )

        let writeGuard = WriteGuard(root: root)
        let created = try writeGuard.createSessionTree(target: targetFolder, dateDir: date, readme: readme)

        return Result(createdURLs: created, targetFolder: targetFolder)
    }

    /// Exact README.txt template ground-truthed against the real
    /// `add_new_session.sh` -- see the design spec's verification note.
    private static func readmeText(
        root: URL,
        targetFolder: String,
        catalogRaw: String,
        nameRaw: String,
        date: String,
        now: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let createdAt = formatter.string(from: now)

        return """
        Astro Session Notes
        ===================

        Target folder : \(targetFolder)
        Target (raw)  : \(nameRaw)
        Catalog prefix: \(catalogRaw)
        Date          : \(date)
        Created at    : \(createdAt)

        Folder map
        ----------
        - sessions/\(targetFolder)/\(date)/lights : RAW light frames
        - sessions/\(targetFolder)/\(date)/flats  : RAW flats
        - sessions/\(targetFolder)/\(date)/darks  : RAW darks
        - sessions/\(targetFolder)/\(date)/biases   : RAW biases (if used)
        - stacks/\(targetFolder)/\(date)          : stacking outputs
        - processed/\(targetFolder)/\(date)       : final edits/exports

        Fill in metadata (recommended)
        ------------------------------
        Camera:
        Sensor temp:
        Gain/Offset:
        Exposure (lights):
        Filter:
        Optics:
        Mount:
        Guiding:
        Total integration:
        Location/Bortle:
        Notes/issues:

        Calibration reminder
        --------------------
        Store reusable masters in: \(root.path)/calibration_library/
        Avoid duplicates: group by temp/gain/exposure/filter.
        """
    }
}
