import AstroApplication
import Foundation
import Observation

/// A simple thread-safe counter used to bridge `SensorMeasurementCommand
/// .run`'s synchronous, per-combo `progress` callback into
/// `OperationHost.reportProgress`'s async, polled-from-the-outside world --
/// mirrors `OnboardingStore.rescan`'s own `LatestOnboardingProgress` box.
private final class SensorMeasurementProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var current: Int64 { lock.lock(); defer { lock.unlock() }; return count }
}

/// Backs `SensorProfilesView`: loads the read-only measured-profile
/// snapshot (`SensorProfilesQuery`) and, unlike the classic-workflow-only
/// state this view used to be stuck with, now runs an actual measurement
/// (`SensorMeasurementCommand`) through `OperationHost` -- so it shows up in
/// `activeOperations`, supports cancel, and reports progress the same way
/// any other V2 background job does. Follows `CalibrationStore`'s
/// query/command-factory injection pattern so tests can supply
/// fixture-backed instances without touching `AppStoragePaths.production`'s
/// real Application Support/Caches directories.
@MainActor
@Observable
public final class SensorProfilesStore {
    public typealias QueryFactory = @Sendable (URL) throws -> SensorProfilesQuery
    public typealias CommandFactory = @Sendable (URL) throws -> SensorMeasurementCommand

    public private(set) var snapshot: SensorProfilesSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let queryFactory: QueryFactory
    private let commandFactory: CommandFactory
    private var rootURL: URL?

    public init(
        queryFactory: @escaping QueryFactory = { rootURL in try SensorProfilesQuery.production(rootURL: rootURL) },
        commandFactory: @escaping CommandFactory = { rootURL in try SensorMeasurementCommand.production(rootURL: rootURL) }
    ) {
        self.queryFactory = queryFactory
        self.commandFactory = commandFactory
    }

    public func load(rootURL: URL) async {
        isLoading = true
        errorMessage = nil
        self.rootURL = rootURL.standardizedFileURL
        defer { isLoading = false }
        do {
            snapshot = try await queryFactory(rootURL).snapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a fresh sensor measurement through `operationHost` -- mirrors
    /// `OnboardingStore.rescan(operationHost:)`'s own shape: registers
    /// under a `.sensorMeasurement` `OperationKind` (so a second measurement
    /// cannot start while one is already running), reports incremental
    /// progress (one tick per combo `SensorMeasurementCommand` reaches),
    /// and refreshes `snapshot` once the run settles -- on success AND on
    /// cancellation/failure alike, since `SensorProfiler.measure` upserts
    /// each combo before moving to the next, so even a cancelled run may
    /// have measured real combos worth showing immediately.
    public func measure(operationHost: OperationHost) async {
        guard let rootURL else {
            operationHost.notify(.info, message: "Choose a library before measuring sensors.")
            return
        }
        let kind = OperationKind.sensorMeasurement(library: rootURL.lastPathComponent)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: "A sensor measurement is already running.")
            return
        }

        do {
            let command = try commandFactory(rootURL)
            let query = try queryFactory(rootURL)
            let counter = SensorMeasurementProgressCounter()

            let id = await operationHost.run(kind: kind, title: "Measuring sensor profiles", cancellation: .cooperative) { [weak self] in
                do {
                    try Task.checkCancellation()
                    _ = try command.run(
                        progress: { _ in counter.increment() },
                        isCancelled: { Task.isCancelled }
                    )
                } catch {
                    await self?.refreshAfterMeasurement(query: query)
                    throw error
                }
                await self?.refreshAfterMeasurement(query: query)
            }

            Task {
                while operationHost.activeOperations.contains(where: { $0.id == id }) {
                    await operationHost.reportProgress(id: id, completed: counter.current)
                    try? await Task.sleep(for: .milliseconds(20))
                }
                await operationHost.reportProgress(id: id, completed: counter.current)
            }
        } catch {
            operationHost.notify(.failure, message: "Sensor measurement failed: \(error.localizedDescription)")
        }
    }

    private func refreshAfterMeasurement(query: SensorProfilesQuery) async {
        if let fresh = try? await query.snapshot() {
            snapshot = fresh
            errorMessage = nil
        }
    }
}
