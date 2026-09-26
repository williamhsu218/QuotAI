import Foundation

/// A shared preference for local token activity; quota status colors remain independent.
public enum TokenActivityTheme: String, CaseIterable, Identifiable, Sendable {
    case ocean
    case emerald
    case violet
    case amber

    public static let defaultsKey = "tokenActivityTheme"
    public static let defaultTheme: Self = .ocean

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultTheme
    }

    public var title: String {
        switch self {
        case .ocean: L10n.text("token_theme.ocean", fallback: "Ocean")
        case .emerald: L10n.text("token_theme.emerald", fallback: "Emerald")
        case .violet: L10n.text("token_theme.violet", fallback: "Violet")
        case .amber: L10n.text("token_theme.amber", fallback: "Amber")
        }
    }

    /// All colors are opaque sRGB values, so wallpaper cannot change the scale.
    /// Light mode becomes darker with activity; dark mode becomes brighter.
    public func palette(dark: Bool, increasedContrast: Bool = false) -> TokenActivityColorScale {
        let activeHex: [UInt32]
        switch (self, dark) {
        case (.ocean, false): activeHex = [0x4B8BC6, 0x246BAD, 0x164D83, 0x0C3158]
        case (.ocean, true): activeHex = [0x367DB7, 0x459EDA, 0x71BCEA, 0xB2DDFA]
        case (.emerald, false): activeHex = [0x398763, 0x247047, 0x125734, 0x073C27]
        case (.emerald, true): activeHex = [0x37895F, 0x4BAA79, 0x78CC9E, 0xB7EACE]
        case (.violet, false): activeHex = [0x9380CE, 0x7960BC, 0x5D409E, 0x3C2770]
        case (.violet, true): activeHex = [0x8266BD, 0xA083D7, 0xBDA2EC, 0xDFCAF9]
        case (.amber, false): activeHex = [0xB98628, 0x966314, 0x764B0D, 0x523307]
        case (.amber, true): activeHex = [0xAA7B28, 0xCF9B3D, 0xE9BF67, 0xFBE6B5]
        }

        let active = activeHex.map { hex in
            let color = TokenActivityRGB(hex: hex)
            guard increasedContrast else { return color }
            return color.mixed(with: dark ? .white : .black, amount: dark ? 0.15 : 0.20)
        }
        return TokenActivityColorScale(
            surface: .init(hex: dark ? 0x151B26 : 0xF8FAFC),
            accent: active[dark ? 2 : 1],
            levels: [.init(hex: dark ? 0x2A3444 : 0xE2E8F0)] + active,
            dark: dark,
            increasedContrast: increasedContrast
        )
    }
}

/// No alpha component is exposed: both the grid surface and cells must be opaque.
public struct TokenActivityRGB: Equatable, Sendable {
    public let hex: UInt32

    public init(hex: UInt32) {
        self.hex = hex & 0xFFFFFF
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: Self) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    fileprivate static let black = Self(hex: 0x000000)
    fileprivate static let white = Self(hex: 0xFFFFFF)

    fileprivate func mixed(with other: Self, amount: Double) -> Self {
        func channel(_ start: Double, _ end: Double) -> UInt32 {
            UInt32(((start * (1 - amount) + end * amount) * 255).rounded())
        }
        return Self(hex: channel(red, other.red) << 16
            | channel(green, other.green) << 8
            | channel(blue, other.blue))
    }
}

public struct TokenActivityColorScale: Equatable, Sendable {
    public let surface: TokenActivityRGB
    public let accent: TokenActivityRGB
    /// Level 0 is no activity; levels 1–4 carry increasing activity.
    public let levels: [TokenActivityRGB]
    private let dark: Bool
    private let increasedContrast: Bool

    fileprivate init(
        surface: TokenActivityRGB,
        accent: TokenActivityRGB,
        levels: [TokenActivityRGB],
        dark: Bool,
        increasedContrast: Bool
    ) {
        self.surface = surface
        self.accent = accent
        self.levels = levels
        self.dark = dark
        self.increasedContrast = increasedContrast
    }

    public func color(for level: Int) -> TokenActivityRGB {
        levels[min(max(level, 0), levels.count - 1)]
    }

    public func border(for level: Int) -> TokenActivityRGB {
        guard level > 0 else {
            if increasedContrast {
                return .init(hex: dark ? 0x8190A6 : 0x64748B)
            }
            return .init(hex: dark ? 0x435169 : 0xCBD5E1)
        }
        return color(for: level).mixed(
            with: dark ? .white : .black,
            amount: increasedContrast ? 0.35 : 0.16
        )
    }

    /// Today and hover use an inset marker that remains legible on every fill.
    public func marker(for level: Int) -> TokenActivityRGB {
        let fill = color(for: level)
        return fill.contrastRatio(with: .white) > fill.contrastRatio(with: .black) ? .white : .black
    }
}
