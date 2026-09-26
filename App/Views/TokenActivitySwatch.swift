import SwiftUI

/// Shared by both activity grids, their legends, and the settings previews.
struct TokenActivitySwatch: View {
    let level: Int
    let palette: TokenActivityPalette
    var cornerRadius: CGFloat = 2.2
    var emphasized = false
    var partial = false
    var unknown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(unknown ? palette.surface : palette.color(for: level))
            .overlay {
                shape.strokeBorder(
                    emphasized || partial || unknown ? palette.marker(for: level) : palette.border(for: level),
                    style: StrokeStyle(
                        lineWidth: emphasized ? 1.3 : (partial || unknown ? 0.9 : 0.5),
                        dash: partial || unknown ? [1.5, 1] : []
                    )
                )
            }
            .accessibilityHidden(true)
    }
}
