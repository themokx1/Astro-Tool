import AppKit
import SwiftUI

/// Shared V2 values. Typography deliberately remains system-native so the
/// workspace follows the user's macOS accessibility and appearance settings.
public enum AstroTokens {
    public enum Color {
        /// Native dynamic colors preserve the graphite character in dark mode
        /// and remain legible in light/increased-contrast appearances.
        public static let graphite = SwiftUI.Color(
            nsColor: NSColor.windowBackgroundColor
        )
        public static let elevatedGraphite = SwiftUI.Color(
            nsColor: NSColor.controlBackgroundColor
        )
        public static let spectralBlue = SwiftUI.Color(
            nsColor: NSColor.systemBlue
        )
        public static let spectralViolet = SwiftUI.Color(
            nsColor: NSColor.systemPurple
        )
        public static let hairline = SwiftUI.Color(
            nsColor: NSColor.separatorColor
        )
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
