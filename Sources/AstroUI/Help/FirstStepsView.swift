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

    public init(
        libraryStore: OnboardingStore,
        currentRootURL: URL?,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        onEnableWrites: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        runScan: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.libraryStore = libraryStore
        self.currentRootURL = currentRootURL
        self.indexedFolders = indexedFolders
        self.existingProjects = existingProjects
        self.onEnableWrites = onEnableWrites
        self.onContinue = onContinue
        self.runScan = runScan
        self.dismiss = dismiss
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
            dismiss: dismiss
        )
        .accessibilityIdentifier("v2.help.first-steps")
    }
}
