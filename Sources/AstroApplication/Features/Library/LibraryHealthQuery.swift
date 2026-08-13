import Foundation

public enum LibraryHealthCategory: String, Sendable { case flat, dark, bias, storage, integrity }
public enum LibraryHealthSeverity: String, Sendable { case healthy, info, warning, critical }
public struct LibraryHealthItem: Equatable, Sendable, Identifiable {
    public let id: String; public let category: LibraryHealthCategory; public let severity: LibraryHealthSeverity
    public let title: String; public let detail: String
}
public struct LibraryHealthSnapshot: Equatable, Sendable {
    public let sessionCount: Int; public let calibrationIssues: Int; public let items: [LibraryHealthItem]; public let isReadOnly: Bool
}
public struct LibraryHealthQuery: Sendable {
    private init() {}
    public static func fixture() -> Self { Self() }
    public func snapshot() async throws -> LibraryHealthSnapshot {
        LibraryHealthSnapshot(sessionCount: 1, calibrationIssues: 2, items: [
            .init(id: "flat", category: .flat, severity: .warning, title: "Flat mismatch", detail: "Rotation differs between lights and flats."),
            .init(id: "dark", category: .dark, severity: .warning, title: "Dark missing", detail: "No matching session or library dark."),
            .init(id: "integrity", category: .integrity, severity: .healthy, title: "Source library protected", detail: "Health checks are read-only."),
        ], isReadOnly: true)
    }
}
