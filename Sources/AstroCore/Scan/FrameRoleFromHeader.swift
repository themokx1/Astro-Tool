/// The one place a FITS `IMAGETYP` header value maps to a `FrameRole` --
/// pulled out of `LibraryScanner.roleFromImagetyp` (which used it privately
/// to refine a loose frame's path-inferred `.other` role) so a second,
/// content-based classifier -- the card-import wizard's own "propose a role
/// for a file that isn't in the library tree yet at all, so there's no path
/// to classify by" step -- can call the SAME predicate `CalibInWrongDirRule
/// .impliedRole` in `Audit/Rules.swift` also reproduces by hand today,
/// rather than hand-copying either one a third time. `LibraryScanner`
/// delegates its own private `roleFromImagetyp` to this type; nothing about
/// its behavior changed.
public enum FrameRoleFromHeader {
    /// `nil` when `imagetyp` names none of the four recognized frame kinds --
    /// callers must treat that as "unknown", never guess.
    public static func role(fromImagetyp imagetyp: String) -> FrameRole? {
        let lower = imagetyp.lowercased()
        if lower.contains("light") { return .light }
        if lower.contains("flat") { return .flat }
        if lower.contains("dark") { return .dark }
        if lower.contains("bias") { return .bias }
        return nil
    }
}
