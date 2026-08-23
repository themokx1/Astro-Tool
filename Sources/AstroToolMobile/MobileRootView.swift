import SwiftUI
import AstroMobileDomain

struct MobileRootView: View {
    let store: MobileLibraryStore
    @Binding private var stagedPackageURL: URL?
    @State private var snapshot: MobileLibrarySnapshot?
    @State private var queuedChangeCount = 0
    @State private var recoveryState: MobileLibraryStoreRecoveryState = .empty
    @State private var keyPayload = ""
    @State private var message: String?
    @State private var showingScanner = false
    private let scanner: CameraQRScanner
    private let fixtureQRPayload: String?
    @Environment(\.scenePhase) private var scenePhase

    init(store: MobileLibraryStore, stagedPackageURL: Binding<URL?> = .constant(nil), scanner: CameraQRScanner = CameraQRScanner(), fixtureQRPayload: String? = nil) {
        self.store = store
        _stagedPackageURL = stagedPackageURL
        self.scanner = scanner
        self.fixtureQRPayload = fixtureQRPayload
    }

    var body: some View {
        NavigationStack {
            Group {
                if recoveryState != .empty && recoveryState != .ready {
                    recoveryStateView
                } else if let snapshot {
                    libraryState(snapshot)
                } else {
                    emptyState
                }
            }
            .navigationTitle("AstroTool")
            .task { await refresh(); if let fixtureQRPayload { keyPayload = fixtureQRPayload } }
            .onChange(of: stagedPackageURL) { _, _ in }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { keyPayload = ""; scanner.stop() }
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
                        keyPayload = value
                        showingScanner = false
                    }
                    do { try scanner.start() } catch { message = "Camera access is unavailable. Try again on an iPhone with camera access." }
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
                    Text("Package received. Scan the one-time key from your Mac to unlock it.")
                        .font(.headline)
                        .accessibilityIdentifier("mobile-unlocking-state")
                    Button("Scan one-time key") { showingScanner = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mobile-package-scan")
                    Button("Import package") {
                        importPackage()
                    }
                    .buttonStyle(.bordered)
                    .disabled(keyPayload.isEmpty)
                    .accessibilityIdentifier("mobile-import-action")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let message {
                Text(message)
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
                LabeledContent("Queued changes", value: "\(queuedChangeCount)")
            }
            Section {
                Text("Original photos stay on your Mac or external drive.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("mobile-imported-state")
    }

    private func refresh() async {
        snapshot = await store.activeSnapshot
        queuedChangeCount = await store.queuedChanges.count
        recoveryState = await store.recoveryState
    }

    private func importPackage() {
        guard let stagedPackageURL, !keyPayload.isEmpty else { return }
        let payload = keyPayload
        keyPayload = ""
        Task {
            do {
                try await store.importPackage(from: stagedPackageURL, keyPayload: payload, removeStagedSource: true)
                await MainActor.run {
                    self.stagedPackageURL = nil
                    self.message = nil
                }
                await refresh()
            } catch {
                await MainActor.run { self.message = "The package could not be imported. Check the key and try again." }
            }
        }
    }
}
