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
    /// Slug from the canonical capture-aware layout, or from a mirrored
    /// stack/processed subfolder. `nil` for classic session paths.
    public var captureSlug: String?
    /// Raw suffix from a legacy role folder such as `lights_osc`. Kept
    /// separate from `captureSlug`: the converter must show this as an
    /// inference rather than pretending the legacy label is canonical.
    public var legacyCaptureLabel: String?

    public init(
        area: LibraryArea,
        target: String? = nil,
        dateRaw: String? = nil,
        role: FrameRole,
        captureSlug: String? = nil,
        legacyCaptureLabel: String? = nil
    ) {
        self.area = area
        self.target = target
        self.dateRaw = dateRaw
        self.role = role
        self.captureSlug = captureSlug
        self.legacyCaptureLabel = legacyCaptureLabel
    }
}

public enum PathClassifier {
    /// Subdirectory name (immediately under `sessions/<target>/<date>/`)
    /// that determines a session frame's role. Both the canonical plural
    /// form and the singular form real libraries sometimes use (`bias`
    /// instead of `biases`, ...) are accepted here, case-insensitively --
    /// this only affects `sessions/`; `calibration_library/`'s orphan-dir
    /// handling (a singular `bias` dir there is deliberately left
    /// unrecognized so `OrphanCalibDirRule` keeps flagging it) is untouched.
    private static let sessionRoleSubdirs: [String: FrameRole] = [
        "lights": .light, "light": .light,
        "flats": .flat, "flat": .flat,
        "darks": .dark, "dark": .dark,
        "biases": .bias, "bias": .bias,
    ]

    /// Subdirectory name (immediately under `calibration_library/`) that
    /// determines a calibration frame's role.
    private static let calibRoleSubdirs: [String: FrameRole] = [
        "darks": .dark,
        "flats": .flat,
        "biases": .bias,
    ]

    /// Recognizes non-canonical but common `lights_osc`/`flats_sv220`
    /// folders. The suffix is evidence for a converter suggestion, not a
    /// canonical capture slug, so the two are returned separately.
    private static func legacySessionRole(_ directory: String) -> (role: FrameRole, label: String)? {
        let lower = directory.lowercased()
        let candidates: [(String, FrameRole)] = [
            ("lights", .light), ("light", .light),
            ("flats", .flat), ("flat", .flat),
            ("darks", .dark), ("dark", .dark),
            ("biases", .bias), ("bias", .bias),
        ]
        for (prefix, role) in candidates {
            let marker = prefix + "_"
            guard lower.hasPrefix(marker) else { continue }
            let label = String(directory.dropFirst(marker.count))
            if !label.isEmpty { return (role, label) }
        }
        return nil
    }

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
            // The classified path's LAST component is always the filename
            // (the scanner only classifies files) -- so a component is only
            // really a directory when there's at least one more component
            // after it. `component[1]` (the target dir) needs >= 3
            // components total; `component[2]` (the date dir) needs >= 4;
            // `component[3]` (the role dir) needs >= 5. Without these
            // thresholds a file sitting directly under `sessions/` (e.g.
            // `sessions/.DS_Store`) or directly under a target dir (e.g.
            // `sessions/IC1805/.DS_Store`) would have its own filename
            // misread as a target/date.
            let target = components.count >= 3 ? components[1] : nil
            let dateRaw = components.count >= 4 ? components[2] : nil
            if components.count >= 7, components[3].lowercased() == "captures" {
                let slug = components[4]
                let role = sessionRoleSubdirs[components[5].lowercased()] ?? .other
                guard !slug.isEmpty, role != .other else {
                    return PathInfo(area: .sessions, target: target, dateRaw: dateRaw, role: .other)
                }
                return PathInfo(
                    area: .sessions, target: target, dateRaw: dateRaw,
                    role: role, captureSlug: slug
                )
            }

            guard components.count >= 5 else {
                return PathInfo(area: .sessions, target: target, dateRaw: dateRaw, role: .other)
            }
            let roleDirectory = components[3]
            if let role = sessionRoleSubdirs[roleDirectory.lowercased()] {
                return PathInfo(area: .sessions, target: target, dateRaw: dateRaw, role: role)
            }
            if let legacy = legacySessionRole(roleDirectory) {
                return PathInfo(
                    area: .sessions, target: target, dateRaw: dateRaw,
                    role: legacy.role, legacyCaptureLabel: legacy.label
                )
            }
            return PathInfo(area: .sessions, target: target, dateRaw: dateRaw, role: .other)

        case "stacks":
            let target = components.count >= 3 ? components[1] : nil
            let dateRaw = components.count >= 4 ? components[2] : nil
            let captureSlug: String? = {
                if components.count >= 6, components[3].lowercased() == "captures" { return components[4] }
                return components.count >= 5 ? components[3] : nil
            }()
            return PathInfo(area: .stacks, target: target, dateRaw: dateRaw, role: .stack, captureSlug: captureSlug)

        case "processed":
            let target = components.count >= 3 ? components[1] : nil
            let dateRaw = components.count >= 4 ? components[2] : nil
            let captureSlug: String? = {
                if components.count >= 6, components[3].lowercased() == "captures" { return components[4] }
                return components.count >= 5 ? components[3] : nil
            }()
            return PathInfo(area: .processed, target: target, dateRaw: dateRaw, role: .processed, captureSlug: captureSlug)

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
