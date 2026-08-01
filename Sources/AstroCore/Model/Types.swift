/// Core model types shared across AstroCore: frame classification, library
/// layout, findings produced by the audit engine, and the error domain.

public enum FrameRole: String, Codable, Sendable, CaseIterable {
    case light, flat, dark, bias, master, stack, processed, other
}

public enum LibraryArea: String, Codable, Sendable {
    case sessions, stacks, processed, calibration, other
}

public enum Severity: String, Codable, Sendable {
    case sureError = "sure_error"
    case suspicious
    case probablyIntentional = "probably_intentional"
}

public enum SuggestedAction: Codable, Equatable, Sendable {
    case rename(from: String, to: String)
    case move(from: String, to: String)
    case review(note: String)
}

public struct Finding: Codable, Equatable, Sendable {
    public var severity: Severity
    public var category: String      // e.g. "placeholder-name", "orphan-calib-dir"
    public var path: String          // root-relative
    public var message: String
    public var suggestion: SuggestedAction?

    public init(
        severity: Severity,
        category: String,
        path: String,
        message: String,
        suggestion: SuggestedAction? = nil
    ) {
        self.severity = severity
        self.category = category
        self.path = path
        self.message = message
        self.suggestion = suggestion
    }
}

public enum AstroError: Error, Equatable {
    case accessDenied(path: String)   // TCC / EPERM
    case volumeNotMounted(path: String)
    case pathNotFound(path: String)   // root or subpath simply doesn't exist
    case corruptFITS(path: String, reason: String)
    case databaseError(String)
    case writeForbidden(path: String)
    case sirilNotFound(path: String)
}
