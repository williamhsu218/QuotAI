import Testing
@testable import QuotAICore

@Test("Every activity level stays visible on its opaque surface", arguments: TokenActivityTheme.allCases)
func tokenActivitySurfaceContrast(theme: TokenActivityTheme) {
    for dark in [false, true] {
        for increasedContrast in [false, true] {
            let palette = theme.palette(dark: dark, increasedContrast: increasedContrast)
            for level in 1...4 {
                #expect(palette.color(for: level).contrastRatio(with: palette.surface)
                    >= (increasedContrast ? 4.5 : 3.0))
                #expect(palette.marker(for: level).contrastRatio(with: palette.color(for: level)) >= 4.5)
            }
            #expect(palette.accent.contrastRatio(with: palette.surface) >= 4.5)
            #expect(palette.color(for: 1).contrastRatio(with: palette.color(for: 0)) >= 2.5)
            #expect(palette.marker(for: 0).contrastRatio(with: palette.color(for: 0)) >= 4.5)
        }
    }
}

@Test("More activity follows a distinct, monotonic luminance scale", arguments: TokenActivityTheme.allCases)
func tokenActivityLuminanceOrder(theme: TokenActivityTheme) {
    for dark in [false, true] {
        for increasedContrast in [false, true] {
            let palette = theme.palette(dark: dark, increasedContrast: increasedContrast)
            for level in 1..<4 {
                let current = palette.color(for: level).relativeLuminance
                let next = palette.color(for: level + 1).relativeLuminance
                #expect(dark ? next > current : next < current)
                #expect(palette.color(for: level).contrastRatio(with: palette.color(for: level + 1)) >= 1.3)
            }
        }
    }
}

@Test("Unrecognized preferences recover the default and valid choices survive persistence")
func tokenActivityPreferenceFallback() {
    #expect(TokenActivityTheme.defaultTheme == .ocean)
    for value: String? in [nil, "", "removed-theme"] {
        #expect(TokenActivityTheme(storedValue: value) == .ocean)
    }
    for theme in TokenActivityTheme.allCases {
        #expect(TokenActivityTheme(storedValue: theme.rawValue) == theme)
    }
}

@Test("Out-of-range activity clamps to a usable scale endpoint")
func tokenActivityClampedLevels() {
    let palette = TokenActivityTheme.ocean.palette(dark: false)
    #expect(palette.color(for: Int.min) == palette.color(for: 0))
    #expect(palette.color(for: Int.max) == palette.color(for: 4))
}
