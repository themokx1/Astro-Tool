@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// Imaging-setup CRUD (V2 UI/UX audit): V1's `EquipmentSettingsView` has
/// always been able to add/edit/delete `AstroConfig.imagingSetups`, but V1's
/// UI is unreachable from the default V2 shell -- until this store existed,
/// nothing in V2 could write `imagingSetups` at all. These tests exercise
/// the actual round trip through the exact same `AstroConfig.save(using:)`
/// -> `WriteGuard` path `SiteSettingsStore` already uses, plus validation
/// (via the shared `ImagingSetupProfile.validate()`/`ImagingSetupValidationError`)
/// and the no-library-open state -- same fixture shape as
/// `SiteSettingsStoreTests`.
@MainActor
@Suite("Equipment setups store")
struct EquipmentSetupsStoreTests {
    private struct TempLibrary {
        let root: URL

        static func make() throws -> TempLibrary {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AstroTool-EquipmentSetupsStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return TempLibrary(root: root)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func loadConfig() throws -> AstroConfig {
            try AstroConfig.load(from: root.appendingPathComponent(".astro_tool/config.json"))
        }
    }

    private func makeProfile(
        id: String = UUID().uuidString,
        name: String = "APS-C astro · 100–400 mm",
        cameraName: String = "APS-C astro",
        isDefault: Bool = false
    ) -> ImagingSetupProfile {
        ImagingSetupProfile(
            id: id, name: name, cameraName: cameraName, cameraKind: .dedicatedAstro,
            sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 100, focalLengthMaxMM: 400, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: isDefault
        )
    }

    // MARK: - No library open

    @Test("With no library open, the store starts empty and every mutation refuses honestly")
    func noLibraryOpenRefusesToSave() throws {
        let store = EquipmentSetupsStore(rootURL: nil)
        #expect(!store.hasLibraryOpen)
        #expect(store.setups.isEmpty)

        #expect(!store.save(makeProfile()))
        #expect(store.lastError == .noLibraryOpen)
        #expect(!store.delete(id: "anything"))
        #expect(store.lastError == .noLibraryOpen)
    }

    // MARK: - Loading

    @Test("Opening the tab against a library that already has saved setups loads them")
    func loadsExistingSetups() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        var config = AstroConfig()
        config.rootPath = library.root.path
        let existing = makeProfile(id: "existing", isDefault: true)
        config.imagingSetups = [existing]
        try config.save(using: WriteGuard(root: library.root))

        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.setups == [existing])
    }

    // MARK: - Add

    @Test("Saving a new setup persists to config.json at the canonical .astro_tool/config.json path")
    func addingASetupRoundTripsThroughConfig() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        let profile = makeProfile()

        let expected = ImagingSetupProfile(
            id: profile.id, name: profile.name, cameraName: profile.cameraName,
            cameraKind: profile.cameraKind, sensorWidthMM: profile.sensorWidthMM,
            sensorHeightMM: profile.sensorHeightMM, focalLengthMinMM: profile.focalLengthMinMM,
            focalLengthMaxMM: profile.focalLengthMaxMM, defaultFocalLengthMM: profile.defaultFocalLengthMM,
            fNumber: profile.fNumber, relativeEfficiency: profile.relativeEfficiency, isDefault: true
        )

        #expect(store.save(profile))
        #expect(store.lastError == nil)
        #expect(store.setups == [expected], "the first-ever saved setup must become the default")

        let reloaded = try library.loadConfig()
        #expect(reloaded.imagingSetups == [expected])
    }

    @Test("A second saved setup does not steal the default from the first")
    func secondSetupIsNotDefaultByItself() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "first")))
        #expect(store.save(makeProfile(id: "second", name: "Canon R8 · 16 mm")))

        #expect(store.setups.first { $0.id == "first" }?.isDefault == true)
        #expect(store.setups.first { $0.id == "second" }?.isDefault == false)
    }

    @Test("Marking a new setup as default clears the default flag from every other saved setup")
    func settingANewDefaultClearsTheOldOne() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "first", isDefault: true)))
        #expect(store.save(makeProfile(id: "second", name: "Canon R8 · 16 mm", isDefault: true)))

        #expect(store.setups.first { $0.id == "first" }?.isDefault == false)
        #expect(store.setups.first { $0.id == "second" }?.isDefault == true)
    }

    @Test("Two setups cannot share the same name, case-insensitively")
    func rejectsADuplicateName() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "first", name: "Main Rig")))

        #expect(!store.save(makeProfile(id: "second", name: "MAIN RIG")))
        #expect(store.lastError == .duplicateName)
        #expect(store.setups.count == 1)
    }

    // MARK: - Validation

    @Test("An invalid profile is rejected with the specific ImagingSetupValidationError, and never written")
    func rejectsAnInvalidProfileWithoutWriting() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        var invalid = makeProfile()
        invalid.name = "   "

        #expect(!store.save(invalid))
        #expect(store.lastError == .validation(.emptyName))
        #expect(store.setups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent(".astro_tool/config.json").path))
    }

    @Test("An out-of-range default focal length is rejected via the shared validator, not a second bespoke check")
    func rejectsDefaultFocalLengthOutsideRange() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        let invalid = ImagingSetupProfile(
            id: "zoom", name: "Zoom", cameraName: "Cam", cameraKind: .unmodifiedColor,
            sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 24, focalLengthMaxMM: 70, defaultFocalLengthMM: 200,
            fNumber: 4, relativeEfficiency: 1
        )

        #expect(!store.save(invalid))
        #expect(store.lastError == .validation(.defaultFocalLengthOutsideRange))
    }

    // MARK: - Edit

    @Test("Saving with an existing id updates that setup in place instead of appending a duplicate")
    func editingAnExistingSetupUpdatesInPlace() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "rig", name: "Original name")))

        var edited = makeProfile(id: "rig", name: "Renamed", isDefault: true)
        edited.fNumber = 4
        #expect(store.save(edited))

        #expect(store.setups.count == 1)
        #expect(store.setups.first?.name == "Renamed")
        #expect(store.setups.first?.fNumber == 4)
    }

    // MARK: - Delete

    @Test("Deleting a setup removes it from config.json")
    func deletingRemovesFromConfig() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "rig")))

        #expect(store.delete(id: "rig"))
        #expect(store.setups.isEmpty)
        let reloaded = try library.loadConfig()
        #expect(reloaded.imagingSetups.isEmpty)
    }

    @Test("Deleting the default setup promotes another remaining setup to default")
    func deletingTheDefaultPromotesAnotherSetup() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "first", isDefault: true)))
        #expect(store.save(makeProfile(id: "second", name: "Canon R8 · 16 mm")))

        #expect(store.delete(id: "first"))
        #expect(store.setups.count == 1)
        #expect(store.setups.first?.id == "second")
        #expect(store.setups.first?.isDefault == true)
    }

    @Test("Deleting an unknown id is a no-op that reports no error")
    func deletingAnUnknownIDIsANoOp() throws {
        let library = try TempLibrary.make()
        defer { library.cleanup() }
        let store = EquipmentSetupsStore(rootURL: library.root)
        #expect(store.save(makeProfile(id: "rig")))

        #expect(store.delete(id: "does-not-exist"))
        #expect(store.setups.count == 1)
    }
}
