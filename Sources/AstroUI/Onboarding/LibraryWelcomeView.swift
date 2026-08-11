import AstroApplication
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

public enum OnboardingPhase: Equatable, Sendable {
    case chooseLibrary
    case scanning(progress: Double?)
    case summary(LibrarySnapshot)
    case accessProblem(String)

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    public var summary: LibrarySnapshot? {
        if case .summary(let snapshot) = self { return snapshot }
        return nil
    }

    public var accessProblemMessage: String? {
        if case .accessProblem(let message) = self { return message }
        return nil
    }
}

public enum OnboardingCompletionChoice: Equatable, Sendable {
    case library
    case preferences
}

public struct OnboardingSessionClient: Sendable {
    public let accessMode: LibraryAccessMode
    private let scanOperation: @Sendable () async throws -> LibrarySnapshot

    public init(
        accessMode: LibraryAccessMode,
        scan: @escaping @Sendable () async throws -> LibrarySnapshot
    ) {
        self.accessMode = accessMode
        scanOperation = scan
    }

    public func scan() async throws -> LibrarySnapshot {
        try await scanOperation()
    }
}

public struct OnboardingSessionFactory: Sendable {
    private let makeSession: @Sendable (URL, AppStoragePaths) async throws -> OnboardingSessionClient

    public init(
        _ makeSession: @escaping @Sendable (URL, AppStoragePaths) async throws
            -> OnboardingSessionClient
    ) {
        self.makeSession = makeSession
    }

    public func callAsFunction(
        root: URL,
        storage: AppStoragePaths
    ) async throws -> OnboardingSessionClient {
        try await makeSession(root, storage)
    }

    public static let production = OnboardingSessionFactory { root, storage in
        let session = try await LibrarySession.open(rootURL: root, storage: storage)
        return OnboardingSessionClient(
            accessMode: await session.accessMode,
            scan: { try await session.scan() }
        )
    }
}

public struct OnboardingStorageFactory: Sendable {
    private let makeStorage: @Sendable (URL) throws -> AppStoragePaths

    public init(_ makeStorage: @escaping @Sendable (URL) throws -> AppStoragePaths) {
        self.makeStorage = makeStorage
    }

    public func callAsFunction(root: URL) throws -> AppStoragePaths {
        try makeStorage(root)
    }

    public static let production = OnboardingStorageFactory { root in
        try AppStoragePaths.production(
            libraryID: LibraryIdentity(rootURL: root),
            libraryRoot: root
        )
    }
}

public struct SecurityScopedAccess: Sendable {
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    public init(
        start: @escaping @Sendable (URL) -> Bool,
        stop: @escaping @Sendable (URL) -> Void
    ) {
        startAccess = start
        stopAccess = stop
    }

    func start(_ url: URL) -> Bool {
        startAccess(url)
    }

    func stop(_ url: URL) {
        stopAccess(url)
    }

    public static let production = SecurityScopedAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )

    public static let inactive = SecurityScopedAccess(
        start: { _ in false },
        stop: { _ in }
    )
}

public enum OnboardingStoreError: Error, Equatable, Sendable {
    case mutationAccessUnsupported
}

@MainActor
@Observable
public final class OnboardingStore {
    public private(set) var phase: OnboardingPhase
    public private(set) var selectedRoot: URL?
    public private(set) var indexDatabaseURL: URL?
    public private(set) var completionChoice: OnboardingCompletionChoice?

    public let accessMode: LibraryAccessMode = .readOnly
    public let personalizationIsOptional = true

    private let sessionFactory: OnboardingSessionFactory
    private let storageFactory: OnboardingStorageFactory
    private let securityScopedAccess: SecurityScopedAccess

    public init(
        sessionFactory: OnboardingSessionFactory = .production,
        storageFactory: OnboardingStorageFactory = .production,
        securityScopedAccess: SecurityScopedAccess = .production
    ) {
        self.sessionFactory = sessionFactory
        self.storageFactory = storageFactory
        self.securityScopedAccess = securityScopedAccess
        phase = .chooseLibrary
        selectedRoot = nil
        indexDatabaseURL = nil
        completionChoice = nil
    }

    public func openAndScan(_ rootURL: URL) async throws {
        let root = rootURL.standardizedFileURL
        selectedRoot = root
        completionChoice = nil
        phase = .scanning(progress: nil)

        let didStartScopedAccess = securityScopedAccess.start(rootURL)
        defer {
            if didStartScopedAccess {
                securityScopedAccess.stop(rootURL)
            }
        }

        do {
            try Task.checkCancellation()
            let storage = try storageFactory(root: root)
            indexDatabaseURL = storage.indexDatabase
            let session = try await sessionFactory(root: root, storage: storage)
            guard session.accessMode == .readOnly else {
                throw OnboardingStoreError.mutationAccessUnsupported
            }
            let snapshot = try await session.scan()
            try Task.checkCancellation()
            phase = .summary(snapshot)
        } catch is CancellationError {
            resetToLibraryChoice()
            throw CancellationError()
        } catch {
            phase = .accessProblem(Self.actionableMessage(for: error))
            throw error
        }
    }

    public func returnToLibraryChoice() {
        resetToLibraryChoice()
    }

    public func continueWithoutPersonalizing() {
        completionChoice = .library
    }

    public func setUpPreferences() {
        completionChoice = .preferences
    }

    private func resetToLibraryChoice() {
        phase = .chooseLibrary
        selectedRoot = nil
        indexDatabaseURL = nil
        completionChoice = nil
    }

    private static func actionableMessage(for error: any Error) -> String {
        "AstroTool could not read this folder. Choose it again to restore access, or select a different image library. (\(error.localizedDescription))"
    }
}

@MainActor
public struct LibraryWelcomeView: View {
    @Bindable private var store: OnboardingStore
    private let onContinue: () -> Void
    private let onPersonalize: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingLibrary = false
    @State private var scanTask: Task<Void, Never>?
    @State private var isDropTargeted = false

    public init(
        store: OnboardingStore,
        onContinue: @escaping () -> Void,
        onPersonalize: @escaping () -> Void
    ) {
        _store = Bindable(store)
        self.onContinue = onContinue
        self.onPersonalize = onPersonalize
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .chooseLibrary:
                welcome
            case .scanning:
                FirstScanView(
                    libraryName: store.selectedRoot?.lastPathComponent ?? "Image Library",
                    cancel: cancelScan
                )
            case .summary(let snapshot):
                FirstScanSummaryView(
                    snapshot: snapshot,
                    continueToLibrary: {
                        store.continueWithoutPersonalizing()
                        onContinue()
                    },
                    personalize: {
                        store.setUpPreferences()
                        onPersonalize()
                    }
                )
            case .accessProblem(let message):
                accessProblem(message)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440)
        .background(AstroTokens.Color.graphite.opacity(0.32))
        .fileImporter(
            isPresented: $isChoosingLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let root = urls.first else { return }
            beginScan(root)
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            Label("READ-ONLY FIRST SCAN", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(AstroTokens.Color.spectralBlue)

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Bring your night sky library into focus")
                    .font(.largeTitle.weight(.semibold))
                Text("Choose the folder that contains your astrophotography images. AstroTool reads it locally and builds a separate index for fast browsing.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                safetyRow(
                    "Files stay where they are",
                    detail: "The first scan does not move, rename, or delete images.",
                    systemImage: "photo.on.rectangle.angled"
                )
                safetyRow(
                    "Your library remains read-only",
                    detail: "Only the folder you choose is inspected.",
                    systemImage: "eye"
                )
                safetyRow(
                    "The index stays outside your library",
                    detail: "Derived data is stored in AstroTool’s Application Support and cache folders.",
                    systemImage: "externaldrive.badge.checkmark"
                )
            }
            .padding(AstroTokens.Spacing.standard)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                    .stroke(isDropTargeted ? AstroTokens.Color.spectralBlue : AstroTokens.Color.hairline, lineWidth: isDropTargeted ? 2 : 1)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let root = urls.first else { return false }
                beginScan(root)
                return true
            } isTargeted: { isDropTargeted = $0 }

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("You can also drop a folder above")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Image Library…") {
                    isChoosingLibrary = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private func safetyRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
            Image(systemName: systemImage)
                .foregroundStyle(AstroTokens.Color.spectralBlue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func accessProblem(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Library access needs attention", systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Choose Another Library") {
                store.returnToLibraryChoice()
                isChoosingLibrary = true
            }
            .buttonStyle(.borderedProminent)
            Button("Back") {
                store.returnToLibraryChoice()
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func beginScan(_ root: URL) {
        scanTask?.cancel()
        scanTask = Task {
            do {
                try await store.openAndScan(root)
            } catch is CancellationError {
                // Cancellation is an explicit navigation action, not an error state.
            } catch {
                // The store exposes an actionable access state for the view.
            }
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }
}
