import AstroApplication
import AstroCore
import Foundation
import Observation

/// V2 UI/UX audit -- the imaging-setup CRUD V2's default shell never had.
/// V1's `EquipmentSettingsView` (`Sources/AstroToolApp`) has always been able
/// to add/edit/delete `AstroConfig.imagingSetups`, but V1's UI is unreachable
/// from the default V2 shell, so an owner using V2 exclusively had no way at
/// all to tell Planning about their real camera/optics combinations -- only
/// the three hardcoded `PlanningStore.defaultSetups` samples, or hand-editing
/// `<library-root>/.astro_tool/config.json` outside the app.
///
/// Writes go through the exact same `AstroConfig.save(using:)` -> `WriteGuard`
/// path every other V2 Settings tab already uses -- `configLoader`/
/// `configSaver` default straight to `SiteSettingsStore`'s own production
/// implementations rather than a second, parallel one, so there is only ever
/// one canonical way anything in V2 Settings reads or writes `config.json`.
///
/// Domain validation (empty name, unspecified camera kind, invalid sensor/
/// focal/f-number/efficiency, out-of-range default focal length) is entirely
/// `ImagingSetupProfile.validate()`'s own -- this store never re-implements
/// or second-guesses it, only adds the two things that ARE this store's own
/// business: no two saved setups may share a name, and exactly one saved
/// setup is ever marked default.
///
/// `PlanningStore` picks up an add/edit/delete made here on its own, with no
/// direct call from this store into it: `PlanningStore.refresh()` re-reads
/// `config.imagingSetups` fresh via its own `setupsProvider` on every
/// recompute (see that type's own doc comment), the exact same "read fresh
/// from disk every time" contract its `skyContextProvider` already has for
/// site edits made in `SiteSettingsStore`. Deleting the setup Planning
/// currently has selected therefore degrades the same way Planning already
/// handles "no setups configured": falling back to the config's own default,
/// or to `PlanningStore.defaultSetups` if none remain.
@MainActor
@Observable
public final class EquipmentSetupsStore {
    public enum EquipmentSetupsError: LocalizedError, Equatable {
        case noLibraryOpen
        case duplicateName
        case validation(ImagingSetupValidationError)
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noLibraryOpen: "Open a library before managing imaging setups."
            case .duplicateName: "Another saved setup already has this name."
            case .validation(let error): EquipmentSetupsError.validationDescription(error)
            case .saveFailed(let message): "Could not save: \(message)"
            }
        }

        /// Kept separate from `errorDescription`'s own `switch` (rather than
        /// inlined there) purely so callers that already have an
        /// `ImagingSetupValidationError` in hand -- e.g. a view rendering it
        /// as a real `LocalizedStringKey`, not this plain-`String` fallback
        /// -- can reuse the same English text without going through `Error`.
        public static func validationDescription(_ error: ImagingSetupValidationError) -> String {
            switch error {
            case .emptyName: "Every setup needs a name."
            case .emptyCameraName: "Enter the camera name for every setup."
            case .unspecifiedCameraKind: "Choose a camera kind for every setup."
            case .invalidSensorSize: "Sensor width and height must be positive numbers."
            case .invalidFocalRange: "Focal length must be positive, and the minimum cannot exceed the maximum."
            case .defaultFocalLengthOutsideRange: "The default focal length must fall within the zoom range."
            case .invalidFNumber: "The f-number must be a positive number."
            case .invalidRelativeEfficiency: "Relative system efficiency must be a positive number (1.0 = reference)."
            }
        }
    }

    public private(set) var setups: [ImagingSetupProfile] = []
    public private(set) var lastError: EquipmentSetupsError?
    public private(set) var saveMessage: String?

    public let rootURL: URL?
    private let configLoader: @Sendable (URL) -> AstroConfig
    private let configSaver: @Sendable (AstroConfig, URL) throws -> Void

    public init(
        rootURL: URL?,
        configLoader: @escaping @Sendable (URL) -> AstroConfig = SiteSettingsStore.productionConfigLoader,
        configSaver: @escaping @Sendable (AstroConfig, URL) throws -> Void = SiteSettingsStore.productionConfigSaver
    ) {
        self.rootURL = rootURL
        self.configLoader = configLoader
        self.configSaver = configSaver
        if let rootURL {
            setups = configLoader(rootURL).imagingSetups
        }
    }

    public var hasLibraryOpen: Bool { rootURL != nil }

    /// Adds a brand-new setup, or updates one in place when `profile.id`
    /// already names a saved setup. Validates via the shared
    /// `ImagingSetupProfile.validate()` before touching disk -- an invalid
    /// profile is rejected and never written. The very first setup ever
    /// saved always becomes the default (there is otherwise nothing for
    /// `ImagingSetupProfile.defaultSetup(in:)`/`PlanningStore` to fall back
    /// on); marking any OTHER setup as default clears the flag from every
    /// other one, so exactly one is ever default at a time.
    @discardableResult
    public func save(_ profile: ImagingSetupProfile) -> Bool {
        lastError = nil
        saveMessage = nil
        guard let rootURL else {
            lastError = .noLibraryOpen
            return false
        }
        do {
            try profile.validate()
        } catch let error as ImagingSetupValidationError {
            lastError = .validation(error)
            return false
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            return false
        }

        let normalizedName = profile.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let isDuplicateName = setups.contains { existing in
            existing.id != profile.id
                && existing.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedName
        }
        guard !isDuplicateName else {
            lastError = .duplicateName
            return false
        }

        var updated = setups
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }

        if profile.isDefault {
            for index in updated.indices where updated[index].id != profile.id {
                updated[index].isDefault = false
            }
        } else if !updated.contains(where: \.isDefault), let firstIndex = updated.indices.first {
            updated[firstIndex].isDefault = true
        }

        guard persist(updated, rootURL: rootURL) else { return false }
        saveMessage = "Saved."
        return true
    }

    /// Removes a saved setup by id. Deleting the setup currently marked
    /// default promotes the first remaining one, so `setups` always has an
    /// explicit default whenever it is non-empty -- the same invariant
    /// `save(_:)` maintains. Deleting an id that isn't actually saved is a
    /// quiet no-op (still reports success): the caller's own confirmation
    /// dialog already named a specific setup, so by the time this runs the
    /// only way the id could be missing is a harmless double-invocation.
    @discardableResult
    public func delete(id: String) -> Bool {
        lastError = nil
        saveMessage = nil
        guard let rootURL else {
            lastError = .noLibraryOpen
            return false
        }
        guard setups.contains(where: { $0.id == id }) else { return true }

        var updated = setups
        let removedWasDefault = updated.first(where: { $0.id == id })?.isDefault == true
        updated.removeAll { $0.id == id }
        if removedWasDefault, !updated.isEmpty, !updated.contains(where: \.isDefault) {
            updated[0].isDefault = true
        }

        guard persist(updated, rootURL: rootURL) else { return false }
        saveMessage = "Deleted."
        return true
    }

    private func persist(_ updated: [ImagingSetupProfile], rootURL: URL) -> Bool {
        var config = configLoader(rootURL)
        config.imagingSetups = updated
        do {
            try configSaver(config, rootURL)
            setups = updated
            return true
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            return false
        }
    }
}
