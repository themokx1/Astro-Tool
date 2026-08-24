import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import AstroMobileDomain
import AstroApplication

public struct MobileSyncView: View {
    @State private var store: MobileSyncStore
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var importSource: URL?
    @State private var importCode = ""
    @State private var qrRetry = 0
    @State private var showsReturnConfirmation = false

    public init(
        rootURL: URL?,
        store: MobileSyncStore? = nil,
        snapshotProvider: MobileSyncStore.SnapshotProvider? = nil
    ) {
        _store = State(initialValue: store ?? MobileSyncStore(
            rootURL: rootURL,
            snapshotProvider: snapshotProvider
        ))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                title
                safetyRail
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.ground)
        .navigationTitle("iPhone Sync")
        .astroSectionMarker("v5.mobile-sync.open", label: "iPhone Sync")
        .fileExporter(
            isPresented: $showsExporter,
            document: MobilePackagePlaceholderDocument(token: store.destinationToken),
            contentType: .astroMobile,
            defaultFilename: "AstroTool-iPhone"
        ) { result in
            switch result {
            case .success(let url):
                store.startExport(to: url)
            case .failure(let error):
                let nsError = error as NSError
                guard nsError.code != NSUserCancelledError else { return }
                store.recordExporterFailure()
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.astroMobile],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importSource = url
            importCode = ""
        }
        .interactiveDismissDisabled(store.phase == .exporting || store.phase == .finishing || store.phase == .applying)
        .onChange(of: store.phase) { _, phase in
            if phase == .importPreviewReady || phase == .completed {
                clearIncomingSelection()
            }
        }
        .onDisappear {
            clearIncomingSelection()
            store.dismiss()
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Send your library summary to iPhone")
                .astroDisplay()
            Text("Choose exactly what the phone can read, then send a sealed package. Original photos stay on this Mac.")
                .astroBody()
                .foregroundStyle(AstroTokens.Color.inkDim)
        }
    }

    private var safetyRail: some View {
        HStack(alignment: .top, spacing: 0) {
            railNode(title: "Mac", detail: "Original photos", systemImage: "desktopcomputer", active: store.phase != .importPreviewReady && store.phase != .completed)
            railLine
            railNode(title: "Sealed package", detail: railMiddleDetail, systemImage: "lock.doc", active: store.phase == .exporting || store.phase == .finishing || store.phase == .exported)
            railLine
            railNode(title: "iPhone", detail: railPhoneDetail, systemImage: "iphone", active: store.phase == .exported || store.phase == .importPreviewReady || store.phase == .completed)
        }
        .padding(AstroTokens.Spacing.standard)
        .astroRecessedSurface()
        .accessibilityIdentifier("v5.mobile-sync.safety")
    }

    private var railMiddleDetail: LocalizedStringKey {
        switch store.phase {
        case .exported: "Ready to share"
        case .exporting: "Being prepared"
        case .finishing: "Finishing safely"
        default: "Only the chosen summary"
        }
    }

    private var railPhoneDetail: LocalizedStringKey {
        switch store.phase {
        case .importPreviewReady: "Preview only"
        case .completed: "Changes saved"
        case .exported: "Unlock with the code"
        default: "No original photos"
        }
    }

    private func railNode(title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(active ? AstroTokens.Color.accent : AstroTokens.Color.inkFaint)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(AstroTokens.Color.inkDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var railLine: some View {
        Image(systemName: "arrow.right")
            .foregroundStyle(AstroTokens.Color.inkFaint)
            .frame(width: 30)
            .padding(.top, 9)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            idleContent
        case .previewing, .importing:
            VStack(spacing: AstroTokens.Spacing.standard) {
                ProgressView(preparationProgressTitle)
                Button("Cancel", role: .cancel) { cancelAndClear() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .ready:
            readyContent
        case .exporting, .finishing:
            exportingContent
        case .applying:
            applyingContent
        case .exported:
            exportedContent
        case .importPreviewReady:
            incomingContent
        case .completed:
            completedContent
        case .discarding:
            discardingContent
        case .failed:
            failedContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Understand what will move").astroSectionTitle()
            Text("Projects, nights, image-set summaries, night plans, checklist items, and notes can move. Original photos and files never move.")
                .astroBody()
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                Button("Review what will move", systemImage: "eye") {
                    store.startPreview()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("v5.mobile-sync.export")
                Button("Preview a package…", systemImage: "arrow.down.doc") { showsImporter = true }
                    .accessibilityIdentifier("v5.mobile-sync.import")
                if let importSource {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Package selected", systemImage: "doc.badge.arrow.down")
                        SecureField("One-time unlock code", text: $importCode)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("v5.mobile-sync.import-code")
                        Button("Preview package", systemImage: "eye") {
                            let code = importCode
                            store.startIncomingPreview(from: importSource, qrPayload: code)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(importCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .astroRaisedSurface()
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            understandBlock
            if let preview = store.preview {
                reviewBlock(preview)
            }
            Text("Original photos are not transferred. iPhone cannot modify files in the image library.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.ok)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("v5.mobile-sync.safety.promise")
            HStack {
                Button("Cancel", role: .cancel) { cancelAndClear() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
                Spacer()
                if let preview = store.preview, !preview.identity.alreadyExists, !store.isIdentityConfirmed {
                    Button("Confirm library identity") { store.confirmIdentity(preview.identity.proposedID) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("v5.mobile-sync.confirm-identity")
                } else if !store.isSummaryConfirmed {
                    Button("Confirm this summary") {
                        if let token = store.preview?.confirmationToken { store.confirmSummary(token) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isIdentityConfirmed)
                    .accessibilityIdentifier("v5.mobile-sync.confirm-summary")
                } else {
                    Button("Create sealed package…") { showsExporter = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v5.mobile-sync.export")
                }
            }
        }
    }

    private var understandBlock: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Understand").astroSectionTitle()
            Label("Moves: projects, nights, image-set summaries, night plans, checklist items, and notes.", systemImage: "checkmark.circle")
            Label("Stays on the Mac: original photos and files.", systemImage: "lock.shield")
        }
        .astroRaisedSurface()
    }

    private func reviewBlock(_ preview: MobileSyncPreview) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Review").astroSectionTitle()
            Text("Check the exact summary before anything is created.").astroBody().foregroundStyle(AstroTokens.Color.inkDim)
            summaryGrid(preview.snapshotSummary)
            LabeledContent("Freshness", value: preview.snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
            Text(String(localized: "Updated \(preview.snapshot.createdAt.formatted(.relative(presentation: .named)))"))
                .font(.caption)
                .foregroundStyle(AstroTokens.Color.inkDim)
            if preview.identity.alreadyExists {
                Label("This Mac already has a confirmed library identity.", systemImage: "checkmark.shield")
            } else {
                Label("The first send will create one small identity for this library after you confirm it.", systemImage: "person.badge.key")
            }
            Label("The destination must be new; an existing package is never replaced.", systemImage: "doc.badge.plus")
        }
        .astroRaisedSurface()
    }

    private func summaryGrid(_ summary: MobileSnapshotSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            count("Projects", summary.projectCount)
            count("Nights", summary.nightCount)
            count("Captures", summary.captureCount)
            count("Briefings", summary.briefingCount)
            count("Notes", summary.noteCount)
            count("Checklist items", summary.checklistItemCount)
        }
    }

    private func count(_ title: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value, format: .number).astroData()
            Text(title).font(.caption).foregroundStyle(AstroTokens.Color.inkDim)
        }
    }

    private var exportingContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            ProgressView(exportProgressTitle)
            Text("The original photos remain on the Mac while this package is prepared.")
                .font(.callout).foregroundStyle(AstroTokens.Color.inkDim)
            if store.phase == .exporting {
                Button("Cancel", role: .cancel) { cancelAndClear() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
            } else {
                Label("The package is being published safely. Please wait.", systemImage: "lock.shield")
                    .foregroundStyle(AstroTokens.Color.attention)
            }
        }
        .astroRaisedSurface()
    }

    private var applyingContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            ProgressView("Applying the reviewed changes…")
            Text("The Mac is writing only the reviewed checklist and note commands. Keep this window open until the receipt is saved.")
                .font(.callout)
                .foregroundStyle(AstroTokens.Color.inkDim)
        }
        .astroRaisedSurface()
        .accessibilityIdentifier("v5.mobile-sync.return.applying")
    }

    private var discardingContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            ProgressView("Cleaning up securely…")
            Text("The package preview is being cleared before another action can start.")
                .font(.callout)
                .foregroundStyle(AstroTokens.Color.inkDim)
        }
        .astroRaisedSurface()
    }

    private var exportProgressTitle: LocalizedStringKey {
        store.phase == .finishing ? "Finishing the sealed package…" : "Creating the sealed package…"
    }

    private var preparationProgressTitle: LocalizedStringKey {
        store.phase == .importing ? "Opening the package safely…" : "Preparing a safe preview…"
    }

    private var exportedContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            Label("Package ready to share", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.ok)
            Text("Use AirDrop or another method to share the file. AstroTool does not send it automatically.")
                .astroBody()
            if let encryptedByteCount = store.encryptedByteCount {
                Text("Encrypted size: \(ByteCountFormatter.string(fromByteCount: encryptedByteCount, countStyle: .file))")
                    .astroData()
            }
            if let qrCodeValue = store.oneTimeQRPayload {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    Text("Unlock on iPhone").astroSectionTitle()
                    Text("After receiving the package, scan this code in AstroTool on your iPhone. The code unlocks this package only.")
                        .astroBody()
                    QRCodeView(value: qrCodeValue, onRetry: { qrRetry += 1 })
                        .id(qrRetry)
                        .frame(width: 260, height: 260)
                        .accessibilityIdentifier("v5.mobile-sync.qr")
                        .accessibilityLabel("After receiving the package, scan this code in AstroTool on your iPhone. The code unlocks this package only.")
                }
                .astroRaisedSurface()
            }
            Button("Send another package") { resetAndClear() }
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
    }

    private var incomingContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            if let incoming = store.incomingPreview {
                Text("Package preview").astroSectionTitle()
                summaryGrid(incoming.snapshotSummary)
                packageIDRow(incoming.packageID)
                LabeledContent("Encrypted size", value: ByteCountFormatter.string(fromByteCount: incoming.encryptedByteCount, countStyle: .file))
                LabeledContent("Incoming changes", value: incoming.incomingChanges.count.formatted())
                if let changes = store.changePreview {
                    LabeledContent("Ready to apply", value: changes.applicable.count.formatted())
                    LabeledContent("Needs your choice", value: changes.conflicts.count.formatted())
                    LabeledContent("Already handled", value: changes.alreadyApplied.count.formatted())
                    LabeledContent("Superseded", value: changes.superseded.count.formatted())
                    LabeledContent("Duplicates", value: changes.duplicates.count.formatted())
                    LabeledContent("Not imported", value: changes.rejected.count.formatted())
                    if !changes.duplicates.isEmpty {
                        Label("Duplicate change IDs were shown for review and were not applied.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    if !changes.superseded.isEmpty {
                        Label("Older edits were superseded by the latest edit for the same target.", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    ForEach(changes.rejected, id: \.changeID) { rejected in
                        Label(rejectionMessage(rejected), systemImage: "nosign")
                            .font(.caption)
                            .foregroundStyle(AstroTokens.Color.critical)
                    }
                    if !changes.conflicts.isEmpty {
                        Text("Choose what to do with each conflict. Notes default to Keep both as field note.")
                            .astroBody()
                            .foregroundStyle(AstroTokens.Color.attention)
                        ForEach(changes.conflicts, id: \.changeID) { conflict in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conflict.targetName).font(.headline)
                                if conflict.kind == .checklist {
                                    Text("Mac: \(conflict.macChecklistCompletion == true ? "Complete" : "Not complete") · iPhone: \(conflict.phoneChecklistCompletion == true ? "Complete" : "Not complete")")
                                } else {
                                    Text("Mac: \(conflict.macText ?? "")")
                                    Text("iPhone: \(conflict.phoneText ?? "")")
                                }
                                Text("Mac \(conflict.macTimestamp.formatted(date: .abbreviated, time: .shortened)) · iPhone \(conflict.phoneTimestamp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("Resolution", selection: resolutionBinding(for: conflict)) {
                                    Text("Apply iPhone").tag(MobileChangeResolution.applyPhone)
                                    Text("Keep Mac").tag(MobileChangeResolution.keepMac)
                                    if conflict.kind == .note { Text("Keep both as field note").tag(MobileChangeResolution.keepBothAsFieldNote) }
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("v5.mobile-sync.return.conflict.\(conflict.changeID.uuidString)")
                        }
                    }
                    if !store.didApplyIncomingChanges {
                        Button("Apply reviewed changes") { showsReturnConfirmation = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!changes.conflicts.allSatisfy { store.changeResolutions[$0.changeID] != nil })
                            .accessibilityLabel("Apply reviewed iPhone changes")
                            .accessibilityHint("Shows a final confirmation before saving checklist and note changes.")
                            .accessibilityIdentifier("v5.mobile-sync.return.apply")
                    }
                }
                Text("Applying changes will be confirmed separately. Nothing in the image library has changed.")
                    .astroBody()
                    .foregroundStyle(AstroTokens.Color.attention)
                Text("Checklist and notes only. Original photos stay on this Mac or external drive. Mac review is required; there is no automatic or cloud sync.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AstroTokens.Color.ok)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v5.mobile-sync.return.safety")
                if let totals = store.receiptTotals {
                    Text("Applied \(totals.applied), kept on Mac \(totals.keptOnMac), superseded \(totals.superseded), already handled \(totals.alreadyHandled), duplicates \(totals.duplicates), rejected \(totals.rejected). A new Mac-to-iPhone package is needed to acknowledge phone changes.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AstroTokens.Color.ok)
                        .accessibilityLabel("Return import result")
                        .accessibilityValue("Applied \(totals.applied), kept on Mac \(totals.keptOnMac), superseded \(totals.superseded), already handled \(totals.alreadyHandled), duplicates \(totals.duplicates), rejected \(totals.rejected)")
                        .accessibilityIdentifier("v5.mobile-sync.return.result")
                }
            }
            Button("Done") { cancelAndClear() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
        .astroRaisedSurface()
        .confirmationDialog("Apply these reviewed checklist and note changes?", isPresented: $showsReturnConfirmation, titleVisibility: .visible) {
            Button("Apply changes") {
                Task {
                    do {
                        try await store.applyAuthenticatedReturnChanges(confirmed: true)
                    } catch {
                        // The store retains the user-visible failure and leaves
                        // the phone queue unacknowledged when apply or receipt
                        // persistence fails.
                    }
                }
            }
            .accessibilityIdentifier("v5.mobile-sync.return.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mac review is required. Original photos stay on this Mac.")
        }
    }

    private var completedContent: some View {
        let totals = store.appliedChangeTotals
        return VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Label("Reviewed changes saved", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.ok)
            Text("Applied \(totals.applied), kept on Mac \(totals.keptOnMac), superseded \(totals.superseded), already handled \(totals.alreadyHandled), duplicates \(totals.duplicates), rejected \(totals.rejected). A new Mac-to-iPhone package will acknowledge these outcomes.")
                .font(.callout.weight(.semibold))
                .accessibilityLabel("Return import result")
                .accessibilityValue("Applied \(totals.applied), kept on Mac \(totals.keptOnMac), superseded \(totals.superseded), already handled \(totals.alreadyHandled), duplicates \(totals.duplicates), rejected \(totals.rejected)")
                .accessibilityIdentifier("v5.mobile-sync.return.result")
            Button("Done") { cancelAndClear() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
        .astroRaisedSurface()
    }

    private func resolutionBinding(for conflict: MobileChangeConflict) -> Binding<MobileChangeResolution> {
        Binding(
            get: { store.changeResolutions[conflict.changeID] ?? conflict.recommendedResolution },
            set: { store.setChangeResolution($0, for: conflict.changeID) }
        )
    }

    private func rejectionMessage(_ rejected: MobileRejectedChange) -> LocalizedStringKey {
        switch rejected.reason {
        case .duplicateChangeID: "Duplicate change ID: none of those records was applied."
        case .unknownTarget: "The target is no longer available on this Mac."
        case .noTextToImport: "The phone note was empty and was not imported."
        case .malformedChange: "The change record was incomplete."
        case .crossDeviceQueue: "The package contains changes from more than one phone."
        default: "This change was not accepted."
        }
    }

    private func packageIDRow(_ packageID: UUID) -> some View {
        let value = packageID.uuidString
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AstroTokens.Spacing.standard) {
                Text("Package")
                Spacer(minLength: AstroTokens.Spacing.compact)
                packageIDValue(value)
                    .lineLimit(1)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Package")
                    .font(.caption)
                    .foregroundStyle(AstroTokens.Color.inkDim)
                packageIDValue(value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func packageIDValue(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("v5.mobile-sync.package-id")
            .accessibilityLabel("Package ID")
            .accessibilityValue(Text(verbatim: value))
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Label(store.errorMessage ?? "Something needs attention.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AstroTokens.Color.critical)
                .accessibilityIdentifier("v5.mobile-sync.error")
            if let receipt = store.appliedChangeReceipt, !receipt.appliedChangeIDs.isEmpty || !receipt.resolvedChangeIDs.isEmpty {
                Text("Saved before failure: applied \(receipt.appliedChangeIDs.count), resolved \(receipt.resolvedChangeIDs.count). Keep the phone package, recover the Mac receipt, then create a fresh forward snapshot.")
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("v5.mobile-sync.partial-receipt")
            }
            HStack {
                Button("Try again", systemImage: "arrow.clockwise") {
                    store.startRetry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile-sync.error.retry")
                Button("Cancel", role: .cancel) { cancelAndClear() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
            }
        }
        .astroRaisedSurface()
    }

    private func clearIncomingSelection() {
        importSource = nil
        importCode = ""
    }

    private func cancelAndClear() {
        clearIncomingSelection()
        store.cancel()
    }

    private func resetAndClear() {
        clearIncomingSelection()
        store.reset()
    }
}

private struct QRCodeView: View {
    let value: String
    let onRetry: () -> Void

    var body: some View {
        Group {
            if let image = Self.image(for: value) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
            } else {
                VStack(spacing: 8) {
                    Label("The unlock code image could not be created.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AstroTokens.Color.critical)
                        .multilineTextAlignment(.center)
                    Button("Try again", action: onRetry)
                }
            }
        }
        .padding(48)
        .background(AstroTokens.Color.qrBackground)
        .clipShape(RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel, style: .continuous))
    }

    private static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scale = 12.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

enum MobileSyncFileExportError: Error, Equatable {
    case existingDestination
}

struct MobilePackagePlaceholderDocument: FileDocument {
    let token: String
    static var readableContentTypes: [UTType] { [.astroMobile] }

    init(token: String) { self.token = token }

    init(configuration: ReadConfiguration) throws { token = "read" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // SwiftUI may ask for a replacement wrapper after the user chooses
        // Replace. Reject that request before it can touch an existing package;
        // Task 3 performs the final exclusive publication itself.
        if configuration.existingFile != nil {
            throw MobileSyncFileExportError.existingDestination
        }
        return FileWrapper(directoryWithFileWrappers: [MobileSyncDestinationCoordinator.placeholderName(for: token): FileWrapper(regularFileWithContents: Data())])
    }
}
