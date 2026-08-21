import Foundation

public struct NightBriefingSVGRenderer: Sendable {
    public init() {}

    public func timeline(targets: [BriefingTargetBlock]) -> String {
        guard let start = targets.map(\.start).min(), let end = targets.map(\.end).max(), end > start else {
            return "<svg viewBox=\"0 0 720 80\" role=\"img\" aria-label=\"Empty timeline\"><line x1=\"20\" y1=\"40\" x2=\"700\" y2=\"40\" stroke=\"#9aa4b2\"/></svg>"
        }
        let duration = end.timeIntervalSince(start)
        let blocks = targets.enumerated().map { index, target in
            let x = 20 + 680 * target.start.timeIntervalSince(start) / duration
            let width = max(2, 680 * target.end.timeIntervalSince(target.start) / duration)
            let fill = target.role == .primary ? "#3f7ddb" : "#718096"
            return "<rect x=\"\(format(x))\" y=\"\(18 + index * 24)\" width=\"\(format(width))\" height=\"16\" rx=\"4\" fill=\"\(fill)\"/><text x=\"\(format(x + 5))\" y=\"\(30 + index * 24)\" fill=\"#ffffff\" font-size=\"10\">\(escape(target.name))</text>"
        }.joined()
        let height = max(80, 48 + targets.count * 24)
        return "<svg viewBox=\"0 0 720 \(height)\" role=\"img\" aria-label=\"Planned timeline\">\(blocks)</svg>"
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
