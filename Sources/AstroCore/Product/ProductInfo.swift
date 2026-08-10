import Foundation

/// Single committed source of truth for AstroTool's public identity.
///
/// The CLI and reports read these values directly. The packaging scripts
/// parse the intentionally simple string constants below so app metadata can
/// never drift from the code users are actually running.
public enum ProductInfo: Sendable {
    public static let name = "AstroTool"
    public static let version = "1.0.0"
    public static let build = "1"
    public static let bundleIdentifier = "io.github.themokx1.AstroTool"
    public static let legacyBundleIdentifier = "com.zoltanpalotai.astrotool"
    public static let websiteURL = "https://themokx1.github.io/Astro-Tool/"
    public static let documentationURL = "https://themokx1.github.io/Astro-Tool/tutorial.html"

    public static var displayVersion: String { "\(version) (\(build))" }
}
