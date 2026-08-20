import Foundation

/// V3 pre-stack program section 5.5 ("Derült-trigger"): turns the same two
/// facts Home's own Preflight Checklist already shows -- how many
/// calibration items are missing, and tonight's top recommended target --
/// into the actual title/body strings `UserNotificationScheduler` hands to
/// `UNMutableNotificationContent`. Pure (no `UNUserNotificationCenter`
/// import, no localization-framework call beyond `NSLocalizedString`
/// itself), so `ClearSkyNotificationContentTests` can assert on exact
/// strings without ever touching the real notification center.
///
/// `NSLocalizedString(_:bundle: .main, comment:)` rather than SwiftUI's
/// `Text`/`LocalizedStringKey`: `UNMutableNotificationContent.title`/`.body`
/// are plain `String`, and this lives in `AstroApplication`, which cannot
/// import `AstroUI` (`OperationHost.localized`'s own module) -- see
/// `CaptureImportCommand.swift`'s identical use of this exact pattern for a
/// user-facing string built from this same module. `hu.lproj/
/// Localizable.strings` still ships inside the app's main bundle regardless
/// of which target the lookup runs from, but the extraction script that
/// keeps that file in sync only scans `Sources/AstroUI` -- every key built
/// here is hand-added to `hu.lproj` instead, following the codebase's own
/// documented convention for exactly this situation.
///
/// Dynamic data (the calibration count, the target's own display name) is
/// always interpolated AROUND the already-resolved literal via
/// `String(format:)`, never through the translation key itself -- the
/// documented `OperationHost.localized(_:)` trap this whole codebase designs
/// around.
public enum ClearSkyNotificationContent {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// - Parameters:
    ///   - missingCalibrationCount: `CalibShoppingList.build(...)`'s own
    ///     item count -- `0` means darks/flats are current, the same number
    ///     `PreflightChecklist.Item.Kind.calibrationCurrent` carries.
    ///   - targetDisplayName: tonight's top recommendation's own display
    ///     name (`Planner.plan`'s best-ranked, observable-tonight target),
    ///     or `nil` when there is none to suggest (no site configured, or
    ///     nothing observable tonight) -- an honest omission, never a guess.
    public static func build(missingCalibrationCount: Int, targetDisplayName: String?) -> Content {
        let title = NSLocalizedString(
            "Tonight looks clear",
            bundle: .main,
            comment: "Clear-sky trigger notification title"
        )

        let body: String
        switch (missingCalibrationCount > 0, targetDisplayName) {
        case (false, let name?):
            let format = NSLocalizedString(
                "Calibration is current. Tonight's top target: %@.",
                bundle: .main,
                comment: "Clear-sky trigger body -- calibration ready, with a suggested target"
            )
            body = String(format: format, name)
        case (false, nil):
            body = NSLocalizedString(
                "Calibration is current.",
                bundle: .main,
                comment: "Clear-sky trigger body -- calibration ready, no suggested target"
            )
        case (true, let name?):
            let format = NSLocalizedString(
                "%lld calibration item(s) need attention. Tonight's top target: %@.",
                bundle: .main,
                comment: "Clear-sky trigger body -- calibration missing, with a suggested target"
            )
            body = String(format: format, missingCalibrationCount, name)
        case (true, nil):
            let format = NSLocalizedString(
                "%lld calibration item(s) need attention.",
                bundle: .main,
                comment: "Clear-sky trigger body -- calibration missing, no suggested target"
            )
            body = String(format: format, missingCalibrationCount)
        }
        return Content(title: title, body: body)
    }
}
