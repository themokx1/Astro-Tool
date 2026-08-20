import Foundation

/// Coordinates the strictly additive filesystem tree with its matching
/// database record. This is the creation path used by both the app and CLI.
public enum CaptureManager {
    public struct Result: Equatable, Sendable {
        public var group: CaptureGroupRecord
        public var createdURLs: [URL]

        public init(group: CaptureGroupRecord, createdURLs: [URL]) {
            self.group = group
            self.createdURLs = createdURLs
        }
    }

    @discardableResult
    public static func create(
        root: URL,
        db: Database,
        target: String,
        date: String,
        draft: CaptureGroupDraft,
        now: Date = Date()
    ) throws -> Result {
        try validate(draft: draft)
        guard try db.captureGroup(target: target, date: date, slug: draft.slug) == nil else {
            throw AstroError.invalidInput(
                "A(z) \(target) / \(date) sessionben már létezik a(z) \(draft.slug) gyűjtés."
            )
        }

        let createdURLs = try WriteGuard(root: root).createCaptureTree(
            target: target,
            dateDir: date,
            slug: draft.slug
        )
        let timestamp = now.timeIntervalSince1970
        var group = CaptureGroupRecord(
            target: target,
            sessionDate: date,
            slug: draft.slug,
            displayName: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            sensorMode: draft.sensorMode,
            signalMode: draft.signalMode,
            filterManufacturer: nonBlank(draft.filterManufacturer),
            filterModel: nonBlank(draft.filterModel),
            filterName: nonBlank(draft.filterName),
            notes: nonBlank(draft.notes),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        group.id = try db.upsertCaptureGroup(group)
        return Result(group: group, createdURLs: createdURLs)
    }

    /// `public` (W3-10): V2's "New Session"/"Add Capture" sheet previews a
    /// draft's validity BEFORE the user submits, the same way it previews
    /// `SessionCreator`'s own target/date validation -- this lets that
    /// preview call the engine's actual validation instead of a second,
    /// hand-copied version of "name non-empty, slug sanitizes to itself".
    public static func validate(draft: CaptureGroupDraft) throws {
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AstroError.invalidInput("A gyűjtés neve nem lehet üres.")
        }
        let expectedSlug = Sanitizer.sanitize(draft.slug)
        guard !draft.slug.isEmpty, expectedSlug == draft.slug else {
            throw AstroError.invalidInput(
                "A gyűjtés slugja csak betűt, számot, pontot, kötőjelet és aláhúzást tartalmazhat."
            )
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
