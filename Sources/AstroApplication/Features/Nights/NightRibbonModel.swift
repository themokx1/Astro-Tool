import Foundation

public enum NightRibbonEventKind: String, Codable, Sendable {
    case astronomicalTwilight = "astronomical_twilight"
    case moon
    case targetVisibility = "target_visibility"
    case capture
    case gap
}

public struct NightRibbonEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let kind: NightRibbonEventKind
    public let label: String

    public init(id: UUID, start: Date, end: Date, kind: NightRibbonEventKind, label: String) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.label = label
    }
}

public enum NightRibbonError: Error, Equatable, Sendable {
    case invalidInterval
}

public struct NightRibbonModel: Equatable, Sendable {
    public let events: [NightRibbonEvent]
    public let durationSeconds: TimeInterval
    public let accessibilitySummary: String

    public init(events: [NightRibbonEvent]) throws {
        guard events.allSatisfy({ $0.end >= $0.start }) else {
            throw NightRibbonError.invalidInterval
        }
        let ordered = events.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        self.events = ordered
        if let first = ordered.first, let lastEnd = ordered.map(\.end).max() {
            durationSeconds = lastEnd.timeIntervalSince(first.start)
        } else {
            durationSeconds = 0
        }
        accessibilitySummary = Self.summary(eventCount: ordered.count, seconds: durationSeconds)
    }

    private static func summary(eventCount: Int, seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let duration: String
        if hours > 0, minutes > 0 {
            duration = "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) minutes"
        } else if hours > 0 {
            duration = "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            duration = "\(minutes) minutes"
        }
        return "Night ribbon: \(eventCount) event\(eventCount == 1 ? "" : "s") across \(duration)."
    }
}
