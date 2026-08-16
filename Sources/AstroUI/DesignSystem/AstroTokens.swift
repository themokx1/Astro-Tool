import AppKit
import AstroApplication
import SwiftUI

/// Shared V2 values. Typography deliberately remains system-native so the
/// workspace follows the user's macOS accessibility and appearance settings.
///
/// The color palette (spec `docs/superpowers/specs/2026-08-16-archive-map-ux-redesign-design.md`
/// section 5.1) comes from narrowband false-color mapping: what the app
/// collected reads as OIII teal, what it made from that reads as SII gold,
/// calibration reads violet, and what it could not identify reads slate.
/// Every color means exactly one thing:
///
/// - `ground`/`surface`/`surfaceRaised`/`edge`/`ink*` are structural --
///   window base, card surfaces, hairlines, and the three text levels.
/// - `dataLight`/`dataStack`/`dataProcessed`/`dataCalibration`/
///   `dataUnclassified` encode a DATA CATEGORY -- what a byte is -- and are
///   never used for status. `AstroTokensTests.dataColorsAreNotStatus` and
///   `V2PolishSurfaceTests.dataColorsAreNotStatus` gate this.
/// - `ok`/`attention`/`critical` encode STATUS -- how something is doing --
///   and never a data category.
/// - `accent` is the app's one primary-action/highlight color.
public enum AstroTokens {
    public enum Color {
        // MARK: Structural surfaces

        /// The window's base surface. Blue-leaning graphite, never a flat
        /// black or a neutral system grey.
        public static let ground = dynamic(dark: 0x070A10, light: 0xF6F7FB)
        /// Card, panel.
        public static let surface = dynamic(dark: 0x10151F, light: 0xFFFFFF)
        /// Elevated card, popover. Light appearance additionally carries a
        /// shadow at the call site; the color itself is the same white.
        public static let surfaceRaised = dynamic(dark: 0x161D29, light: 0xFFFFFF)
        /// Hairline divider.
        public static let edge = dynamic(dark: 0x232C3C, light: 0xDFE4EE)

        // MARK: Text

        /// Primary text.
        public static let ink = dynamic(dark: 0xE9EDF6, light: 0x131824)
        /// Secondary text.
        public static let inkDim = dynamic(dark: 0x7B89A3, light: 0x5C6884)
        /// Tertiary text.
        public static let inkFaint = dynamic(dark: 0x55607A, light: 0x8E99AE)

        // MARK: Data-category colors
        //
        // These five encode WHAT A BYTE IS (light frame, stack, processed
        // image, calibration frame, or unclassified) for band/legend/chip
        // use -- archive map category coding. They must never carry status
        // meaning (`severity`/`isHealthy`/`verdict`); see the class doc
        // above for the gates that hold this line.

        /// Light frame.
        public static let dataLight = dynamic(dark: 0x46CDD6, light: 0x0E9AA4)
        /// Stack.
        public static let dataStack = dynamic(dark: 0xF0B429, light: 0xB87B0C)
        /// Processed image.
        public static let dataProcessed = dynamic(dark: 0xC78F1D, light: 0x8E5E08)
        /// Dark / flat / bias. Never a status color.
        public static let dataCalibration = dynamic(dark: 0x9B87E8, light: 0x6A54C4)
        /// What the app could not identify. Grey, because the app knows
        /// nothing about it.
        public static let dataUnclassified = dynamic(dark: 0x48536B, light: 0x98A3B8)

        // MARK: Accent

        /// The app's one primary-action/highlight color -- not decoration.
        /// Spec 5.1: `dataLight` "is also the primary action color" -- the
        /// same OIII-teal position in the palette serves both roles, so
        /// `accent` is `dataLight` under a name that states the OTHER
        /// intent, exactly as `attention` below is `dataStack` under a
        /// status name. Call sites choose the token that matches what the
        /// color means at that spot, not which one happens to render the
        /// same pixels.
        public static let accent = dataLight

        /// The Archive map's data-category color for one `ArchiveClass`.
        /// Absorbed from the former `ArchivePalette` (wave 2 task 2) --
        /// `ArchiveStripView`/`ArchiveTargetRowView` are its only callers.
        public static func forArchiveClass(_ archiveClass: ArchiveClass) -> SwiftUI.Color {
            switch archiveClass {
            case .light: dataLight
            case .stack: dataStack
            case .processed: dataProcessed
            case .calibration: dataCalibration
            case .unclassified: dataUnclassified
            }
        }

        // MARK: Semantic status colors
        //
        // V2 UI/UX audit (2026-08-14) systemic pattern S9: every feature view
        // used to invent its own `.green`/`.orange`/`.red` for "this is fine"
        // / "needs attention" / "this failed", so the same status could read
        // as a different color from one screen to the next. These three are
        // the single definition every status use should read from now on --
        // `V2PolishSurfaceTests.noInlineColorsInFeatureViews` gates against
        // ANY bare SwiftUI color name (not just the four S9 happened to
        // find) creeping back into `Features/` or `Settings/`. Wave 2 Task
        // 2c: the original gate only named `green`/`orange`/`red`/`purple`,
        // so `.yellow`/`.blue`/`.gray`/`.white` sat invisible in the tree --
        // the merged gate states the SwiftUI color vocabulary itself now,
        // not a sample of it.
        /// Rendben / a healthy/successful/positive state -- "no action
        /// needed", "writable", "OK", "linked". Desaturated, OIII-derived --
        /// deliberately not a plain system green.
        public static let ok = dynamic(dark: 0x3FB58F, light: 0x1E8464)
        /// A state that needs attention but isn't broken -- "stale",
        /// "excluded frames", "new finding since last audit". Shares
        /// `dataStack`'s hue by definition (spec 5.1): it reads as
        /// attention-worthy, not as a data category, purely from the
        /// `attention` call site's context.
        public static let attention = dataStack
        /// A failed/rejected/destructive/critical state -- "checksum
        /// mismatch", "rejected frame", "save failed", a recoverable slot.
        /// The one loud color in the palette, kept rare on purpose. Named
        /// `critical` (not `danger`): "danger" is a property of an action,
        /// "critical" is a property of a state.
        public static let critical = dynamic(dark: 0xFF6455, light: 0xD0392A)

        /// Builds a color from two literal RGB hex values, one per
        /// appearance, via `NSColor(name:dynamicProvider:)` -- the only way
        /// a token here can honestly claim to support both appearances.
        /// `AstroTokensTests.everyColorDefinesBothAppearances` gates against
        /// any token built any other way.
        static func dynamic(dark: Int, light: Int) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(astroHex: isDark ? dark : light)
            })
        }
    }

    public enum Spacing {
        public static let compact: CGFloat = 8
        public static let standard: CGFloat = 16
        public static let section: CGFloat = 24
        public static let spacious: CGFloat = 32
    }

    public enum CornerRadius {
        public static let panel: CGFloat = 12
    }
}

extension NSColor {
    convenience init(astroHex hex: Int) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
