import Foundation

public struct ConversionSessionID: Hashable, Sendable {
    public let target: String
    public let date: String
    public init(target: String, date: String) { self.target = target; self.date = date }
    public static let ic1396 = Self(target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08")
}

public enum ConversionPreviewMode: String, Sendable { case logical, physical }
public struct ConversionScopeSummary: Equatable, Sendable { public let target: String; public let date: String; public let sessionCount: Int }
public struct ProposedConversionSeries: Equatable, Sendable, Identifiable {
    public let id: String; public let exposureSeconds: Double; public let title: String; public let frameCount: Int
}
public struct ConversionMovePreview: Equatable, Sendable { public let source: String; public let destination: String }
public struct ConversionPreview: Equatable, Sendable {
    public let scope: ConversionScopeSummary
    public let mode: ConversionPreviewMode
    public let proposedSeries: [ProposedConversionSeries]
    public let moves: [ConversionMovePreview]
    public let canApply: Bool
    public let authorizationMessage: String?
}

public struct ConversionUseCase: Sendable {
    private let fixtureMode: Bool
    private init(fixtureMode: Bool) { self.fixtureMode = fixtureMode }
    public static func fixture() -> Self { Self(fixtureMode: true) }

    public func plan(sessionID: ConversionSessionID, mode: ConversionPreviewMode = .logical) async throws -> ConversionPreview {
        let exposures: [(Double, Int)] = [(5, 24), (30, 32), (120, 3), (300, 46)]
        let series = exposures.map { exposure, count in
            ProposedConversionSeries(
                id: "capture-\(Int(exposure))s", exposureSeconds: exposure,
                title: exposure < 120 ? "OSC \(Int(exposure)) s" : "OSC · Dual-band · SV220 · \(Int(exposure)) s",
                frameCount: count
            )
        }
        return ConversionPreview(
            scope: .init(target: sessionID.target, date: sessionID.date, sessionCount: 1),
            mode: mode, proposedSeries: series,
            moves: mode == .logical ? [] : [],
            canApply: mode == .logical,
            authorizationMessage: mode == .physical ? "Explicit write access is required before any file can move." : nil
        )
    }
}
