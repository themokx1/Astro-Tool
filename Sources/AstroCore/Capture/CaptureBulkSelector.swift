import Foundation

/// The five scopes offered by the frame-classification sheet. Keeping this
/// in AstroCore makes the preview and the eventual write consume the same,
/// deterministic path set instead of duplicating selection rules in SwiftUI.
public enum CaptureAssignmentScope: String, CaseIterable, Sendable {
    case currentFile
    case selectedFiles
    case sameFolder
    case sameExposure
    case wholeSession

    public var displayNameHU: String {
        switch self {
        case .currentFile: return "Csak ez a fájl"
        case .selectedFiles: return "Kijelölt fájlok"
        case .sameFolder: return "Ugyanez a mappa"
        case .sameExposure: return "Azonos expozíciós csoport"
        case .wholeSession: return "A teljes session"
        }
    }
}

public struct CaptureAssignmentCandidate: Equatable, Sendable {
    public var path: String
    public var exposureSeconds: Double?

    public init(path: String, exposureSeconds: Double?) {
        self.path = path
        self.exposureSeconds = exposureSeconds
    }
}

public enum CaptureBulkSelector {
    /// Returns a sorted, duplicate-free list and never crosses the anchor's
    /// exact `sessions/<target>/<date>` boundary, even if the caller passes a
    /// broader candidate list.
    public static func paths(
        scope: CaptureAssignmentScope,
        anchor: CaptureAssignmentCandidate,
        selectedPaths: [String],
        candidates: [CaptureAssignmentCandidate]
    ) -> [String] {
        let sessionPrefix = prefix(of: anchor.path, componentCount: 3)
        let inSession = candidates.filter { candidate in
            guard let sessionPrefix else { return candidate.path == anchor.path }
            return candidate.path == sessionPrefix || candidate.path.hasPrefix(sessionPrefix + "/")
        }

        let picked: [String]
        switch scope {
        case .currentFile:
            picked = [anchor.path]
        case .selectedFiles:
            let allowed = Set(inSession.map(\.path))
            let selected = selectedPaths.filter(allowed.contains)
            picked = selected.isEmpty ? [anchor.path] : selected
        case .sameFolder:
            let folder = (anchor.path as NSString).deletingLastPathComponent
            picked = inSession.filter {
                ($0.path as NSString).deletingLastPathComponent == folder
            }.map(\.path)
        case .sameExposure:
            guard let exposure = anchor.exposureSeconds else {
                picked = inSession.filter { $0.exposureSeconds == nil }.map(\.path)
                break
            }
            let nominalTenths = Int((exposure * 10).rounded())
            picked = inSession.filter {
                $0.exposureSeconds.map { Int(($0 * 10).rounded()) } == nominalTenths
            }.map(\.path)
        case .wholeSession:
            picked = inSession.map(\.path)
        }
        return Array(Set(picked)).sorted()
    }

    private static func prefix(of path: String, componentCount: Int) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= componentCount, components.first == "sessions" else { return nil }
        return components.prefix(componentCount).joined(separator: "/")
    }
}
