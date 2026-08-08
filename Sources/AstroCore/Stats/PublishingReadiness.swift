import Foundation

/// Non-blocking pre-publication checklist for one target. The evaluator is
/// deliberately pure: callers gather DB/filesystem facts and this model only
/// turns them into stable, deterministically ordered issues.
public struct PublishingReadiness: Codable, Sendable, Equatable {
    public enum Issue: String, Codable, Sendable, Equatable, CaseIterable {
        case projectNotComplete = "project-not-complete"
        case outstandingOverallGoal = "outstanding-overall-goal"
        case outstandingFilterGoal = "outstanding-filter-goal"
        case unmappedAstroBinFilter = "unmapped-astrobin-filter"
        case missingProcessedOutput = "missing-processed-output"
    }

    public let issues: [Issue]
    public var isReady: Bool { issues.isEmpty }

    public init(issues: [Issue]) {
        self.issues = issues
    }

    public static func evaluate(
        project: ProjectState,
        unmappedFilters: [String],
        hasProcessedOutput: Bool
    ) -> PublishingReadiness {
        var issues: [Issue] = []
        if project.phase != .done { issues.append(.projectNotComplete) }
        if (project.missingSeconds ?? 0) > 0 { issues.append(.outstandingOverallGoal) }
        if project.filterGoals.contains(where: { ($0.missingSeconds ?? 0) > 0 }) {
            issues.append(.outstandingFilterGoal)
        }
        if !unmappedFilters.isEmpty { issues.append(.unmappedAstroBinFilter) }
        if !hasProcessedOutput { issues.append(.missingProcessedOutput) }
        return PublishingReadiness(issues: issues)
    }
}
