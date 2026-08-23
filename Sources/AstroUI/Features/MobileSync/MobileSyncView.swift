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
            guard case .success(let url) = result else { return }
            store.startExport(to: url)
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.astroMobile],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importSource = url
        }
        .onDisappear { store.dismiss() }
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
            railNode(title: "Mac", detail: "Original photos", systemImage: "desktopcomputer", active: store.phase != .importPreviewReady)
            railLine
            railNode(title: "Sealed package", detail: railMiddleDetail, systemImage: "lock.doc", active: store.phase == .exporting || store.phase == .exported)
            railLine
            railNode(title: "iPhone", detail: railPhoneDetail, systemImage: "iphone", active: store.phase == .exported || store.phase == .importPreviewReady)
        }
        .padding(AstroTokens.Spacing.standard)
        .astroRecessedSurface()
        .accessibilityIdentifier("v5.mobile-sync.safety")
    }

    private var railMiddleDetail: LocalizedStringKey {
        switch store.phase {
        case .exported: "Ready to share"
        case .exporting: "Being prepared"
        default: "Only the chosen summary"
        }
    }

    private var railPhoneDetail: LocalizedStringKey {
        switch store.phase {
        case .importPreviewReady: "Preview only"
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
                ProgressView(store.phase == .importing ? "Opening the package safely…" : "Preparing a safe preview…")
                Button("Cancel", role: .cancel) { store.cancel() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .ready:
            readyContent
        case .exporting:
            exportingContent
        case .exported:
            exportedContent
        case .importPreviewReady:
            incomingContent
        case .failed:
            failedContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Understand what will move").astroSectionTitle()
            Text("Projects, nights, image-set summaries, night plans, checklist items, and notes can move. Original photos and files never move.")
                .astroBody()
            HStack {
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
                        TextField("One-time unlock code", text: $importCode)
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
                Button("Cancel", role: .cancel) { store.cancel() }
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
            ProgressView("Creating the sealed package…")
            Text("The original photos remain on the Mac while this package is prepared.")
                .font(.callout).foregroundStyle(AstroTokens.Color.inkDim)
            Button("Cancel", role: .cancel) { store.cancel() }
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
        .astroRaisedSurface()
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
            Button("Send another package") { store.reset() }
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
    }

    private var incomingContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            if let incoming = store.incomingPreview {
                Text("Package preview").astroSectionTitle()
                summaryGrid(incoming.snapshotSummary)
                LabeledContent("Package", value: incoming.packageID.uuidString)
                LabeledContent("Encrypted size", value: ByteCountFormatter.string(fromByteCount: incoming.encryptedByteCount, countStyle: .file))
                LabeledContent("Incoming changes", value: incoming.incomingChanges.count.formatted())
                Text("Applying changes will be confirmed separately. Nothing in the image library has changed.")
                    .astroBody()
                    .foregroundStyle(AstroTokens.Color.attention)
            }
            Button("Done") { store.cancel() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile-sync.cancel")
        }
        .astroRaisedSurface()
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Label(store.errorMessage ?? "Something needs attention.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AstroTokens.Color.critical)
                .accessibilityIdentifier("v5.mobile-sync.error")
            HStack {
                Button("Try again", systemImage: "arrow.clockwise") {
                    store.startRetry()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v5.mobile-sync.error.retry")
                Button("Cancel", role: .cancel) { store.cancel() }
                    .accessibilityIdentifier("v5.mobile-sync.cancel")
            }
        }
        .astroRaisedSurface()
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
