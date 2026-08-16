import AppKit
import AstroApplication
import SwiftUI

/// The Archive map's five data-category colors, derived from narrowband
/// false-color mapping: what you collected reads as OIII teal, what you made
/// from it reads as SII gold, calibration reads violet, and what the app
/// could not identify reads as a muted slate -- grey because the app knows
/// nothing about it.
///
/// These encode a DATA CATEGORY and never a status. Status stays on
/// `AstroTokens.Color.success` / `.warning` / `.danger`, which
/// `V2PolishSurfaceTests.noBareStatusColorLiterals` already gates. Wave 2
/// folds this enum into a rebuilt `AstroTokens`; it lives beside its only
/// consumer until then.
enum ArchivePalette {
    static func color(for archiveClass: ArchiveClass) -> Color {
        switch archiveClass {
        case .light: dataLight
        case .stack: dataStack
        case .processed: dataProcessed
        case .calibration: dataCalibration
        case .unclassified: dataUnclassified
        }
    }

    static let dataLight = dynamic(dark: 0x46CDD6, light: 0x0E9AA4)
    static let dataStack = dynamic(dark: 0xF0B429, light: 0xB87B0C)
    static let dataProcessed = dynamic(dark: 0xC78F1D, light: 0x8E5E08)
    static let dataCalibration = dynamic(dark: 0x9B87E8, light: 0x6A54C4)
    static let dataUnclassified = dynamic(dark: 0x48536B, light: 0x98A3B8)

    private static func dynamic(dark: Int, light: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
