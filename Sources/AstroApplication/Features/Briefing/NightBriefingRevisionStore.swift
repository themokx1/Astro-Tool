import Foundation

public enum NightBriefingRevisionStoreError: Error, Equatable, Sendable {
    case revisionAlreadyExists(URL)
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

    public func save(_ draft: NightBriefingDraft) throws -> NightBriefingDraft {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try saveUnlocked(draft)
    }

    /// Saves only if the durable latest revision is exactly the revision the
    /// caller reviewed.  This is the compare-and-set used by mobile return
    /// batches to prevent overwriting an intervening Mac edit.
    public func saveIfLatest(_ draft: NightBriefingDraft, expectedRevision: Int) throws -> NightBriefingDraft {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let currentRevision = try revisionNumbers(id: draft.id).max() ?? 0
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
        let drafts = urls.compactMap(decode)
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
            .compactMap(decode)
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

    private func decode(_ url: URL) -> NightBriefingDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(NightBriefingDraft.self, from: data)
    }

    private func revisionURL(id: UUID, revision: Int) -> URL {
        directory.appendingPathComponent(
            String(format: "%@-r%06d.json", id.uuidString.lowercased(), revision),
            isDirectory: false
        )
    }
}
