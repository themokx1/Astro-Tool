import Foundation

/// Version comparison kept in AstroCore so first-run behavior is testable
/// without SwiftUI/UserDefaults. Raising `currentVersion` offers a materially
/// new onboarding once to existing installations as well.
public enum OnboardingLifecycle {
    public static let currentVersion = 1

    public static func shouldPresent(
        completedVersion: Int,
        currentVersion: Int = currentVersion
    ) -> Bool {
        completedVersion < currentVersion
    }
}
