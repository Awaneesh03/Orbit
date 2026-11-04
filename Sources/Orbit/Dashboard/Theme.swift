import SwiftUI

/// Shared dashboard tokens. Dark only: the dashboard always renders dark.
enum Theme {
    static let accent = Color(red: 0.56, green: 0.62, blue: 1.0)  // Orbit's soft indigo
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let cardFill = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.08)
    static let selectedFill = Color.white.opacity(0.13)
    static let cardRadius: CGFloat = 18
    static let spacing: CGFloat = 10
}
