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

@MainActor
@Observable
public final class NightBriefingStore {
    public var draft: NightBriefingDraft
    public var currentStep: NightBriefingStep = .basics
    public var hasStarted = false
    public private(set) var recentDrafts: [NightBriefingDraft] = []
    public private(set) var previewPDF: Data?
    public private(set) var isWorking = false
    public private(set) var message: LocalizedStringKey?

    private let now: () -> Date
    private let revisionStore: NightBriefingRevisionStore?
    private let composer = NightBriefingComposer()

    public init(
        now: @autoclosure @escaping () -> Date = Date(),
        revisionStore: NightBriefingRevisionStore? = nil
    ) {
        self.now = now
        self.revisionStore = revisionStore
        let language: BriefingDocumentLanguage = Locale.current.language.languageCode?.identifier == "hu" ? .hu : .en
        draft = NightBriefingDraft(savedAt: now(), language: language)
    }

    public convenience init(libraryRoot: URL?) {
        let revisionStore: NightBriefingRevisionStore?
        if let libraryRoot,
           let paths = try? AppStoragePaths.production(
               libraryID: LibraryIdentity(rootURL: libraryRoot),
               libraryRoot: libraryRoot
           ) {
            revisionStore = NightBriefingRevisionStore(directory: paths.briefings)
        } else {
            revisionStore = nil
        }
        self.init(now: Date(), revisionStore: revisionStore)
    }

    public var document: NightBriefingDocument {
        composer.compose(draft: draft, context: .init())
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
        draft = saved
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
        recentDrafts = (try? await revisionStore.latestRevisions()) ?? []
    }

    public func saveRevision() async throws {
        guard let revisionStore else { return }
        isWorking = true
        defer { isWorking = false }
        draft.savedAt = now()
        draft = try await revisionStore.save(draft)
        recentDrafts = try await revisionStore.latestRevisions()
        message = draft.language == .hu ? "A változat biztonságosan elmentve." : "Revision saved safely."
    }

    public func makePreview() async {
        guard canExport else {
            previewPDF = nil
            return
        }
        isWorking = true
        defer { isWorking = false }
        let html = NightBriefingHTMLRenderer().render(document)
        previewPDF = try? await NightBriefingPDFExporter().pdfData(html: html)
    }

    public func export(to destination: URL, format: BriefingExportFormat) async throws -> BriefingExportResult {
        isWorking = true
        defer { isWorking = false }
        let result = try await NightBriefingExportCommand().export(document: document, to: destination, format: format)
        message = draft.language == .hu ? "A briefing elkészült. Az eredeti képeidhez nem nyúltunk." : "Briefing ready. Your original images were not changed."
        return result
    }

    private func reset(date: Date) {
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
        message = nil
    }
}
