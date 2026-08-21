import AstroApplication
import Foundation
import Observation
import SwiftUI

public enum NightBriefingStep: Int, CaseIterable, Identifiable, Sendable {
    case basics
    case targets
    case capture
    case checklist
    case preview

    public var id: Int { rawValue }
}

public struct NightBriefingSeed: Equatable, Sendable {
    public var date: Date
    public var site: BriefingSiteSummary?
    public var setup: BriefingSetupSummary?
    public var target: BriefingTargetBlock?
    public var context: NightBriefingContext
    public var weather: BriefingDataState<BriefingWeatherSummary>

    public init(
        date: Date,
        site: BriefingSiteSummary? = nil,
        setup: BriefingSetupSummary? = nil,
        target: BriefingTargetBlock? = nil,
        context: NightBriefingContext = .init(),
        weather: BriefingDataState<BriefingWeatherSummary> = .missing(reason: "No weather data")
    ) {
        self.date = date
        self.site = site
        self.setup = setup
        self.target = target
        self.context = context
        self.weather = weather
    }
}

@MainActor
@Observable
public final class NightBriefingStore {
    public var draft: NightBriefingDraft {
        didSet { scheduleAutosaveIfNeeded() }
    }
    public var currentStep: NightBriefingStep = .basics
    public var hasStarted = false
    public private(set) var recentDrafts: [NightBriefingDraft] = []
    public private(set) var previewPDF: Data?
    public private(set) var isWorking = false
    public private(set) var message: LocalizedStringKey?
    public private(set) var errorMessage: String?
    public private(set) var previewError: String?

    private let now: () -> Date
    private let revisionStore: NightBriefingRevisionStore?
    private let pdfExporter: any NightBriefingPDFExporting
    private let autosaveDelay: Duration
    private let composer = NightBriefingComposer()
    private var context: NightBriefingContext
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingPersistence = false
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var lastSavedContent: NightBriefingDraft?

    public init(
        now: @autoclosure @escaping () -> Date = Date(),
        revisionStore: NightBriefingRevisionStore? = nil,
        pdfExporter: any NightBriefingPDFExporting = NightBriefingPDFExporter(),
        autosaveDelay: Duration = .milliseconds(800),
        seed: NightBriefingSeed? = nil
    ) {
        self.now = now
        self.revisionStore = revisionStore
        self.pdfExporter = pdfExporter
        self.autosaveDelay = autosaveDelay
        context = seed?.context ?? .init()
        let language: BriefingDocumentLanguage = Locale.current.language.languageCode?.identifier == "hu" ? .hu : .en
        if let seed {
            let targets = seed.target.map { [$0] } ?? []
            let arrival = seed.target?.astronomicalStart ?? seed.target?.start
            let departure = seed.target?.astronomicalEnd ?? seed.target?.end
            draft = NightBriefingDraft(
                savedAt: now(),
                nightDate: seed.date,
                arrival: arrival,
                departure: departure,
                site: seed.site,
                setup: seed.setup,
                weather: seed.weather,
                targets: targets,
                checklist: NightBriefingChecklistTemplate().sections(language: language),
                language: language
            )
            hasStarted = true
        } else {
            draft = NightBriefingDraft(savedAt: now(), language: language)
        }
    }

    public convenience init(
        libraryRoot: URL?,
        seed: NightBriefingSeed? = nil,
        applicationSupport: URL? = nil,
        caches: URL? = nil
    ) {
        let revisionStore: NightBriefingRevisionStore?
        if let libraryRoot {
            let paths: AppStoragePaths? = if let applicationSupport, let caches {
                try? AppStoragePaths(
                    applicationSupport: applicationSupport,
                    caches: caches,
                    libraryID: LibraryIdentity(rootURL: libraryRoot),
                    libraryRoot: libraryRoot
                )
            } else {
                try? AppStoragePaths.production(
                    libraryID: LibraryIdentity(rootURL: libraryRoot),
                    libraryRoot: libraryRoot
                )
            }
            if let paths {
            revisionStore = NightBriefingRevisionStore(directory: paths.briefings)
            } else {
                revisionStore = nil
            }
        } else {
            revisionStore = nil
        }
        self.init(now: Date(), revisionStore: revisionStore, seed: seed)
    }

    public var document: NightBriefingDocument {
        composer.compose(draft: draft, context: context)
    }

    public var canExport: Bool {
        !NightBriefingValidator().validate(draft).blocksExport
    }

    public func startTonight() {
        let date = now()
        reset(date: date)
    }

    public func start(date: Date) {
        reset(date: date)
    }

    public func continueDraft(_ saved: NightBriefingDraft) {
        isApplyingPersistence = true
        draft = saved
        isApplyingPersistence = false
        lastSavedContent = contentIdentity(saved)
        hasStarted = true
        currentStep = .basics
        message = nil
        previewPDF = nil
    }

    public func addTarget() {
        let start = draft.arrival ?? draft.nightDate ?? now()
        let role: BriefingTargetRole = draft.targets.contains(where: { $0.role == .primary }) ? .backup : .primary
        draft.targets.append(.init(name: "", role: role, start: start, end: start.addingTimeInterval(90 * 60)))
    }

    public func removeTarget(id: UUID) {
        draft.targets.removeAll { $0.id == id }
    }

    public func addCustomChecklistItem(title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let item = BriefingChecklistItem(
            id: "custom-\(UUID().uuidString.lowercased())",
            title: clean,
            isBuiltIn: false
        )
        if let index = draft.checklist.firstIndex(where: { $0.id == "custom" }) {
            draft.checklist[index].items.append(item)
        } else {
            let title = draft.language == .hu ? "Saját tételek" : "My items"
            draft.checklist.append(.init(id: "custom", title: title, items: [item]))
        }
    }

    public func goForward() {
        guard let next = NightBriefingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    public func goBack() {
        guard let previous = NightBriefingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
    }

    public func loadRecent() async {
        guard let revisionStore else { return }
        do {
            recentDrafts = try await revisionStore.latestRevisions()
            errorMessage = nil
        } catch {
            errorMessage = readable(error)
        }
    }

    public func saveRevision() async throws {
        guard let revisionStore else { throw NightBriefingStoreError.storageUnavailable }
        guard !isSaving else { return }
        let identity = contentIdentity(draft)
        if identity == lastSavedContent {
            message = draft.language == .hu ? "Nincs új változás; a legutóbbi mentés már biztonságban van." : "No new changes; the latest revision is already safe."
            return
        }
        isSaving = true
        isWorking = true
        defer {
            isSaving = false
            isWorking = false
        }
        var candidate = draft
        candidate.savedAt = now()
        let saved = try await revisionStore.save(candidate)
        let currentContent = contentIdentity(draft)
        isApplyingPersistence = true
        if currentContent == identity {
            draft = saved
        } else {
            draft.revision = saved.revision
            draft.savedAt = saved.savedAt
        }
        isApplyingPersistence = false
        lastSavedContent = contentIdentity(saved)
        recentDrafts = try await revisionStore.latestRevisions()
        errorMessage = nil
        message = draft.language == .hu ? "A változat biztonságosan elmentve." : "Revision saved safely."
    }

    public func saveRevisionShowingErrors() async {
        do {
            try await saveRevision()
        } catch {
            errorMessage = readable(error)
        }
    }

    public func flushAutosave() async {
        await autosaveTask?.value
    }

    public func makePreview() async {
        guard canExport else {
            previewPDF = nil
            return
        }
        isWorking = true
        defer { isWorking = false }
        let html = NightBriefingHTMLRenderer().render(document)
        do {
            previewPDF = try await pdfExporter.pdfData(html: html)
            previewError = nil
        } catch {
            previewPDF = nil
            previewError = readable(error)
        }
    }

    public func export(to destination: URL, format: BriefingExportFormat) async throws -> BriefingExportResult {
        isWorking = true
        defer { isWorking = false }
        let result = try await NightBriefingExportCommand().export(document: document, to: destination, format: format)
        message = draft.language == .hu ? "A briefing elkészült. Az eredeti képeidhez nem nyúltunk." : "Briefing ready. Your original images were not changed."
        return result
    }

    private func reset(date: Date) {
        autosaveTask?.cancel()
        lastSavedContent = nil
        context = .init()
        let calendar = Calendar.current
        let arrival = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: date)
        let departure = arrival.flatMap { calendar.date(byAdding: .hour, value: 8, to: $0) }
        draft = NightBriefingDraft(
            savedAt: now(),
            nightDate: date,
            arrival: arrival,
            departure: departure,
            checklist: NightBriefingChecklistTemplate().sections(language: draft.language),
            language: draft.language
        )
        currentStep = .basics
        hasStarted = true
        previewPDF = nil
        previewError = nil
        errorMessage = nil
        message = nil
    }

    private func scheduleAutosaveIfNeeded() {
        guard !isApplyingPersistence, hasStarted, revisionStore != nil else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                try await self.saveRevision()
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = self?.readable(error)
            }
        }
    }

    private func contentIdentity(_ value: NightBriefingDraft) -> NightBriefingDraft {
        var identity = value
        identity.revision = 0
        identity.savedAt = Date(timeIntervalSince1970: 0)
        return identity
    }

    private func readable(_ error: Error) -> String {
        let prefix = draft.language == .hu
            ? "Nem sikerült biztonságosan megőrizni a briefinget."
            : "The briefing could not be preserved safely."
        return "\(prefix) \(error.localizedDescription)"
    }
}

public enum NightBriefingStoreError: LocalizedError, Equatable, Sendable {
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Open or create an AstroTool library before saving this briefing."
        }
    }
}
