import Foundation
import Testing

@Suite("PublicFirstRunSurface") struct PublicFirstRunSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func detailedWizardIsExplicitRatherThanAnAutomaticLaunchBlocker() throws {
        let app = try source("Sources/AstroToolApp/AstroToolApp.swift")
        #expect(app.contains("onboardingPresentationNonce"))
        #expect(!app.contains("presentOnboardingIfNeeded"))
        #expect(!app.contains("needsAutomaticOnboarding"))
    }

    @Test func welcomeExplainsLocalSafeAndExplicitLibraryAccess() throws {
        let welcome = try source("Sources/AstroToolApp/Views/WelcomeView.swift")
        #expect(welcome.contains("A képeid helyben maradnak"))
        #expect(welcome.contains("Csak az általad kiválasztott könyvtárhoz fér hozzá"))
        #expect(welcome.contains("Az első beolvasás nem töröl és nem mozgat"))
        #expect(welcome.contains("Képkönyvtár kiválasztása…"))
        #expect(welcome.contains("accessibilityLabel"))
    }

    @Test func emptyWizardContainsNoPersonalEquipmentOrFilterDrafts() throws {
        let wizard = try source("Sources/AstroToolApp/Views/OnboardingWizardView.swift")
        for forbidden in ["Canon R8", "SV220", "100–400", "onboarding-r8"] {
            #expect(!wizard.contains(forbidden), Comment(rawValue: forbidden))
        }
        #expect(wizard.contains("setups = appState.config.imagingSetups"))
        #expect(wizard.contains("APS-C szenzorméret"))
        #expect(wizard.contains("Full frame szenzorméret"))
    }

    @Test func firstScanOffersOptionalPersonalizationAfterTheCoreAction() throws {
        let app = try source("Sources/AstroToolApp/AstroToolApp.swift")
        let firstScan = try source("Sources/AstroToolApp/Views/FirstScanView.swift")
        #expect(app.contains("appState.shouldShowFirstScanExperience"))
        #expect(firstScan.contains("Személyre szabás…"))
        #expect(firstScan.contains("appState.requestOnboarding()"))
        #expect(firstScan.contains("Az audit csak jelöl"))
    }

    @Test func setupPresetsOnlySupplyNeutralSensorDimensions() throws {
        let wizard = try source("Sources/AstroToolApp/Views/OnboardingWizardView.swift")
        let settings = try source("Sources/AstroToolApp/Views/Settings/EquipmentSettingsView.swift")

        #expect(!settings.contains("Canon APS-C"))
        #expect(wizard.contains("cameraKind: .unspecified"))
        #expect(settings.contains("cameraKind: .unspecified"))
        for injected in ["focalLengthMinMM: 200", "focalLengthMinMM: 50", "defaultFocal: 200", "defaultFocal: 50"] {
            #expect(!wizard.contains(injected), Comment(rawValue: injected))
            #expect(!settings.contains(injected), Comment(rawValue: injected))
        }
    }

    @Test func productionUISourcesContainNoPersonalEquipmentExamples() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AstroToolApp", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["Canon R8", "SV220", "SVBONY", "100–400 mm"] {
                #expect(!text.contains(forbidden), Comment(rawValue: "\(file.lastPathComponent): \(forbidden)"))
            }
        }
    }
}
