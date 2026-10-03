import SwiftUI

enum MoeStyle {
    static let pink = Color(red: 244 / 255, green: 181 / 255, blue: 205 / 255)
    static let lavender = Color(red: 192 / 255, green: 185 / 255, blue: 226 / 255)
    static let blue = Color(red: 135 / 255, green: 199 / 255, blue: 234 / 255)
    static let sidebarWidth: CGFloat = 178
    static let rowHeight: CGFloat = 28
    static let contentInset: CGFloat = 16
    static let secondarySurface = Color(nsColor: .controlBackgroundColor)
}

extension View {
    func compactText() -> some View { font(.system(size: 12)).lineLimit(1) }
}
