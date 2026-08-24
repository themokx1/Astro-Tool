import Foundation

public enum NightBriefingRevisionStoreError: Error, Equatable, Sendable {
    case revisionAlreadyExists(URL)
    case corruptRevision(URL)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.revisionAlreadyExists(let left), .revisionAlreadyExists(let right)),
             (.corruptRevision(let left), .corruptRevision(let right)):
            return normalizedPath(left) == normalizedPath(right)
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
    public func create(_ draft: NightBriefingDraft) throws -> NightBriefingDraft {
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
    /// caller reviewed.  This is the compare-and-set used by mobile return
    /// batches to prevent overwriting an intervening Mac edit.
    public func saveIfLatest(_ draft: NightBriefingDraft, expectedRevision: Int) throws -> NightBriefingDraft {
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
