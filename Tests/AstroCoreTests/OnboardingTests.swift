import Testing
@testable import AstroCore

@Test func onboardingPresentsUntilCurrentVersionIsCompleted() {
    #expect(OnboardingLifecycle.currentVersion == 2)
    #expect(OnboardingLifecycle.shouldPresent(completedVersion: 0))
    #expect(!OnboardingLifecycle.shouldPresent(completedVersion: OnboardingLifecycle.currentVersion))
}

@Test func newerOnboardingVersionCanBeOfferedAgain() {
    #expect(OnboardingLifecycle.shouldPresent(completedVersion: 1, currentVersion: 2))
}
