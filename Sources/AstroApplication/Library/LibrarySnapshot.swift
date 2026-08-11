public struct LibrarySnapshot: Equatable, Sendable {
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let projectCount: Int
    public let nightCount: Int
    public let frameCount: Int

    public init(
        libraryID: LibraryIdentity,
        revision: UInt64,
        projectCount: Int,
        nightCount: Int,
        frameCount: Int
    ) {
        self.libraryID = libraryID
        self.revision = revision
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.frameCount = frameCount
    }
}
