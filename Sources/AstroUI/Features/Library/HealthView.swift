import AstroApplication
import AstroCore
import Observation
import SwiftUI

public struct HealthView: View {
    let rootURL: URL?
    let chooseLibrary: () -> Void
    let openCalibration: () -> Void
    let accessMode: LibraryAccessMode
    /// Wave 4 Task 1: Cleanup Preview and Sensor Profiles are now routes
    /// `V2RootView`'s `DetailHost` pushes (they used to be nested inside
    /// this view's own `.overlay`) -- these two just ask the router to push
    /// them.
    let openCleanup: () -> Void
    let openSensorProfiles: () -> Void
    @Bindable var store: LibraryHealthStore
    @Environment(OperationHost.self) private var operationHost

    public init(
        rootURL: URL?,
        chooseLibrary: @escaping () -> Void,
        openCalibration: @escaping () -> Void,
        accessMode: LibraryAccessMode = .readOnly,
        openCleanup: @escaping () -> Void = {},
        openSensorProfiles: @escaping () -> Void = {},
        store: LibraryHealthStore = LibraryHealthStore()
    ) {
        self.rootURL = rootURL
        self.chooseLibrary = chooseLibrary
        self.openCalibration = openCalibration
        self.accessMode = accessMode
        self.openCleanup = openCleanup
        self.openSensorProfiles = openSensorProfiles
        self.store = store
    }
    @State private var showsVerifySheet = false
    @State private var category: LibraryHealthCategory?
    @State private var selectedFindingID: String?
    @State private var acknowledgeRequest: AcknowledgeRequest?

    public var body: some View {
        WorkspacePage(eyebrow: "Read-only diagnostics", title: "Library Health", subtitle: "Actionable calibration and integrity checks without changing source files.") {
            if let snapshot = store.snapshot {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Sessions", value: "\(snapshot.sessionCount)", detail: "Indexed nights", systemImage: "moon.stars")
                    MetricCard(title: "Calibration", value: "\(snapshot.calibrationIssues)", detail: "Needs attention", systemImage: "exclamationmark.triangle")
                    MetricCard(title: "Duplicates", value: "\(snapshot.duplicateFiles)", detail: "Additional copies", systemImage: "square.on.square")
                    MetricCard(title: "Organization", value: "\(snapshot.organizationIssues)", detail: "Reviewable residue", systemImage: "tray.full")
                    MetricCard(title: "Access", value: snapshot.isReadOnly ? "Read only" : "Writable", detail: "Images protected", systemImage: "lock.shield")
                }
                HStack {
                    Menu("Run Audit") {
                        Button("Fast (Skip Duplicate Scan)") {
                            Task { await store.runAudit(mode: .fast, rootURL: rootURL, operationHost: operationHost) }
                        }
                    } primaryAction: {
                        Task { await store.runAudit(mode: .full, rootURL: rootURL, operationHost: operationHost) }
                    }
                    .disabled(rootURL == nil || runningAuditOperation != nil)
                    .help("Scan the library for calibration gaps, duplicates, and organization issues")
                    .accessibilityIdentifier("v2.health.run-audit")

                    Button("Verify Integrity…") { showsVerifySheet = true }
                        .buttonStyle(.bordered)
                        .disabled(rootURL == nil || runningVerifyOperation != nil)
                        .help("Re-hash indexed files and compare against their stored checksums")
                        .accessibilityIdentifier("v2.health.verify")

                    Spacer()
                }
                if let running = runningAuditOperation {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(running.title).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { Task { await operationHost.cancel(id: running.id) } }
                    }
                }
                if let running = runningVerifyOperation {
                    HStack {
                        ProgressView(value: running.total.map { Double(running.completed) / Double(max($0, 1)) })
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                        Text(running.title).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { Task { await operationHost.cancel(id: running.id) } }
                    }
                }
                HStack {
                    Picker("Category", selection: $category) {
                        Text("All findings").tag(LibraryHealthCategory?.none)
                        ForEach(LibraryHealthCategory.allCases, id: \.rawValue) { value in
                            Text(value.rawValue.capitalized).tag(Optional(value))
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("v2.health.categories")
                    Toggle("Show Acknowledged", isOn: Binding(
                        get: { store.showAcknowledged },
                        set: { value in Task { await store.setShowAcknowledged(value) } }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("v2.health.show-acknowledged")
                }
                GroupBox("Health findings") {
                    Table(filteredItems(snapshot), selection: $selectedFindingID) {
                        TableColumn("Finding") { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(item.severity)).foregroundStyle(color(item.severity))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(item.title).font(.headline)
                                        if item.isAcknowledged {
                                            Label("Acknowledged", systemImage: "checkmark.seal")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .opacity(item.isAcknowledged ? 0.6 : 1)
                        }
                        TableColumn("Target / Night") { item in
                            Text([item.target, item.sessionDate].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
                                .font(.callout.monospaced())
                        }
                        .width(min: 145, ideal: 190)
                        TableColumn("Category") { item in
                            Text(item.category.rawValue.capitalized)
                        }
                        .width(min: 90, ideal: 110)
                        TableColumn("Next step") { item in
                            Text(nextStep(item.category)).foregroundStyle(AstroTokens.Color.spectralBlue)
                        }
                        .width(min: 115, ideal: 145)
                    }
                    .frame(minHeight: 250)
                    .contextMenu(forSelectionType: String.self) { findingIDs in
                        if let item = filteredItems(snapshot).first(where: { findingIDs.contains($0.id) }) {
                            healthActionMenu(item)
                        }
                    }
                    .accessibilityIdentifier("v2.health.findings-table")
                }
                HStack {
                    Button("Review Cleanup Candidates…", action: openCleanup).buttonStyle(.bordered)
                    Button("Sensor Profiles…", action: openSensorProfiles).buttonStyle(.bordered)
                    Button("Calibration…", action: openCalibration).buttonStyle(.bordered)
                }
                GroupBox("Audit run history") {
                    if snapshot.auditRuns.isEmpty {
                        Text("No recorded audit runs yet.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(snapshot.auditRuns.enumerated()), id: \.offset) { _, run in
                                HStack {
                                    Text(run.ranAt, style: .date).font(.callout.monospaced())
                                    Text("\(run.findingCount) finding(s)").foregroundStyle(.secondary)
                                    Spacer()
                                    Text("+\(run.newCount) new").foregroundStyle(.orange)
                                    Text("−\(run.resolvedCount) resolved").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("v2.health.audit-history")
            } else if store.isLoading {
                ProgressView("Checking library health…").frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ContentUnavailableView {
                    Label("No library open", systemImage: "externaldrive.badge.questionmark")
                } description: { Text(store.errorMessage ?? "Choose an image library to run read-only health checks.") }
                actions: { Button("Choose Image Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                .frame(minHeight: 300)
            }
        }
        .task(id: rootURL) { if let rootURL { await store.load(rootURL: rootURL) } }
        .navigationTitle("Library Health")
        .accessibilityLabel("Library Health")
        .accessibilityIdentifier("v2.detail.library.health")
        .sheet(item: $acknowledgeRequest) { request in
            AcknowledgeFindingSheet(item: request.item) { note in
                Task { await store.acknowledge(request.item, note: note) }
                acknowledgeRequest = nil
            } onCancel: {
                acknowledgeRequest = nil
            }
        }
        .sheet(isPresented: $showsVerifySheet) {
            VerifyIntegritySheet(
                onConfirm: { options in
                    showsVerifySheet = false
                    Task { await store.verifyIntegrity(options: options, rootURL: rootURL, operationHost: operationHost) }
                },
                onCancel: { showsVerifySheet = false }
            )
        }
    }

    private var runningAuditOperation: OperationHost.ActiveOperation? {
        guard let rootURL else { return nil }
        let kind = OperationKind.audit(library: rootURL.standardizedFileURL.path)
        return operationHost.activeOperations.first { $0.kind == kind }
    }

    private var runningVerifyOperation: OperationHost.ActiveOperation? {
        guard let rootURL else { return nil }
        let kind = OperationKind.verify(library: rootURL.standardizedFileURL.path)
        return operationHost.activeOperations.first { $0.kind == kind }
    }

    private func icon(_ severity: LibraryHealthSeverity) -> String { severity == .healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    private func color(_ severity: LibraryHealthSeverity) -> Color { severity == .healthy ? .green : .orange }
    private func nextStep(_ category: LibraryHealthCategory) -> String {
        switch category {
        case .flat, .dark, .bias: "Review calibration"
        case .duplicates, .organization, .storage: "Preview cleanup"
        case .integrity: "No action needed"
        }
    }

    private func filteredItems(_ snapshot: LibraryHealthSnapshot) -> [LibraryHealthItem] {
        snapshot.items.filter { category == nil || $0.category == category }
    }

    @ViewBuilder
    private func healthActionMenu(_ item: LibraryHealthItem) -> some View {
        switch item.category {
        case .duplicates, .organization, .storage:
            Button("Preview Cleanup…", action: openCleanup)
        case .flat, .dark, .bias:
            Button("Review Sensor Profiles…", action: openSensorProfiles)
            Button("Open Calibration…", action: openCalibration)
        case .integrity:
            Text("No action required")
        }
        Divider()
        if item.isAcknowledged {
            Button("Revoke Acknowledgement") {
                Task { await store.revokeAcknowledgement(item) }
            }
        } else {
            Button("Mark as Acknowledged…") {
                acknowledgeRequest = AcknowledgeRequest(item: item)
            }
        }
    }
}

private struct AcknowledgeRequest: Identifiable {
    let item: LibraryHealthItem
    var id: String { item.id }
}

private struct AcknowledgeFindingSheet: View {
    let item: LibraryHealthItem
    let onAcknowledge: (String?) -> Void
    let onCancel: () -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Mark as Acknowledged").font(.title3.bold())
            Text(item.title).font(.headline)
            Text(item.detail).font(.callout).foregroundStyle(.secondary)
            TextField("Optional note", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.health.acknowledge-note")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Acknowledge") {
                    onAcknowledge(note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.health.acknowledge-confirm")
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(width: 420)
    }
}

/// V1's "Integritás-ellenőrzés" confirmation sheet (`VerifyConfirmationSheet`)
/// folded into one action: its "Csak minta (10%)" toggle and "Hiányzó
/// összegek pótlása" button become two independent toggles here (see
/// `AuditRunCommand.VerifyRunOptions`'s own doc comment for why V2 combines
/// them into a single "Verify" instead of two separate buttons).
private struct VerifyIntegritySheet: View {
    let onConfirm: (VerifyRunOptions) -> Void
    let onCancel: () -> Void
    @State private var sampleOnly = false
    @State private var fillMissingChecksums = false

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Verify Integrity").font(.title3.bold())
            Text(
                "Re-reads every indexed, previously-hashed file and compares it against its stored "
                    + "checksum. Read-only -- nothing is repaired, moved, or deleted; a mismatch is only "
                    + "ever flagged for you to restore from backup."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Sample only (10%)", isOn: $sampleOnly)
                .accessibilityIdentifier("v2.health.verify.sample")
            Toggle("Fill missing checksums first", isOn: $fillMissingChecksums)
                .accessibilityIdentifier("v2.health.verify.fill-missing")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Verify") {
                    onConfirm(VerifyRunOptions(
                        sampleFraction: sampleOnly ? 0.1 : nil,
                        fillMissingChecksums: fillMissingChecksums
                    ))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("v2.health.verify.confirm")
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(width: 460)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
