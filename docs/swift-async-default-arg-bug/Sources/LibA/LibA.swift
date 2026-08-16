import Foundation

@MainActor
public final class Store {
    public typealias Provider = @Sendable (Int) async throws -> [Int]
    private let provider: Provider
    public init(provider: @escaping Provider = Store.production) { self.provider = provider }
    public static func production(_ x: Int) async throws -> [Int] { [x] }
    public func use() async -> [Int] { (try? await provider(1)) ?? [] }
}

@MainActor
public final class NonIsolatedDefault {
    public typealias Provider = @Sendable (Int) async throws -> [Int]
    private let provider: Provider
    public init(provider: @escaping Provider = { try await NonIsolatedDefault.production($0) }) { self.provider = provider }
    public static func production(_ x: Int) async throws -> [Int] { [x] }
}

public final class NoActor: Sendable {
    public typealias Provider = @Sendable (Int) async throws -> [Int]
    private let provider: Provider
    public init(provider: @escaping Provider = NoActor.production) { self.provider = provider }
    public static func production(_ x: Int) async throws -> [Int] { [x] }
}

@MainActor public func makeInLib() -> Store { Store() }

@MainActor
public final class OptionalDefault {
    public typealias Provider = @Sendable (Int) async throws -> [Int]
    private let provider: Provider
    public init(provider: Provider? = nil) {
        self.provider = provider ?? OptionalDefault.production
    }
    public static func production(_ x: Int) async throws -> [Int] { [x] }
    public func use() async -> [Int] { (try? await provider(1)) ?? [] }
}
