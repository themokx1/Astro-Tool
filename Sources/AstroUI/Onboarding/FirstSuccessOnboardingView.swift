import AstroApplication
import AstroCore
import SwiftUI
import UniformTypeIdentifiers

/// The shared first-run and Help experience. It coordinates existing,
/// independently tested engines: library scan, session/capture creation, and
/// copy-only verified import.
@MainActor
public struct FirstSuccessOnboardingView: View {
    /// Owned by the SHELL, not by this view (2026-09-02 audit, fix C).
    /// Asking for the native folder picker closes the sheet this view lives
    /// in, which destroyed a `@State` coordinator -- so "I already have an
    /// AstroTool library" restarted from scratch as a bare scan receipt
    /// after the picker, never reaching `libraryReady()`, the import offer,
    /// or the write-enabling the guided flow depends on.
    @Bindable private var coordinator: FirstSuccessOnboardingStore
    @Bindable private var libraryStore: OnboardingStore
    @State private var libraryName = "Astro Photos"
    @State private var chosenParent: URL?
    @State private var isChoosingParent = false
    @State private var isCreatingLibrary = false

    private let currentRootURL: URL?
    private let indexedFolders: [String]
    private let existingProjects: [ProjectRecord]
    private let onEnableWrites: () -> Void
    private let onContinue: () -> Void
    private let runScan: () -> Void
    private let dismiss: () -> Void
    private let requestLibraryPicker: (() -> Void)?

    public init(
        coordinator: FirstSuccessOnboardingStore,
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
        _coordinator = Bindable(coordinator)
        _libraryStore = Bindable(libraryStore)
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
        Group {
            switch coordinator.step {
            case .landing: landing
            case .understanding(let page): understanding(page: page)
            case .createLibrary: createLibrary
            case .openLibrary: openLibrary
            case .importOffer: importOffer
            case .importFlow: importFlow
            case .completion: completion
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 570, idealHeight: 680)
        .background(AstroTokens.Color.ground)
        .alert(
            "This step needs attention",
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { if !$0 { coordinator.clearError() } }
            )
        ) {
            Button("OK") { coordinator.clearError() }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .accessibilityIdentifier("v3.first-success-onboarding")
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                header(
                    eyebrow: "FIRST STEPS",
                    title: "Let’s give your night-sky photos a clear home.",
                    detail: "You do not need to know a folder standard. Choose what fits your situation, and AstroTool will guide you safely."
                )
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    choice(
                        title: "Create a new image library",
                        detail: "AstroTool creates the right folders, then can copy in your first photos.",
                        symbol: "folder.badge.plus",
                        identifier: "v3.onboarding.create-library",
                        action: { coordinator.chooseEntry(.createLibrary) }
                    )
                    choice(
                        title: "I already have an AstroTool library",
                        detail: "Choose it, check its structure, and continue where you left off.",
                        symbol: "folder.badge.checkmark",
                        identifier: "v3.onboarding.open-library",
                        action: { coordinator.chooseEntry(.openLibrary) }
                    )
                    choice(
                        title: "I want to understand it first",
                        detail: "See the idea in a few calm steps. Nothing will be changed.",
                        symbol: "lightbulb.max",
                        identifier: "v3.onboarding.understand",
                        action: { coordinator.chooseEntry(.understand) }
                    )
                }
                safetyStrip
                HStack {
                    Spacer()
                    Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                }
            }
            .padding(AstroTokens.Spacing.spacious)
        }
    }

    private func choice(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(AstroTokens.Color.accent)
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Label("Continue", systemImage: "arrow.right").font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .astroRaisedSurface()
        .accessibilityIdentifier(identifier)
    }

    private func understanding(page: Int) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            topBar(title: "How AstroTool keeps things understandable")
            LibraryMapView()
            Group {
                if page == 0 {
                    Text("A library is the home. Projects follow one object, nights keep dates honest, and captures separate different setups or exposure series.")
                } else {
                    Text("Light frames contain the sky. Flats, darks, and biases help correct the camera and optical system. AstroTool keeps their roles clear without changing your originals.")
                }
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            HStack {
                Button("Back to the three choices") { coordinator.finishUnderstanding() }
                Spacer()
                if page == 0 {
                    Button("Next") { coordinator.advanceUnderstanding(pageCount: 2) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("I’m ready to choose") { coordinator.finishUnderstanding() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private var createLibrary: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            topBar(title: "Create a new image library")
            Text("Choose a familiar name and a place with enough room for your photos. AstroTool only creates the missing folders.")
                .font(.title3).foregroundStyle(.secondary)
            Form {
                TextField("Library name", text: $libraryName)
                LabeledContent("Location") {
                    HStack {
                        Text(chosenParent?.path(percentEncoded: false) ?? String(localized: "Not chosen yet"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose Location…") { isChoosingParent = true }
                    }
                }
            }
            DisclosureGroup("What will be created on my Mac?") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Projects and nights · Stacks · Processed images")
                    Text("Calibration library: darks, flats, and biases")
                    Text("AstroTool’s small private index area")
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
            safetyStrip
            HStack {
                Button("Back") { coordinator.returnToLanding() }
                Spacer()
                if isCreatingLibrary { ProgressView().controlSize(.small) }
                Button("Create Library") { makeLibrary() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenParent == nil || trimmedLibraryName.isEmpty || isCreatingLibrary)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
        .fileImporter(
            isPresented: $isChoosingParent,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result { chosenParent = urls.first }
        }
    }

    private var openLibrary: some View {
        LibraryWelcomeView(
            store: libraryStore,
            onContinue: libraryReady,
            onPersonalize: libraryReady,
            requestLibraryPicker: requestLibraryPicker
        )
        .overlay(alignment: .topLeading) {
            Button("Back") { coordinator.returnToLanding() }
                .padding(AstroTokens.Spacing.standard)
        }
    }

    private var importOffer: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            topBar(title: "Your library is ready")
            LibraryMapView()
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Would you like to copy in your first photos now?").font(.title2.weight(.semibold))
                Text("This optional step creates the first project, night, and capture together, then copies your selected photos into it.")
                    .foregroundStyle(.secondary)
            }
            safetyStrip
            HStack {
                Button("Skip this whole step") { coordinator.skipImport() }
                Spacer()
                Button("Copy my first photos") { coordinator.startImport() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    @ViewBuilder
    private var importFlow: some View {
        if let root = libraryStore.selectedRoot ?? currentRootURL {
            VStack(spacing: 0) {
                safetyStrip.padding([.horizontal, .top], AstroTokens.Spacing.standard)
                CaptureImportView(
                    rootURL: root,
                    accessMode: .mutationEnabled,
                    indexedFolders: indexedFolders,
                    existingProjects: existingProjects,
                    dismiss: { coordinator.cancelImport() },
                    runScan: runScan,
                    importCompleted: { coordinator.importCompleted(createdFirstProject: true) },
                    // W-fix (item 3): `CaptureImportView`'s own store is
                    // `@State` and dies the instant `cancelImport()` above
                    // unmounts this view -- these two calls are the
                    // coordinator's only chance to learn (and later revise)
                    // whether "Create Structure" actually wrote a real
                    // session/capture tree, so the completion screen can
                    // stay honest about it.
                    structureCreated: { targetFolder, date, captureSlug in
                        coordinator.recordCreatedStructure(targetFolder: targetFolder, date: date, captureSlug: captureSlug)
                    },
                    structureUndone: { coordinator.clearCreatedStructure() }
                )
            }
        } else {
            ContentUnavailableView(
                "No library is open",
                systemImage: "folder.badge.questionmark",
                description: Text("Return and choose or create a library before importing photos.")
            )
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            topBar(title: coordinator.didSkipImport ? "You’re ready" : "Your first project is ready")
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(AstroTokens.Color.ok)
            Text(completionDetail)
                .font(.title3).foregroundStyle(.secondary)
            safetyStrip
            HStack {
                Spacer()
                Button(coordinator.didSkipImport ? "Enter AstroTool" : "Open Project") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    /// W-fix (item 3): honest completion copy. Skipping the import used to
    /// always say "No project or capture was created" even when "Create
    /// Structure" had already written a real session/capture folder tree
    /// moments earlier and the user only backed out of COPYING PHOTOS into
    /// it -- `coordinator.createdStructure` (recorded by the wizard itself,
    /// since it survives the wizard's own store dying) is what tells these
    /// two true-but-different outcomes apart.
    private var completionDetail: LocalizedStringKey {
        guard coordinator.didSkipImport else {
            return "The import receipt shows what was copied, verified, skipped, or could not be copied."
        }
        guard coordinator.createdStructure != nil else {
            return "No project or capture was created. You can return to First Steps whenever you want."
        }
        return "The project folders were created; no photos were copied. You can return to First Steps whenever you want."
    }

    private var safetyStrip: some View {
        HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
            Image(systemName: "lock.shield.fill").foregroundStyle(AstroTokens.Color.ok)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your source files stay unchanged").font(.headline)
                Text("AstroTool only creates verified copies in your library. It never overwrites a file and offers no standalone delete action.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .astroRecessedSurface()
        .accessibilityIdentifier("v3.onboarding.copy-only-safety")
    }

    private func header(eyebrow: LocalizedStringKey, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text(eyebrow).font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(AstroTokens.Color.accent)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(detail).font(.title3).foregroundStyle(.secondary)
        }
    }

    private func topBar(title: LocalizedStringKey) -> some View {
        HStack {
            Text(title).font(.largeTitle.weight(.semibold))
            Spacer()
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }

    private var trimmedLibraryName: String {
        libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeLibrary() {
        guard let chosenParent, !trimmedLibraryName.isEmpty else { return }
        let root = chosenParent.appendingPathComponent(trimmedLibraryName, isDirectory: true)
        isCreatingLibrary = true
        Task { @MainActor in
            defer { isCreatingLibrary = false }
            do {
                _ = try LibraryCreationCommand(root: root, accessMode: .mutationEnabled).create()
                try await libraryStore.openAndScan(root)
                libraryReady()
            } catch {
                coordinator.reportError(error.localizedDescription)
            }
        }
    }

    private func libraryReady() {
        onEnableWrites()
        coordinator.libraryBecameReady()
    }
}
