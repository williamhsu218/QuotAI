import AppKit
import QuartzCore
import SwiftUI

/// The same track, highlight and timing in Settings, provider and quota-group tabs.
struct SlidingSegmentedPicker<Selection: Hashable, SegmentLabel: View>: View {
    let options: [Selection]
    @Binding var selection: Selection
    var keyboardShortcuts = false
    @ViewBuilder let label: (Selection, Bool) -> SegmentLabel

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                Button { selection = option } label: {
                    label(option, selection == option)
                        .foregroundStyle(selection == option ? AppTheme.primaryText : AppTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.small)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .keyboardShortcut(keyboardShortcuts
                    ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    : nil)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
        .background {
            PickerSelectionBackground(
                selectedIndex: options.firstIndex(of: selection) ?? 0,
                count: options.count,
                spacing: AppTheme.Spacing.small,
                cornerRadius: 7
            )
        }
        .padding(AppTheme.Spacing.xSmall)
        .background(AppTheme.pickerTrack, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Only the highlight crosses into AppKit. Its compositor animation survives
/// SwiftUI content/layout updates and retargets from the current presentation.
struct PickerSelectionBackground: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickerReduceMotionOverride) private var forceReduceMotion
    @Environment(\.pickerAnimationDuration) private var duration
    let selectedIndex: Int
    let count: Int
    var spacing: CGFloat = 2
    var cornerRadius: CGFloat = 6

    func makeNSView(context: Context) -> PickerHighlightView { PickerHighlightView() }

    func updateNSView(_ view: PickerHighlightView, context: Context) {
        view.configure(index: selectedIndex, count: count, spacing: spacing,
                       radius: cornerRadius, duration: duration,
                       reduceMotion: reduceMotion || forceReduceMotion)
    }
}

final class PickerHighlightView: NSView {
    private let highlight = CALayer()
    private let border = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private var index = 0
    private var count = 1
    private var spacing: CGFloat = 2
    private var radius: CGFloat = 6
    private var duration: TimeInterval = AppTheme.Motion.quick
    private var reduceMotion = false
    private var hasLayout = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        highlight.name = "selectionHighlight"
        highlight.cornerCurve = .continuous
        highlight.shadowRadius = 2
        highlight.shadowOffset = CGSize(width: 0, height: -1)
        highlight.shadowOpacity = 1
        border.startPoint = CGPoint(x: 0.5, y: 0)
        border.endPoint = CGPoint(x: 0.5, y: 1)
        border.mask = borderMask
        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        borderMask.lineWidth = 0.5
        highlight.addSublayer(border)
        layer?.addSublayer(highlight)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(index: Int, count: Int, spacing: CGFloat, radius: CGFloat,
                   duration: TimeInterval, reduceMotion: Bool) {
        let selectionChanged = self.index != index
        self.index = index; self.count = count; self.spacing = spacing
        self.radius = radius; self.duration = duration; self.reduceMotion = reduceMotion
        updateHighlight(animateSelection: selectionChanged)
    }

    override func layout() {
        super.layout()
        // Repeated layout passes must never restart an in-flight selection.
        updateHighlight(animateSelection: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            highlight.removeAllAnimations()
            hasLayout = false
        }
        updateHighlight(animateSelection: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight(animateSelection: false)
    }

    private func updateHighlight(animateSelection: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let slots = max(1, count)
        let width = max(0, (bounds.width - CGFloat(slots - 1) * spacing) / CGFloat(slots))
        let target = CGRect(x: CGFloat(min(max(0, index), slots - 1)) * (width + spacing),
                            y: 0, width: width, height: bounds.height)
        let currentX = highlight.presentation()?.position.x ?? highlight.position.x
        let xChanged = abs(highlight.position.x - target.midX) > 0.001
        let shouldAnimate = hasLayout && animateSelection && !reduceMotion && duration > 0 && window != nil
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.bounds = CGRect(origin: .zero, size: target.size)
        highlight.position = CGPoint(x: target.midX, y: target.midY)
        highlight.cornerRadius = radius
        let scale = window?.backingScaleFactor ?? 2
        highlight.contentsScale = scale; border.contentsScale = scale; borderMask.contentsScale = scale
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor(AppTheme.pickerSelectedBackground).cgColor
            highlight.shadowColor = NSColor(AppTheme.pickerSelectedShadow).cgColor
            border.colors = dark
                ? [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0.06).cgColor]
                : [NSColor.white.withAlphaComponent(0.80).cgColor, NSColor.black.withAlphaComponent(0.06).cgColor]
        }
        border.frame = highlight.bounds
        borderMask.path = CGPath(roundedRect: highlight.bounds.insetBy(dx: 0.25, dy: 0.25),
                                 cornerWidth: max(0, radius - 0.25), cornerHeight: max(0, radius - 0.25), transform: nil)
        highlight.shadowPath = CGPath(roundedRect: highlight.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        if reduceMotion || !hasLayout || (xChanged && !shouldAnimate) {
            highlight.removeAnimation(forKey: "selection.slide")
        } else if xChanged && shouldAnimate {
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = currentX
            slide.toValue = target.midX
            slide.duration = duration
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Replacing this key samples the old presentation before the model
            // changes, so rapid reversals continue from the visible position.
            highlight.add(slide, forKey: "selection.slide")
        }
        hasLayout = true
    }
}

private struct PickerAnimationDurationKey: EnvironmentKey {
    static let defaultValue = AppTheme.Motion.quick
}

private struct PickerReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pickerReduceMotionOverride: Bool {
        get { self[PickerReduceMotionOverrideKey.self] }
        set { self[PickerReduceMotionOverrideKey.self] = newValue }
    }
    /// Isolated QA windows can slow the highlight to inspect in-flight frames.
    var pickerAnimationDuration: TimeInterval {
        get { self[PickerAnimationDurationKey.self] }
        set { self[PickerAnimationDurationKey.self] = newValue }
    }
}
