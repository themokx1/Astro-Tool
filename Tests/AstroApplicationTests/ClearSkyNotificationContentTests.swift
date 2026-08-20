import AstroApplication
import Foundation
import Testing

/// `ClearSkyNotificationContent.build` turns the preflight's own calibration
/// count + tonight's top target into the notification's actual title/body.
/// Runs against the app's real bundle (`hu.lproj`/`en.lproj`, whichever this
/// test process's locale resolves), so these assertions are on STRUCTURE
/// (interpolated data present, right shape) rather than one fixed-locale
/// literal -- the strings themselves are pinned by `hu.lproj`'s own content,
/// not duplicated here.
@Suite("Clear-sky notification content (V3 5.5)")
struct ClearSkyNotificationContentTests {
    @Test("Calibration ready, with a suggested target: both facts appear in the body")
    func readyWithTarget() {
        let content = ClearSkyNotificationContent.build(missingCalibrationCount: 0, targetDisplayName: "M31")
        #expect(!content.title.isEmpty)
        #expect(content.body.contains("M31"))
    }

    @Test("Calibration ready, no suggested target: the body never claims a target it doesn't have")
    func readyWithoutTarget() {
        let content = ClearSkyNotificationContent.build(missingCalibrationCount: 0, targetDisplayName: nil)
        #expect(!content.body.isEmpty)
        #expect(!content.body.contains("nil"))
    }

    @Test("Calibration missing, with a suggested target: the count and the target both appear")
    func missingWithTarget() {
        let content = ClearSkyNotificationContent.build(missingCalibrationCount: 3, targetDisplayName: "NGC 7000")
        #expect(content.body.contains("3"))
        #expect(content.body.contains("NGC 7000"))
    }

    @Test("Calibration missing, no suggested target: the count still appears")
    func missingWithoutTarget() {
        let content = ClearSkyNotificationContent.build(missingCalibrationCount: 5, targetDisplayName: nil)
        #expect(content.body.contains("5"))
    }

    @Test("The title never changes with the facts -- it's the same headline every time")
    func titleIsStable() {
        let a = ClearSkyNotificationContent.build(missingCalibrationCount: 0, targetDisplayName: "M31")
        let b = ClearSkyNotificationContent.build(missingCalibrationCount: 4, targetDisplayName: nil)
        #expect(a.title == b.title)
    }
}
