import Foundation

/// Read-only capture classification audit. It never proposes file moves:
/// every finding directs the user to review assignments or open the
/// single-session converter, whose exact plan remains a separate step.
public struct CaptureClassificationRule: AuditRule {
    public let id = "capture-classification"

    public init() {}

    public func evaluate(_ ctx: AuditContext) -> [Finding] {
        let resolver = CaptureResolver(
            groups: ctx.captureGroups,
            sources: ctx.captureSources,
            assignments: ctx.fileCaptureAssignments
        )
        let groupsBySession = Dictionary(grouping: ctx.captureGroups) {
            Self.scope(target: $0.target, date: $0.sessionDate)
        }
        var findings: [Finding] = []

        for group in ctx.captureGroups where group.signalMode == .narrowband || group.signalMode == .dualBand {
            guard group.filterLabel == nil else { continue }
            findings.append(Finding(
                severity: .suspicious,
                category: "capture-missing-filter",
                path: "sessions/\(group.target)/\(group.sessionDate)/captures/\(group.slug)",
                message: "A(z) \(group.signalMode.displayNameHU) gyűjtéshez nincs konkrét filter megadva.",
                suggestion: nil
            ))
        }

        for file in ctx.files {
            guard let target = file.target, let date = file.sessionDate else { continue }
            let groups = groupsBySession[Self.scope(target: target, date: date)] ?? []
            let meta = file.id.flatMap { ctx.fitsMetaByFileID[$0] }
            let resolved = resolver.resolve(file: file, meta: meta)
            let pathInfo = PathClassifier.classify(relativePath: file.path)

            if let legacy = pathInfo.legacyCaptureLabel {
                findings.append(Finding(
                    severity: .probablyIntentional,
                    category: "capture-legacy-folder",
                    path: file.path,
                    message: "A legacy „\(legacy)” mappanév gyűjtési szándékot jelez, de még nem első osztályú hozzárendelés.",
                    suggestion: nil
                ))
            }

            if !groups.isEmpty, file.role == .light, resolved.groupID == nil {
                findings.append(Finding(
                    severity: .suspicious,
                    category: "capture-unassigned-light",
                    path: file.path,
                    message: "A light nincs gyűjtéshez rendelve, miközben ebben a sessionben már vannak külön gyűjtések.",
                    suggestion: nil
                ))
            }

            if groups.count > 1, file.role == .flat, resolved.groupID == nil {
                findings.append(Finding(
                    severity: .suspicious,
                    category: "capture-ambiguous-flat",
                    path: file.path,
                    message: "A flat több gyűjtés mellett nem rendelhető biztonságosan OSC vagy szűrős sorozathoz.",
                    suggestion: nil
                ))
            }

            if !groups.isEmpty,
               (file.role == .stack || file.role == .processed || StackDiscovery.hasASIAirStackedPrefix(
                    ((file.path as NSString).lastPathComponent).lowercased()
               )),
               resolved.groupID == nil
            {
                findings.append(Finding(
                    severity: .suspicious,
                    category: "capture-unassigned-artifact",
                    path: file.path,
                    message: "A stack/feldolgozott eredmény nincs egyik gyűjtéshez sem rendelve.",
                    suggestion: nil
                ))
            }

            for conflict in resolved.conflicts {
                findings.append(Finding(
                    severity: .suspicious,
                    category: "capture-metadata-conflict",
                    path: file.path,
                    message: "\(conflict) Forrás: \(resolved.filterOrigin.displayNameHU).",
                    suggestion: nil
                ))
            }
        }

        return findings
    }

    private static func scope(target: String, date: String) -> String {
        "\(target)\u{1F}\(date)"
    }
}
