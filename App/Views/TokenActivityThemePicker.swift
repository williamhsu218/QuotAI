import SwiftUI

struct TokenActivityThemePicker: View {
    @AppStorage(TokenActivityTheme.defaultsKey) private var storedTheme = TokenActivityTheme.defaultTheme.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var selection: TokenActivityTheme { TokenActivityTheme(storedValue: storedTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(TokenActivityTheme.allCases) { theme in
                    themeButton(theme)
                }
            }

            Text(L10n.text("settings.token_theme_help", fallback: "Applies to both activity grids. Colors adapt to Light and Dark Mode."))
                .font(.system(size: AppTheme.TypeSize.small))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func themeButton(_ theme: TokenActivityTheme) -> some View {
        let selected = selection == theme
        let palette = TokenActivityPalette(theme: theme, colorScheme: colorScheme, increasedContrast: contrast == .increased)
        return Button {
            storedTheme = theme.rawValue
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? palette.accent : AppTheme.secondaryText)
                    .font(.system(size: 12, weight: .medium))
                Text(theme.title)
                    .font(.system(size: AppTheme.TypeSize.small, weight: selected ? .semibold : .regular))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    ForEach(0..<5) { level in
                        TokenActivitySwatch(level: level, palette: palette, cornerRadius: 1.5)
                            .frame(width: 9, height: 12)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(8)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? palette.accent : AppTheme.separator, lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.tokenTheme.\(theme.rawValue)")
    }
}
