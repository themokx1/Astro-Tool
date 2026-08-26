import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Darwin
import UIKit
import AstroMobileDomain
import AstroMobileTransport

private enum MobileTab: Hashable {
    case tonight, projects, briefings, sync
}

/// The nearby-sync screen's own plain, `AstroMobileTransport`-free state
/// mirror of `NearbyPhoneSyncState`/`NearbyPhoneSyncFailure` — see
/// `MobileNearbySyncScreen.swift`'s doc comment for why the screen itself
/// never imports that module directly.
enum MobileNearbySyncUIState: Equatable {
    case idle
    case searching
    case pairingCode(String)
    case connecting
    case receiving
    case staged
    case sendingReturn
    case finished
    case failed(MobileNearbySyncUIFailure)

    init(_ state: NearbyPhoneSyncState) {
        switch state {
        case .idle: self = .idle
        case .searching: self = .searching
        case .pairingCode(let code): self = .pairingCode(code)
        case .connecting: self = .connecting
        case .receiving: self = .receiving
        case .staged: self = .staged
        case .sendingReturn: self = .sendingReturn
        case .finished: self = .finished
        case .failed(let failure): self = .failed(MobileNearbySyncUIFailure(failure))
        }
    }
}

enum MobileNearbySyncUIFailure: Equatable {
    case peerNotFound
    case pairingRejected
    case identityChanged
    case transferFailed
    case importFailed
    case timeout
    case cancelled

    init(_ failure: NearbyPhoneSyncFailure) {
        switch failure {
        case .peerNotFound: self = .peerNotFound
        case .pairingRejected: self = .pairingRejected
        case .identityChanged: self = .identityChanged
        case .transferFailed: self = .transferFailed
        case .importFailed: self = .importFailed
        case .timeout: self = .timeout
        case .cancelled: self = .cancelled
        }
    }
}

enum MobileSnapshotFreshness: Equatable, Sendable {
    case fresh
    case stale

    static let staleThreshold: TimeInterval = 24 * 60 * 60

    static func classification(snapshotDate: Date, now: Date) -> Self {
        guard snapshotDate <= now,
              now.timeIntervalSince(snapshotDate) >= staleThreshold else { return .fresh }
        return .stale
    }
}

enum MobileEffectiveState {
    static func checklistValue(briefingID: UUID, itemID: String, snapshotValue: Bool, changes: [MobileChange]) -> Bool {
        changes.reversed().compactMap { change -> Bool? in
            guard case .checklistCompletion(let completion) = change,
                  completion.briefingID == briefingID,
                  completion.itemID == itemID else { return nil }
            return completion.isCompleted
        }.first ?? snapshotValue
    }

    static func noteText(noteID: String, snapshotText: String, changes: [MobileChange]) -> String {
        changes.reversed().compactMap { change -> String? in
            guard case .noteRevision(let revision) = change, revision.noteID == noteID else { return nil }
            return revision.text
        }.first ?? snapshotText
    }
}

enum MobileProjectProgress {
    static func fraction(integrationSeconds: Double, goalHours: Double?) -> Double? {
        guard let goalHours, goalHours.isFinite, goalHours > 0,
              integrationSeconds.isFinite else { return nil }
        return min(max(integrationSeconds / (goalHours * 3_600), 0), 1)
    }
}

/// Decides whether a project row's monospaced catalog identifier is worth
/// showing beside the bold display name. Real-library owner data (see the
/// v5-iphone-companion screenshot audit) commonly has `catalogID ==
/// displayName`, in which case repeating the identical string twice — once
/// bold, once monospaced — is pure noise and, for long identifiers, forces
/// the row into a mid-token line wrap. The comparison is trimmed and
/// case-insensitive so incidental whitespace or casing differences between
/// the two fields don't resurrect a duplicate-looking row.
enum MobileProjectRowModel {
    static func showsCatalogID(displayName: String, catalogID: String) -> Bool {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCatalogID = catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCatalogID.isEmpty else { return false }
        return trimmedCatalogID.caseInsensitiveCompare(trimmedDisplayName) != .orderedSame
    }
}

enum MobileProjectPhaseLabel {
    static func label(for value: String) -> String {
        switch value.lowercased() {
        case "planned": return String(localized: "Planned")
        case "collecting": return String(localized: "Collecting")
        case "processing": return String(localized: "Processing")
        case "complete": return String(localized: "Complete")
        case "archived": return String(localized: "Archived")
        default: return String(localized: "Planned")
        }
    }
}

enum MobileBriefingReadinessLabel {
    static func label(for value: String) -> String {
        switch value.lowercased() {
        case "ready": return String(localized: "Ready")
        case "attention": return String(localized: "Needs attention")
        case "incomplete": return String(localized: "Incomplete")
        default: return String(localized: "Plan status available")
        }
    }
}

enum MobileBriefingTargetRoleLabel {
    static func label(for value: String) -> String {
        switch value.lowercased() {
        case "primary": return String(localized: "Primary target")
        case "backup": return String(localized: "Backup target")
        default: return String(localized: "Target")
        }
    }
}

enum MobileBriefingSelection {
    enum Kind: Equatable, Sendable {
        case tonight
        case upcoming
        case past
        case saved
    }

    struct Result: Equatable, Sendable {
        let briefing: MobileBriefing
        let kind: Kind
    }

    static func select(briefings: [MobileBriefing], now: Date, calendar: Calendar = .current) -> Result? {
        let stable = briefings.sorted { lhs, rhs in
            lhs.savedAt == rhs.savedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.savedAt > rhs.savedAt
        }
        let today = calendar.startOfDay(for: now)
        if let tonight = stable.filter({ briefing in
            guard let date = briefing.nightDate else { return false }
            return calendar.isDate(date, inSameDayAs: today)
        }).first {
            return Result(briefing: tonight, kind: .tonight)
        }
        if let upcoming = stable.filter({ briefing in
            guard let date = briefing.nightDate else { return false }
            return date > now
        }).sorted(by: upcomingSort).first {
            return Result(briefing: upcoming, kind: .upcoming)
        }
        if let past = stable.filter({ briefing in
            guard let date = briefing.nightDate else { return false }
            return date <= now
        }).sorted(by: pastSort).first {
            return Result(briefing: past, kind: .past)
        }
        return stable.first.map { Result(briefing: $0, kind: .saved) }
    }

    static func timeZone(for date: Date, nights: [MobileNight]) -> TimeZone? {
        let matches = nights.filter { night in
            guard let zone = TimeZone(identifier: night.timeZoneID) else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date) == night.localDate
        }
        guard matches.count == 1 else { return nil }
        return TimeZone(identifier: matches[0].timeZoneID)
    }

    private static func upcomingSort(_ lhs: MobileBriefing, _ rhs: MobileBriefing) -> Bool {
        guard let left = lhs.nightDate, let right = rhs.nightDate else { return lhs.id.uuidString < rhs.id.uuidString }
        return left == right ? lhs.savedAt > rhs.savedAt : left < right
    }

    private static func pastSort(_ lhs: MobileBriefing, _ rhs: MobileBriefing) -> Bool {
        guard let left = lhs.nightDate, let right = rhs.nightDate else { return lhs.id.uuidString < rhs.id.uuidString }
        return left == right ? lhs.savedAt > rhs.savedAt : left > right
    }
}

@MainActor
struct MobileRootView: View {
    let store: MobileLibraryStore
    @Binding private var stagedPackageURL: URL?
    @Binding private var intakeError: MobileIntakeError?
    @State private var snapshot: MobileLibrarySnapshot?
    @State private var changes: [MobileChange] = []
    @State private var queuedChangeCount = 0
    @State private var recoveryState: MobileLibraryStoreRecoveryState = .empty
    @State private var durabilityWarning = false
    @State private var durabilityAttemptWarning = false
    @State private var durabilityAmbiguousWarning = false
    @State private var keyPayload = ""
    @State private var message: String?
    @State private var showingScanner = false
    @State private var showingReturnExporter = false
    @State private var returnQRCode: String?
    @State private var returnExportTask: Task<Void, Never>?
    @State private var returnExportGeneration = 0
    @State private var selectedTab: MobileTab = .tonight
    @State private var showingNearbySync = false
    @State private var nearbySyncState: MobileNearbySyncUIState = .idle
    @State private var nearbySyncSession: NearbyPhoneSyncSession?
    @State private var nearbySyncTask: Task<Void, Never>?
    private let scanner: any MobileQRScanner
    private let fixtureMode: String?
    private let fixtureQRPayload: String?
    private let fixtureRoot: URL?
    @State private var importTask: Task<Void, Never>?
    @State private var fixturePrepared = false
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(store: MobileLibraryStore, stagedPackageURL: Binding<URL?> = .constant(nil), intakeError: Binding<MobileIntakeError?> = .constant(nil), scanner: any MobileQRScanner, fixtureMode: String? = nil, fixtureQRPayload: String? = nil, fixtureRoot: URL? = nil) {
        self.store = store
        _stagedPackageURL = stagedPackageURL
        _intakeError = intakeError
        self.scanner = scanner
        self.fixtureMode = fixtureMode
        self.fixtureQRPayload = fixtureQRPayload
        self.fixtureRoot = fixtureRoot
    }

    @MainActor
    init(store: MobileLibraryStore, stagedPackageURL: Binding<URL?> = .constant(nil), intakeError: Binding<MobileIntakeError?> = .constant(nil), fixtureMode: String? = nil, fixtureQRPayload: String? = nil, fixtureRoot: URL? = nil) {
        self.init(store: store, stagedPackageURL: stagedPackageURL, intakeError: intakeError, scanner: CameraQRScanner(), fixtureMode: fixtureMode, fixtureQRPayload: fixtureQRPayload, fixtureRoot: fixtureRoot)
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
                if let intakeError {
                    HStack {
                        Text(LocalizedStringKey(intakeError.localizedKey)).font(.footnote)
                        Spacer()
                        Button("Dismiss") { self.intakeError = nil; message = nil }
                    }.padding(10).background(.red.opacity(0.15)).accessibilityIdentifier("mobile-intake-error")
                }
                if let message, intakeError == nil {
                    HStack {
                        Text(LocalizedStringKey(message)).font(.footnote)
                        Spacer()
                        Button("Dismiss") { self.message = nil }
                    }
                    .padding(10)
                    .background(.red.opacity(0.15))
                    .accessibilityIdentifier("mobile-action-error")
                }
                if durabilityWarning || durabilityAttemptWarning || durabilityAmbiguousWarning {
                    Label(durabilityWarning ? "The latest change was saved, but iPhone storage needs attention. Keep the app open and make a backup before the next import." : durabilityAttemptWarning ? "A save attempt may need attention. Keep the app open and try the same action again." : "AstroTool could not confirm whether the latest save reached iPhone storage. Keep this iPhone data unchanged and restore from a trusted backup before retrying.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.2))
                        .accessibilityIdentifier("mobile-durability-warning")
                }
                if stagedPackageURL != nil && snapshot != nil {
                    Button {
                        selectedTab = .sync
                    } label: {
                        Label("A newer plan is ready to review in Sync.", systemImage: "arrow.down.circle")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("mobile-staged-update-banner")
                }
                }
            }
            .navigationTitle("AstroTool")
            .fileExporter(
                isPresented: $showingReturnExporter,
                document: MobileReturnPackagePlaceholderDocument(),
                contentType: .astroMobile,
                defaultFilename: "AstroTool-iPhone-changes"
            ) { result in
                switch result {
                case .success(let url):
                    let placeholder: MobileReturnPackagePlaceholderDocument.Identity
                    do {
                        placeholder = try MobileReturnPackagePlaceholderDocument.retainPlaceholder(at: url)
                    } catch {
                        message = "The return package was not created. Your queued changes are still here."
                        return
                    }
                    returnExportGeneration &+= 1
                    let exportGeneration = returnExportGeneration
                    returnExportTask = Task { @MainActor in
                        do {
                            try Task.checkCancellation()
                            try MobileReturnPackagePlaceholderDocument.removePlaceholder(at: url, retaining: placeholder)
                            let exported = try await store.exportReturnPackage(to: url)
                            try Task.checkCancellation()
                            guard exportGeneration == returnExportGeneration else { return }
                            returnQRCode = exported.oneTimeQRPayload
                            message = "Ready to import on Mac. Your queued changes remain here until the Mac confirms them."
                            await refresh()
                        } catch is CancellationError {
                        } catch {
                            guard exportGeneration == returnExportGeneration else { return }
                            message = "The return package was not created. Your queued changes are still here."
                        }
                        if exportGeneration == returnExportGeneration {
                            returnExportTask = nil
                        }
                    }
                case .failure(let error):
                    guard (error as NSError).code != NSUserCancelledError else { return }
                    message = "The return package was not created. Your queued changes are still here."
                }
            }
            .task {
                await refresh()
                message = intakeError?.localizedKey
                if let fixtureQRPayload { keyPayload = fixtureQRPayload }
                await prepareImportedFixtureIfNeeded()
            }
            .onChange(of: intakeError) { _, next in message = next?.localizedKey }
            .onChange(of: stagedPackageURL) { _, _ in }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    keyPayload = ""
                    scanner.stop()
                    importTask?.cancel()
                    importTask = nil
                    showingScanner = false
                    cancelReturnExport()
                    showingReturnExporter = false
                } else {
                    Task { await refresh() }
                }
            }
            .onDisappear {
                cancelReturnExport()
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
            .sheet(isPresented: $showingNearbySync, onDismiss: { cancelNearbySync() }) {
                MobileNearbySyncScreen(
                    state: nearbySyncState,
                    onStart: startNearbySync,
                    onConfirmCode: confirmNearbySyncCode,
                    onRejectCode: rejectNearbySyncCode,
                    onCancel: { showingNearbySync = false },
                    onRetry: startNearbySync,
                    onOpenSettings: openNearbySyncSettings,
                    onUseAirDropInstead: { showingNearbySync = false },
                    onDone: {
                        showingNearbySync = false
                        Task { await refresh() }
                    }
                )
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
                Button("Connect to my Mac") { showingNearbySync = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v5.mobile.nearby.open")
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
        }
    }

    private func libraryState(_ snapshot: MobileLibrarySnapshot) -> some View {
        TabView(selection: $selectedTab) {
            TonightMobileView(snapshot: snapshot, changes: changes, store: store, onStoreChange: refresh)
                .tabItem { Label("Tonight", systemImage: "moon.stars.fill") }
                .tag(MobileTab.tonight)
            ProjectsMobileView(snapshot: snapshot, changes: changes, store: store, onStoreChange: refresh)
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up.fill") }
                .tag(MobileTab.projects)
            BriefingsMobileView(snapshot: snapshot, changes: changes, store: store, onStoreChange: refresh)
                .tabItem { Label("Briefings", systemImage: "doc.text.fill") }
                .tag(MobileTab.briefings)
            SyncMobileView(snapshot: snapshot, changes: changes, queuedChangeCount: queuedChangeCount, stagedPackageURL: stagedPackageURL, onScan: { showingScanner = true }, onImport: primaryImportAction, onDiscard: discardStagedPackage, onExport: { showingReturnExporter = true }, onCancelExport: cancelReturnExport, onDiscardReturnExport: discardReturnExport, isExporting: returnExportTask != nil, returnQRCode: returnQRCode, onNearbySync: { showingNearbySync = true })
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(MobileTab.sync)
        }
        .accessibilityIdentifier("mobile-imported-state")
    }

    private func refresh() async {
        snapshot = await store.activeSnapshot
        changes = await store.queuedChanges
        queuedChangeCount = await store.queuedChanges.count
        recoveryState = await store.recoveryState
        durabilityWarning = await store.durabilityWarning
        durabilityAttemptWarning = await store.durabilityAttemptWarning
        durabilityAmbiguousWarning = await store.durabilityAmbiguousWarning
        stagedPackageURL = await store.stagedPackageURL
        returnQRCode = await store.recoverableReturnExport?.oneTimeQRPayload
    }

    /// Starts (or, called again from a `.failed` state, retries) exactly one
    /// nearby session. A received plan enters through the SAME two store
    /// routes the AirDrop path uses (`stagePackage` then
    /// `importCurrentStagedPackage`, here with the received `pairedDevice`
    /// key instead of a scanned QR payload); a queued reply leaves through
    /// the unmodified `exportReturnPackage`. Neither route is new — this
    /// only adds a second way to reach them.
    private func startNearbySync() {
        guard nearbySyncSession == nil else { return }
        let currentStore = store
        do {
            let session = try NearbyPhoneSyncSession(rootURL: currentStore.applicationSupportURL, displayName: UIDevice.current.name)
            nearbySyncSession = session
            nearbySyncTask = Task { @MainActor in
                let stream = await session.run(handleForwardPackage: { directory, wrapping in
                    try await currentStore.stagePackage(from: directory)
                    try await currentStore.importCurrentStagedPackage(pairedWrapping: wrapping)
                    return try await Self.nearbyReturnPackage(store: currentStore)
                })
                for await state in stream {
                    nearbySyncState = MobileNearbySyncUIState(state)
                    if case .staged = state {
                        await refresh()
                    }
                }
                await Self.clearNearbyReturnStaging(store: currentStore)
                nearbySyncSession = nil
                nearbySyncTask = nil
            }
        } catch {
            nearbySyncState = .failed(.peerNotFound)
        }
    }

    private func confirmNearbySyncCode() {
        guard let nearbySyncSession else { return }
        Task { await nearbySyncSession.confirmPairing() }
    }

    private func rejectNearbySyncCode() {
        guard let nearbySyncSession else { return }
        Task { await nearbySyncSession.rejectPairing() }
    }

    private func cancelNearbySync() {
        if let nearbySyncSession {
            Task { await nearbySyncSession.cancel() }
        }
        nearbySyncTask?.cancel()
        nearbySyncTask = nil
        nearbySyncSession = nil
        nearbySyncState = .idle
    }

    private func openNearbySyncSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Builds the phone's reply from its own queued checklist/note changes,
    /// through the unmodified `exportReturnPackage` — export still never
    /// clears the queue — then carries its one-time key over the nearby
    /// session as a `pairedDevice`-style key built from the exact same raw
    /// bytes (see `OneTimePackageKey.rawRepresentation`'s own doc comment
    /// for why that is sound). Returns `nil`, meaning "nothing to send
    /// back", when there is nothing queued.
    private static func nearbyReturnPackage(store: MobileLibraryStore) async throws -> NearbyPhoneReturnPackage? {
        guard await !store.queuedChanges.isEmpty else { return nil }
        let outboxRoot = store.applicationSupportURL.appendingPathComponent(
            ".astro-tool/nearby-return-outbox/\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: outboxRoot, withIntermediateDirectories: true)
        let destination = outboxRoot.appendingPathComponent("package.astromobile", isDirectory: true)
        let exported = try await store.exportReturnPackage(to: destination)
        let oneTimeKey = try OneTimePackageKey(scanning: exported.oneTimeQRPayload)
        let wrapping = try PairedDeviceKeyWrapping(rawRepresentation: oneTimeKey.rawRepresentation)
        return NearbyPhoneReturnPackage(packageDirectory: destination, packageID: exported.packageID, wrapping: wrapping)
    }

    private static func clearNearbyReturnStaging(store: MobileLibraryStore) async {
        let outboxRoot = store.applicationSupportURL.appendingPathComponent(".astro-tool/nearby-return-outbox", isDirectory: true)
        try? FileManager.default.removeItem(at: outboxRoot)
    }

    private func cancelReturnExport() {
        returnExportGeneration &+= 1
        returnExportTask?.cancel()
        returnExportTask = nil
    }

    private func discardReturnExport() {
        Task { @MainActor in
            do {
                try await store.discardRecoverableReturnExport()
                returnQRCode = nil
            } catch {
                message = "The saved return code could not be discarded. It remains available for recovery."
                await refresh()
            }
        }
    }

    private func primaryImportAction() {
        if keyPayload.isEmpty {
            showingScanner = true
        } else {
            importPackage()
        }
    }

    private func prepareImportedFixtureIfNeeded() async {
        guard fixtureMode == "imported", !fixturePrepared, let fixtureRoot else { return }
        fixturePrepared = true
        guard await store.stagedPackageURL == nil else { return }
        do {
            guard let current = await store.activeSnapshot else { throw MobileLibraryStoreError.invalidSnapshot }
            let currentData = try MobileJSON.encoder.encode(current)
            guard var object = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                throw MobileLibraryStoreError.invalidSnapshot
            }
            object["revision"] = 2
            let updatedData = try JSONSerialization.data(withJSONObject: object)
            let update = try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: updatedData)
            let source = fixtureRoot.appendingPathComponent("fixture-update.astromobile", isDirectory: true)
            let key = OneTimePackageKey()
            _ = try await MobilePackageService().export(
                MobilePackageEnvelope(snapshot: update, changes: [], acknowledgedChangeIDs: []),
                to: source,
                wrapping: key
            )
            _ = try await store.stagePackage(from: source)
            await refresh()
        } catch {
            // A fixture is test infrastructure. If it cannot establish the
            // real persisted/staged state, fail loudly instead of fabricating
            // a UI-only imported surface or swallowing setup errors.
            fatalError("Could not bootstrap the imported mobile UI fixture: \(error)")
        }
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

private struct MobileReturnPackagePlaceholderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.astroMobile] }
    private static let marker = Data("ASTROTOOL_RETURN_PLACEHOLDER_V1".utf8)

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.existingFile != nil {
            throw MobileLibraryStoreError.persistenceFailed
        }
        return FileWrapper(regularFileWithContents: Self.marker)
    }

    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// The exporter has already created this public placeholder before its
    /// completion callback. Retain its filesystem identity immediately, then
    /// refuse deletion if any later path lookup observes a replacement.
    static func retainPlaceholder(at url: URL) throws -> Identity {
        guard let data = try? Data(contentsOf: url), data == marker else { throw MobileLibraryStoreError.persistenceFailed }
        return try identity(of: url)
    }

    static func removePlaceholder(at url: URL, retaining expected: Identity) throws {
        guard try identity(of: url) == expected,
              let data = try? Data(contentsOf: url), data == marker else {
            throw MobileLibraryStoreError.persistenceFailed
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func identity(of url: URL) throws -> Identity {
        var status = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw MobileLibraryStoreError.persistenceFailed
        }
        return .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}
