import Foundation
import AstroCore
import AstroMobileDomain

/// Converts the Mac's typed query records into the deliberately small mobile
/// allowlist. This adapter never receives a library URL, database object, or
/// source-file payload, so those values cannot be serialized accidentally.
public struct MobileSnapshotComposer: Sendable {
    public struct Input: Sendable {
        public let libraryID: PortableLibraryID
        public let revision: Int
        public let projects: [ProjectRecord]
        public let nights: [NightRecord]
        public let captures: [SeriesRecord]
        /// Integration totals calculated by the query layer after frame
        /// acceptance/rejection decisions. Every capture must have an entry;
        /// zero is meaningful when no frames were usable.
        public let integrationSecondsByCaptureID: [UUID: Double]
        public let annotations: [ProjectAnnotationRecord]
        public let briefings: [NightBriefingDraft]

        public init(
            libraryID: PortableLibraryID,
            revision: Int,
            projects: [ProjectRecord],
            nights: [NightRecord],
            captures: [SeriesRecord],
            annotations: [ProjectAnnotationRecord],
            briefings: [NightBriefingDraft],
            integrationSecondsByCaptureID: [UUID: Double]
        ) {
            self.libraryID = libraryID
            self.revision = revision
            self.projects = projects
            self.nights = nights
            self.captures = captures
            self.integrationSecondsByCaptureID = integrationSecondsByCaptureID
            self.annotations = annotations
            self.briefings = briefings
        }
    }

    public init() {}

    public func compose(input: Input, now: Date) throws -> MobileLibrarySnapshot {
        let annotationsByProject = Dictionary(uniqueKeysWithValues: input.annotations.map { ($0.projectID, $0) })
        var integrationByCapture = [UUID: Double](minimumCapacity: input.captures.count)
        for capture in input.captures {
            guard let total = input.integrationSecondsByCaptureID[capture.id],
                  total.isFinite,
                  total >= 0
            else {
                throw AstroError.invalidInput(
                    "Every mobile capture must have a finite, non-negative query integration total."
                )
            }
            integrationByCapture[capture.id] = total
        }
        let integrationByProject = Dictionary(grouping: input.captures, by: \.projectID)
            .mapValues { $0.reduce(0) { $0 + integrationByCapture[$1.id]! } }

        let projects = input.projects.map { project in
            let annotation = annotationsByProject[project.id]
            return MobileProject(
                id: project.id,
                displayName: project.displayName,
                catalogID: project.catalogID,
                phase: project.phase.rawValue,
                integrationSeconds: integrationByProject[project.id] ?? 0,
                goalHours: annotation?.integrationGoalHours
            )
        }

        let captures = input.captures.map { capture in
            MobileCapture(
                id: capture.id,
                projectID: capture.projectID,
                nightID: capture.nightID,
                displayName: capture.setupDescriptor,
                filterName: capture.filterName,
                exposureSeconds: capture.exposureSeconds,
                integrationSeconds: integrationByCapture[capture.id]!
            )
        }

        let briefings = input.briefings.map { draft in
            let readiness = NightBriefingValidator().validate(draft).readiness.rawValue
            let targets = draft.targets.map {
                MobileBriefingTarget(
                    id: $0.id,
                    name: $0.name,
                    role: $0.role.rawValue,
                    start: $0.start,
                    end: $0.end,
                    warnings: $0.warnings
                )
            }
            let checklist = draft.checklist.map { section in
                MobileChecklistSection(
                    id: section.id,
                    title: section.title,
                    items: section.items.filter(\.isVisible).map {
                        MobileChecklistItem(
                            id: $0.id,
                            title: $0.title,
                            explanation: $0.explanation,
                            isCompleted: $0.isCompleted,
                            baseRevision: draft.revision
                        )
                    }
                )
            }
            return MobileBriefing(
                id: draft.id,
                revision: draft.revision,
                savedAt: draft.savedAt,
                nightDate: draft.nightDate,
                readiness: readiness,
                targets: targets,
                checklist: checklist,
                noteID: Self.briefingNoteID(draft.id)
            )
        }

        var notes = input.annotations.map { annotation in
            MobileNote(
                id: Self.projectNoteID(annotation.projectID),
                scope: .project,
                ownerID: annotation.projectID.uuidString,
                text: annotation.notes,
                baseRevision: input.revision,
                updatedAt: annotation.updatedAt,
                isEditableOnPhone: true
            )
        }
        notes.append(contentsOf: input.briefings.map { draft in
            MobileNote(
                id: Self.briefingNoteID(draft.id),
                scope: .briefing,
                ownerID: draft.id.uuidString,
                text: draft.notes,
                baseRevision: draft.revision,
                updatedAt: draft.savedAt,
                isEditableOnPhone: true
            )
        })

        return MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: input.libraryID,
            snapshotID: UUID(),
            revision: input.revision,
            createdAt: now,
            projects: projects,
            nights: input.nights.map {
                MobileNight(id: $0.id, localDate: $0.localDate, timeZoneID: $0.timeZoneID)
            },
            captures: captures,
            briefings: briefings,
            notes: notes
        )
    }

    private static func projectNoteID(_ id: UUID) -> String { "project-\(id.uuidString.lowercased())" }
    private static func briefingNoteID(_ id: UUID) -> String { "briefing-\(id.uuidString.lowercased())" }
}
