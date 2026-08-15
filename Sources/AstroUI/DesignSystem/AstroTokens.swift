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

        // MARK: Semantic status colors
        //
        // V2 UI/UX audit (2026-08-14) systemic pattern S9: every feature view
        // used to invent its own `.green`/`.orange`/`.red` for "this is fine"
        // / "needs attention" / "this failed", so the same status could read
        // as a different color from one screen to the next. These three are
        // the single definition every status use should read from now on --
        // `V2PolishSurfaceTests.noBareStatusColorLiterals` gates against a
        // bare `.green`/`.orange`/`.red`/`.purple` creeping back into
        // `Features/` or `Settings/`.
        /// A healthy/successful/positive state -- "no action needed",
        /// "writable", "OK", "linked".
        public static let success = SwiftUI.Color(
            nsColor: NSColor.systemGreen
        )
        /// A state that needs attention but isn't broken -- "stale",
        /// "excluded frames", "new finding since last audit".
        public static let warning = SwiftUI.Color(
            nsColor: NSColor.systemOrange
        )
        /// A failed/rejected/destructive state -- "checksum mismatch",
        /// "rejected frame", "save failed".
        public static let danger = SwiftUI.Color(
            nsColor: NSColor.systemRed
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
