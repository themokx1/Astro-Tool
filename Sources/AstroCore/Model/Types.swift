/// Core model types shared across AstroCore: frame classification, library
/// layout, findings produced by the audit engine, and the error domain.

import Foundation

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

public enum AstroError: Error, Equatable, Sendable {
    case accessDenied(path: String)   // TCC / EPERM
    case volumeNotMounted(path: String)
    case pathNotFound(path: String)   // root or subpath simply doesn't exist
    case corruptFITS(path: String, reason: String)
    case databaseError(String)
    case writeForbidden(path: String)
    case sirilNotFound(path: String)
    /// A caller-supplied value (e.g. `new-session`'s catalog/name/date) fails
    /// validation before any filesystem write is attempted -- the associated
    /// string explains what was wrong. Also carries the "this library index
    /// was written by a NEWER AstroTool" refusal (`Database.migrate`): the
    /// message itself is the only actionable recovery there ("update
    /// AstroTool"), which is exactly this case's contract -- recovery
    /// `.none`, message surfaced verbatim.
    case invalidInput(String)
}

// MARK: - LocalizedError (Task 14, 2026-08-16 owner screenshot)
//
// Before this conformance, `localizedDescription` fell through to Swift's
// default `Error` description -- `"AstroCore.AstroError error 4"` -- which is
// exactly what the owner's screenshot showed the user: an internal type name
// and a raw case index, discarding the message `databaseError(String)` was
// actually carrying in its own associated value.
//
// `errorDescription` here is a plain, honest ENGLISH string -- the fallback
// for the CLI (`astrotool`, which has its own `describeAstroError(_:)` in
// `Sources/astrotool/Commands.swift` and does not read this property) and for
// logs. It deliberately does NOT translate: `AstroCore` has no localization
// bundle, and a bare `String` returned from here can never resolve through
// `SwiftUI.Text(LocalizedStringKey)` against `Bundle.main` in the app target
// -- the same trap this wave hit five times before (V2SettingsTests /
// V2HonestSurfacesTests document the previous instances). Translatable
// user-facing copy is the SwiftUI layer's job: `LibraryWelcomeView` switches
// on the `AstroError` case itself and builds a `Text` with a
// `LocalizedStringKey`, with its own hand-added `hu.lproj` entries.
extension AstroError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            "AstroTool is not allowed to read \(path)."
        case .volumeNotMounted(let path):
            "The volume holding \(path) is not mounted."
        case .pathNotFound(let path):
            "\(path) no longer exists."
        case .corruptFITS(let path, let reason):
            "\(path) could not be read as a FITS file: \(reason)"
        case .databaseError(let detail):
            "AstroTool's own index could not be read: \(detail)"
        case .writeForbidden(let path):
            "Writing to \(path) is not permitted."
        case .sirilNotFound(let path):
            "Siril was not found at \(path)."
        case .invalidInput(let detail):
            detail
        }
    }

    /// What the user can actually do about it -- rendered as the dialog's
    /// action, so a wrong recovery suggestion becomes a wrong BUTTON rather
    /// than only a wrong sentence, which people skim past.
    public var recovery: AstroErrorRecovery {
        switch self {
        case .accessDenied, .pathNotFound: .rechooseLibrary
        case .volumeNotMounted: .retry
        case .databaseError: .retry
        case .corruptFITS, .writeForbidden, .sirilNotFound, .invalidInput: .none
        }
    }
}

public enum AstroErrorRecovery: Equatable, Sendable {
    /// Re-picking the folder restores a stale security-scoped bookmark.
    case rechooseLibrary
    /// Transient: the volume may appear, the lock may clear.
    case retry
    /// Nothing the dialog can offer; the message has to carry it.
    case none
}
