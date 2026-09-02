import AstroApplication
import SwiftUI

/// Help ▸ First Steps reopens the same complete experience as first launch.
/// This wrapper preserves the stable help route while guidance and actual
/// operations remain one shared flow.
public struct FirstStepsView: View {
    let libraryStore: OnboardingStore
    let currentRootURL: URL?
    let indexedFolders: [String]
    let existingProjects: [ProjectRecord]
    let onEnableWrites: () -> Void
    let onContinue: () -> Void
    let runScan: () -> Void
    let dismiss: () -> Void
    /// 2026-09-02 audit, fix H: forwarded to `FirstSuccessOnboardingView` ->
    /// `LibraryWelcomeView`, which without it falls back to
    /// `NSOpenPanel.begin` from inside this very sheet -- the unreliable
    /// nested-modal case `V2RootView.requestLibraryPicker` exists to avoid.
    let requestLibraryPicker: (() -> Void)?

    public init(
        libraryStore: OnboardingStore,
        currentRootURL: URL?,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        onEnableWrites: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        runScan: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        requestLibraryPicker: (() -> Void)? = nil
    ) {
        self.libraryStore = libraryStore
        self.currentRootURL = currentRootURL
        self.indexedFolders = indexedFolders
        self.existingProjects = existingProjects
        self.onEnableWrites = onEnableWrites
        self.onContinue = onContinue
        self.runScan = runScan
        self.dismiss = dismiss
        self.requestLibraryPicker = requestLibraryPicker
    }

    public var body: some View {
        FirstSuccessOnboardingView(
            mode: .help,
            libraryStore: libraryStore,
            currentRootURL: currentRootURL,
            indexedFolders: indexedFolders,
            existingProjects: existingProjects,
            onEnableWrites: onEnableWrites,
            onContinue: onContinue,
            runScan: runScan,
            dismiss: dismiss,
            requestLibraryPicker: requestLibraryPicker
        )
        .accessibilityIdentifier("v2.help.first-steps")
    }
}
