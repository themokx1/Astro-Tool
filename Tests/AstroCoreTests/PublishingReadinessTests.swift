import Testing
@testable import AstroCore

private func readinessProject(
    phase: ProjectPhase = .done,
    missing: Double? = nil,
    filterMissing: Double? = nil,
    hasProcessed: Bool = true
) -> (ProjectState, Bool) {
    let filterRows = filterMissing.map {
        [FilterIntegration(
            filter: "Ha", usableFrameCount: 1, integrationSeconds: 3600,
            goalSeconds: 3600 + $0, missingSeconds: $0
        )]
    } ?? []
    return (
        ProjectState(
            target: "T1", phase: phase, usableIntegrationSeconds: 3600,
            goalSeconds: missing.map { 3600 + $0 }, missingSeconds: missing,
            filterGoals: filterRows,
            latestProcessedDate: hasProcessed ? "2026-01-01" : nil
        ),
        hasProcessed
    )
}

@Test func publishingReadinessReportsCollectingProject() {
    let (project, processed) = readinessProject(phase: .collecting)
    let result = PublishingReadiness.evaluate(project: project, unmappedFilters: [], hasProcessedOutput: processed)
    #expect(result.issues == [.projectNotComplete])
}

@Test func publishingReadinessReportsOutstandingFilterGoal() {
    let (project, processed) = readinessProject(filterMissing: 7200)
    let result = PublishingReadiness.evaluate(project: project, unmappedFilters: [], hasProcessedOutput: processed)
    #expect(result.issues == [.outstandingFilterGoal])
}

@Test func publishingReadinessReportsUnmappedFilterAndMissingProcessedOutput() {
    let (project, _) = readinessProject()
    let result = PublishingReadiness.evaluate(
        project: project, unmappedFilters: ["Ha"], hasProcessedOutput: false
    )
    #expect(result.issues == [.unmappedAstroBinFilter, .missingProcessedOutput])
}

@Test func publishingReadinessFullyReadyHasNoIssues() {
    let (project, processed) = readinessProject()
    let result = PublishingReadiness.evaluate(project: project, unmappedFilters: [], hasProcessedOutput: processed)
    #expect(result.isReady)
}

@Test func publishingReadinessMultipleIssuesHaveStableOrder() {
    let (project, _) = readinessProject(phase: .collecting, missing: 3600, filterMissing: 7200, hasProcessed: false)
    let result = PublishingReadiness.evaluate(project: project, unmappedFilters: ["OIII"], hasProcessedOutput: false)
    #expect(result.issues == [
        .projectNotComplete,
        .outstandingOverallGoal,
        .outstandingFilterGoal,
        .unmappedAstroBinFilter,
        .missingProcessedOutput,
    ])
}
