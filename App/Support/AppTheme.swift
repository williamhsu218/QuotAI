import AppKit
import SwiftUI

enum AppTheme {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let compact: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum TypeSize {
        static let panelTitle: CGFloat = 18
        static let body: CGFloat = 14
        static let cardTitle: CGFloat = 13
        static let caption: CGFloat = 12
        static let small: CGFloat = 11
    }

    enum Motion {
        static let quick: TimeInterval = 0.18
        static let refresh: TimeInterval = 0.40
    }

    static let quotaCriticalUpperBound = 20
    static let quotaAttentionUpperBound = 50
    static let quotaScaleThresholds: [CGFloat] = [
        CGFloat(quotaCriticalUpperBound) / 100,
        CGFloat(quotaAttentionUpperBound) / 100
    ]

    static let separator = Color(nsColor: .separatorColor).opacity(0.72)
    static let track = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.08),
        dark: NSColor(white: 1.0, alpha: 0.12)
    )
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let cyan = Color(nsColor: .systemTeal)
    static let lime = Color(nsColor: .systemGreen)
    static let resetAccent = Color(nsColor: .systemIndigo)
    static let awakeAccent = Color(nsColor: .systemOrange)
    static let inactiveControlBackground = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark: NSColor(white: 1.0, alpha: 0.08)
    )

    static let cardBackground = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.035),
        dark: NSColor(white: 1.0, alpha: 0.055)
    )
    static let cardBorder = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark: NSColor(white: 1.0, alpha: 0.08)
    )
    static let cardSpecularBorder = LinearGradient(
        stops: [
            .init(
                color: adaptiveColor(
                    light: NSColor(white: 1.0, alpha: 0.65),
                    dark: NSColor(white: 1.0, alpha: 0.16)
                ),
                location: 0.00
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(white: 0.0, alpha: 0.06),
                    dark: NSColor(white: 1.0, alpha: 0.04)
                ),
                location: 1.00
            )
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let pickerTrack = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark: NSColor(white: 1.0, alpha: 0.08)
    )
    static let pickerSelectedBackground = adaptiveColor(
        light: NSColor(white: 1.0, alpha: 0.95),
        dark: NSColor(white: 1.0, alpha: 0.18)
    )
    static let pickerSelectedBorder = LinearGradient(
        stops: [
            .init(
                color: adaptiveColor(
                    light: NSColor(white: 1.0, alpha: 0.80),
                    dark: NSColor(white: 1.0, alpha: 0.22)
                ),
                location: 0.00
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(white: 0.0, alpha: 0.04),
                    dark: NSColor(white: 1.0, alpha: 0.06)
                ),
                location: 1.00
            )
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let pickerSelectedShadow = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.10),
        dark: NSColor(white: 0.0, alpha: 0.30)
    )

    static let planBadgeText = adaptiveColor(
        light: NSColor(displayP3Red: 0.25, green: 0.22, blue: 0.66, alpha: 1),
        dark: NSColor(displayP3Red: 0.78, green: 0.86, blue: 1.00, alpha: 1)
    )
    static let planBadgeBackground = LinearGradient(
        colors: [
            adaptiveColor(
                light: NSColor(displayP3Red: 0.39, green: 0.31, blue: 0.91, alpha: 0.16),
                dark: NSColor(displayP3Red: 0.49, green: 0.43, blue: 1.00, alpha: 0.24)
            ),
            adaptiveColor(
                light: NSColor(displayP3Red: 0.08, green: 0.59, blue: 0.80, alpha: 0.13),
                dark: NSColor(displayP3Red: 0.15, green: 0.71, blue: 0.92, alpha: 0.20)
            ),
            adaptiveColor(
                light: NSColor(displayP3Red: 0.16, green: 0.68, blue: 0.48, alpha: 0.10),
                dark: NSColor(displayP3Red: 0.31, green: 0.82, blue: 0.58, alpha: 0.15)
            )
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let planBadgeBorder = LinearGradient(
        colors: [
            adaptiveColor(
                light: NSColor(displayP3Red: 0.37, green: 0.28, blue: 0.84, alpha: 0.40),
                dark: NSColor(displayP3Red: 0.63, green: 0.58, blue: 1.00, alpha: 0.48)
            ),
            adaptiveColor(
                light: NSColor(displayP3Red: 0.06, green: 0.57, blue: 0.76, alpha: 0.28),
                dark: NSColor(displayP3Red: 0.27, green: 0.78, blue: 0.94, alpha: 0.38)
            )
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let planBadgeShadow = adaptiveColor(
        light: NSColor(displayP3Red: 0.25, green: 0.26, blue: 0.75, alpha: 0.08),
        dark: NSColor(displayP3Red: 0.20, green: 0.65, blue: 0.92, alpha: 0.10)
    )
    static let quotaHealthy = QuotaPalette(
        accent: adaptiveColor(
            light: NSColor(displayP3Red: 0.05, green: 0.60, blue: 0.40, alpha: 1),
            dark: NSColor(displayP3Red: 0.24, green: 0.88, blue: 0.60, alpha: 1)
        )
    )
    static let quotaAttention = QuotaPalette(
        accent: adaptiveColor(
            light: NSColor(displayP3Red: 0.95, green: 0.52, blue: 0.08, alpha: 1),
            dark: NSColor(displayP3Red: 1.00, green: 0.62, blue: 0.16, alpha: 1)
        )
    )
    static let quotaCritical = QuotaPalette(
        accent: adaptiveColor(
            light: NSColor(displayP3Red: 0.92, green: 0.18, blue: 0.24, alpha: 1),
            dark: NSColor(displayP3Red: 1.00, green: 0.30, blue: 0.35, alpha: 1)
        )
    )
    static func quotaFillGradient(for remainingPercent: Int) -> LinearGradient {
        if remainingPercent >= quotaAttentionUpperBound {
            // Healthy: Brand Aurora Cyan -> Lime
            return LinearGradient(
                colors: [
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.05, green: 0.62, blue: 0.90, alpha: 1),
                        dark: NSColor(displayP3Red: 0.14, green: 0.74, blue: 1.00, alpha: 1)
                    ),
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.14, green: 0.74, blue: 0.42, alpha: 1),
                        dark: NSColor(displayP3Red: 0.32, green: 0.90, blue: 0.55, alpha: 1)
                    )
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if remainingPercent >= quotaCriticalUpperBound {
            // Warning: Warm Gold Amber -> Sunset Coral
            return LinearGradient(
                colors: [
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.98, green: 0.68, blue: 0.10, alpha: 1),
                        dark: NSColor(displayP3Red: 1.00, green: 0.74, blue: 0.22, alpha: 1)
                    ),
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.95, green: 0.44, blue: 0.12, alpha: 1),
                        dark: NSColor(displayP3Red: 1.00, green: 0.50, blue: 0.18, alpha: 1)
                    )
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            // Critical: Electric Rose -> Crimson Red
            return LinearGradient(
                colors: [
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.96, green: 0.22, blue: 0.40, alpha: 1),
                        dark: NSColor(displayP3Red: 1.00, green: 0.32, blue: 0.48, alpha: 1)
                    ),
                    adaptiveColor(
                        light: NSColor(displayP3Red: 0.88, green: 0.10, blue: 0.18, alpha: 1),
                        dark: NSColor(displayP3Red: 0.96, green: 0.18, blue: 0.24, alpha: 1)
                    )
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    static let quotaScaleGradient = LinearGradient(
        stops: [
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.91, green: 0.13, blue: 0.20, alpha: 1),
                    dark: NSColor(displayP3Red: 1.00, green: 0.27, blue: 0.32, alpha: 1)
                ),
                location: 0.00
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.94, green: 0.17, blue: 0.18, alpha: 1),
                    dark: NSColor(displayP3Red: 1.00, green: 0.31, blue: 0.28, alpha: 1)
                ),
                location: 0.13
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.97, green: 0.31, blue: 0.12, alpha: 1),
                    dark: NSColor(displayP3Red: 1.00, green: 0.42, blue: 0.22, alpha: 1)
                ),
                location: 0.20
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.96, green: 0.49, blue: 0.06, alpha: 1),
                    dark: NSColor(displayP3Red: 1.00, green: 0.60, blue: 0.17, alpha: 1)
                ),
                location: 0.27
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.94, green: 0.52, blue: 0.06, alpha: 1),
                    dark: NSColor(displayP3Red: 1.00, green: 0.64, blue: 0.18, alpha: 1)
                ),
                location: 0.42
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.77, green: 0.62, blue: 0.08, alpha: 1),
                    dark: NSColor(displayP3Red: 0.83, green: 0.74, blue: 0.20, alpha: 1)
                ),
                location: 0.50
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.38, green: 0.63, blue: 0.16, alpha: 1),
                    dark: NSColor(displayP3Red: 0.47, green: 0.79, blue: 0.30, alpha: 1)
                ),
                location: 0.57
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.06, green: 0.56, blue: 0.30, alpha: 1),
                    dark: NSColor(displayP3Red: 0.25, green: 0.83, blue: 0.48, alpha: 1)
                ),
                location: 0.64
            ),
            .init(
                color: adaptiveColor(
                    light: NSColor(displayP3Red: 0.20, green: 0.67, blue: 0.37, alpha: 1),
                    dark: NSColor(displayP3Red: 0.36, green: 0.88, blue: 0.55, alpha: 1)
                ),
                location: 1.00
            )
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let quotaThresholdMarkerEdge = adaptiveColor(
        light: NSColor(white: 0.04, alpha: 0.28),
        dark: NSColor(white: 0.00, alpha: 0.48)
    )
    static let quotaThresholdMarkerHighlight = adaptiveColor(
        light: NSColor(white: 1.00, alpha: 0.60),
        dark: NSColor(white: 1.00, alpha: 0.35)
    )

    static func quotaPalette(for remainingPercent: Int) -> QuotaPalette {
        if remainingPercent >= quotaAttentionUpperBound {
            return quotaHealthy
        }
        if remainingPercent >= quotaCriticalUpperBound {
            return quotaAttention
        }
        return quotaCritical
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }
}

struct QuotaPalette {
    let accent: Color
}

struct AppPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        AppTheme.cyan.opacity(colorScheme == .dark ? 0.10 : 0.065),
                        .clear,
                        AppTheme.lime.opacity(colorScheme == .dark ? 0.055 : 0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private struct NativeGlassRenderingKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SystemPopoverSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DesignPreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var nativeGlassRenderingEnabled: Bool {
        get { self[NativeGlassRenderingKey.self] }
        set { self[NativeGlassRenderingKey.self] = newValue }
    }

    var usesSystemPopoverSurface: Bool {
        get { self[SystemPopoverSurfaceKey.self] }
        set { self[SystemPopoverSurfaceKey.self] = newValue }
    }

    var designPreviewRendering: Bool {
        get { self[DesignPreviewRenderingKey.self] }
        set { self[DesignPreviewRenderingKey.self] = newValue }
    }
}

private struct AppPanelSurfaceModifier: ViewModifier {
    @Environment(\.nativeGlassRenderingEnabled) private var nativeGlassRenderingEnabled
    @Environment(\.usesSystemPopoverSurface) private var usesSystemPopoverSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if usesSystemPopoverSurface {
            // NSPopover provides native Liquid Glass on macOS 26. Applying a
            // second full-panel effect here flattens the system refraction.
            content
        } else if #available(macOS 26.0, *), nativeGlassRenderingEnabled {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background {
                AppPanelBackground()
                    .clipShape(shape)
            }
        }
    }
}

/// Shared content surface inside the system glass panel. Feature-specific
/// palettes belong to marks and controls, not an extra opaque card background.
struct AppCardSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var tintColor: Color? = nil
    var isActive: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if let tintColor, isActive {
                    shape
                        .fill(tintColor.opacity(colorScheme == .dark ? 0.12 : 0.08))
                } else {
                    shape
                        .fill(AppTheme.cardBackground)
                }
            }
            .overlay {
                if let tintColor, isActive {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    tintColor.opacity(colorScheme == .dark ? 0.45 : 0.35),
                                    tintColor.opacity(colorScheme == .dark ? 0.20 : 0.15)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                } else {
                    shape
                        .strokeBorder(AppTheme.cardSpecularBorder, lineWidth: 0.75)
                }
            }
    }
}

extension View {
    func appPanelSurface() -> some View {
        modifier(AppPanelSurfaceModifier())
    }

    func appCardSurface(
        cornerRadius: CGFloat = 10,
        tintColor: Color? = nil,
        isActive: Bool = false
    ) -> some View {
        modifier(
            AppCardSurfaceModifier(
                cornerRadius: cornerRadius,
                tintColor: tintColor,
                isActive: isActive
            )
        )
    }
}
