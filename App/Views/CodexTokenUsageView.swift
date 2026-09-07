import SwiftUI

struct CodexTokenUsageView: View {
    let snapshot: UsageSnapshot

    @State private var hoveredDay: ActivityDay? = nil

    private let weeksCount = 18
    private let cellSize: CGFloat = 11
    private let cellGap: CGFloat = 2.8
    private let cornerRadius: CGFloat = 2.2

    private var summary: AccountTokenUsageSummary? {
        snapshot.tokenUsageSummary
    }

    private var weeks: [ActivityWeek] {
        snapshot.activityWeeks(count: weeksCount)
    }

    private var maxTokens: Int64 {
        let bucketMax = snapshot.dailyUsageBuckets.map(\.tokens).max() ?? 0
        let summaryPeak = summary?.peakDailyTokens ?? 0
        return max(1, max(bucketMax, summaryPeak))
    }

    var body: some View {
        if !snapshot.dailyUsageBuckets.isEmpty || snapshot.tokenUsageSummary != nil {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                headerView

                infoRow

                matrixView

                legendRow
            }
            .padding(AppTheme.Spacing.compact)
            .appCardSurface(cornerRadius: 10)
        }
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.small) {
            Text(L10n.text("usage.title", fallback: "Token 活跃度"))
                .font(.system(size: AppTheme.TypeSize.cardTitle, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let streak = summary?.currentStreakDays, streak > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.orange)

                    Text(streakText(streak))
                        .font(.system(size: AppTheme.TypeSize.small, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.5))
                .fixedSize()
            }

            if let lifetime = summary?.formattedLifetimeTokens {
                HStack(spacing: 3) {
                    Text(L10n.format("usage.lifetime_format", fallback: "累计 %@", lifetime))
                        .font(.system(size: AppTheme.TypeSize.small, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(AppTheme.track, in: Capsule())
                .fixedSize()
            }
        }
    }

    private var infoRow: some View {
        HStack(spacing: 4) {
            if let day = hoveredDay {
                HStack(spacing: 4) {
                    Text(formattedDate(day))
                        .font(.system(size: AppTheme.TypeSize.caption, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)

                    if day.isToday {
                        Text(L10n.text("usage.today_tag", fallback: "今天"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AppTheme.cyan.opacity(0.12), in: Capsule())
                    }
                }

                Spacer()

                Text(formattedTokenText(day.tokens))
                    .font(.system(size: AppTheme.TypeSize.caption, weight: .semibold, design: .rounded))
                    .foregroundStyle(day.tokens > 0 ? AppTheme.primaryText : AppTheme.secondaryText)
                    .monospacedDigit()
            } else {
                Text(L10n.format("usage.grid_range_format", fallback: "近 %d 周活跃度", weeksCount))
                    .font(.system(size: AppTheme.TypeSize.caption))
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer()

                Text(L10n.text("usage.hover_hint", fallback: "悬停方格查看每日用量"))
                    .font(.system(size: AppTheme.TypeSize.small))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.75))
            }
        }
        .frame(height: 16)
    }

    private var matrixView: some View {
        HStack(alignment: .top, spacing: 5) {
            weekdayLabelsColumn

            HStack(spacing: cellGap) {
                ForEach(weeks) { week in
                    VStack(spacing: cellGap) {
                        ForEach(week.days) { day in
                            dayCell(day)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("usage.accessibility_grid", fallback: "Token 历史活跃度方框图"))
    }

    private var weekdayLabelsColumn: some View {
        VStack(spacing: cellGap) {
            Text(L10n.text("usage.weekday_mon", fallback: "一"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.65))
                .frame(width: 12, height: cellSize)

            Text("")
                .frame(width: 12, height: cellSize)

            Text(L10n.text("usage.weekday_wed", fallback: "三"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.65))
                .frame(width: 12, height: cellSize)

            Text("")
                .frame(width: 12, height: cellSize)

            Text(L10n.text("usage.weekday_fri", fallback: "五"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.65))
                .frame(width: 12, height: cellSize)

            Text("")
                .frame(width: 12, height: cellSize)

            Text("")
                .frame(width: 12, height: cellSize)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: ActivityDay) -> some View {
        if day.isFuture {
            Color.clear
                .frame(width: cellSize, height: cellSize)
        } else {
            let isHovered = hoveredDay?.id == day.id
            let level = levelForTokens(day.tokens)

            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(colorForLevel(level))
                .frame(width: cellSize, height: cellSize)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            isHovered
                                ? Color.white
                                : (day.isToday ? AppTheme.cyan.opacity(0.85) : (level == 0 ? Color.primary.opacity(0.04) : Color.clear)),
                            lineWidth: isHovered ? 1.2 : (day.isToday ? 1.0 : 0.5)
                        )
                )
                .scaleEffect(isHovered ? 1.25 : 1.0)
                .zIndex(isHovered ? 10 : 0)
                .animation(.easeInOut(duration: 0.10), value: isHovered)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredDay = day
                    } else if hoveredDay?.id == day.id {
                        hoveredDay = nil
                    }
                }
                .help(helpText(for: day))
        }
    }

    private var legendRow: some View {
        HStack(spacing: 3) {
            Spacer()

            Text(L10n.text("usage.legend_less", fallback: "少"))
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))

            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colorForLevel(level))
                    .frame(width: 8, height: 8)
            }

            Text(L10n.text("usage.legend_more", fallback: "多"))
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))
        }
        .padding(.top, 2)
    }

    private func levelForTokens(_ tokens: Int64) -> Int {
        guard tokens > 0, maxTokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(maxTokens)
        if ratio > 0.70 { return 4 }
        if ratio > 0.40 { return 3 }
        if ratio > 0.15 { return 2 }
        return 1
    }

    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 1:
            return AppTheme.cyan.opacity(0.32)
        case 2:
            return AppTheme.cyan.opacity(0.55)
        case 3:
            return AppTheme.cyan.opacity(0.78)
        case 4:
            return AppTheme.cyan
        default:
            return AppTheme.track
        }
    }

    private func formattedDate(_ day: ActivityDay) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = L10n.locale
        if L10n.isSimplifiedChinese {
            formatter.dateFormat = "M月d日 EEE"
        } else {
            formatter.dateFormat = "EEE, MMM d"
        }
        return formatter.string(from: day.date)
    }

    private func formattedExactTokens(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formattedTokenText(_ count: Int64) -> String {
        if count == 0 {
            return "0 tokens"
        }
        return "\(DailyUsageBucket.formatTokens(count)) (\(formattedExactTokens(count)))"
    }

    private func helpText(for day: ActivityDay) -> String {
        let dateStr = formattedDate(day)
        let todaySuffix = day.isToday ? " (\(L10n.text("usage.today_tag", fallback: "今天")))" : ""
        if day.tokens == 0 {
            return "\(dateStr)\(todaySuffix): 0 tokens"
        } else {
            return "\(dateStr)\(todaySuffix): \(formattedExactTokens(day.tokens)) tokens (\(day.formattedTokens))"
        }
    }

    private func streakText(_ streak: Int) -> String {
        let key = streak == 1 ? "usage.streak_single_format" : "usage.streak_format"
        let fallback = streak == 1 ? "%d day" : "%d days"
        return L10n.format(key, fallback: fallback, streak)
    }
}
