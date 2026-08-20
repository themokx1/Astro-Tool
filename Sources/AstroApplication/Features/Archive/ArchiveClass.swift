import Foundation

/// The five buckets the Archive map renders a library's bytes into. This is
/// the ONLY place `files.role` (the scanner's own vocabulary, owned by
/// `AstroCore.Scanner`) is translated into a presentation category -- every
/// other Archive type takes an `ArchiveClass` and never sees a raw role
/// string. An unrecognized role lands in `.unclassified` rather than
/// throwing: the scanner may learn new roles, and a map that refuses to draw
/// is worse than one that honestly says "I don't know what this is".
public enum ArchiveClass: String, CaseIterable, Codable, Sendable {
    case light
    case calibration
    case stack
    case processed
    case unclassified

    public init(role: String) {
        switch role.lowercased() {
        case "light": self = .light
        case "flat", "dark", "bias": self = .calibration
        case "stack": self = .stack
        case "processed": self = .processed
        default: self = .unclassified
        }
    }

    /// Left-to-right order in the strip and the legend: what you collected
    /// first, what you made from it next, the supporting frames after that,
    /// and what the app could not identify last.
    public static let displayOrder: [ArchiveClass] = [
        .light, .stack, .processed, .calibration, .unclassified
    ]
}
