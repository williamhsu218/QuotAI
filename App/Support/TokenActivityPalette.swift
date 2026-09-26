import SwiftUI

struct TokenActivityPalette {
    private let scale: TokenActivityColorScale

    init(theme: TokenActivityTheme, colorScheme: ColorScheme, increasedContrast: Bool = false) {
        scale = theme.palette(dark: colorScheme == .dark, increasedContrast: increasedContrast)
    }

    var surface: Color { scale.surface.color }
    var accent: Color { scale.accent.color }

    func color(for level: Int) -> Color { scale.color(for: level).color }
    func border(for level: Int) -> Color { scale.border(for: level).color }
    func marker(for level: Int) -> Color { scale.marker(for: level).color }
}

private extension TokenActivityRGB {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
