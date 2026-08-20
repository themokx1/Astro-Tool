import AstroApplication
import Foundation
import Observation

/// One row of `ArchiveTaskDetailView`'s hierarchical table: a parent-folder
/// heading (however many findings share that directory -- the owner's own
/// complaint, "28 identical bias files from one folder" shown as 28 flat
/// rows, reads as one line now, not 28), or one of that folder's findings
/// nested under it. Deliberately two distinct `Kind` cases rather than a
/// single struct with an optional finding -- the owner's second complaint
/// ("the first row is a bare FOLDER shown with 0 KB among files") was
/// exactly that ambiguity: a folder is not a zero-byte file, and this type
/// makes the two cases impossible to confuse at the call site.
public struct ArchiveFindingRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder(path: String, fileCount: Int, bytes: Int64)
        case finding(ArchiveFinding)
    }

    public let id: String
    public let kind: Kind
    public var children: [ArchiveFindingRow]?

    public init(id: String, kind: Kind, children: [ArchiveFindingRow]?) {
        self.id = id
        self.kind = kind
        self.children = children
    }
}

/// Loads the full finding set behind one `ArchiveTaskKind` for
/// `ArchiveTaskDetailView` -- the destination `ArchiveTaskAction.showFindings`
/// pushes to. Follows `ArchiveStore`'s own shape exactly (its doc comment
/// spells out why): a side-effect-free `init`, no query in a computed
/// getter, and a generation guard on the async load so a superseded slow
/// load (e.g. the user backs out and reopens a different kind's list before
/// the first load finishes) can never overwrite a newer result or clear its
/// `isLoading`. `totalBytes` is summed once here, at load time, rather than
/// as a computed property the view would otherwise re-reduce over
/// potentially thousands of rows on every render. `rows` (W4-7 item 3,
/// owner review) is grouped the same way, once here, never in the view's
/// `body` -- this codebase's freeze history is entirely "work that ran on
/// the body path" (see `ArchiveStore`'s own doc comment for the five prior
/// incidents), and a 3 231-finding card is exactly the size that would turn
/// a per-render regroup into the next one.
@MainActor
@Observable
public final class ArchiveTaskDetailStore {
    public typealias FindingsFactory = @Sendable (URL, ArchiveTaskKind) async throws -> [ArchiveFinding]

    public private(set) var findings: [ArchiveFinding] = []
    public private(set) var rows: [ArchiveFindingRow] = []
    public private(set) var totalBytes: Int64 = 0
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let factory: FindingsFactory
    private var generation = 0

    public init(
        factory: @escaping FindingsFactory = { rootURL, kind in
            try await ArchiveTaskQuery.production(rootURL: rootURL).findings(for: kind)
        }
    ) {
        self.factory = factory
    }

    public func load(rootURL: URL, kind: ArchiveTaskKind) async {
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await factory(rootURL, kind)
            guard token == generation else { return }
            findings = loaded
            totalBytes = loaded.reduce(0) { $0 + $1.bytes }
            rows = Self.groupedByFolder(loaded)
        } catch {
            guard token == generation else { return }
            findings = []
            totalBytes = 0
            rows = []
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }

    /// One folder row per distinct parent directory among `findings`,
    /// biggest folder (by total bytes) first -- the same "worst offender
    /// first" ordering `ArchiveMapQuery.buildRows` already uses for target
    /// rows, so a folder actually worth the user's attention never hides
    /// below a screenful of one-file folders. A folder's own children keep
    /// `findings`' original (size-desc, from `ArchiveTaskQuery.findings(for:)`'s
    /// `ORDER BY d.id`... actually path-insertion) order rather than being
    /// re-sorted a second time.
    static func groupedByFolder(_ findings: [ArchiveFinding]) -> [ArchiveFindingRow] {
        var byFolder: [String: [ArchiveFinding]] = [:]
        var order: [String] = []
        for finding in findings {
            let folder = (finding.path as NSString).deletingLastPathComponent
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(finding)
        }
        return order
            .map { folder -> ArchiveFindingRow in
                let entries = byFolder[folder] ?? []
                let bytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
                let children = entries.map { finding in
                    ArchiveFindingRow(id: "f:\(finding.id)", kind: .finding(finding), children: nil)
                }
                return ArchiveFindingRow(
                    id: "d:\(folder)",
                    kind: .folder(path: folder, fileCount: entries.count, bytes: bytes),
                    children: children
                )
            }
            .sorted { lhs, rhs in
                guard case .folder(let lhsPath, _, let lhsBytes) = lhs.kind,
                      case .folder(let rhsPath, _, let rhsBytes) = rhs.kind
                else { return false }
                if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
                return lhsPath < rhsPath
            }
    }
}
