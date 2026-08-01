/// Classifies a root-relative library path into an area/target/date/role
/// tuple, purely from its path components — no filesystem access, no file
/// content. This is the single source of truth the scanner (and later the
/// audit engine) uses to interpret where a file sits in the canonical
/// `sessions/<TARGET>/<DATE>/{lights,flats,darks,biases}`,
/// `stacks/<TARGET>/<DATE>/`, `processed/<TARGET>/<DATE>/`,
/// `calibration_library/{darks,flats,biases}/` layout.
public struct PathInfo: Equatable, Sendable {
    public var area: LibraryArea
    public var target: String?
    public var dateRaw: String?
    public var role: FrameRole

    public init(
        area: LibraryArea,
        target: String? = nil,
        dateRaw: String? = nil,
        role: FrameRole
    ) {
        self.area = area
        self.target = target
        self.dateRaw = dateRaw
        self.role = role
    }
}

public enum PathClassifier {
    /// Subdirectory name (immediately under `sessions/<target>/<date>/`)
    /// that determines a session frame's role.
    private static let sessionRoleSubdirs: [String: FrameRole] = [
        "lights": .light,
        "flats": .flat,
        "darks": .dark,
        "biases": .bias,
    ]

    /// Subdirectory name (immediately under `calibration_library/`) that
    /// determines a calibration frame's role.
    private static let calibRoleSubdirs: [String: FrameRole] = [
        "darks": .dark,
        "flats": .flat,
        "biases": .bias,
    ]

    /// Classifies `relativePath` (root-relative, "/"-separated, no leading
    /// "/"). Only the top-level area directory and — for `sessions`/
    /// `stacks`/`processed` — the two components right after it are ever
    /// consulted; anything deeper (e.g. a stray nested `sessions/` folder
    /// under `stacks/<target>/<date>/`) does not change the area. That
    /// mislabeling is intentionally left for the audit engine to flag later,
    /// not silently reinterpreted here.
    public static func classify(relativePath: String) -> PathInfo {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard let top = components.first else {
            return PathInfo(area: .other, role: .other)
        }

        switch top {
        case "sessions":
            let target = components.count > 1 ? components[1] : nil
            let dateRaw = components.count > 2 ? components[2] : nil
            let role = components.count > 3
                ? (sessionRoleSubdirs[components[3].lowercased()] ?? .other)
                : .other
            return PathInfo(area: .sessions, target: target, dateRaw: dateRaw, role: role)

        case "stacks":
            let target = components.count > 1 ? components[1] : nil
            let dateRaw = components.count > 2 ? components[2] : nil
            return PathInfo(area: .stacks, target: target, dateRaw: dateRaw, role: .stack)

        case "processed":
            let target = components.count > 1 ? components[1] : nil
            let dateRaw = components.count > 2 ? components[2] : nil
            return PathInfo(area: .processed, target: target, dateRaw: dateRaw, role: .processed)

        case "calibration_library":
            let role = components.count > 1
                ? (calibRoleSubdirs[components[1].lowercased()] ?? .other)
                : .other
            return PathInfo(area: .calibration, target: nil, dateRaw: nil, role: role)

        default:
            return PathInfo(area: .other, target: nil, dateRaw: nil, role: .other)
        }
    }
}
