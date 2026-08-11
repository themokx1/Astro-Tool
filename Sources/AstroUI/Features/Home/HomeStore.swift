import Foundation
import Observation

public struct HomeSnapshot: Equatable, Sendable {
    public struct NightContext: Equatable, Sendable {
        public let leadingLabel: String
        public let centerLabel: String
        public let trailingLabel: String

        public init(
            leadingLabel: String,
            centerLabel: String,
            trailingLabel: String
        ) {
            self.leadingLabel = leadingLabel
            self.centerLabel = centerLabel
            self.trailingLabel = trailingLabel
        }
    }

    public let libraryName: String?
    public let nightContext: NightContext

    public init(libraryName: String?, nightContext: NightContext) {
        self.libraryName = libraryName
        self.nightContext = nightContext
    }

    /// Neutral preview content: it conveys the shape of the workspace without
    /// inventing a home location, equipment profile, or observation target.
    public static let unconfigured = HomeSnapshot(
        libraryName: nil,
        nightContext: NightContext(
            leadingLabel: "Dusk",
            centerLabel: "Observation window",
            trailingLabel: "Dawn"
        )
    )
}

@MainActor
@Observable
public final class HomeStore {
    public private(set) var snapshot: HomeSnapshot

    public init(snapshot: HomeSnapshot = .unconfigured) {
        self.snapshot = snapshot
    }

    public func replaceSnapshot(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
    }
}
