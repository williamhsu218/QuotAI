import AppKit
import SwiftUI

@MainActor
enum MenuBarProviderIcon {
    static let openAITemplateBase64 = "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"

    static func image(for icon: MenuBarPresentation.Icon, size: CGFloat = 13) -> NSImage {
        switch icon {
        case .codex: return openAISpiralImage(size: size)
        case .gemini: return geminiSymbolImage(size: size)
        case .thirdParty: return claudeSymbolImage(size: size)
        case .antigravity:
            let image = NSImage(systemSymbolName: "circle.dashed",
                                accessibilityDescription: "Antigravity") ?? NSImage()
            image.isTemplate = true
            return image
        }
    }

    static func openAISpiralImage(size: CGFloat = 13) -> NSImage {
        if let image = NSImage(named: "CodexMark") {
            image.isTemplate = true
            return image
        }
        if let url = Bundle.main.url(forResource: "CodexMark-master", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        if let data = Data(base64Encoded: openAITemplateBase64),
           let image = NSImage(data: data) {
            image.isTemplate = true
            return image
        }
        return NSImage()
    }

    static func geminiSymbolImage(size: CGFloat = 13) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = rect.midX
            let cy = rect.midY
            let r: CGFloat = 5.8
            let inner: CGFloat = 1.3
            let p = NSBezierPath()
            p.move(to: NSPoint(x: cx, y: cy + r))
            p.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + inner, y: cy + inner), controlPoint2: NSPoint(x: cx + inner, y: cy + inner))
            p.curve(to: NSPoint(x: cx, y: cy - r), controlPoint1: NSPoint(x: cx + inner, y: cy - inner), controlPoint2: NSPoint(x: cx + inner, y: cy - inner))
            p.curve(to: NSPoint(x: cx - r, y: cy), controlPoint1: NSPoint(x: cx - inner, y: cy - inner), controlPoint2: NSPoint(x: cx - inner, y: cy - inner))
            p.curve(to: NSPoint(x: cx, y: cy + r), controlPoint1: NSPoint(x: cx - inner, y: cy + inner), controlPoint2: NSPoint(x: cx - inner, y: cy + inner))
            p.close()
            NSColor.black.setFill()
            p.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func claudeSymbolImage(size: CGFloat = 13) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cx = rect.midX
            let cy = rect.midY
            let r: CGFloat = 5.2
            let w: CGFloat = 1.35
            NSColor.black.setStroke()
            for i in 0..<4 {
                let angle = CGFloat(i) * (CGFloat.pi / 4.0)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx - cos(angle)*r, y: cy - sin(angle)*r))
                p.line(to: NSPoint(x: cx + cos(angle)*r, y: cy + sin(angle)*r))
                p.lineWidth = w
                p.lineCapStyle = .round
                p.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Preserves the existing status item's geometry; previews use this exact image.
@MainActor
enum MenuBarStatusRenderer {
    private static func createTabularFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func image(for presentation: MenuBarPresentation) -> NSImage {
        let providerIcon: NSImage? = MenuBarProviderIcon.image(for: presentation.icon)
        let isStayAwakeActive = presentation.isStayAwakeActive
        let lines = presentation.lines
        let barHeight: CGFloat = 22.0
        let providerIconSize: CGFloat = 13.0
        let spacing: CGFloat = 4.0
        let isTwoLines = lines.count >= 2

        let font: NSFont
        if isTwoLines {
            font = createTabularFont(size: 10.0, weight: .medium)
        } else {
            font = createTabularFont(size: 12.5, weight: .medium)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]

        var textWidth: CGFloat = 0
        for line in lines {
            let w = (line as NSString).size(withAttributes: attrs).width
            if w > textWidth { textWidth = w }
        }

        let hasProviderIcon = (providerIcon != nil)
        let coffeeImage = isStayAwakeActive ? stayAwakeStatusImage() : nil
        let coffeeWidth: CGFloat
        let coffeeHeight: CGFloat = 11.5
        if let coffee = coffeeImage {
            let ratio = coffee.size.width / max(coffee.size.height, 1.0)
            coffeeWidth = round(coffeeHeight * ratio)
        } else {
            coffeeWidth = 0.0
        }

        var totalWidth: CGFloat = 0.0
        if isStayAwakeActive {
            totalWidth += coffeeWidth + spacing
        }
        if hasProviderIcon {
            totalWidth += providerIconSize + spacing
        }
        totalWidth += ceil(textWidth) + 1.0

        let image = NSImage(size: NSSize(width: max(totalWidth, 16.0), height: barHeight), flipped: false) { _ in
            var xOffset: CGFloat = 0.0

            if let coffee = coffeeImage {
                let coffeeY = floor((barHeight - coffeeHeight) / 2.0)
                coffee.draw(
                    in: NSRect(x: xOffset, y: coffeeY, width: coffeeWidth, height: coffeeHeight),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                xOffset += coffeeWidth + spacing
            }

            if let icon = providerIcon {
                let iconY = floor((barHeight - providerIconSize) / 2.0)
                icon.draw(
                    in: NSRect(x: xOffset, y: iconY, width: providerIconSize, height: providerIconSize),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                xOffset += providerIconSize + spacing
            }

            if isTwoLines {
                let line1 = lines[0]
                let line2 = lines[1]
                (line1 as NSString).draw(at: NSPoint(x: xOffset, y: 11.5), withAttributes: attrs)
                (line2 as NSString).draw(at: NSPoint(x: xOffset, y: 1.8), withAttributes: attrs)
            } else if let line = lines.first {
                let size = (line as NSString).size(withAttributes: attrs)
                let y = floor((barHeight - size.height) / 2.0)
                (line as NSString).draw(at: NSPoint(x: xOffset, y: y), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func stayAwakeStatusImage() -> NSImage? {
        let description = L10n.text(
            "awake.menu_bar_active",
            fallback: "Stay Awake on"
        )
        guard let baseImage = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: description
        ) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        image.isTemplate = true
        return image
    }
}

struct MenuBarStatusLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        let image = MenuBarStatusRenderer.image(for: presentation)
        Image(nsImage: image)
            .renderingMode(.template)
            .frame(width: image.size.width, height: image.size.height)
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}
