import Foundation

public enum NightBriefingRevisionStoreError: Error, Equatable, Sendable {
    case revisionAlreadyExists(URL)
    case corruptRevision(URL)
    /// A public (non-bridge) writer supplied nonempty mobile evidence
    /// (`mobileChangeIDs` / `mobileChangeMarkers`) for the briefing with this
    /// id. Only the package-internal mobile domain bridge may write new
    /// mobile evidence; see `saveIfLatestRecordingMobileEvidence`.
    case mobileEvidenceNotWritable(UUID)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.revisionAlreadyExists(let left), .revisionAlreadyExists(let right)),
             (.corruptRevision(let left), .corruptRevision(let right)):
            return normalizedPath(left) == normalizedPath(right)
        case (.mobileEvidenceNotWritable(let left), .mobileEvidenceNotWritable(let right)):
            return left == right
        default:
            return false
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "/private/var/", with: "/var/")
    }
}

public actor NightBriefingRevisionStore {
    /// Revision filename allocation is a read-modify-write operation. Keep it
    /// process-wide so two window-specific actors cannot each observe the
    /// same latest revision and write a stale successor.
    private static let processLock = NSLock()
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Creation-only entrypoint. Existing briefings must use the explicit
    /// compare-and-set update below; there is no unconditional update API.
    ///
    /// Public writer: a draft carrying nonempty mobile evidence
    /// (`mobileChangeIDs` / `mobileChangeMarkers`) is rejected before
    /// anything is written. Only the internal mobile domain bridge may
    /// author new mobile evidence.
    public func create(_ draft: NightBriefingDraft) throws -> NightBriefingDraft {
        guard draft.mobileChangeIDs.isEmpty, draft.mobileChangeMarkers.isEmpty else {
            throw NightBriefingRevisionStoreError.mobileEvidenceNotWritable(draft.id)
        }
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let existing = try decodedRevisions(id: draft.id)
        guard existing.isEmpty else {
            throw NightBriefingRevisionStoreError.revisionAlreadyExists(
                revisionURL(id: draft.id, revision: existing.map(\.revision).max() ?? 1)
            )
        }
        return try saveUnlocked(draft)
    }

    /// Saves only if the durable latest revision is exactly the revision the
    /// caller reviewed. This is the compare-and-set used by ordinary Mac
    /// editors (and by the public surface generally).
    ///
    /// Public writer: mobile evidence is never taken from the caller here.
    /// When no durable revision exists yet, a nonempty `mobileChangeIDs` /
    /// `mobileChangeMarkers` is rejected before anything is written (mirroring
    /// `create`). When a durable latest revision exists and the compare-and-set
    /// check passes, the candidate's `mobileChangeIDs` and `mobileChangeMarkers`
    /// are overwritten with the durable latest revision's own values before
    /// saving -- caller-supplied evidence, whether added, altered, or
    /// stripped, is never persisted through this path. Only
    /// `saveIfLatestRecordingMobileEvidence` (the internal mobile domain
    /// bridge's path) may author new mobile evidence.
    public func saveIfLatest(_ draft: NightBriefingDraft, expectedRevision: Int) throws -> NightBriefingDraft {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let latestDraft = try decodedRevisions(id: draft.id).max { $0.revision < $1.revision }
        let currentRevision = latestDraft?.revision ?? 0
        guard currentRevision == expectedRevision else {
            throw NightBriefingRevisionStoreError.revisionAlreadyExists(revisionURL(id: draft.id, revision: currentRevision))
        }
        var sanitized = draft
        if let latestDraft {
            sanitized.mobileChangeIDs = latestDraft.mobileChangeIDs
            sanitized.mobileChangeMarkers = latestDraft.mobileChangeMarkers
        } else {
            guard draft.mobileChangeIDs.isEmpty, draft.mobileChangeMarkers.isEmpty else {
                throw NightBriefingRevisionStoreError.mobileEvidenceNotWritable(draft.id)
            }
        }
        return try saveUnlocked(sanitized)
    }

    /// Saves the draft exactly as given, including its `mobileChangeIDs` /
    /// `mobileChangeMarkers` fields, verbatim -- the same compare-and-set
    /// semantics as `saveIfLatest` but without evidence sanitization.
    ///
    /// This is the package-internal mobile domain bridge's only
    /// marker-writing path (see `MobileMacDomainCommandBridge`). It is not
    /// public: normal editors must go through `saveIfLatest` above, which can
    /// never persist mobile evidence supplied by its caller.
    func saveIfLatestRecordingMobileEvidence(_ draft: NightBriefingDraft, expectedRevision: Int) throws -> NightBriefingDraft {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let currentRevision = try decodedRevisions(id: draft.id).map(\.revision).max() ?? 0
        guard currentRevision == expectedRevision else {
            throw NightBriefingRevisionStoreError.revisionAlreadyExists(revisionURL(id: draft.id, revision: currentRevision))
        }
        return try saveUnlocked(draft)
    }

    private func saveUnlocked(_ draft: NightBriefingDraft) throws -> NightBriefingDraft {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let nextRevision = (try revisionNumbers(id: draft.id).max() ?? 0) + 1
        var saved = draft
        saved.revision = nextRevision
        let url = revisionURL(id: draft.id, revision: nextRevision)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw NightBriefingRevisionStoreError.revisionAlreadyExists(url)
        }
        do {
            try encoder.encode(saved).write(to: url, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw NightBriefingRevisionStoreError.revisionAlreadyExists(url)
        }
        return saved
    }

    public func latest(id: UUID) throws -> NightBriefingDraft? {
        try decodedRevisions(id: id).max { $0.revision < $1.revision }
    }

    public func latestRevisions() throws -> [NightBriefingDraft] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let drafts = try urls.filter { revisionIdentity($0) != nil }.map(decode)
        return Dictionary(grouping: drafts, by: \.id)
            .values
            .compactMap { $0.max { $0.revision < $1.revision } }
            .sorted { ($0.savedAt, $0.id.uuidString) > ($1.savedAt, $1.id.uuidString) }
    }

    private func decodedRevisions(id: UUID) throws -> [NightBriefingDraft] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let prefix = id.uuidString.lowercased() + "-r"
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            .map(decode)
    }

    private func revisionNumbers(id: UUID) throws -> [Int] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let prefix = id.uuidString.lowercased() + "-r"
        let suffix = ".json"
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
                let start = name.index(name.startIndex, offsetBy: prefix.count)
                let end = name.index(name.endIndex, offsetBy: -suffix.count)
                guard start < end else { return nil }
                return Int(name[start..<end])
            }
    }

    private func decode(_ url: URL) throws -> NightBriefingDraft {
        do {
            let data = try Data(contentsOf: url)
            let draft = try decoder.decode(NightBriefingDraft.self, from: data)
            guard let identity = revisionIdentity(url),
                  identity.id == draft.id,
                  identity.revision == draft.revision else {
                throw NightBriefingRevisionStoreError.corruptRevision(url)
            }
            return draft
        } catch let error as NightBriefingRevisionStoreError {
            throw error
        } catch {
            throw NightBriefingRevisionStoreError.corruptRevision(url)
        }
    }

    private func revisionIdentity(_ url: URL) -> (id: UUID, revision: Int)? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        guard name.count > 38 else { return nil }
        let idEnd = name.index(name.startIndex, offsetBy: 36)
        guard let id = UUID(uuidString: String(name[..<idEnd])),
              name[idEnd...].hasPrefix("-r"),
              let revision = Int(name[name.index(idEnd, offsetBy: 2)...]),
              revision > 0 else { return nil }
        return (id, revision)
    }

    private func revisionURL(id: UUID, revision: Int) -> URL {
        directory.appendingPathComponent(
            String(format: "%@-r%06d.json", id.uuidString.lowercased(), revision),
            isDirectory: false
        )
    }
}
