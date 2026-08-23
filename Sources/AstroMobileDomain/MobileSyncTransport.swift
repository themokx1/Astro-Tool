public protocol MobileSyncTransport: Sendable {
    func send(_ envelope: MobilePackageEnvelope) async throws
    func receive() async throws -> MobilePackageEnvelope
}
