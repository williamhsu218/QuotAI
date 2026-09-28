import SwiftUI

struct QuotaRowView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let quota: QuotaWindow
    var compact = false
    /// The window's reset time has passed: the stored percentage belongs to
    /// the previous window, so it is shown muted with a pending label.
    var isExpired = false

    private var resetText: String {
        isExpired
            ? L10n.text("date.reset_passed", fallback: "Reset passed · waiting for new data")
            : DisplayDateFormatter.resetText(for: quota.resetsAt)
    }

    private var quotaPalette: QuotaPalette {
        AppTheme.quotaPalette(for: quota.remainingPercent)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            Text(quota.kind.displayName)
                .font(.system(size: compact ? AppTheme.TypeSize.cardTitle : 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(
                    width: compact ? (L10n.isSimplifiedChinese ? 50 : 58) : 66,
                    alignment: .leading
                )
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: compact ? AppTheme.Spacing.xSmall : 6) {
                HStack(spacing: AppTheme.Spacing.small) {
                    QuotaProgressBar(
                        value: quota.remainingPercent
                    )

                    percentageLabel
                }
                .opacity(isExpired ? 0.4 : 1)

                Text(resetText)
                    .font(.system(size: compact ? AppTheme.TypeSize.small : AppTheme.TypeSize.caption, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.format(
                "quota.accessibility_format",
                fallback: "%@, %d%% left, %@",
                quota.kind.displayName,
                quota.remainingPercent,
                resetText
            )
        )
    }

    @ViewBuilder
    private var percentageLabel: some View {
        if L10n.isSimplifiedChinese {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(L10n.text("quota.remaining_prefix", fallback: "剩余"))
                    .font(.system(size: compact ? AppTheme.TypeSize.small : AppTheme.TypeSize.caption, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                Text("\(quota.remainingPercent)")
                    .font(.system(size: compact ? AppTheme.TypeSize.body : 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quotaPalette.accent)
                    .contentTransition(.numericText(value: Double(quota.remainingPercent)))
                    .animation(refreshAnimation, value: quota.remainingPercent)
                Text("%")
                    .font(.system(size: compact ? AppTheme.TypeSize.small : AppTheme.TypeSize.caption, weight: .semibold, design: .rounded))
                    .foregroundStyle(quotaPalette.accent.opacity(0.85))
            }
            .fixedSize()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(quota.remainingPercent)")
                    .font(.system(size: compact ? AppTheme.TypeSize.body : 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quotaPalette.accent)
                    .contentTransition(.numericText(value: Double(quota.remainingPercent)))
                    .animation(refreshAnimation, value: quota.remainingPercent)
                Text("% left")
                    .font(.system(size: compact ? AppTheme.TypeSize.small : AppTheme.TypeSize.caption, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .fixedSize()
        }
    }

    private var refreshAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: AppTheme.Motion.refresh)
    }
}

struct QuotaProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let value: Int

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let totalHeight = proxy.size.height
            let fillWidth = max(0, totalWidth * CGFloat(value) / 100)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.track)

                Capsule()
                    .fill(AppTheme.quotaFillGradient(for: value))
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: fillWidth)
                    }

                ForEach(AppTheme.quotaScaleThresholds, id: \.self) { threshold in
                    let xPos = totalWidth * threshold
                    ZStack {
                        Rectangle()
                            .fill(AppTheme.quotaThresholdMarkerEdge)
                            .frame(width: 1.5, height: totalHeight)

                        Rectangle()
                            .fill(AppTheme.quotaThresholdMarkerHighlight)
                            .frame(width: 0.75, height: totalHeight)
                            .offset(x: 0.4)
                    }
                    .position(x: xPos, y: totalHeight / 2)
                }
            }
            .animation(refreshAnimation, value: value)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var refreshAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: AppTheme.Motion.refresh)
    }
}
