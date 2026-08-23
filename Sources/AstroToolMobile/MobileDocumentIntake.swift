import Foundation

/// The document-provider security-scope contract is kept behind this tiny
/// seam so intake can be proved without a live Files/AirDrop provider.
/// A false return means that no balanced stop call is allowed, but it does
/// not mean that the URL is unreadable: some providers hand the app a URL
/// that is already readable inside its current sandbox.
struct MobileSecurityScopedAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    init(
        start: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.start = start
        self.stop = stop
    }

    func perform<T: Sendable>(at url: URL, operation: @escaping @Sendable () async throws -> T) async rethrows -> T {
        let acquired = start(url)
        return try await perform(at: url, acquired: acquired, operation: operation)
    }

    /// Use this overload when the caller needs the acquisition result to
    /// choose a typed recovery message. It guarantees exactly one matching
    /// stop call for the explicit acquisition result.
    func perform<T: Sendable>(at url: URL, acquired: Bool, operation: @escaping @Sendable () async throws -> T) async rethrows -> T {
        defer {
            if acquired { stop(url) }
        }
        return try await operation()
    }
}

enum MobileIntakeError: Error, Equatable, Sendable {
    case copyFailed

    var localizedKey: String {
        switch self {
        case .copyFailed:
            return "AstroTool could not copy that mobile package safely. Send it from your Mac again and try once more."
        }
    }
}
