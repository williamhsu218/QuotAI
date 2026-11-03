import SwiftUI

struct ResetCreditsView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let snapshot: UsageSnapshot
    var maximumVisibleRows: Int? = nil

    private var visibleCredits: [ResetCredit] {
        if let maximumVisibleRows {
            return Array(snapshot.resetCredits.prefix(maximumVisibleRows))
        }
        return snapshot.resetCredits
    }

    private var undisclosedCount: Int {
        max(0, snapshot.availableResetCount - visibleCredits.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack(spacing: AppTheme.Spacing.small) {
                Text(L10n.text("reset.title", fallback: "Usage Resets"))
                    .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Spacer(minLength: AppTheme.Spacing.small)

                Text(resetCountLabel)
                    .font(.system(size: AppTheme.TypeSize.small, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(snapshot.availableResetCount)))
                    .animation(refreshAnimation, value: snapshot.availableResetCount)
                    .frame(minWidth: 20)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.resetAccent, in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                resetAccessibilityLabel
            )

            if resetDataUnavailable {
                Text(
                    L10n.text(
                        "reset.temporarily_unavailable",
                        fallback: "Temporarily unavailable"
                    )
                )
                .font(.system(size: AppTheme.TypeSize.caption))
                .foregroundStyle(AppTheme.secondaryText)
            } else if visibleCredits.isEmpty, snapshot.availableResetCount > 0 {
                Text(
                    L10n.text(
                        "reset.expiry_unavailable",
                        fallback: "Expiry details unavailable"
                    )
                )
                .font(.system(size: AppTheme.TypeSize.caption))
                .foregroundStyle(AppTheme.secondaryText)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 6, alignment: .leading),
                        GridItem(.flexible(), spacing: 6, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(visibleCredits) { credit in
                        resetCreditCell(credit)
                    }
                }
            }

            if undisclosedCount > 0 {
                Text("+\(undisclosedCount)")
                    .font(.system(size: AppTheme.TypeSize.small, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(AppTheme.Spacing.compact)
        .appCardSurface(cornerRadius: 10)
    }

    private var resetDataUnavailable: Bool {
        !snapshot.hasCurrentResetCreditData
            && snapshot.availableResetCount == 0
            && snapshot.resetCredits.isEmpty
    }

    private var resetCountLabel: String {
        if resetDataUnavailable { return "—" }
        return snapshot.availableResetCount.formatted()
    }

    private var resetAccessibilityLabel: String {
        if resetDataUnavailable {
            return L10n.text(
                "reset.accessibility_unavailable",
                fallback: "Usage Resets temporarily unavailable"
            )
        }
        return L10n.format(
            "reset.accessibility_format",
            fallback: "Usage Resets: %d",
            snapshot.availableResetCount
        )
    }

    private func resetCreditCell(_ credit: ResetCredit) -> some View {
        HStack(spacing: AppTheme.Spacing.xSmall) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.resetAccent)

            Text(DisplayDateFormatter.compactDateTime(credit.expiresAt))
                .font(.system(size: AppTheme.TypeSize.small, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.small)
        .padding(.vertical, 5)
        .background(
            AppTheme.resetAccent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.resetAccent.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DisplayDateFormatter.expiryText(for: credit.expiresAt))
    }

    private var refreshAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: AppTheme.Motion.refresh)
    }
}
