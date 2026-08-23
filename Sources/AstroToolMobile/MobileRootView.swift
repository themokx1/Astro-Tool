import SwiftUI
import AstroMobileDomain
import AstroMobileTransport

struct MobileRootView: View {
    let store: MobileLibraryStore
    @Binding private var stagedPackageURL: URL?
    @Binding private var intakeMessage: String?
    @State private var snapshot: MobileLibrarySnapshot?
    @State private var queuedChangeCount = 0
    @State private var recoveryState: MobileLibraryStoreRecoveryState = .empty
    @State private var durabilityWarning = false
    @State private var keyPayload = ""
    @State private var message: String?
    @State private var showingScanner = false
    private let scanner: any MobileQRScanner
    private let fixtureMode: String?
    private let fixtureQRPayload: String?
    @State private var importTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init(store: MobileLibraryStore, stagedPackageURL: Binding<URL?> = .constant(nil), intakeMessage: Binding<String?> = .constant(nil), scanner: any MobileQRScanner = CameraQRScanner(), fixtureMode: String? = nil, fixtureQRPayload: String? = nil) {
        self.store = store
        _stagedPackageURL = stagedPackageURL
        _intakeMessage = intakeMessage
        self.scanner = scanner
        self.fixtureMode = fixtureMode
        self.fixtureQRPayload = fixtureQRPayload
    }

    var body: some View {
        NavigationStack {
            Group {
                if fixtureMode == "empty" {
                    emptyState
                } else if recoveryState != .empty && recoveryState != .ready {
                    recoveryStateView
                } else if let snapshot {
                    libraryState(snapshot)
                } else {
                    emptyState
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                if let intakeMessage {
                    HStack {
                        Text(LocalizedStringKey(intakeMessage)).font(.footnote)
                        Spacer()
                        Button("Dismiss") { self.intakeMessage = nil; message = nil }
                    }.padding(10).background(.red.opacity(0.15)).accessibilityIdentifier("mobile-intake-error")
                }
                if durabilityWarning {
                    Label("The latest change was saved, but iPhone storage needs attention. Keep the app open and make a backup before the next import.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.2))
                        .accessibilityIdentifier("mobile-durability-warning")
                }
                }
            }
            .navigationTitle("AstroTool")
            .task { await refresh(); message = intakeMessage; if let fixtureQRPayload { keyPayload = fixtureQRPayload } }
            .onChange(of: intakeMessage) { _, next in message = next }
            .onChange(of: stagedPackageURL) { _, _ in }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    keyPayload = ""
                    scanner.stop()
                    importTask?.cancel()
                    importTask = nil
                    showingScanner = false
                }
            }
            .sheet(isPresented: $showingScanner, onDismiss: { scanner.stop() }) {
                VStack {
                    Text("Scan the one-time key shown on your Mac.").font(.headline).padding()
                    CameraQRScannerView(scanner: scanner).clipShape(RoundedRectangle(cornerRadius: 16)).padding()
                    Button("Cancel") { showingScanner = false; scanner.stop() }.buttonStyle(.bordered)
                }
                .accessibilityIdentifier("mobile-unlocking-scanner")
                .task {
                    scanner.onPayload = { value in
                        scanner.stop()
                        showingScanner = false
                        do {
                            _ = try OneTimePackageKey(scanning: value)
                            keyPayload = value
                        } catch {
                            Task { @MainActor in
                                message = "The scanned key is not valid. Scan the one-time key shown on your Mac."
                            }
                        }
                    }
                    do { try scanner.start() } catch {
                        scanner.stop()
                        showingScanner = false
                        Task { @MainActor in
                            message = "Camera access is unavailable. Try again on an iPhone with camera access."
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                Text("No AstroTool library on this iPhone yet.")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("On your Mac, choose iPhone Sync, then send the mobile package with AirDrop.")
                    .font(.body)
                Text("Original photos stay on your Mac or external drive.")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                importSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("mobile-empty-state")
        }
    }

    private var recoveryStateView: some View {
        ContentUnavailableView {
            Label("Recovery required", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text("AstroTool found damaged local data and has locked imports and edits. Keep this iPhone data unchanged and restore it from a trusted backup before trying again.")
        }
        .accessibilityIdentifier("mobile-recovery-state")
        .padding()
    }

    private var importSection: some View {
        Group {
            if stagedPackageURL != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(snapshot == nil && fixtureMode != "imported" ? "Package received. Scan the one-time key from your Mac to unlock it." : "Import newer package. AirDrop the update from your Mac, then scan its one-time key to unlock it."))
                        .font(.headline)
                        .accessibilityIdentifier("mobile-unlocking-state")
                    if snapshot != nil {
                        Text(LocalizedStringKey("Your current library stays available until the newer package passes validation."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Scan one-time key") { showingScanner = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mobile-package-scan")
                    Button(LocalizedStringKey(snapshot == nil && fixtureMode != "imported" ? "Import package" : "Import newer package")) {
                        importPackage()
                    }
                    .buttonStyle(.bordered)
                    .disabled(keyPayload.isEmpty)
                    .accessibilityIdentifier("mobile-import-action")
                    Button("Discard package") {
                        discardStagedPackage()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mobile-discard-action")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let message {
                Text(LocalizedStringKey(message))
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("mobile-import-error")
            }
        }
    }

    private func libraryState(_ snapshot: MobileLibrarySnapshot) -> some View {
        List {
            Section("Latest library") {
                LabeledContent("Revision", value: "\(snapshot.revision)")
                LabeledContent("Projects", value: "\(snapshot.projects.count)")
                if let project = snapshot.projects.first { LabeledContent("Current project", value: project.displayName) }
                LabeledContent("Queued changes", value: "\(queuedChangeCount)")
            }
            Section {
                Text("Original photos stay on your Mac or external drive.")
                    .foregroundStyle(.secondary)
            }
            if stagedPackageURL != nil {
                Section { importSection }
            }
        }
        .accessibilityIdentifier("mobile-imported-state")
    }

    private func refresh() async {
        snapshot = await store.activeSnapshot
        queuedChangeCount = await store.queuedChanges.count
        recoveryState = await store.recoveryState
        durabilityWarning = await store.durabilityWarning
        stagedPackageURL = await store.stagedPackageURL
    }

    private func importPackage() {
        guard stagedPackageURL != nil, !keyPayload.isEmpty else { return }
        let payload = keyPayload
        keyPayload = ""
        importTask = Task {
            do {
                try Task.checkCancellation()
                try await store.importCurrentStagedPackage(keyPayload: payload)
                let current = await store.stagedPackageURL
                await MainActor.run {
                    self.stagedPackageURL = current
                    self.message = nil
                    self.importTask = nil
                }
                await refresh()
            } catch {
                let current = await store.stagedPackageURL
                await refresh()
                await MainActor.run {
                    self.stagedPackageURL = current
                    if !Task.isCancelled { self.message = "The package could not be imported. Check the key and try again." }
                    self.importTask = nil
                }
            }
        }
    }

    private func discardStagedPackage() {
        guard stagedPackageURL != nil else { return }
        importTask?.cancel()
        Task {
            await store.discardCurrentStagedPackage()
            await MainActor.run {
                self.stagedPackageURL = nil
                self.keyPayload = ""
                self.message = nil
            }
        }
    }
}
