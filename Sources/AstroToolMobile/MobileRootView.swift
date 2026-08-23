import SwiftUI
import AstroMobileDomain

struct MobileRootView: View {
    let store: MobileLibraryStore
    @Binding private var stagedPackageURL: URL?
    @State private var snapshot: MobileLibrarySnapshot?
    @State private var queuedChangeCount = 0
    @State private var keyPayload = ""
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    init(store: MobileLibraryStore, stagedPackageURL: Binding<URL?> = .constant(nil)) {
        self.store = store
        _stagedPackageURL = stagedPackageURL
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    libraryState(snapshot)
                } else {
                    emptyState
                }
            }
            .navigationTitle("AstroTool")
            .task { await refresh() }
            .onChange(of: stagedPackageURL) { _, _ in }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { keyPayload = "" }
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
        }
    }

    private var importSection: some View {
        Group {
            if stagedPackageURL != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Package received. Scan the one-time key from your Mac to unlock it.")
                        .font(.headline)
                    SecureField("One-time key", text: $keyPayload)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("mobile-package-key")
                    Button("Import package") {
                        importPackage()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyPayload.isEmpty)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout) }
        }
    }

    private func libraryState(_ snapshot: MobileLibrarySnapshot) -> some View {
        List {
            Section("Latest library") {
                LabeledContent("Revision", value: "(snapshot.revision)")
                LabeledContent("Projects", value: "(snapshot.projects.count)")
                LabeledContent("Queued changes", value: "(queuedChangeCount)")
            }
            Section {
                Text("Original photos stay on your Mac or external drive.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        snapshot = await store.activeSnapshot
        queuedChangeCount = await store.queuedChanges.count
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
