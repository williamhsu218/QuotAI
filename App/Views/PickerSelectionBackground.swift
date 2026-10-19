import SwiftUI

/// One persistent highlight in the picker's local coordinates. Matching frames
/// in window space is unstable when an NSPopover changes height on selection.
struct PickerSelectionBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pickerReduceMotionOverride) private var forceReduceMotion
    @Environment(\.pickerAnimationDuration) private var duration
    let selectedIndex: Int
    let count: Int
    var spacing: CGFloat = 2
    var cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let slots = max(1, count)
            let width = max(0, (geometry.size.width - CGFloat(slots - 1) * spacing) / CGFloat(slots))
            let index = min(max(0, selectedIndex), slots - 1)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.pickerSelectedBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppTheme.pickerSelectedBorder, lineWidth: 0.5)
                }
                .shadow(color: AppTheme.pickerSelectedShadow, radius: 2, y: 1)
                .frame(width: width, height: geometry.size.height)
                .offset(x: CGFloat(index) * (width + spacing))
                .animation(reduceMotion || forceReduceMotion ? nil : .easeInOut(duration: duration), value: index)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
