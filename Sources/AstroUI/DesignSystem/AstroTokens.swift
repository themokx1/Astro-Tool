import SwiftUI

/// Shared V2 values. Typography deliberately remains system-native so the
/// workspace follows the user's macOS accessibility and appearance settings.
public enum AstroTokens {
    public enum Color {
        public static let graphite = SwiftUI.Color(
            red: 0.055,
            green: 0.063,
            blue: 0.078
        )
        public static let elevatedGraphite = SwiftUI.Color(
            red: 0.082,
            green: 0.094,
            blue: 0.118
        )
        public static let spectralBlue = SwiftUI.Color(
            red: 0.31,
            green: 0.58,
            blue: 0.96
        )
        public static let spectralViolet = SwiftUI.Color(
            red: 0.55,
            green: 0.43,
            blue: 0.92
        )
        public static let hairline = SwiftUI.Color.white.opacity(0.12)
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
