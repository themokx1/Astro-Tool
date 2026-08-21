public struct NightBriefingComposer: Sendable {
    private let validator: NightBriefingValidator
    private let checklistTemplate: NightBriefingChecklistTemplate
    private let contingencyBuilder: NightBriefingContingencyBuilder

    public init(
        validator: NightBriefingValidator = .init(),
        checklistTemplate: NightBriefingChecklistTemplate = .init(),
        contingencyBuilder: NightBriefingContingencyBuilder = .init()
    ) {
        self.validator = validator
        self.checklistTemplate = checklistTemplate
        self.contingencyBuilder = contingencyBuilder
    }

    public func compose(draft: NightBriefingDraft, context: NightBriefingContext) -> NightBriefingDocument {
        var composed = draft
        if composed.checklist.isEmpty {
            composed.checklist = checklistTemplate.sections(language: composed.language)
        }
        let report = validator.validate(composed)
        return NightBriefingDocument(
            draft: composed,
            readiness: report.readiness,
            issues: report.issues,
            contingencies: contingencyBuilder.build(draft: composed, context: context)
        )
    }
}
