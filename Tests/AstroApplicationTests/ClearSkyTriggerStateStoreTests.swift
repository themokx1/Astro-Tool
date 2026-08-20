import AstroApplication
import AstroCore
import Foundation
import Testing

/// `ClearSkyTriggerStateStore` persists `ClearSkyTrigger.State` under
/// `.astro_tool/clear_sky_trigger_state.json`, the same `WriteGuard
/// .writeToolFile` mechanism `AstroConfig.save(using:)` uses for
/// `config.json` -- this is disposable runtime state, not a user document,
/// so a missing or corrupt file must load back to a clean default rather
/// than throwing.
@Suite("Clear-sky trigger state store (V3 5.5)")
struct ClearSkyTriggerStateStoreTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-sky-trigger-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A library with no state file yet loads back the clean default")
    func missingFileLoadsDefault() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ClearSkyTriggerStateStore.load(from: root) == ClearSkyTrigger.State())
    }

    @Test("Save then load round-trips the full state, including the dedupe pin")
    func saveThenLoadRoundTrips() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = ClearSkyTrigger.State(
            earlierMeasurement: .init(dayKey: "2026-08-20", cloudPercent: 42),
            lastNotifiedDayKey: "2026-08-19"
        )
        try ClearSkyTriggerStateStore.save(state, using: WriteGuard(root: root))

        #expect(ClearSkyTriggerStateStore.load(from: root) == state)
    }

    @Test("A corrupt state file loads back the clean default instead of throwing")
    func corruptFileLoadsDefault() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let toolDir = root.appendingPathComponent(".astro_tool", isDirectory: true)
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        let stateFile = toolDir.appendingPathComponent("clear_sky_trigger_state.json")
        try Data("not valid json".utf8).write(to: stateFile)

        #expect(ClearSkyTriggerStateStore.load(from: root) == ClearSkyTrigger.State())
    }

    @Test("Saving again overwrites the previous state -- this is the tool's own runtime state, not a library file")
    func savingTwiceOverwrites() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try ClearSkyTriggerStateStore.save(
            .init(lastNotifiedDayKey: "2026-08-19"), using: WriteGuard(root: root)
        )
        try ClearSkyTriggerStateStore.save(
            .init(lastNotifiedDayKey: "2026-08-20"), using: WriteGuard(root: root)
        )

        #expect(ClearSkyTriggerStateStore.load(from: root).lastNotifiedDayKey == "2026-08-20")
    }
}
